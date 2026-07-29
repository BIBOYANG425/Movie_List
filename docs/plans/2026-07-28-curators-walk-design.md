# The Curator's Walk — Gallery Redesign (Design)

**Date:** 2026-07-28
**Status:** Implemented (Tasks 1-5) — pending live pass (Task 6)

## What

Rebuild Gallery mode as **The Curator's Walk**: a fullscreen, first-person night-museum
walk through the user's ranked canon. One continuous dark hall; posters hang in strict
rank order, alternating left/right walls, each in its own pool of light with a serif
rank numeral (`№ 7`) beneath. As you scroll, you *walk*; as you reach each piece the
camera drifts to the opposite wall and **turns to face it fully**, holds, then swings
back and walks on — the rhythm of a curator doing rounds. Click pulls the case off the
wall to float before you (placard: title, director/year, curator's note, rank line);
Esc rehangs it. You walk *through* floating tier lettering ("S · TRANSCENDENT · 15
FILMS · 9.0–10.0") between wings.

## Why this shape (decisions from the session)

- **Minimal everywhere** — no ornament; drama = light + order + the user's posters.
  (Velvet/gilded/salon and book-spine shelf concepts were explored and rejected.)
- **Walkthrough > lateral wall** — user verdict on prototypes: corridor walk with a
  full turn to each poster beats the glide-along-wall.
- **Scales to 100-film tiers** — the walk is linear; big tiers = longer wings. Rank is
  strict (anchor ceremony H2H, `rankingSession.ts`), so a single ordered path is the
  honest representation. Tier nav letters fast-travel between wings.
- **Fullscreen takeover** — the current embedded canvas breaks immersion; the Walk
  mounts in a portal over the app. Desktop-first showcase surface; the 2D board stays
  the mobile/daily surface.
- **Inspect must be bright** — the merged gallery's inspected poster renders near-black
  in production. Root-cause first; the Walk dims the world with a curtain/fog, never
  the inspected case, and a pixel-sample smoke assertion guards regression.

## Key mechanics (validated in prototype)

- Stations: `z` spaced ~2.7 world units, side alternates L/R; №1–3 slightly larger.
- Turn: per-frame dominant-station weight `w = smoothstep(1.6 − |camZ − z|, 0, 1.25)`;
  camera x drifts `−side · 1.15 · w`; look target lerps corridor-ahead → poster center
  by `smoothstep(w, .12, .9)`.
- Inspect: case lerps to `camera + forward·2.1`, faces camera, scales to ~2.3 world
  height; fog density ~3× during inspect dims everything else.
- Reuse from merged gallery: texture windowing (`textureWindow.ts`), WebGL support
  check + grid fallback, context-loss recovery, reduced-motion crossfades, 7px
  click-vs-drag, lazy three.js chunk.

## Attribution

Interaction patterns (continuous walk, pull-forward inspect, click-vs-drag) studied
from The Complete Shelf (mintdotgg/mint-playground, MIT as of 2026-07-28). Add MIT
attribution note to `GalleryEngine.ts` header.

## Out of scope (this pass)

Mobile tuning pass, Feed/Discover/Profile restyle, board-as-ledger, font swap
evaluation — tracked in the whole-app design brief (session artifact).
