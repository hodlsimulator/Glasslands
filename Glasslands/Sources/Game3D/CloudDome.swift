//
//  CloudDome.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  World-anchored cumulus on an inside-out skydome.
//  – Samples noise in WORLD space (doesn't lock to the camera)
//  – Gravity shaping makes bottoms fuller/flatter than tops
//  – Drawn under everything: depth test ON, depth write OFF
//

import SceneKit
import simd
import UIKit

enum CloudDome {
    static func make(radius: CGFloat, seed: UInt32 = 0x9E3779B9) -> (node: SCNNode, material: SCNMaterial) {
        let sphere = SCNSphere(radius: radius)
        sphere.isGeodesic = true
        sphere.segmentCount = 96

        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.clear
        mat.emission.contents = UIColor.white
        mat.emission.intensity = 1.0
        mat.blendMode = .alpha
        mat.transparencyMode = .aOne
        mat.isDoubleSided = false
        mat.cullMode = .front                  // render inside of the sphere
        mat.writesToDepthBuffer = false        // sky never writes depth
        mat.readsFromDepthBuffer = false       // and doesn't need to read it

        // Shader (SURFACE stage for iOS reliability)
        mat.shaderModifiers = [.surface: surface]

        // Tunables (can be tweaked live via material.setValue)
        mat.setValue(0.42,                      forKey: "coverage")     // 0…1 (higher = more filled)
        mat.setValue(0.22,                      forKey: "thickness")    // edge softness
        mat.setValue(2.2,                       forKey: "detailScale")  // feature size
        mat.setValue(SCNVector3(0.04, 0.0, 0.02), forKey: "windDir")
        mat.setValue(0.006,                     forKey: "windSpeed")    // units/s (uses u_time)
        mat.setValue(1.0,                       forKey: "brightness")
        mat.setValue(Float(seed & 0xFFFF),      forKey: "seed")
        mat.setValue(SCNVector3(0,  1, 0),      forKey: "sunDir")       // updated in applySunDirection(...)
        mat.setValue(SCNVector3(0, -1, 0),      forKey: "gravityDir")   // -Y = gravity

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000           // draw first; terrain & UI draw over it
        return (node, mat)
    }

    // SURFACE shader modifier: world-anchored, gravity-shaped cumulus
    private static let surface = """
    #pragma arguments
    float coverage;
    float thickness;
    float detailScale;
    float3 windDir;
    float windSpeed;
    float3 sunDir;
    float brightness;
    float seed;
    float3 gravityDir;
    #pragma transparent
    #pragma body

    float fractf(float x) { return x - floor(x); }
    float hash1(float n) { return fractf(sin(n) * 43758.5453123); }
    float hash3(float3 p) { return hash1(dot(p, float3(127.1,311.7,74.7))); }

    float noise3(float3 x){
        float3 p=floor(x), f=fract(x);
        f=f*f*(3.0-2.0*f);
        float3 S=float3(seed);
        float n000=hash3(p+float3(0,0,0)+S), n100=hash3(p+float3(1,0,0)+S);
        float n010=hash3(p+float3(0,1,0)+S), n110=hash3(p+float3(1,1,0)+S);
        float n001=hash3(p+float3(0,0,1)+S), n101=hash3(p+float3(1,0,1)+S);
        float n011=hash3(p+float3(0,1,1)+S), n111=hash3(p+float3(1,1,1)+S);
        float nx00=mix(n000,n100,f.x), nx10=mix(n010,n110,f.x);
        float nx01=mix(n001,n101,f.x), nx11=mix(n011,n111,f.x);
        float nxy0=mix(nx00,nx10,f.y), nxy1=mix(nx01,nx11,f.y);
        return mix(nxy0,nxy1,f.z);
    }

    float fbm(float3 p){
        float v=0.0, a=0.5;
        for (int i=0;i<5;i++){
            v+=a*noise3(p);
            p*=2.0;
            a*=0.5;
        }
        return v;
    }

    // Convert view-space surface normal to WORLD-space direction:
    // this is the key fix so clouds do not lock to the camera.
    float3 nView = normalize(_surface.normal);
    float3 dirWorld = normalize((u_inverseViewTransform * float4(nView, 0.0)).xyz);

    // World up points opposite gravity.
    float3 up = normalize(-gravityDir);
    float y = clamp(dot(dirWorld, up), -1.0, 1.0);  // -1..1

    // 3D noise sample position (anisotropic: squashed vertically)
    float t = windSpeed * u_time;
    float3 wind = (length(windDir)>0.0)? normalize(windDir) : float3(1,0,0);
    float s = max(0.5, detailScale);
    float3 p = float3(dirWorld.x, dirWorld.y*0.55, dirWorld.z) * s + wind * t;

    // Gentle domain warp → puffier shapes
    float warp = noise3(p*0.70 + 13.37) * 0.85;

    // Billowy FBM with mild sharpening
    float n = fbm(p + warp);
    n = pow(n, 1.35);

    // Gravity bias: denser lower parts, lighter tops (bottoms look heavier/flatter)
    float base = clamp(coverage, 0.0, 1.0);
    float thick = max(0.001, thickness);
    float grav = (1.0 - clamp(y, 0.0, 1.0));   // 0 at zenith → 1 near horizon
    float bias = grav * 0.22;                  // how much the base slumps
    float alpha = smoothstep(base - bias, base - bias + thick, n);

    // Flatten undersides a touch for that cumulus “flat base” look
    float flatness = smoothstep(-0.15, 0.35, -dirWorld.y);
    alpha = mix(alpha, alpha*0.92 + 0.08, flatness);

    // Fade to horizon so there's never a hard ring
    float horizon = clamp((y + 0.20) * 1.4, 0.0, 1.0);
    alpha *= horizon;

    // Silver lining facing the sun (WORLD space)
    float sunDot = max(0.0, dot(dirWorld, normalize(sunDir)));
    float silver = pow(sunDot, 10.0) * 0.6 + pow(sunDot, 28.0) * 0.4;

    float b = max(0.0, brightness);
    float3 cloudCol = float3(1.0) * (0.84 + 0.30 * silver) * (0.75 + 0.25*b);

    _surface.emission.rgb = mix(_surface.emission.rgb, cloudCol, alpha);
    _surface.opacity = alpha;
    """
}
