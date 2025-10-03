//
//  SceneKitHelpers+Sky.swift
//  Glasslands
//
//  Created by . . on 10/3/25.
//
//  Seam-free equirectangular sky with gravity-biased cumulus.
//  No GameplayKit; pure Swift Perlin FBM for reliable, visible clouds.
//

import UIKit
import simd

enum SkyGen {
    static func skyWithCloudsImage(
        width: Int = 2048,
        height: Int = 1024,
        coverage: Float = 0.30,     // lower → more/larger clouds
        thickness: Float = 0.50,    // higher → softer edges
        seed: Int32 = 424242,
        sunAzimuthDeg: Float = 40,
        sunElevationDeg: Float = 65
    ) -> UIImage {
        let W = max(64, width)
        let H = max(32, height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = W * 4
        var pixels = [UInt8](repeating: 0, count: W * H * 4)

        @inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }
        @inline(__always) func mix3(_ a: simd_float3, _ b: simd_float3, _ t: Float) -> simd_float3 { a + (b - a) * t }
        @inline(__always) func toByte(_ f: Float) -> UInt8 { UInt8(clampf(f, 0, 1) * 255.0) }
        @inline(__always) func smooth01(_ x: Float) -> Float { let t = clampf(x, 0, 1); return t * t * (3 - 2 * t) }
        @inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let d = e1 - e0
            if abs(d) < .ulpOfOne { return x < e0 ? 0 : 1 }
            return smooth01((x - e0) / d)
        }

        // Sun direction (world space) for silver lining.
        let deg = Float.pi / 180
        let sunAz = sunAzimuthDeg * deg
        let sunEl = sunElevationDeg * deg
        let sunDir = simd_normalize(simd_float3(
            sinf(sunAz) * cosf(sunEl),
            sinf(sunEl),
            cosf(sunAz) * cosf(sunEl)
        ))

        // Sky gradient colours (top → mid → bottom)
        let top = simd_float3(0.50, 0.74, 0.92)
        let mid = simd_float3(0.70, 0.86, 0.95)
        let bot = simd_float3(0.86, 0.93, 0.98)

        // Perlin noise (3D), seam-free across u because we sample on the unit sphere.
        struct Perlin {
            static let p: [Int] = {
                let base: [Int] = [
                    151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
                    140,36,103,30,69,142,8,99,37,240,21,10,23,190, 6,148,
                    247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
                    57,177,33,88,237,149,56,87,174,20,125,136,171,168, 68,175,
                    74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
                    60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
                    65,25,63,161, 1,216,80,73,209,76,132,187,208,89,18,169,
                    200,196,135,130,116,188,159,86,164,100,109,198,173,186, 3,64,
                    52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
                    207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
                    119,248,152, 2,44,154,163,70,221,153,101,155,167, 43,172,9,
                    129,22,39,253, 19,98,108,110,79,113,224,232,178,185,112,104,
                    218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
                    81,51,145,235,249,14,239,107,49,192,214, 31,181,199,106,157,
                    184,84,204,176,115,121,50,45,127,  4,150,254,138,236,205,93,
                    222,114, 67,29,24,72,243,141,128,195,78,66,215,61,156,180
                ]
                return base + base
            }()

            @inline(__always) static func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
            @inline(__always) static func lerp(_ t: Float, _ a: Float, _ b: Float) -> Float { a + t * (b - a) }
            @inline(__always) static func grad(_ h: Int, _ x: Float, _ y: Float, _ z: Float) -> Float {
                let hh = h & 15
                let u = hh < 8 ? x : y
                let v = hh < 4 ? y : (hh == 12 || hh == 14 ? x : z)
                let r = ((hh & 1) == 0 ? u : -u) + ((hh & 2) == 0 ? v : -v)
                return r
            }
            // Returns [-1, +1]
            static func noise(_ x: Float, _ y: Float, _ z: Float) -> Float {
                let X = Int(floor(x)) & 255
                let Y = Int(floor(y)) & 255
                let Z = Int(floor(z)) & 255
                let xf = x - floor(x)
                let yf = y - floor(y)
                let zf = z - floor(z)
                let u = fade(xf), v = fade(yf), w = fade(zf)
                let A  = p[X] + Y, AA = p[A] + Z, AB = p[A + 1] + Z
                let B  = p[X + 1] + Y, BA = p[B] + Z, BB = p[B + 1] + Z
                let res =
                    lerp(w,
                        lerp(v,
                            lerp(u, grad(p[AA],   xf,   yf,   zf),
                                     grad(p[BA],   xf-1, yf,   zf)),
                            lerp(u, grad(p[AB],   xf,   yf-1, zf),
                                     grad(p[BB],   xf-1, yf-1, zf))
                        ),
                        lerp(v,
                            lerp(u, grad(p[AA+1], xf,   yf,   zf-1),
                                     grad(p[BA+1], xf-1, yf,   zf-1)),
                            lerp(u, grad(p[AB+1], xf,   yf-1, zf-1),
                                     grad(p[BB+1], xf-1, yf-1, zf-1))
                        )
                    )
                return res
            }
            // Fractal Brownian Motion in 3D (sum of octaves). Output ~= [-1, +1].
            static func fbm(_ x: Float, _ y: Float, _ z: Float, octaves: Int = 5) -> Float {
                var amp: Float = 0.5
                var freq: Float = 1.0
                var sum: Float = 0.0
                var norm: Float = 0.0
                for _ in 0..<octaves {
                    sum += amp * noise(x * freq, y * freq, z * freq)
                    norm += amp
                    amp *= 0.5
                    freq *= 2.0
                }
                return sum / max(0.0001, norm)
            }
        }

