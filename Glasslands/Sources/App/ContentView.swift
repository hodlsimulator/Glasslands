//
//  ContentView.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//
// Glasslands/Sources/App/ContentView.swift
// 3D first-person SceneKit port (fixed camera selection + correct tiling).
// Uses our NoiseFields/BiomeRecipe/TileClassifier/WorldContext.

import SwiftUI
import SceneKit
import GameplayKit
import Combine
import simd
import UIKit
import GameKit

// MARK: - ViewModel

final class GameViewModel: ObservableObject {
    @Published var seedCharm: String = SaveStore.shared.lastSeedCharm ?? "RAIN_FOX_PEAKS"
    @Published var score: Int = 0
    @Published var isPaused: Bool = false

    let biomeService = BiomeSynthesisService()
    let imageService = ImageCreatorService()

    func recipe() -> BiomeRecipe {
        let r = biomeService.recipe(for: seedCharm)
        SaveStore.shared.lastSeedCharm = seedCharm
        return r
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = GameViewModel()
    @State private var engine: FirstPersonEngine?
    @State private var lastSnapshot: UIImage?

    private func rebuildEngine() {
        engine?.apply(recipe: vm.recipe())
    }

    var body: some View {
        ZStack {
            Scene3DView(
                recipe: vm.recipe(),
                isPaused: vm.isPaused,
                onScore: { vm.score = $0 },
                onReady: { eng in
                    self.engine = eng
                }
            )
            .ignoresSafeArea()

            HUDOverlay(
                seedCharm: $vm.seedCharm,
                score: vm.score,
                isPaused: $vm.isPaused,
                onApplySeed: { rebuildEngine() },
                onSavePostcard: {
                    guard let img = engine?.snapshot() else { return }
                    Task {
                        do {
                            let palette = AppColours.uiColors(from: vm.recipe().paletteHex)
                            let postcard = try await vm.imageService.generatePostcard(
                                from: img,
                                title: vm.seedCharm,
                                palette: palette
                            )
                            try await PhotoSaver.saveImageToPhotos(postcard)
                            lastSnapshot = postcard
                        } catch {
                            print("Postcard save failed:", error)
                        }
                    }
                },
                onShowLeaderboards: {
                    // Don’t crash or throw scary errors if GC isn’t enabled for this bundle.
                    if GKLocalPlayer.local.isAuthenticated {
                        GameCenterHelper.shared.presentLeaderboards()
                    } else {
                        GKLocalPlayer.local.authenticateHandler = { vc, error in
                            if let error { print("Game Center auth error:", error.localizedDescription) }
                            // Silently ignore in Release if unrecognised; user can re-try from HUD.
                        }
                    }
                }
            )
            .padding(.top, 8)
        }
    }
}

// MARK: - SceneKit wrapper

struct Scene3DView: UIViewRepresentable {
    let recipe: BiomeRecipe
    var isPaused: Bool
    var onScore: (Int) -> Void
    var onReady: (FirstPersonEngine) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.backgroundColor = .black

        let engine = FirstPersonEngine(onScore: onScore)
        engine.attach(to: view, recipe: recipe)
        engine.setPaused(isPaused)
        context.coordinator.engine = engine
        onReady(engine)

        // Gestures: left = move, right = look
        let leftPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onLeftPan(_:)))
        let rightPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onRightPan(_:)))
        leftPan.cancelsTouchesInView = false
        rightPan.cancelsTouchesInView = false
        view.addGestureRecognizer(leftPan)
        view.addGestureRecognizer(rightPan)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.engine?.setPaused(isPaused)
        context.coordinator.engine?.apply(recipe: recipe) // no-op if identical
    }

    final class Coordinator: NSObject {
        weak var engine: FirstPersonEngine?

        @objc func onLeftPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            let isLeft = p.x < view.bounds.midX
            if !isLeft {
                if g.state == .ended || g.state == .cancelled { engine?.setMoveInput(.zero) }
                return
            }
            switch g.state {
            case .began, .changed:
                let v = g.translation(in: view)
                let radius: CGFloat = 80
                let dx = max(-radius, min(radius, v.x))
                let dy = max(-radius, min(radius, v.y))
                let len = max(1, sqrt(dx*dx + dy*dy))
                let nx = Float(dx / len)
                let ny = Float(dy / len)
                engine?.setMoveInput(SIMD2<Float>(nx, -ny) * min(1, Float(len / radius)))
            default:
                engine?.setMoveInput(.zero)
            }
        }

        @objc func onRightPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            let p = g.location(in: view)
            let isRight = p.x >= view.bounds.midX
            if !isRight { return }
            switch g.state {
            case .began, .changed:
                let v = g.translation(in: view)
                let yawDeltaDeg: Float = Float(v.x) * 0.12
                let pitchDeltaDeg: Float = Float(-v.y) * 0.10
                engine?.addLook(yawDegrees: yawDeltaDeg, pitchDegrees: pitchDeltaDeg)
                g.setTranslation(.zero, in: view)
            default:
                break
            }
        }
    }
}

