# File: README.md

# Glasslands

A living, pocket-sized wilderness that rewrites itself from your **seed charms**.

Players compose a charm by mixing 2–3 **Genmoji** or a short phrase. On-device **Apple Intelligence** turns that prompt into a compact **Biome Recipe** (JSON). Your device then generates an endless, streamable world—terrain, flora, setpieces, weather tints, and ambient cues—entirely offline and uniquely themed to that charm. Share any seed as a **Challenge**; friends spawn the exact same world and race time-boxed goals.

**Why iOS 26-only?** We lean on iOS 26 features: Apple Intelligence Foundation Models (on-device), **Image Playground / Image Creator** (on-device art), Apple **Games** app Challenges & overlay, and **MetalFX** Frame Interpolation/Denoising for smooth traversal on supported devices.

---

## What makes it new

### Seeds you can see
Players literally *compose* seeds with Genmoji (e.g. “🌧️🦊⛰️”) or a short phrase (“misty fox highlands”). The app converts the charm into a Biome Recipe via **on-device** Foundation Models. It works offline, with no per-request cost and no server round-trips.

### Procedural world that never repeats
A chunk streamer builds terrain from **GameplayKit noise** (Perlin/simplex, ridged, turbulence) and applies rules from the Biome Recipe (elevation bands → blocks; moisture → vegetation; rarity tables for artefacts). Noise is deterministic; chunks stream in around the player and unload behind them.

### Runtime art that matches the seed
Using **Image Playground / Image Creator**, we synthesise small, style-locked 2D atlases on the device at runtime (icons, decals, banner art, postcard frames). It gives every seed its own look without shipping gigabytes of textures.

### Feels great at high frame rates
Traversal pushes lots of chunks. On devices with support, **MetalFX Frame Interpolation** raises perceived FPS and **MetalFX Denoising** cleans up ray-/path-traced effects in our optional Metal render path. Default path is SpriteKit and remains fast on non-MetalFX devices.

### Instant social replay via Apple Games
From the system **Game Overlay**, players join Challenges (e.g. daily seed) and compare progress—no custom social UI required. Controller users benefit from USB-C pairing and fast device switching.

---

## Core loop

1. **Make a Seed Charm** → pick 2–3 Genmoji or type a 2–4-word phrase.
2. **Drop In** → the world streams in; explore, collect **glass beacons**, clear 2–3 emergent objectives (e.g. “light the beacons before dusk”).
3. **Bank & Share** → extract at **waystones**, mint a postcard (Image Creator) and push a **Challenge** so friends can run your seed.
4. **Repeat** → escalate modifiers (harder weather, rarer resources) or remix your charm.

---

## Generative pipeline (deterministic & fast)

**Inputs**
- Seed Charm → canonical string (e.g. `RAIN_FOX_PEAKS`) + 64-bit seed
- Device capability flags (ray tracing, 120 Hz, MetalFX availability)

**Apple Intelligence (on-device) → Biome Recipe (compact JSON)**

Example schema (illustrative):

    {
      "height": {"base":"ridged","octaves":5,"amp":18,"scale":240},
      "moisture": {"base":"perlin","octaves":3,"amp":1.0,"scale":520},
      "palette": ["#8BC7DA","#36667C","#E0F2F6","#F3E2C0","#704B2C"],
      "floraTags": ["spruce","tussock"],
      "faunaTags": ["fox","nocturnal"],
      "setpieces": [{"name":"glass_beacon","rarity":0.015}],
      "weatherBias": "drizzle",
      "music": {"mode":"Dorian","tempo":92},
      "style": {"ui":"Watercolour","decals":"Sketch"}
    }

Generated locally with Foundation Models; **no network required**. If Apple Intelligence is unavailable, we fall back to a deterministic ruleset derived directly from the 64-bit seed.

**World synthesis**
- Terrain: GKNoise fields (height, moisture, temperature) → tile classifier → streamed tile nodes / optional meshes
- Structures: grammar/WFC seeded from setpieces
- Creatures/NPCs: lightweight behaviour trees (GameplayKit state machines)
- Visuals: Image Playground / Image Creator generates style-matched UI/collectibles/postcards on device

**Performance**
- Chunk generation on background threads
- MetalFX Frame Interpolation toggled when available
- Optional hardware ray tracing on supported iPhones; fall back to probes otherwise

---

## Controls (vertical slice)

- **Virtual thumbstick:** press and hold anywhere to anchor; drag to move; release to stop.
- **Pause/Resume:** top-right button.
- **While paused:** change seed charm, save a postcard, open Leaderboards.

