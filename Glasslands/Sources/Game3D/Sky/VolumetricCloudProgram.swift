//
//  VolumetricCloudProgram.swift
//  Glasslands
//
//  Created by . . on 10/5/25.
//
//  Metal SCNProgram wrapper for SkyVolumetricClouds.metal.
//
//  Clouds are rendered as ONE inside-out sphere using Metal (gl_vapour_*),
//  instead of hundreds of raymarched billboards.
//  Uniforms are streamed from VolCloudUniformsStore into the shader buffer.
//
//  If the Metal program cannot be constructed, fall back to a lightweight
//  shader-modifier using a precomputed equirect alpha mask (still one draw).
//

import SceneKit
import UIKit
import Metal

enum VolumetricCloudProgram {

    private static let vertexFnName = "gl_vapour_vertex"
    private static let fragmentFnName = "gl_vapour_fragment"

    @MainActor
    private static var program: SCNProgram? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("VolumetricCloudProgram: Metal device unavailable")
            return nil
        }

        guard let lib = loadLibrary(device: device) else {
            print("VolumetricCloudProgram: default Metal library unavailable")
            return nil
        }

        guard lib.makeFunction(name: vertexFnName) != nil else {
            print("VolumetricCloudProgram: missing Metal function \(vertexFnName)")
            return nil
        }

        guard lib.makeFunction(name: fragmentFnName) != nil else {
            print("VolumetricCloudProgram: missing Metal function \(fragmentFnName)")
            return nil
        }

        let p = SCNProgram()
        p.library = lib
        p.vertexFunctionName = vertexFnName
        p.fragmentFunctionName = fragmentFnName
        p.delegate = ProgramDelegate.shared

        let bindUniforms: SCNBufferBindingBlock = { bufferStream, _, _, _ in
            var u = VolCloudUniformsStore.shared.snapshot()
            withUnsafeBytes(of: &u) { raw in
                guard let base = raw.baseAddress else { return }
                bufferStream.writeBytes(base, count: raw.count)
            }
        }

        p.handleBinding(ofBufferNamed: "U", frequency: .perFrame, handler: bindUniforms)
        p.handleBinding(ofBufferNamed: "uCloudsGL", frequency: .perFrame, handler: bindUniforms)

        return p
    }()

    @MainActor
    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() { return lib }
        return try? device.makeDefaultLibrary(bundle: .main)
    }

    // MARK: - Fallback mask (one draw, opaque)

    @MainActor
    private static var fallbackMaskCache: UIImage?

    @MainActor
    private static func fallbackCloudMask() -> UIImage {
        if let img = fallbackMaskCache { return img }

        let opts = VolumetricCloudCoverage.Options(
            width: 384,
            height: 192,
            coverage: 0.52,
            seed: 0xC10D5,
            zenithCapScale: 0.25
        )

        let img = VolumetricCloudCoverage.makeImage(opts)
        fallbackMaskCache = img
        return img
    }

    @MainActor
    private static func makeFallbackMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        // Render as an opaque background pass.
        m.blendMode = .replace
        m.transparencyMode = .aOne

        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        m.isLitPerPixel = false

        let maskImage = fallbackCloudMask()
        let maskProp = SCNMaterialProperty(contents: maskImage)
        maskProp.wrapS = .repeat
        maskProp.wrapT = .clamp
        maskProp.minificationFilter = .linear
        maskProp.magnificationFilter = .linear
        maskProp.mipFilter = .linear

        let frag = """
        #pragma arguments
        sampler2D cloudMask;
        float3 sunDirWorld;
        float3 sunTint;

        #pragma declaration
        inline float3 safeNormalize(float3 v) {
            float l = length(v);
            return (l > 1.0e-6) ? (v / l) : float3(0.0, 1.0, 0.0);
        }
        static const float PI = 3.14159265358979323846;

        inline float2 equirectUV(float3 dir) {
            dir = safeNormalize(dir);
            float lon = atan2(dir.x, dir.z);
            float lat = asin(clamp(dir.y, -1.0, 1.0));
            float u = lon / (2.0 * PI) + 0.5;
            float v = 0.5 - (lat / PI);
            return float2(u, v);
        }

        #pragma body
        float3 V = safeNormalize(_surface.position);
        float3 S = safeNormalize(sunDirWorld);
        float3 tint = clamp(sunTint, 0.0, 10.0);

        // Sky base (cheap gradient + sun highlight, same palette as Metal path).
        float tSky = clamp(V.y * 0.5 + 0.5, 0.0, 1.0);
        float3 horizon = float3(0.55, 0.75, 0.95);
        float3 zenith  = float3(0.14, 0.34, 0.88);
        float3 sky = mix(horizon, zenith, tSky);

        float s = clamp(dot(V, S), 0.0, 1.0);
        sky += float3(1.0, 0.95, 0.85) * pow(s, 350.0) * 1.2;

        sky *= tint;

        float exposure = 0.85;
        sky = 1.0 - exp(-sky * exposure);

        // Cloud mask sample (alpha drives coverage).
        float2 uv = equirectUV(V);
        float a = texture2D(cloudMask, uv).a;

        // Keep it subtle; avoid overcast sheets.
        a = smoothstep(0.35, 0.85, a) * 0.65;

        float3 col = mix(sky, float3(1.0), a);
        _output.color = float4(clamp(col, 0.0, 1.0), 1.0);
        """

        m.shaderModifiers = [.fragment: frag]

        m.setValue(maskProp, forKey: "cloudMask")
        m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: "sunDirWorld")
        m.setValue(NSValue(scnVector3: SCNVector3(1.0, 0.97, 0.92)), forKey: "sunTint")

        return m
    }

    @MainActor
    static func makeMaterial() -> SCNMaterial {
        guard let p = program else {
            return makeFallbackMaterial()
        }

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = false
        m.cullMode = .front

        // Opaque pass (cheapest) — shader returns alpha=1.
        m.blendMode = .replace
        m.transparencyMode = .aOne

        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false

        m.isLitPerPixel = false
        m.program = p

        return m
    }

    private final class ProgramDelegate: NSObject, SCNProgramDelegate {
        static let shared = ProgramDelegate()

        func program(_ program: SCNProgram, handleError error: Error) {
            print("VolumetricCloudProgram error: \(error.localizedDescription)")
        }
    }
}
