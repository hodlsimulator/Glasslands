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
        sphere.segmentCount = 128

        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.black
        mat.emission.contents = UIColor.white
        mat.emission.intensity = 1.0
        mat.blendMode = .alpha
        mat.transparencyMode = .aOne
        mat.isDoubleSided = false
        mat.cullMode = .front               // render inside faces only
        mat.writesToDepthBuffer = false     // never occludes world
        mat.readsFromDepthBuffer = false

        // Shader draws the blue sky + clouds together (no cubemap needed).
        mat.shaderModifiers = [.surface: surface]

        // Tunables
        mat.setValue(0.45,                      forKey: "coverage")
        mat.setValue(0.24,                      forKey: "thickness")
        mat.setValue(1.8,                       forKey: "detailScale")
        mat.setValue(SCNVector3(0.04, 0.0, 0.02), forKey: "windDir")
        mat.setValue(0.005,                     forKey: "windSpeed")
        mat.setValue(1.0,                       forKey: "brightness")
        mat.setValue(Float(seed & 0xFFFF),      forKey: "seed")
        mat.setValue(SCNVector3(0,  1, 0),      forKey: "sunDir")
        mat.setValue(SCNVector3(0, -1, 0),      forKey: "gravityDir")

        // Sky colours (top → mid → bottom)
        mat.setValue(SCNVector3(0.50, 0.74, 0.92), forKey: "skyTop")
        mat.setValue(SCNVector3(0.70, 0.86, 0.95), forKey: "skyMid")
        mat.setValue(SCNVector3(0.86, 0.93, 0.98), forKey: "skyBot")

        let node = SCNNode(geometry: sphere)
        node.name = "CloudDome"
        node.renderingOrder = -10_000
        return (node, mat)
    }

    // World-anchored cumulus with gravity bias; also renders the blue sky.
    private static let surface = """
    #pragma arguments
    float coverage, thickness, detailScale, windSpeed, brightness, seed;
    float3 windDir, sunDir, gravityDir;
    float3 skyTop, skyMid, skyBot;
    #pragma body

    float fractf(float x){ return x - floor(x); }
    float hash1(float n){ return fractf(sin(n) * 43758.5453123); }
    float hash3(float3 p){ return hash1(dot(p, float3(127.1,311.7,74.7))); }

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
        for (int i=0;i<5;i++){ v+=a*noise3(p); p*=2.0; a*=0.5; }
        return v;
    }

    // On a skydome, the outward normal is the WORLD direction from the centre.
    float3 dirWorld = normalize(_surface.normal);

    // Base sky gradient (replaces cubemap, so no seams).
    float3 up = normalize(-gravityDir);
    float y = clamp(dot(dirWorld, up), -1.0, 1.0);
    float t1 = clamp((y + 0.20) * 0.80, 0.0, 1.0);
    float t0 = clamp((y + 1.00) * 0.50, 0.0, 1.0);
    float3 skyCol = mix(skyBot, skyMid, t1);
    skyCol = mix(skyCol, skyTop, t0);

    // WORLD-space cloud field (vertical squashing for “puff” feel)
    float t = windSpeed * u_time;
    float3 wind = (length(windDir)>0.0)? normalize(windDir) : float3(1,0,0);
    float s = max(0.25, detailScale);
    float3 p = float3(dirWorld.x, dirWorld.y*0.55, dirWorld.z) * s + wind * t;

    float warp = noise3(p*0.70 + 13.37) * 0.85;
    float n = pow(fbm(p + warp), 1.30);

    // Gravity bias: heavier bottoms, lighter tops
    float base = clamp(coverage, 0.0, 1.0);
    float thick = max(0.001, thickness);
    float grav = (1.0 - clamp(y, 0.0, 1.0));
    float bias = grav * 0.22;
    float a = smoothstep(base - bias, base - bias + thick, n);

    // Flatter undersides
    float flat = smoothstep(-0.15, 0.35, -dirWorld.y);
    a = mix(a, a*0.92 + 0.08, flat);

    // Horizon fade
    float horizon = clamp((y + 0.20) * 1.4, 0.0, 1.0);
    a *= horizon;

    // Silver lining
    float sunDot = max(0.0, dot(dirWorld, normalize(sunDir)));
    float silver = pow(sunDot, 10.0) * 0.6 + pow(sunDot, 28.0) * 0.4;
    float b = max(0.0, brightness);
    float3 cloudCol = float3(1.0) * (0.84 + 0.30 * silver) * (0.75 + 0.25*b);

    float3 col = mix(skyCol, cloudCol, a);

    _surface.emission.rgb = col;
    _surface.opacity = 1.0; // fully opaque dome (depth writes are off)
    """
}
