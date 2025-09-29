# Glasslands — Vertical Slice Architecture

**Goal:** deterministic, infinite 2D world with chunk streaming and collectible "beacons". Everything runs on-device with no external assets.

## Modules

- **App /**
  - `App.swift` — entry; authenticates Game Center.
  - `ContentView.swift` — hosts `SpriteView` + SwiftUI HUD.

- **Game /**
  - **Core/**
    - `GameScene.swift` — world root, input → movement, streaming, scoring.
    - `CameraRig.swift` — smooth-follow SKCamera.
    - `Input/TouchInput.swift` — finger → desired velocity.
  - **World/**
    - `BiomeRecipe.swift` — recipe schema (noise params, palette…).
    - `NoiseFields.swift` — GKNoise fields (height, moisture).
    - `TileClassifier.swift` — noise → tile types & colours.
    - `ChunkStreamer.swift` — load/unload 16×16 tile chunks.
    - `Setpieces/BeaconStructures.swift` — place collectible beacons.
  - **Gameplay/**
    - `Player.swift` — avatar node + physics bubble.
    - `Systems/ScoringSystem.swift` — count beacons.
    - `Systems/CollisionSystem.swift` — tile-based blocking.
    - `UI/HUDOverlay.swift` — SwiftUI overlay with seed/score/pause.
    - `UI/Menus/PauseMenu.swift` — reserved for future menu.

- **Services/**
  - **Intelligence/**
    - `BiomeSynthesisService.swift` — FoundationModels (guarded) + deterministic fallback.
    - `ImageCreatorService.swift` — postcard composer; optional Metal effect.
  - **GameCenter/**
    - `Leaderboards.swift` — sign-in, submit, present UI.
    - `Challenges.swift` — placeholder (Apple Games uses leaderboards for challenges).
  - **Persistence/**
    - `SaveStore.swift` — seed persistence.
    - `PhotoSaver.swift` — add-only Photos saving.

- **Shaders/**
  - `TerrainShaders.metal` — compute kernel for postcard tint.

- **Resources/**
  - `Localisation/en.lproj/Localizable.strings` — reserved.

- **Tests/**
  - `WorldTests.swift` — determinism test.

## Determinism

- Seed charm → `hash64` → `SplitMix64` drives all param choices.
- GKNoise seeds are set from `seed64`.
- Setpiece placement uses Mersenne Twister seeded with `seed64`.

## Extending

- Swap tiles for textured sprites.
- Add energy / day-night cycles from `recipe.weatherBias`.
- Submit score on extraction; Apple Games exposes challenges via Game Center.

