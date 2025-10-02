//
//  CloudDome.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Seam-free white fluffy clouds on an inside-out skydome.
//  – Samples noise in direction space (no UVs → no seams)
//  – Uses FRAGMENT stage and writes _output.color.a
//  – Draws LAST with depth-test ON, depth-write OFF (can’t affect terrain)
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
        mat.cullMode = .front            // render inside of the dome
        mat.writesToDepthBuffer = false  // clouds never write depth
        mat.readsFromDepthBuffer = false // …or read it (drawn under everything)
        mat.shaderModifiers = [.surface: surface]   // rock-solid in SceneKit

        // Tunables
        mat.setValue(0.40, forKey: "coverage")            // 0…1; higher = more fill
        mat.setValue(0.25, forKey: "thickness")           // edge softness
        mat.setValue(2.2,  forKey: "detailScale")         // feature size
        mat.setValue(SCNVector3(0.06, 0.0, 0.02), forKey: "windDir")
        mat.setValue(0.005, forKey: "windSpeed")          // units/s (uses u_time)
        mat.setValue(1.0,   forKey: "brightness")
        mat.setValue(Float(seed & 0xFFFF), forKey: "seed")
        mat.setValue(SCNVector3(0,1,0), forKey: "sunDir") // replaced in buildSky()

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000    // draw first; terrain & UI draw over it
        return (node, mat)
    }

    // SURFACE stage: uses _surface.* and sets _surface.opacity (reliable on iOS)
    private static let surface = """
    #pragma arguments
    float  coverage;
    float  thickness;
    float  detailScale;
    float3 windDir;
    float  windSpeed;
    float3 sunDir;
    float  brightness;
    float  seed;

    #pragma transparent
    #pragma body

    float fractf(float x) { return x - floor(x); }
    float hash1(float n)  { return fractf(sin(n) * 43758.5453123); }
    float hash3(float3 p) { return hash1(dot(p, float3(127.1,311.7,74.7))); }

    float noise3(float3 x){
        float3 p=floor(x), f=fract(x); f=f*f*(3.0-2.0*f);
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
        for (int i=0;i<5;i++){ v+=a*noise3(p); p*=2.0; a*=0.5; }
        return v;
    }

    // Inside-out dome → use the inverted surface normal
    float3 dir = -normalize(_surface.normal);
    float  t   = windSpeed * u_time;
    float3 w   = (length(windDir)>0.0)? normalize(windDir) : float3(1,0,0);

    float3 p = dir * max(0.5, detailScale) + w * t;
    float warp = noise3(p * 0.75 + 13.37);
    float n    = fbm(p + warp * 0.75);
    n = pow(n, 1.45);

    float cov   = clamp(coverage, 0.0, 1.0);
    float thick = max(0.001, thickness);
    float alpha = smoothstep(cov, cov + thick, n);

    // Fade to horizon so we never see a hard ring
    float horizon = clamp((dir.y + 0.20) * 1.4, 0.0, 1.0);
    alpha *= horizon;

    // Gentle silver lining facing the sun
    float  sunDot   = max(0.0, dot(dir, normalize(sunDir)));
    float  silver   = pow(sunDot, 10.0) * 0.6 + pow(sunDot, 28.0) * 0.4;
    float  b        = max(0.0, brightness);
    float3 cloudCol = float3(1.0) * (0.84 + 0.30 * silver) * (0.75 + 0.25*b);

    _surface.emission.rgb = mix(_surface.emission.rgb, cloudCol, alpha);
    _surface.opacity      = alpha;
    """
}