// MARK: - Engine

final class FirstPersonEngine: NSObject, SCNSceneRendererDelegate {
    struct Config {
        let tileSize: Float = 2.0        // metres per tile
        let heightScale: Float = 18.0    // metres at height=1.0
        let chunkTiles = IVec2(48, 48)   // tiles per chunk
        let preloadRadius: Int = 2       // chunk radius
        let moveSpeed: Float = 6.0       // m/s
        let eyeHeight: Float = 1.62

        // Expose counts to tests without reaching into IVec2 internals
        var tilesX: Int { chunkTiles.x }
        var tilesZ: Int { chunkTiles.y }
    }

    private let cfg = Config()
    private var scene = SCNScene()
    private weak var scnView: SCNView?
    private var noise: NoiseFields!
    private var recipe: BiomeRecipe!
    private var chunker: ChunkStreamer3D!
    private var beacons = Set<SCNNode>()
    private var beaconCounter = 0
    private var onScore: (Int) -> Void

    // Camera rig
    private let yawNode = SCNNode()
    private let pitchNode = SCNNode()
    private let camNode = SCNNode()

    // Input
    private var moveInput = SIMD2<Float>(repeating: 0) // x=strafe, y=forward
    private var yaw: Float = 0
    private var pitch: Float = 0

    // Timing
    private var lastTime: TimeInterval = 0

    init(onScore: @escaping (Int) -> Void) {
        self.onScore = onScore
        super.init()
    }

    func attach(to view: SCNView, recipe: BiomeRecipe) {
        scnView = view
        view.scene = scene
        view.delegate = self
        view.isPlaying = true
        buildCommonLighting()
        apply(recipe: recipe, force: true)
    }

    func setPaused(_ paused: Bool) {
        scnView?.isPlaying = !paused
    }

    func setMoveInput(_ v: SIMD2<Float>) {
        moveInput = v
    }

    func addLook(yawDegrees: Float, pitchDegrees: Float) {
        yaw += yawDegrees * Float.pi / 180
        pitch += pitchDegrees * Float.pi / 180
        pitch = max(-Float.pi/2 + 0.01, min(Float.pi/2 - 0.01, pitch))
        updateRigOrientation()
    }

    func apply(recipe: BiomeRecipe, force: Bool = false) {
        if !force, let existing = self.recipe, existing == recipe { return }
        self.recipe = recipe
        self.noise = NoiseFields(recipe: recipe)
        resetWorld()
    }

    func snapshot() -> UIImage? { scnView?.snapshot() }

    // MARK: SCNSceneRendererDelegate

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt: Float = lastTime == 0 ? 1.0/60.0 : Float(min(1.0/30.0, max(0.0, time - lastTime)))
        lastTime = time

        // Move in XZ plane based on yaw
        let forward = SIMD3<Float>(-sinf(yaw), 0, -cosf(yaw))
        let right   = SIMD3<Float>(cosf(yaw),  0, -sinf(yaw))
        let delta   = (right * moveInput.x + forward * moveInput.y) * (cfg.moveSpeed * dt)

        var pos = yawNode.position.simd
        pos.x += delta.x
        pos.z += delta.z

        // Stick to height + eye height
        let h = sampleHeight(atWorldX: pos.x, z: pos.z)
        pos.y = h + cfg.eyeHeight
        yawNode.position = SCNVector3(pos)

