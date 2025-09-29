//
//  GameScene.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SpriteKit
import GameplayKit
import UIKit

// MARK: - Physics Categories
fileprivate struct PC {
    static let player: UInt32 = 0x1 << 0
    static let beacon: UInt32 = 0x1 << 1
}

final class GameScene: SKScene, SKPhysicsContactDelegate {
    // MARK: - Public
    let recipe: BiomeRecipe
    var onScore: ((Int) -> Void)?
    var paletteUIColors: [UIColor] { AppColours.uiColors(from: recipe.paletteHex) }

    // MARK: - World config
    let tileSize: CGFloat = 40
    let chunkTiles = IVec2(16,16)
    private lazy var world = WorldContext(recipe: recipe, tileSize: tileSize, chunkTiles: chunkTiles)

    // MARK: - Nodes
    private let worldNode = SKNode()
    private let player = PlayerNode(radius: 14)
    private let cameraRig = CameraRig()

    // Systems
    private lazy var streamer   = ChunkStreamer(context: world, parent: worldNode)
    private lazy var classifier = TileClassifier(context: world)
    private lazy var scoring    = ScoringSystem()
    private lazy var beacons    = BeaconStructures(context: world)

    // HUD label (for quick debug; main HUD is SwiftUI)
    private let fpsLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")

    // State
    private var touchInput = TouchInput()
    private(set) var score = 0 { didSet { onScore?(score) } }

    // MARK: - Init
    init(size: CGSize, recipe: BiomeRecipe, onScore: ((Int)->Void)? = nil) {
        self.recipe = recipe
        self.onScore = onScore
        super.init(size: size)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    override func didMove(to view: SKView) {
        backgroundColor = .black
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self

        addChild(worldNode)
        addChild(cameraRig)

        // Player setup
        player.position = .zero
        player.physicsBody?.categoryBitMask = PC.player
        player.physicsBody?.contactTestBitMask = PC.beacon
        worldNode.addChild(player)

        // Camera
        let cam = SKCameraNode()
        self.camera = cam
        addChild(cam)
        cameraRig.attach(camera: cam, to: player, smoothing: 0.12)

        // Initial stream
        streamer.buildAround(player.position, preloadRadius: 2) { [weak self] chunk in
            self?.populateSetpieces(in: chunk)
        }

        // Debug label
        fpsLabel.fontSize = 14
        fpsLabel.fontColor = .white
        fpsLabel.horizontalAlignmentMode = .right
        fpsLabel.verticalAlignmentMode = .top
        fpsLabel.position = CGPoint(x: size.width/2 - 8, y: size.height/2 - 8)
        camera?.addChild(fpsLabel)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        fpsLabel.position = CGPoint(x: size.width/2 - 8, y: size.height/2 - 8)
    }

    // MARK: - Updates
    override func update(_ currentTime: TimeInterval) {
        let fps = self.view?.preferredFramesPerSecond ?? 60
        let dt = CGFloat(1.0 / Double(max(1, fps)))

        // Input → velocity
        let v = touchInput.desiredVelocity(maxSpeed: 160)
        let next = player.position + v * dt

        // Collision against blocked tiles
        if CollisionSystem.canOccupy(point: next, classifier: classifier) {
            player.position = next
        } else {
            // slide a bit on X or Y
            let nx = CGPoint(x: next.x, y: player.position.y)
            let ny = CGPoint(x: player.position.x, y: next.y)
            if CollisionSystem.canOccupy(point: nx, classifier: classifier) {
                player.position = nx
            } else if CollisionSystem.canOccupy(point: ny, classifier: classifier) {
                player.position = ny
            }
        }

        // Stream chunks
        streamer.updateVisible(center: player.position, marginChunks: 1) { [weak self] chunk in
            self?.populateSetpieces(in: chunk)
        }

        // Camera follow
        cameraRig.update()

        // Debug
        if let view = view {
            fpsLabel.text = String(
                format: "FPS %.0f Chunks %d Score %d",
                view.preferredFramesPerSecond == 0 ? 60 : Double(view.preferredFramesPerSecond),
                streamer.loadedChunkCount,
                score
            )
        }
    }

    // MARK: - Setpieces
    private func populateSetpieces(in chunk: ChunkRef) {
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

    // MARK: - Input
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touchInput.touchesBegan(touches, in: self) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touchInput.touchesMoved(touches, in: self) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchInput.touchesEnded(touches, in: self) }

    // MARK: - Snapshot
    func captureSnapshot() -> UIImage? {
        guard let view = self.view,
              let tex  = view.texture(from: worldNode),
              let cg   = tex.cgImage()
        else { return nil }
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

    func worldToTile(_ p: CGPoint) -> IVec2 { IVec2(Int(floor(p.x / tileSize)), Int(floor(p.y / tileSize))) }
    func tileToWorld(_ t: IVec2) -> CGPoint { CGPoint(x: CGFloat(t.x) * tileSize + tileSize/2, y: CGFloat(t.y) * tileSize + tileSize/2) }
    func tileRect(_ t: IVec2) -> CGRect { CGRect(x: CGFloat(t.x) * tileSize, y: CGFloat(t.y) * tileSize, width: tileSize, height: tileSize) }
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