---

## Build & run

- **Requires:** Xcode 26, iOS 26 SDK; iPhone 11/A13 or newer.
- Open `Glasslands.xcodeproj` and run the **Glasslands** scheme on an iOS 26 simulator/device.
- Asset Catalogues: the repo ships a minimal `Assets.xcassets` (AppIcon + AccentColor). If Xcode stalls at `actool`, clean DerivedData and ensure only one catalogue exists under `Glasslands/`.

---

## Technical stack (Apple-native)

- **Engine:** SpriteKit (2.5D) today; optional Metal/SceneKit hybrid path for advanced effects
- **World:** GameplayKit (GKNoise, state machines); our chunk streamer; deterministic seeding
- **Gen AI:** Foundation Models (text in/out) for Biome Recipes and short names/lore; Image Playground / Image Creator for art
- **Graphics:** MetalFX (Frame Interpolation + Denoising); optional Metal RT
- **Platform:** Apple Games (Challenges overlay); Game Controller; Photos (add-only) for postcards
- **Design:** iOS 26 **Liquid Glass** visual style

---

## Monetisation (simple & clean)

Paid app + optional IAP **Style Packs** (additional Image Playground styles + music themes) and **Cosmetic Postcards** export bundle. All content is generated **on device**; no servers.

---

## Risks & mitigations

- **Determinism across devices:** fix random seeds; version Biome Recipes; clamp/quantise ML outputs before synthesis.
- **Performance on older hardware:** cap chunk radius; dynamic quality; auto-disable heavy paths; use MetalFX where available.
- **Policy/safety:** constrain prompts; filter styles; keep all generation local via Apple frameworks.

---

## Privacy

No accounts. No ads. No tracking. Postcards are created on-device; you choose if you save/share them.

---

# File: Glasslands/Docs/ARCHITECTURE.md

# Architecture

This is a high-level map of systems and how a seed charm becomes a streamable world.

Directory outline:

    Glasslands/
    ├─ Sources/
    │  ├─ App/
    │  │  ├─ App.swift                # SwiftUI lifecycle + Game Center hooks
    │  │  ├─ ContentView.swift        # Game view + HUD overlay
    │  │  └─ Theme/Colours.swift
    │  ├─ Game/
    │  │  ├─ Core/
    │  │  │  ├─ GameScene.swift       # SpriteKit loop; camera; contacts
    │  │  │  ├─ CameraRig.swift       # Smooth follow camera
    │  │  │  └─ Input/TouchInput.swift# Virtual thumbstick
    │  │  ├─ Gameplay/
    │  │  │  ├─ Player.swift
    │  │  │  └─ Systems/
    │  │  │     ├─ CollisionSystem.swift
    │  │  │     └─ ScoringSystem.swift
    │  │  ├─ Gameplay/UI/
    │  │  │  ├─ HUDOverlay.swift
    │  │  │  └─ Menus/PauseMenu.swift
    │  │  └─ World/
    │  │     ├─ BiomeRecipe.swift     # Parsed/validated recipe model
    │  │     ├─ NoiseFields.swift     # Height/moisture/heat etc.
    │  │     ├─ TileClassifier.swift  # Noise → tile types
    │  │     ├─ ChunkStreamer.swift   # Loads/unloads 16×16 tile chunks
    │  │     └─ Setpieces/BeaconStructures.swift
    │  ├─ Services/
    │  │  ├─ Intelligence/
    │  │  │  ├─ BiomeSynthesisService.swift # Apple Intelligence wrapper + fallback
    │  │  │  └─ ImageCreatorService.swift   # Image Playground / Image Creator
    │  │  ├─ GameCenter/
    │  │  │  ├─ Leaderboards.swift
    │  │  │  └─ Challenges.swift
    │  │  └─ Persistence/
    │  │     ├─ SaveStore.swift
    │  │     └─ PhotoSaver.swift
    │  └─ Shaders/TerrainShaders.metal
    └─ Docs/

---

## Seed → Recipe → World

1) **Canonicalise seed charm** (see `SEEDS.md`) and hash to a 64-bit seed.

2) **BiomeSynthesisService**
   - If Apple Intelligence is available: prompt a local Foundation Model to produce a compact Biome Recipe JSON; validate and clamp ranges; persist alongside the canonical charm.
   - Else: compute a deterministic baseline recipe from the 64-bit seed (pure function) for full offline compatibility.

3) **NoiseFields** initialises GKNoise sources according to the recipe (height base type, octaves, scales, offsets derived from seed).