        // Stream world + pickups
        chunker.updateVisible(center: pos)
        collectNearbyBeacons(playerXZ: SIMD2<Float>(pos.x, pos.z))
    }

    // MARK: helpers

    private func resetWorld() {
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        beacons.removeAll()
        beaconCounter = 0
        buildCommonLighting()

        // Camera rig
        yaw = 0; pitch = 0
        yawNode.position = spawnNearOrigin()
        updateRigOrientation()

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 5000
        camera.fieldOfView = 70
        camNode.camera = camera

        pitchNode.addChildNode(camNode)
        yawNode.addChildNode(pitchNode)
        scene.rootNode.addChildNode(yawNode)

        // CRITICAL: select our camera explicitly (fixes “black scene”)
        scnView?.pointOfView = camNode

        // Terrain streaming
        chunker = ChunkStreamer3D(cfg: cfg, noise: noise, recipe: recipe, root: scene.rootNode) { [weak self] newBeacons in
            newBeacons.forEach { self?.beacons.insert($0) }
        }
        chunker.buildAround(yawNode.position.simd)
    }

    private func buildCommonLighting() {
        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 250
        amb.color = UIColor(white: 0.9, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1100
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowRadius = 4
        sun.shadowColor = UIColor.black.withAlphaComponent(0.4)
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = SCNVector3(-Float.pi/3, Float.pi/4, 0)
        scene.rootNode.addChildNode(sunNode)

        scene.background.contents = UIColor.black
    }

    private func updateRigOrientation() {
        yawNode.eulerAngles = SCNVector3(0, yaw, 0)
        pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)
        camNode.position = SCNVector3(0, 0, 0)
    }

    private func spawnNearOrigin() -> SCNVector3 {
        let ts = cfg.tileSize
        let classifier = TileClassifier(context: WorldContext(recipe: recipe, tileSize: CGFloat(ts), chunkTiles: IVec2(16, 16)))
        let start = IVec2(0, 0)
        func isWalkable(_ t: IVec2) -> Bool { !classifier.tile(at: t).isBlocked }
        if isWalkable(start) { return SCNVector3(ts * 0.5, sampleHeight(atWorldX: 0, z: 0) + cfg.eyeHeight, ts * 0.5) }
        for r in 1...32 {
            for y in -r...r {
                for x in -r...r where abs(x) == r || abs(y) == r {
                    let t = IVec2(start.x + x, start.y + y)
                    if isWalkable(t) {
                        let wx = Float(t.x) * ts + ts * 0.5
                        let wz = Float(t.y) * ts + ts * 0.5
                        return SCNVector3(wx, sampleHeight(atWorldX: wx, z: wz) + cfg.eyeHeight, wz)
                    }
                }
            }
        }
        return SCNVector3(0, sampleHeight(atWorldX: 0, z: 0) + cfg.eyeHeight, 0)
    }

    private func sampleHeight(atWorldX x: Float, z: Float) -> Float {
        // Convert metres → tile coordinates, sample 0..1, then scale
        let tx = Double(x) / Double(cfg.tileSize)
        let tz = Double(z) / Double(cfg.tileSize)
        let h = noise.sampleHeight(tx, tz)
        return Float(h) * cfg.heightScale
    }

    private func collectNearbyBeacons(playerXZ: SIMD2<Float>) {
        var picked = [SCNNode]()
        for node in beacons {
            let p = node.worldPosition
            let dx = playerXZ.x - p.x
            let dz = playerXZ.y - p.z
            if dx*dx + dz*dz < 1.3 * 1.3 { picked.append(node) }
        }
        if !picked.isEmpty {
            picked.forEach { $0.removeFromParentNode(); beacons.remove($0) }
            beaconCounter += picked.count
            onScore(beaconCounter)
        }
    }
}

// MARK: - Chunk streaming

final class ChunkStreamer3D {
    private let cfg: FirstPersonEngine.Config
    private let noise: NoiseFields
    private let recipe: BiomeRecipe
    private weak var root: SCNNode?
    private var loaded: [IVec2: SCNNode] = [:]
    private let beaconSink: ([SCNNode]) -> Void

    init(cfg: FirstPersonEngine.Config, noise: NoiseFields, recipe: BiomeRecipe, root: SCNNode, beaconSink: @escaping ([SCNNode]) -> Void) {
        self.cfg = cfg
        self.noise = noise
        self.recipe = recipe
        self.root = root
        self.beaconSink = beaconSink
    }

    func buildAround(_ center: SIMD3<Float>) { updateVisible(center: center) }

