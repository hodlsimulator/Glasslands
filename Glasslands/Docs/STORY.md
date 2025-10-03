# Glasslands — Story & Objective

## North Star (one‑liner)
A pocket wilderness that rewrites itself from your seed charm. Enter, relight its glass beacons, and bank their light before the world shifts again.

## Premise (short)
Long ago the Sky Ring shattered, and our world splintered into wandering **glasslands** — pocket biomes that take shape from small charms (emoji and words). Each charm you cast stabilises one of these wandering places just long enough to explore. Within every glassland lie dim **Glass Beacons** and a lone **Waystone**. Relight the beacons and carry their light to the Waystone to mend a sliver of the Ring.

*(This cleanly matches your current “seed charm → Biome Recipe → streamed world” flow, and the existing collectible beacons.)* :contentReference[oaicite:0]{index=0}

---

## Core Objective (per run)
- **Goal:** Collect as many **Glass Beacons** as you can and **bank** them at a **Waystone** before **Dusk** (a short timer) falls. Banked beacons = your score for that run.  
  *(Beacons already spawn and increment score on pickup; this formalises what the number means and adds a simple “bank” step.)* :contentReference[oaicite:1]{index=1}
- **Loop:**  
  1) **Cast a Seed Charm** (pick 2–3 Genmoji or a short phrase).  
  2) **Drop In** to its generated glassland.  
  3) **Relight Beacons** (they shimmer; get close to collect).  
  4) **Find the Waystone** and **Bank** to lock in your score.  
  5) **Mint a Postcard** (optional) and **share** the charm as a **Challenge** for friends. :contentReference[oaicite:2]{index=2}

**Why it works now:**  
- Beacons exist and increment score on contact in both 2D and 3D paths.  
- HUD already shows **Score** and **Pause**.  
- Postcards/Leaderboards hooks exist.  
You only need to add a simple Waystone set‑piece and a Dusk timer UI. :contentReference[oaicite:3]{index=3}

---

## Win / Fail
- **Win the run:** Reach the Waystone and Bank before Dusk.  
- **Soft fail:** Dusk falls while unbanked → you keep only the last banked total (or zero if you never banked).  
- **Leaderboards:** “Most Beacons Banked” and “Fastest First Bank” per daily charm. *(Uses the system Games overlay / leaderboards.)* :contentReference[oaicite:4]{index=4}

---

## Meta‑Progression (lightweight, optional)
- **Mending the Ring:** Each run that banks ≥N beacons awards a **Ring Shard**. Collect shards across any charms to complete **Ring Steps** (cosmetic milestones: title cards, postcard frames, UI tints). *(Cosmetic only; aligns with your postcards & style packs.)* :contentReference[oaicite:5]{index=5}

---

## World Bits (diegetic names)
- **Glass Beacons:** Small standing lenses that hum when you’re near. *(Shimmering visuals match what you draw now.)* :contentReference[oaicite:6]{index=6}  
- **Waystone:** A taller prism that accepts beacon‑light; pulses brighter as you approach.  
- **Dusk:** A short countdown; sky warms, audio hushes, vignette grows.

---

## Acts (seasonable arcs you can ship piecemeal)
**Act I — “Light the Beacons”**  
- *Objective:* Bank 5 beacons on any charm.  
- *Tutorial beats:* Cast charm → move → collect a beacon → find the Waystone → bank.  
- *Challenge template:* 3‑minute sprint: most banked.

**Act II — “Follow the Rivers”**  
- *Objective:* Bank a chain of beacons placed along riverbeds in one charm. *(Your noise fields include a river mask, so placement is trivial.)* :contentReference[oaicite:7]{index=7}

**Act III — “Ring Singer”**  
- *Objective:* Bank 10+ beacons on three unique charms to unlock a cosmetic “Sky Ring” postcard frame.

---

## Challenge Templates (ready for the Games overlay)
1) **Daily Charm Sprint** — 3:00 timer, most beacons banked. *(Share just the charm string; determinism gives identical worlds.)* :contentReference[oaicite:8]{index=8}  
2) **First Bank Race** — First to reach the Waystone and bank 3 beacons.  
3) **Cartographer** — Visit 3 map pins (simple set‑pieces) then bank once.

---

## Minimal Tutorial Copy (on‑screen, < 150 chars each)
- **“Relight the Glass Beacons”** — They shimmer; walk into them.  
- **“Find the Waystone”** — Bank to lock your score.  
- **“Dusk is coming”** — Bank before the light fades.  
- **“New Charm, New World”** — Change the seed any time.

*(Fits your current HUD, pause apply, and postcard flow.)* :contentReference[oaicite:9]{index=9}

---

## Implementation Notes (bite‑size)
- **Waystone set‑piece:** Place one per centre/chunk cluster; physics body + name `"waystone"`; on contact, **commit score** and flash UI. (Mirror your `BeaconStructures` placement and 3D `BeaconPlacer` sink.) :contentReference[oaicite:10]{index=10}  
- **Banking:** Add a `bankedScore` and `runScore` to your scoring; banking moves `runScore` → `bankedScore`.  
- **Dusk:** A countdown shown on HUD (progress pill). On expire, end run with `bankedScore`.  
- **Leaderboards:** Submit `bankedScore` at bank or when Dusk ends; show Games overlay button you already expose. :contentReference[oaicite:11]{index=11}

---

## Sample In‑Game Blurbs (short & British)
- *Prologue:* “The Ring broke. The lands wander. Your charm holds a place still — just long enough to bring the light home.”  
- *Waystone:* “Banked. The Ring remembers.”  
- *Dusk:* “Light thins. Make for the stone.”

---

## Why this fits the slice
- Uses the systems you already ship: **seed charms**, **deterministic biomes**, **glass beacons**, **postcards**, **leaderboards**.  
- Requires only two small additions for a full loop: **Waystone** placement and a **Dusk** timer.  
- Plays great solo; **Challenges** work by sharing the charm string and comparing scores. :contentReference[oaicite:12]{index=12}