4) **ChunkStreamer** keeps a (2n+1)×(2n+1) window of chunks around the player. For each new chunk:
   - Sample noise on the chunk’s tile grid
   - Classify into tile types (deep water / water / sand / grass / scrub / rock / snow)
   - Build tile sprites (vertical slice) or batched meshes (future path)
   - Call setpiece placers (e.g., beacons)

5) **Gameplay**
   - `TouchInput` produces desired velocity; `CollisionSystem` resolves movement vs blocked tiles with axis-separable slide.
   - Contacts dispatch through `GameScene` (e.g., Player ↔ Beacon → score increment).

6) **UI/HUD**
   - Minimal while playing (score, pause).
   - Paused: seed field, apply, postcard, leaderboards.

7) **Postcards**
   - `GameScene.captureSnapshot()` → small Metal pass (tint/border) → `PhotoSaver` (add-only).

---

## Determinism rules

- All stochastic behaviour is derived from the 64-bit seed and integer tile/chunk coordinates.
- ML outputs are post-processed:
  - Missing keys default from a fixed base recipe.
  - Numeric ranges are clamped and quantised.
  - Palette colours are snapped to a reproducible 8-bit sRGB set.

This guarantees the same charm renders the same world on every device and OS minor version.

---

## Performance profile

- Node counts: 16×16 tiles per chunk; keep a 3×3 window (~768 tiles) in the slice.
- Background generation: chunk work happens off the main thread; SpriteKit node creation returns to main.
- Optional render path:
  - MetalFX Frame Interpolation toggled when present.
  - MetalFX Denoising for ray-/path-traced effects in future lighting experiments.
- Graceful degrade:
  - Lower chunk radius when thermals rise.
  - Cap update rate where necessary.
  - Disable heavy passes on unsupported devices.

---

## Testing

- **Unit:** seed canonicalisation; recipe validation; tile thresholds.
- **UI:** launch, set charm, pause, postcard flow (Photos mocked).
- **Determinism:** golden-image checks for a set of canonical charms.

---

# File: Glasslands/Docs/SEEDS.md

# Seed Charms

A **seed charm** is the compact, human-friendly input that shapes your world—2–3 Genmoji or a short phrase. The same charm always recreates the same world.

---

## Canonical form

We canonicalise the raw text before hashing:

1. Unicode NFKC normalisation
2. Trim leading/trailing whitespace
3. Collapse internal whitespace to one space
4. Lowercase
5. Replace spaces with underscores

Example: “Misty   Fox   Highlands” → `misty_fox_highlands` → displayed as `MISTY_FOX_HIGHLANDS`.

---

## Stable hashing

    seed64 = first_8_bytes_of( SHA256(utf8: canonical_text) )

We never use Swift’s `hashValue`. The 64-bit seed drives all local PRNGs and noise offsets.

---

## From charm to Biome Recipe

**Primary path (preferred):** On devices with Apple Intelligence, `BiomeSynthesisService` prompts a local Foundation Model to emit a compact JSON recipe. We validate and clamp it, then store it alongside the charm.

**Fallback path:** A deterministic ruleset maps `seed64` → recipe parameters (palette pick, base noise types, scales, thresholds). This ensures identical worlds even without Apple Intelligence availability.

**Example recipe**

    {
      "height": {"base":"ridged","octaves":5,"amp":18,"scale":240},
      "moisture": {"base":"perlin","octaves":3,"amp":1.0,"scale":520},
      "temperature": {"gradient":0.3,"noise":"perlin","scale":800},
      "palette": ["#8BC7DA","#36667C","#E0F2F6","#F3E2C0","#704B2C"],
      "setpieces":[{"name":"glass_beacon","rarity":0.015}],
      "weatherBias":"drizzle",
      "style":{"ui":"Watercolour","decals":"Sketch"}
    }

---

## Tile classifier (typical thresholds)

    if height < waterline - 0.06      -> deep_water
    else if height < waterline        -> water
    else if height < waterline + bw   -> sand
    else if rockiness > 0.7           -> rock
    else if moisture < 0.25           -> scrub
    else                               -> grass

Where `waterline`, beach width `bw`, and rockiness weights come from the Biome Recipe.

---

## Sharing & Challenges

- Sharing the seed charm string is enough. Canonicalisation + hashing → identical recipe selection → identical world.
- Challenges use the system **Games** overlay for invites, timers, and comparing results. We send only the charm and a small ruleset version tag.

---

## Guard rails

- Prompt constraints and safe style sets for Image Creator.
- Palette snapping and numeric clamping for ML outputs.
- Versioned recipes so older charms keep their original look.

---