    func updateVisible(center: SIMD3<Float>) {
        guard let root else { return }
        let ci = chunkIndex(forWorldX: center.x, z: center.z)
        var keep: Set<IVec2> = []
        for dy in -cfg.preloadRadius...cfg.preloadRadius {
            for dx in -cfg.preloadRadius...cfg.preloadRadius {
                let k = IVec2(ci.x + dx, ci.y + dy)
                keep.insert(k)
                if loaded[k] == nil {
                    let node = TerrainChunk3D.makeNode(originChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    root.addChildNode(node)
                    loaded[k] = node
                    let beacons = BeaconPlacer3D.place(inChunk: k, cfg: cfg, noise: noise, recipe: recipe)
                    beacons.forEach { node.addChildNode($0) }
                    beaconSink(beacons)
                }
            }
        }
        for (k, n) in loaded where !keep.contains(k) {
            n.removeAllActions()
            n.removeFromParentNode()
            loaded.removeValue(forKey: k)
        }
    }

    private func chunkIndex(forWorldX x: Float, z: Float) -> IVec2 {
        let tX = Int(floor(Double(x) / Double(cfg.tileSize)))
        let tZ = Int(floor(Double(z) / Double(cfg.tileSize)))
        return IVec2(floorDiv(tX, cfg.tilesX), floorDiv(tZ, cfg.tilesZ))
    }

    private func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : ((a + 1) / b - 1) }
}

// MARK: - Terrain building

struct TerrainChunk3D {
    static func makeNode(originChunk: IVec2, cfg: FirstPersonEngine.Config, noise: NoiseFields, recipe: BiomeRecipe) -> SCNNode {
        let node = SCNNode()
        node.name = "chunk_\(originChunk.x)_\(originChunk.y)"

        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let vertsX = tilesX + 1
        let vertsZ = tilesZ + 1
        let tileSize = cfg.tileSize
        let heightScale = cfg.heightScale

        // Heights in tile-space
        var heights = [Float](repeating: 0, count: vertsX * vertsZ)
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tileX = originChunk.x * tilesX + x
                let tileZ = originChunk.y * tilesZ + z
                let h = noise.sampleHeight(Double(tileX), Double(tileZ))
                heights[z*vertsX + x] = Float(h) * heightScale
            }
        }

        // Vertices in world metres
        var vertices = [SCNVector3]()
        vertices.reserveCapacity(vertsX * vertsZ)
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let tileX = originChunk.x * tilesX + x
                let tileZ = originChunk.y * tilesZ + z
                let wx = Float(tileX) * tileSize
                let wz = Float(tileZ) * tileSize
                let wy = heights[z*vertsX + x]
                vertices.append(SCNVector3(wx, wy, wz))
            }
        }

        // Normals
        var normals = [SCNVector3](repeating: SCNVector3(0,1,0), count: vertsX*vertsZ)
        func h(_ x: Int, _ z: Int) -> Float {
            heights[max(0, min(vertsZ-1, z))*vertsX + max(0, min(vertsX-1, x))]
        }
        for z in 0..<vertsZ {
            for x in 0..<vertsX {
                let hx = h(x-1, z) - h(x+1, z)
                let hz = h(x, z-1) - h(x, z+1)
                let n = simd_normalize(SIMD3<Float>(-hx, 2.0, -hz))
                normals[z*vertsX + x] = SCNVector3(n)
            }
        }

        // Indices
        var indices = [Int32]()
        indices.reserveCapacity(tilesX * tilesZ * 6)
        for z in 0..<tilesZ {
            for x in 0..<tilesX {
                let i0 = Int32(z*vertsX + x)
                let i1 = Int32(z*vertsX + x + 1)
                let i2 = Int32((z+1)*vertsX + x)
                let i3 = Int32((z+1)*vertsX + x + 1)
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }

        // Vertex colours (RGBA float buffer)
        let palette = AppColours.uiColors(from: recipe.paletteHex)
        let gradient = HeightGradient(palette: palette)
        var rgba = [Float]()
        rgba.reserveCapacity(vertices.count * 4)
        for v in vertices {
            let yNorm = max(0, min(1, v.y / heightScale))
            let col = gradient.color(yNorm: Float(yNorm))
            var r: CGFloat=0, g: CGFloat=0, b: CGFloat=0, a: CGFloat=0
            col.getRed(&r, green: &g, blue: &b, alpha: &a)
            rgba += [Float(r), Float(g), Float(b), 1.0]
        }

        let vSource = SCNGeometrySource(vertices: vertices)
        let nSource = SCNGeometrySource(normals: normals)
        let cSource = rgba.withUnsafeBufferPointer {
            SCNGeometrySource(
                data: Data(buffer: $0),
                semantic: .color,
                vectorCount: vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
        }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geom = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = UIColor.white
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        geom.materials = [mat]

        node.geometry = geom
        node.castsShadow = false
        return node
    }

    private struct HeightGradient {
        let stops: [UIColor]
        init(palette: [UIColor]) {
            if palette.count >= 5 { stops = palette }
            else {
                stops = [
                    UIColor(red: 0.55, green: 0.80, blue: 0.85, alpha: 1),
                    UIColor(red: 0.20, green: 0.45, blue: 0.55, alpha: 1),
                    UIColor(red: 0.94, green: 0.95, blue: 0.90, alpha: 1),
                    UIColor(red: 0.93, green: 0.88, blue: 0.70, alpha: 1),
                    UIColor(red: 0.43, green: 0.30, blue: 0.17, alpha: 1)
                ]
            }
        }
        func color(yNorm: Float) -> UIColor {
            let t = CGFloat(yNorm)
            func lerp(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
                var ar: CGFloat=0, ag: CGFloat=0, ab: CGFloat=0, aa: CGFloat=0
                var br: CGFloat=0, bg: CGFloat=0, bb: CGFloat=0, ba: CGFloat=0
                a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
                b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
                return UIColor(red: ar + (br - ar)*t, green: ag + (bg - ag)*t, blue: ab + (bb - ab)*t, alpha: 1)
            }
            if t < 0.18 { return stops[1] }      // deep water
            if t < 0.28 { return stops[0] }      // shallow
            if t < 0.34 { return stops[3] }      // sand
            if t < 0.62 { return stops[2] }      // lowlands
            if t < 0.82 { return .darkGray }     // rock
            return lerp(.white, stops[min(stops.count-1, 4)], 0.1) // snow
        }
    }
}

