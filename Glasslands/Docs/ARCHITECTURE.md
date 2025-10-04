# Glasslands — Vertical Slice Architecture

**Goal:** deterministic, infinite 2D world with chunk streaming and collectible “beacons”. Everything runs on-device with no external assets. A parallel 3D slice exists for SceneKit/first-person experiments; both share the same seed pipeline.

## Modules

- **App /**
  - `App.swift` — entry; authenticates Game Center.
  - `ContentView.swift` — hosts SpriteKit `SpriteView` + SwiftUI HUD and can embed the 3D view.
  - `Info.plist` — iOS 26 target, SceneKit/SpriteKit usage.
  - **Theme/**
    - `Colours.swift` — app colour palette.

- **Game /** *(2D SpriteKit vertical slice)*
  - **Core/**
    - `GameScene.swift` — world root; input → movement, streaming, scoring.
    - `CameraRig.swift` — smooth-follow `SKCameraNode`.
    - **Input/**
      - `TouchInput.swift` — finger → desired velocity.
  - **World/**
    - `BiomeRecipe.swift` — recipe schema (noise params, palette…).
    - `NoiseFields.swift` — `GKNoise` fields (height, moisture).
    - `NoiseFields+Sendable.swift` — concurrency helpers for noise fields.
    - `TileClassifier.swift` — noise → tile types & colours.
    - `ChunkStreamer.swift` — load/unload 16×16 tile chunks around the player.
    - **Setpieces/**
      - `BeaconStructures.swift` — place collectible beacons (deterministic layout).
  - **Gameplay/**
    - `Player.swift` — avatar node + physics bubble.
    - **Systems/**
      - `ScoringSystem.swift` — count beacons and update score.
      - `CollisionSystem.swift` — tile-based blocking/collisions.
    - **UI/**
      - `HUDOverlay.swift` — SwiftUI overlay with seed/score/pause.
      - **Menus/**
        - `PauseMenu.swift` — placeholder for future menu.

- **Game3D /** *(SceneKit first-person vertical slice; shares seeds)*
  - `FirstPersonEngine.swift` — assembles the 3D scene, sky, terrain, and input wiring.
  - `RendererProxy.swift` — SCNRenderer bridge/ownership.
  - `Scene3DView.swift` — SwiftUI host for SceneKit view.
  - `RandomAdaptor.swift` — unified RNG seeded from the world seed.
  - **Input/**
    - `VirtualSticks.swift` — on-screen twin-stick controls.
  - **Terrain/**
    - `TerrainMath.swift` — height/utility maths.
    - `TerrainMeshBuilder.swift` — chunk mesh generation.
    - `TerrainChunkNode.swift` — per-chunk node wrapper.
    - `ChunkStreamer3D.swift` — stream terrain chunks around the player.
  - **Sky/**
    - `CloudBillboardLayer.swift` — cumulus billboard impostors (depth-safe, premultiplied alpha).
    - `CloudSpriteTexture.swift` — SDF-based fluffy puff sprites (runtime atlas).
    - `CloudFieldLL.swift` — low-level cloud field helpers.
    - `CumulusRenderer.swift` — sky pipeline glue.
    - `SkyMath.swift` — sun/zenith maths.
    - `ZenithCapField.swift` — zenith fade/cap utilities.
    - `SceneKitHelpers+Sky.swift` — equirect gradient, sky helpers.
    - `SceneKitHelpers+Sun.swift` — sun light/disc helpers.
  - **Ground & Set-dressing/**
    - `SceneKitHelpers+Ground.swift` — ground plane/gradient material.
    - `BeaconPlacer3D.swift` — deterministic beacon placement in 3D.
    - `VegetationPlacer3D.swift` — simple vegetation scatter (LOD-safe).
  - `SceneKitHelpers.swift` — shared helpers (materials, images).

- **Services/**
  - **Intelligence/**
    - `BiomeSynthesisService.swift` — Foundation Models (guarded) + deterministic fallback.
    - `ImageCreatorService.swift` — postcard composer; optional Metal tint.
  - **GameCenter/**
    - `Leaderboards.swift` — sign-in, submit, present UI.
    - `Challenges.swift` — placeholder (Apple Games exposes challenges via Game Center).
  - **Persistence/**
    - `SaveStore.swift` — seed persistence.
    - `PhotoSaver.swift` — add-only Photos saving.
  - **Diagnostics/**
    - `Signposts.swift` — os_signpost points for streaming/render steps.

- **Shaders/**
  - `TerrainShaders.metal` — compute/tint kernel for postcards and effects.

- **Resources/**
  - `Localisation/en.lproj/Localizable.strings` — reserved.

- **Docs/**
  - `Docs/README.md`, `Docs/ARCHITECTURE.md`, `Docs/SEEDS.md`, `Docs/STORY.md`.

- **Entitlements & Assets/**
  - `Glasslands.entitlements` — Game Center + Photos add-only (and any required capabilities).
  - `Assets.xcassets` — app icon and placeholders.

- **Tests/**
  - `GlasslandsTests/GlasslandsTests.swift` — core unit tests.
  - `GlasslandsTests/WorldLogicTests.swift` — determinism/streaming tests.
  - `GlasslandsUITests/GlasslandsUITests.swift` — basic UI smoke.
  - `GlasslandsUITests/GlasslandsUITestsLaunchTests.swift` — launch baseline.

## Determinism

- Seed charm → `hash64` → `SplitMix64` → shared `seed64`.
- `GKNoise` seeds derive from `seed64` (2D) and the same seed feeds 3D `RandomAdaptor`.
- Setpiece placement (2D/3D) uses deterministic RNG (Mersenne Twister/bridged adaptor).
- Chunk streamers (2D and 3D) sample only local seed-derived state; no external I/O.

## Rendering Notes

- **2D:** SpriteKit tiles coloured by `TileClassifier`; beacons as SKNodes; camera smoothing via `CameraRig`.
- **3D:** SceneKit terrain chunks built off-thread, pre-warmed via `SCNView.prepare`.  
  Sky uses **billboard impostors** from `CloudBillboardLayer` with **premultiplied alpha**, **no depth writes**, clamp-safe sprites from `CloudSpriteTexture`.

## Extending

- Swap flat tiles for textured sprites (2D).
- Day–night and energy loops from `BiomeRecipe.weatherBias`.
- Submit score on extraction; Apple Games exposes challenges via Game Center.
- Expand 3D slice: physics pickups, horizon fog, and terrain materials from biome palette.
