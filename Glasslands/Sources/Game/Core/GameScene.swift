//
//  GameScene.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit
import GameplayKit
import UIKit

fileprivate struct PC {
    static let player: UInt32 = 0x1 << 0
    static let beacon: UInt32 = 0x1 << 1
}

final class GameScene: SKScene, SKPhysicsContactDelegate {

    // MARK: - Public surface

    let recipe: BiomeRecipe
    var onScore: ((Int) -> Void)?

    /// Expose UI colours for postcard generation
    var paletteUIColors: [UIColor] { AppColours.uiColors(from: recipe.paletteHex) }

    // MARK: - World config

    let tileSize: CGFloat = 40
    let chunkTiles = IVec2(16, 16)

    // MARK: - World state

    private lazy var world = WorldContext(recipe: recipe, tileSize: tileSize, chunkTiles: chunkTiles)
    private let worldNode = SKNode()
    private let player = PlayerNode(radius: 14)
    private let cameraRig = CameraRig()

    private lazy var streamer = ChunkStreamer(context: world, parent: worldNode)
    private lazy var classifier = TileClassifier(context: world)
    private lazy var scoring = ScoringSystem()
    private lazy var beacons = BeaconStructures(context: world)

    private let fpsLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private var touchInput = TouchInput()

    private(set) var score = 0 { didSet { onScore?(score) } }
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Init

    init(size: CGSize, recipe: BiomeRecipe, onScore: ((Int) -> Void)? = nil) {
        self.recipe = recipe
        self.onScore = onScore
        super.init(size: size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .black

        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self

        addChild(worldNode)
        addChild(cameraRig)

        // Player
        player.position = .zero
        player.physicsBody?.categoryBitMask = PC.player
        player.physicsBody?.contactTestBitMask = PC.beacon
        worldNode.addChild(player)

        // Camera
        let cam = SKCameraNode()
        self.camera = cam
        addChild(cam)
        cameraRig.attach(camera: cam, to: player, smoothing: 0.12)

        // Stream initial area
        streamer.buildAround(player.position, preloadRadius: 2) { [weak self] chunk in
            self?.populateSetpieces(in: chunk)
        }

        // HUD debug label
        fpsLabel.fontSize = 14
        fpsLabel.fontColor = .white
        fpsLabel.horizontalAlignmentMode = .right
        fpsLabel.verticalAlignmentMode = .top
        fpsLabel.position = CGPoint(x: size.width / 2 - 8, y: size.height / 2 - 8)
        camera?.addChild(fpsLabel)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        fpsLabel.position = CGPoint(x: size.width / 2 - 8, y: size.height / 2 - 8)
    }

    // MARK: - Frame loop

    override func update(_ currentTime: TimeInterval) {
        // Delta-time with a sensible clamp to avoid huge jumps.
        let dt: CGFloat
        if lastUpdateTime == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = CGFloat(min(1.0 / 30.0, max(0.0, currentTime - lastUpdateTime)))
        }
        lastUpdateTime = currentTime

        // Input → desired velocity
        let v = touchInput.desiredVelocity(maxSpeed: 160)

        // Basic AABB collision against blocked tiles via classifier sampling
        let next = player.position + v * dt
        if CollisionSystem.canOccupy(point: next, classifier: classifier) {
            player.position = next
        } else {
            let nx = CGPoint(x: next.x, y: player.position.y)
            let ny = CGPoint(x: player.position.x, y: next.y)
            if CollisionSystem.canOccupy(point: nx, classifier: classifier) {
                player.position = nx
            } else if CollisionSystem.canOccupy(point: ny, classifier: classifier) {
                player.position = ny
            }
        }

        // Stream chunks around the player and populate setpieces for new ones
        streamer.updateVisible(center: player.position, marginChunks: 1) { [weak self] chunk in
            self?.populateSetpieces(in: chunk)
        }

        // Camera follow
        cameraRig.update()

        // Debug stats
        if let view = view {
            let fpsSetting = view.preferredFramesPerSecond == 0 ? 60 : Double(view.preferredFramesPerSecond)
            fpsLabel.text = String(
                format: "FPS %.0f   Chunks %d   Score %d",
                fpsSetting,
                streamer.loadedChunkCount,
                score
            )
        }
    }

    // MARK: - World population

    private func populateSetpieces(in chunk: ChunkRef) {
        // For the slice we only place beacons; later this can branch on setpiece defs.
        beacons.placeBeacons(in: chunk, into: worldNode, categoryMask: PC.beacon)
    }

    // MARK: - Contacts

    func didBegin(_ contact: SKPhysicsContact) {
        let mask = contact.bodyA.categoryBitMask | contact.bodyB.categoryBitMask
        if mask == (PC.player | PC.beacon) {
            let beaconNode = (contact.bodyA.categoryBitMask == PC.beacon ? contact.bodyA.node : contact.bodyB.node)
            beaconNode?.removeFromParent()
            score += scoring.onBeaconCollected()
        }
    }

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchInput.touchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchInput.touchesMoved(touches, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchInput.touchesEnded(touches, in: self)
    }

    // MARK: - Snapshot (for postcards)

    /// Snapshot of the game layer (world only, not HUD).
    /// Uses non-optional `cgImage()` on iOS 26.
    func captureSnapshot() -> UIImage? {
        guard let view = self.view, let tex = view.texture(from: worldNode) else { return nil }
        let cg: CGImage = tex.cgImage()
        return UIImage(cgImage: cg)
    }
}

// MARK: - WorldContext & Math

struct WorldContext {
    let recipe: BiomeRecipe
    let tileSize: CGFloat
    let chunkTiles: IVec2
    let noise: NoiseFields

    init(recipe: BiomeRecipe, tileSize: CGFloat, chunkTiles: IVec2) {
        self.recipe = recipe
        self.tileSize = tileSize
        self.chunkTiles = chunkTiles
        self.noise = NoiseFields(recipe: recipe)
    }

    func worldToTile(_ p: CGPoint) -> IVec2 {
        IVec2(Int(floor(p.x / tileSize)), Int(floor(p.y / tileSize)))
    }

    func tileToWorld(_ t: IVec2) -> CGPoint {
        CGPoint(x: CGFloat(t.x) * tileSize + tileSize / 2,
                y: CGFloat(t.y) * tileSize + tileSize / 2)
    }

    func tileRect(_ t: IVec2) -> CGRect {
        CGRect(x: CGFloat(t.x) * tileSize, y: CGFloat(t.y) * tileSize, width: tileSize, height: tileSize)
    }
}

struct IVec2: Hashable, Equatable {
    let x: Int; let y: Int
    init(_ x: Int, _ y: Int) { self.x = x; self.y = y }

    static func + (l: IVec2, r: IVec2) -> IVec2 { IVec2(l.x + r.x, l.y + r.y) }
    static func - (l: IVec2, r: IVec2) -> IVec2 { IVec2(l.x - r.x, l.y - r.y) }
}

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
}