// MARK: - Beacons

struct BeaconPlacer3D {
    static func place(inChunk ci: IVec2, cfg: FirstPersonEngine.Config, noise: NoiseFields, recipe: BiomeRecipe) -> [SCNNode] {
        let tilesX = cfg.tilesX
        let tilesZ = cfg.tilesZ
        let originTile = IVec2(ci.x * tilesX, ci.y * tilesZ)
        let classifier = TileClassifier(context: WorldContext(recipe: recipe, tileSize: CGFloat(cfg.tileSize), chunkTiles: IVec2(16, 16)))

        let rarity = recipe.setpieces.first(where: { $0.name == "glass_beacon" })?.rarity ?? 0.015
        let tilesPerChunk = tilesX * tilesZ
        let expected = max(0, Int(round(Double(tilesPerChunk) * rarity)))

        let seed = recipe.seed64 &+ UInt64(bitPattern: Int64(ci.x)) &* 0x9E3779B97F4A7C15 &+ UInt64(bitPattern: Int64(ci.y))
        let rng = GKMersenneTwisterRandomSource(seed: seed)

        var out: [SCNNode] = []
        var placed = 0
        var attempts = 0
        while placed < expected && attempts < tilesPerChunk * 2 {
            attempts += 1
            let tx = originTile.x + rng.nextInt(upperBound: tilesX)
            let tz = originTile.y + rng.nextInt(upperBound: tilesZ)
            let tt = IVec2(tx, tz)
            let ttype = classifier.tile(at: tt)
            guard ttype == .grass || ttype == .forest || ttype == .sand else { continue }

            let wx = Float(tx) * cfg.tileSize + cfg.tileSize * 0.5
            let wz = Float(tz) * cfg.tileSize + cfg.tileSize * 0.5
            let wy = Float(noise.sampleHeight(Double(tx), Double(tz))) * cfg.heightScale + 0.2

            let n = SCNNode(geometry: beaconGeometry())
            n.position = SCNVector3(wx, wy, wz)
            n.name = "beacon"
            out.append(n)
            placed += 1
        }
        return out
    }

    private static func beaconGeometry() -> SCNGeometry {
        let cyl = SCNCapsule(capRadius: 0.18, height: 0.46)
        let m = SCNMaterial()
        m.emission.contents = UIColor.white.withAlphaComponent(0.85)
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.2)
        m.lightingModel = .physicallyBased
        cyl.materials = [m]
        return cyl
    }
}

private extension SCNVector3 {
    var simd: SIMD3<Float> { SIMD3<Float>(x, y, z) }
    init(_ v: SIMD3<Float>) { self.init(v.x, v.y, v.z) }
}
