# Seed charms

A seed charm is the player’s input that selects a deterministic world recipe. The project treats charms as “simple and shareable”: a charm should be easy to type, easy to read, and stable across devices.

## Accepted format (current implementation)

The current recipe builder is token-based:

- Use uppercase words separated by underscores, e.g. `RAIN_FOX_PEAKS`.
- Tokens are matched by presence. Unknown tokens are ignored.
- The same charm string always produces the same `seed64` and the same recipe.

Practical guidance:

- Keep to 2–4 tokens for readability.
- Avoid punctuation.
- If using spaces, normalise to underscores before saving/sharing.

## Token meanings (current)

These are the meaningful tokens in `BiomeSynthesisService` today:

- Climate / mood:
  - `RAIN`, `MIST`, `MOON` → cooler palette and “cool” weather bias
  - `SUN`, `BLOOM` → warmer palette and “warm” weather bias

- Terrain flavour:
  - `PEAKS` → ridged height noise (more mountainous)
  - `MESA` → billow height noise (more plateau-like)
  - Otherwise → perlin height noise

- Moisture flavour:
  - `MIST` → billow moisture noise
  - Otherwise → perlin moisture noise

If a charm contains both warm and cool cues, cool currently wins (because it is checked first).

## Examples

- `RAIN_FOX_PEAKS` — cool palette, ridged height noise.
- `SUN_MESA_BLOOM` — warm palette, billow height noise.
- `MIST_GROVE_MOON` — cool palette, billow moisture noise.

## Determinism notes

`seed64` is derived from the charm string using a stable hash + SplitMix64. This is intentionally not Swift’s `hashValue`. Any future Apple Intelligence output must be clamped and quantised before it affects world generation so that the same charm remains stable.

## Roadmap for richer seed semantics (design intent)

Without adding server cost or heavy assets:

- Introduce “verbs” (e.g. `DRIFT`, `SHARD`, `STITCH`) that toggle run modifiers.
- Allow a small, curated dictionary of “biome nouns” (e.g. `FJORD`, `HEATH`, `GROVE`) that map to deterministic parameter bundles.
- Keep free-form phrases as an optional input mode later, but always canonicalise to a stable internal form before hashing.

The rule to keep: a charm is a shareable, reproducible contract, not a prompt that can drift between OS versions.
