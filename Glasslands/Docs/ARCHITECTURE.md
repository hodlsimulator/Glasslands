# Glasslands — Vertical Slice Architecture

**Goal:** Deterministic, infinite 2D world with chunk streaming and collectible “beacons”. Everything runs on-device with no external assets. A parallel 3D slice (SceneKit, first-person) shares the same seed pipeline.

> **Status (Oct 2025)**
> - HDR sun now renders as an additive **core + halo** billboard (EDR, blooms nicely).
> - 3D per-frame updates run via **CADisplayLink** on the main thread (no SceneKit delegate).
> - Volumetric clouds are **parked** while the sun is locked; billboard clouds remain available and use a view-space sun vector.
> - EDR pipeline enabled end-to-end (10-bit XR CAMetalLayer + HDR camera settings).

## Modules

- **App /**
  - `App.swift` — entry; authenticates Game Center.
  - `ContentView.swift` — hosts SpriteKit `SpriteView` + SwiftUI HUD and can embed the 3D view.
  - `Info.plist` — iOS 26 target; SceneKit/SpriteKit usage.
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
        - `PauseMenu.swift` — placeholder.

- **Game3D /** *(SceneKit first-person vertical slice; shares seeds)*
  - `FirstPersonEngine.swift` — assembles the 3D scene, **HDR sun (core+halo)**, and input.
  - `RendererProxy.swift` — SCNRenderer bridge/ownership.
  - `Scene3DView.swift` — SwiftUI host; **CADisplayLink main-thread tick** (no SceneKit delegate).
  - `RandomAdaptor.swift` — unified RNG seeded from the world seed.
  - **Terrain/**
    - `TerrainMath.swift` — height/utility maths.
    - `TerrainMeshBuilder.swift` — chunk mesh generation.
    - `TerrainChunkNode.swift` — per-chunk node wrapper.
    - `ChunkStreamer3D.swift` — stream terrain chunks around the player.
  - **Sky/**
    - `SceneKitHelpers+Sky.swift` — equirect gradient, sky helpers.
    - `SceneKitHelpers+Sun.swift` — sun helpers (EDR sprite utils: core/halo).
    - `CloudBillboardLayer.swift` — cumulus billboard impostors (premultiplied alpha, depth-safe).
    - `CloudSpriteTexture.swift` — SDF-based fluffy puff sprites (runtime atlas).
    - `CloudFieldLL.swift`, `CumulusRenderer.swift`, `SkyMath.swift`, `ZenithCapField.swift` — sky pipeline glue and maths.
    - `VolumetricCloudMaterial.swift` — **minimal stable gradient/HDR-sun shader** (volumetrics parked).
    - `VolumetricCloudProgram.swift` — legacy SCNProgram path (**unused** for now).
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
  - `TerrainShaders.metal` — compute/tint kernel for postcards/effects.
  - `SkyVolumetricClouds.metal` — **experimental/parked** (kept for future volumetrics).

- **Resources/**
  - `Localisation/en.lproj/Localizable.strings` — reserved.

- **Docs/**
  - `Docs/README.md`, `Docs/ARCHITECTURE.md`, `Docs/SEEDS.md`, `Docs/STORY.md`.

- **Entitlements & Assets/**
  - `Glasslands.entitlements` — Game Center + Photos add-only.
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

- **EDR/HDR pipeline:** `SCNView`’s `CAMetalLayer` is `wantsExtendedDynamicRangeContent = true` with `pixelFormat = .bgra10_xr_srgb`; camera has `wantsHDR = true`. Bloom tuned so **only hot pixels bloom** (sun core + halo).
- **3D sky (current):**
  - **HDR Sun:** additive **core + halo** billboard at sky distance. Core is a crisp circle (no texture) with high emission; halo is a radial gradient texture with softer falloff. Both render after the sky (`renderingOrder` high) and use EDR intensities.
  - **Billboard clouds:** available; fragment uses **view-space** sun (`sunDirView`) passed from Swift (no `scn_frame` in shader modifiers).
  - **Volumetric clouds:** shader kept minimal/stable for now (gradient + analytic sun). The heavy march path is parked until we re-introduce it incrementally.
- **Per-frame updates:** `Scene3DView` drives updates via **CADisplayLink on the main thread**; no SceneKit renderer delegate or SCNProgram buffer-binding closures (avoids render-queue isolation asserts).
- **Terrain:** chunk meshes built off-thread; call `renderer.prepare(...)` to pre-warm before attach.

## Extending

- Re-enable volumetric marching in the sky shader in small steps (add one helper at a time), keeping the additive sun as a guaranteed highlight.
- Occlude sun brightness under dense cloud, using transmittance from the march.
- Atmospheric tweaks: horizon fog/inscattering, sky colour from sun elevation.
- Gameplay: physics pickups, extraction loop, terrain materials from biome palette.
