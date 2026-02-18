# Glasslands — roadmap (performance-aware)

This is a build plan that makes the game feel like a game without requiring heavy decoration density. The priority is “meaning per object”: fewer things, each with clear purpose.

## Constraints (hard)

- Keep the world light on nodes and physics. Prefer systems (timers, UI, audio, lighting) over more meshes.
- Keep determinism: shared charms should reproduce world layout and narrative selection.
- Keep changes chunk-local: anything that scales with “all beacons in the world” will become a performance trap.

## Milestone 1 — turn the sandbox into a run

Outcome: A run has a clear start, a clear end, and a reason to move with urgency.

Build:

1) Waystone
- Exactly one Waystone per run (or per N×N chunks), placed deterministically.
- Banking radius is generous enough to be readable and forgiving.

2) Banking rules
- Carrying beacons is temporary; banking makes them permanent for the run result.
- Banking triggers a clear feedback moment (sound + screen text + glow).

3) Dusk timer
- A short countdown that starts when the run starts.
- Dusk affects presentation (sky warmth shift, vignette, audio hush) before it ends the run.

4) Run outcome screen
- Shows: collected, banked, time remaining, best for this charm, best overall.
- Offers: retry same charm, remix charm, share charm (later).

Performance notes:

- Waystone should be a single node with simple material.
- Banking detection should be near-field (player vs local setpiece), not a world scan.
- Dusk effects should be shader/light tweaks, not spawning particles everywhere.

## Milestone 2 — navigation without a heavy map

Outcome: The player can make decisions and route quickly without the world being stuffed with props.

Build:

1) Compass / bearing HUD
- Minimal arrow that points to the Waystone.
- Optional second indicator for “nearest beacon” (only look in nearby chunks).

2) Ping system
- A short, rhythmic ping that grows faster when facing the Waystone.
- Works with accessibility (visual alternative).

3) Landmark language (cheap)
- One or two “silhouette” landmarks per biome (e.g. a tall rock spire, a crystal cluster).
- Use extremely low density: landmark-per-chunk is too much; aim for landmark-per-run or per several chunks.

Performance notes:

- Do not add a minimap that requires full scene capture every frame.
- If “nearest beacon” is implemented, index beacons by chunk and query only a small neighbourhood.

## Milestone 3 — narrative that feels earned

Outcome: Banking and progress have emotional weight. The player wants “one more run” to see the next fragment.

Build:

1) Echo fragments
- Beacon pickup shows 1 line of text for ~2 seconds (subtle).
- Deterministic per charm + beacon index so friends see the same echoes.

2) Waystone transmissions
- Banking shows a short 2–4 line message.
- These messages reflect success/failure and tease the next thread.

3) Journal
- A simple screen that stores and displays collected Echoes.
- Groups by “Ring Steps” so the player sees progress.

4) Ring Shards (meta)
- Banking thresholds award shards (e.g. bank 3, 6, 9 beacons).
- Shards unlock cosmetic frames/tints and narrative chapters.

Performance notes:

- This milestone is mostly UI + persistence. It should be almost free at runtime.

## Milestone 4 — make it shareable

Outcome: A run becomes something that can be shared and compared without building social infrastructure.

Build:

1) Charm cards
- A compact share sheet payload: charm string + a small “rules version” tag.
- Optional postcard attached.

2) Daily/weekly charms
- Fixed featured charms with leaderboards.
- Local generation; no servers required.

3) Challenges (future)
- Integrate with the platform layer you already have (Game Center / Games overlay) when ready.

Performance notes:

- Keep “challenge” logic out of the hot path. It is UI and metadata.

## Milestone 5 — biome variety, not biome clutter

Outcome: New charms feel different because rules change, not because density explodes.

Build:

1) Run modifiers (“verbs”)
- Examples: `DRIFT` (fog/mist), `SHARD` (more beacons, less time), `STITCH` (banking bonus).
- These are systemic shifts (timer, visibility, scoring), not object spam.

2) A second setpiece type (one only)
- Something that changes decision-making: a “Rift” that shortcuts but costs time, or a “Mirror Pool” that reveals waystone direction for a moment.
- Place rarely: at most one per several chunks.

3) Audio identity per biome
- Simple procedural or parameterised ambience; no need for large asset packs.

## Performance budget (rules of thumb)

- Do not introduce per-frame O(N) scans over all setpieces.
- Keep setpieces indexed per chunk.
- Prefer shader/light changes over new particle systems.
- Physics bodies should be rare. If collision is needed, use simple radii as you already do with obstacle hitRadius.
- Keep per-chunk decoration as “suggestive”: a few hero nodes, not fields of small meshes.

## Codex change style (workflow guard-rail)

- One milestone item per Codex session.
- Allowed scope should be narrow (one or two files + any required small helpers).
- No project file edits; no scheme edits; no commits from Codex.
- Compile gate + `git status --porcelain` printed, then stop.
