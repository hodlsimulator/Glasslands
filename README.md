# Glasslands

Glasslands is a small, living wilderness that rewrites itself from a seed charm. Speak a charm, step into a drifting shard, collect Glass Beacons, and bank their light at a Waystone before Dusk takes it.

This repo currently contains a playable 3D first-person slice (SceneKit) with deterministic terrain streaming, beacon pickups, and postcard saving. The clouds and frame pacing are considered stable for now; the focus is building the actual game loop and narrative.

Docs live in `Glasslands/Docs/`.

## Core player promise

- A new “place” from a simple charm (e.g. `RAIN_FOX_PEAKS`).
- A short, tense run: gather light quickly, then decide when to bank.
- A story that unfolds in fragments without requiring dense world decoration.

## What works today (repo reality)

- 3D world: chunk-streamed terrain, seed-driven palette, first-person movement + look.
- Beacons: collectible objects; score increments when collected.
- Postcards: snapshot → stylised postcard → optional save to Photos.
- Seed input: simple token-based recipe selection (deterministic).

## What should be built next (high impact, low object count)

1) Waystone + banking (turn “wandering” into a run with an end condition).
2) Dusk timer + end-of-run summary (creates pace and meaning for score).
3) A compass/ping HUD (navigation without a heavy map or extra scenery).
4) Narrative “Echoes” tied to beacons/banking (story without NPCs).
5) Lightweight meta progression (Ring Shards / cosmetic unlocks).

## Build & run

- Requires: Xcode 26, iOS 26 SDK.
- Open `Glasslands.xcodeproj` and run the `Glasslands` scheme on an iOS 26 simulator/device.

If testing seed/debug toggles, keep them on a local (non-shared) scheme to avoid committing scheme changes.

## Repository map

- `Glasslands/Sources/Game3D/` — primary 3D slice (SceneKit).
- `Glasslands/Sources/Game/` — 2D SpriteKit slice (kept for reference/tests).
- `Glasslands/Sources/Services/` — seed recipe, postcard generation, persistence, diagnostics.
- `Glasslands/Docs/` — architecture, seeds, story, roadmap.
