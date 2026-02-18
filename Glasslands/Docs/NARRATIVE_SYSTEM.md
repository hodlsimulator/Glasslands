# Narrative system (low asset, deterministic)

This document describes a story delivery system that is compelling without requiring NPCs, voice acting, or dense bespoke environments.

## Goals

- Make each run feel like it matters.
- Deliver a clear mystery and progression in small, satisfying pieces.
- Keep runtime overhead negligible.
- Keep determinism: friends running the same charm should see the same “beats”.

## Concepts

Echo
- A one-line memory fragment shown when a beacon is collected.

Transmission
- A short 2–4 line message shown when banking at a Waystone (or at run end).

Journal
- A text-first screen that stores unlocked Echoes and Transmissions.

Ring Step
- A milestone state that gates which content pools are eligible.

## Content structure (data, not code)

Content should be stored as plain data so it can be edited and localised without touching core systems.

Recommended split:

- `Echoes`
  - Short, sensory, evocative lines.
  - Large pool (50–200) so repeats are rare.

- `Transmissions`
  - Small pools per Ring Step (10–25 each).
  - Tagged by outcome: bank success, bank late, failed run, first ever bank, etc.

- `Chapters`
  - Optional longer text unlocked at key Ring Steps.
  - Can live entirely inside the Journal.

Determinism strategy:

- Choose an Echo index from: (seed64, beaconOrdinal, ringStep).
- Choose a Transmission index from: (seed64, bankOrdinal, outcome, ringStep).
- Clamp all selections to content array bounds.

This yields stable selection per charm while still producing variety across different charms.

## How it appears in-game

Beacon pickup
- Small overlay near the top or bottom, fades in/out.
- Display time: ~1.5–2.0 seconds.
- If pickups happen rapidly, queue and show the most recent one only.

Waystone bank
- Short “banked” feedback + transmission text.
- The first line should always confirm the mechanical result (“Banked”, “Too late”, etc).

Journal
- Two tabs:
  - Echoes (chronological)
  - Ring (chapters / milestones)

## Writing rules (so it stays compelling)

- Concrete beats abstract. “Warmth sealed in glass” is better than “entropy resists”.
- Avoid invented proper nouns unless they earn their keep.
- Repetition is a tool: a phrase that returns later makes the player feel progress.
- Keep the Binder’s voice consistent: quiet urgency, not superhero bravado.

## Localisation plan

- Keep Echoes and Transmissions in localisable resources.
- Avoid puns and culturally-specific idioms; keep lines transportable.
- Prefer short sentences that fit small screens.

## Starter content pack (enough to test the system)

Echoes (12)
- “Warmth, sealed in glass.”
- “A colour that no longer exists.”
- “Rain on stone, remembered perfectly.”
- “A road that ends mid-step.”
- “Someone laughing, then nothing.”
- “Footprints with no maker.”
- “A melody with one note missing.”
- “Mist that tastes of metal.”
- “A name half-spoken.”
- “Sunlight trapped behind a crack.”
- “A promise written in frost.”
- “A doorway that opens onto sky.”

Transmissions (8)
- “Banked. The Ring takes note.”
- “Good. The Hollow hates a place that’s remembered.”
- “Another stitch. Do not linger.”
- “Careful. A charm can hold a place, not protect it.”
- “The shard is thinning. Bank what you can.”
- “Too late. Unbanked light scatters.”
- “Try again. Say the charm like it matters.”
- “You brought something back. That is enough for now.”