        // Seed offsets so different seeds give different skies.
        let sx = Float((seed &+ 101) % 997)
        let sy = Float((seed &+ 202) % 991)
        let sz = Float((seed &+ 303) % 983)

        // Feature sizes
        let fieldScale: Float = 3.0     // larger → smaller cloud features
        let warpScale:  Float = 0.8
        let warpAmp:    Float = 0.35

        for y in 0..<H {
            // v=0 top (zenith), v=1 bottom (nadir)
            let v = (Float(y) + 0.5) / Float(H)
            let phi = v * Float.pi
            let upY = cosf(phi) // 1 at zenith → -1 at nadir

            // Sky gradient (seamless)
            var sky = mix3(bot, mid, clampf((upY + 0.20) * 0.80, 0, 1))
            sky = mix3(sky, top, clampf((upY + 1.00) * 0.50, 0, 1))

            for x in 0..<W {
                let u = (Float(x) + 0.5) / Float(W)
                let theta = u * 2 * Float.pi

                // Direction on unit sphere (seam-free across u=0/1)
                let dir = simd_float3(cosf(theta) * sinf(phi),
                                      upY,
                                      sinf(theta) * sinf(phi))

                // Domain warp (low-freq 3D Perlin) in world space
                let wx = Perlin.fbm(dir.x * warpScale + sx, dir.y * warpScale + sy, dir.z * warpScale + sz, octaves: 3)
                let wy = Perlin.fbm(dir.x * warpScale + sy, dir.y * warpScale + sz, dir.z * warpScale + sx, octaves: 3)
                let wz = Perlin.fbm(dir.x * warpScale + sz, dir.y * warpScale + sx, dir.z * warpScale + sy, octaves: 3)
                let warped = simd_float3(dir.x + warpAmp * wx, dir.y + warpAmp * wy, dir.z + warpAmp * wz)

                // FBM field for clouds
                var n = Perlin.fbm(warped.x * fieldScale + sx,
                                   warped.y * fieldScale + sy,
                                   warped.z * fieldScale + sz,
                                   octaves: 5)            // ≈ [-1, +1]
                // Map to [0,1] and sharpen a touch
                var billow = 0.5 * (n + 1.0)
                billow = pow(billow, 1.20)

                // Gravity bias: heavier bottoms, lighter tops
                let baseThr = clampf(coverage, 0, 1)
                let thick = max(0.001, thickness)
                let grav = (1 - clampf(upY, 0, 1))   // 0 at zenith → 1 near horizon
                let bias = grav * 0.25
                var a = smoothstep(baseThr - bias, baseThr - bias + thick, billow)

                // Flatten undersides slightly
                let flat = smoothstep(-0.15, 0.35, -dir.y)
                a = a * (0.90 + 0.10 * flat)

                // Horizon fade
                a *= clampf((upY + 0.20) * 1.4, 0, 1)

                // Silver lining towards the sun
                let sdot = max(0, simd_dot(simd_normalize(dir), sunDir))
                let silver = pow(sdot, 10) * 0.6 + pow(sdot, 28) * 0.4
                let cloud = simd_float3(repeating: 0.84 + 0.30 * silver)

                let rgb = mix3(sky, cloud, a)

                let idx = y * bpr + x * 4
                pixels[idx + 0] = toByte(rgb.x)
                pixels[idx + 1] = toByte(rgb.y)
                pixels[idx + 2] = toByte(rgb.z)
                pixels[idx + 3] = 255
            }
        }

        var cgImg: CGImage?
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            if let ctx = CGContext(data: base,
                                   width: W, height: H,
                                   bitsPerComponent: 8, bytesPerRow: bpr,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                cgImg = ctx.makeImage()
            }
        }
        if let cg = cgImg { return UIImage(cgImage: cg, scale: 1, orientation: .up) }
        return UIImage()
    }
}
