# C4 Web Audit — ranking management (reference semantics for iOS RankingRepository management ops)

**Cycle:** C4 (ranking management: edit notes, reorder within tier, move across tiers, delete)
**Audited at commit:** `8815127` on `main`
**Scope:** `pages/RankingAppPage.tsx` (all movie/TV/book management handlers), `components/media/AddMediaModal.tsx` (re-rank + migration entry), `components/media/MediaCard.tsx`, `components/media/MediaDetailModal.tsx`, `components/ranking/TierRow.tsx`, `components/media/RankingFlowModal.tsx`, `services/activityService.ts`, `services/stubService.ts`, `hooks/useLocalizedItems.ts`, `supabase/migrations/supabase_schema.sql` + `20260707_feed_ranking_scores_rpc.sql` + `20260708_c3_drop_taste_recompute.sql`, iOS `RankingRepository.swift` / `RankPersistence.swift` / `RankH2HScreen.swift` / `FullListScreen.swift` / `FeedScreen.swift`. Audit only — no code changed.

**Premise notes (read first):**
1. The **movie path is the reference** per program design, but for reorder/move integrity the movie path is the *worst* of the three: TV/book cross-tier drops compact BOTH tiers (`handleTVDrop`, `RankingAppPage.tsx:908-927`; `handleBookDrop :1153-1159`) while the movie path leaves gaps (B2) and duplicates (B1). The iOS port should implement the movie path's *product* semantics (migration comparison flow) with the TV/book *persistence* semantics (dual-tier compaction).
2. **There is no "edit notes" feature on web.** Notes are only writable inside a ranking ceremony (`NotesStep`); post-rank, the sole route is the destructive re-rank flow (§1.4, B3). "Edit notes" on iOS is therefore a semantics *decision*, not a port (Q3/gap list #4).
3. C3's B4 fix is confirmed landed: all three `trg_recompute_taste*` triggers + both functions are dropped (`20260708_c3_drop_taste_recompute.sql:407-417`), so whole-tier upserts no longer amplify into taste recomputes. The remaining whole-tier-write costs are `updated_at` churn (D1) and the B6 race.

---

## 1. Reference semantics

### 1.0 Position-integrity invariant (the contract everything else assumes)

> Within each `(user_id, tier)`, `rank_position` must be contiguous `0..n-1` with no duplicates (0 = best). Nothing in the DB enforces this — the only constraint is `UNIQUE(user_id, tmdb_id)` (`supabase_schema.sql:33`); the invariant is maintained purely by convention: every write path is supposed to rewrite the *entire affected tier* with recomputed indices.

Consumers that **break visibly** when it's violated:
- `get_feed_ranking_scores` RPC (`20260707_feed_ranking_scores_rpc.sql:80-100`) does arithmetic on the raw column: `score = lo + (hi-lo)·(tier_total-1-rank_position)/(tier_total-1)` with `tier_total = count(*)`. A **gap** puts the max position above `tier_total-1` → negative numerator → score **below the tier's lower bound** (B-tier item scoring 4.4; D-tier can go negative). A **duplicate** gives two items identical scores.
- iOS `getAllRankedItems`/`getTierItems` order by `rank_position` (`RankingRepository.swift:32,55`) — duplicates make order nondeterministic; the H2H engine walks that order.
- Web's own UI is *immune* (it sorts then uses array index — `computeScores`, `RankingAppPage.tsx:50-70`; `TierRow` sort `:1523`), which is exactly why B1/B2 have gone unnoticed.

Compliance matrix per write path:

| Path | Tier(s) rewritten | Invariant held? |
|---|---|---|
| ceremony insert `addItem` (`:485-516`) | target tier, full upsert | ✓ |
| same-tier reorder `handleDropOnItem` (`:434-471`) | target tier, full upsert | ✓ |
| same-tier drop-on-container `handleDrop` (`:373-394`) | **single-row UPDATE** | ✗ dup+gap (**B1**) |
| cross-tier migration (movie, `:366-371` → `addItem`) | target only | ✗ source gap (**B2**) |
| delete `removeItem` (`:556-605`) | removed item's tier, full upsert | ✓ |
| TV/book cross-tier (`:908-927`, `:1153-1159`) | **both** tiers | ✓ |
| TV/book same-tier reorder (`:978-996`, `:1180-1191`) | target tier | ✓ |
| iOS ceremony insert (`RankPersistence.swift:62-75` → `insertRanking`) | **none** — single INSERT at mid-tier `finalRank` | ✗ dup (**B5**) |
| `rankActivityMovie` (`activityService.ts:283-338`) | appends at max+1 | dead code (C3 D7) |

### 1.1 Reorder within tier (movie reference)

Two distinct drop targets, two different code paths:

- **Drop on another card** → `handleDropOnItem` (`RankingAppPage.tsx:412-478`). Same-tier: splice moved item to the target's index (`:445-446`), reassign `rank = idx` over the whole tier (`:449`), optimistic `setItems`, then **one upsert of the entire tier** on `(user_id, tmdb_id)` (`:454-471`). Rows carry all media columns + `notes: item.notes ?? null` + fresh `updated_at`; `watched_with_user_ids` is **omitted** (PostgREST only SETs supplied columns on conflict, so the column survives — D8). On upsert error: toast + **full rollback** to the pre-drop snapshot (`prevItems` captured `:433`, restored `:475`). **No activity event** is written for a same-tier reorder via this path.
- **Drop on the tier container** (TierRow row/header, `TierRow.tsx:104,132`) → `handleDrop` (`:356-410`). Same-tier: moves the item **to the end of the tier** (`newRank = others-in-tier count`, `:374-375`), updates ONLY the moved row (`.update({tier, rank_position, updated_at})`, `:390-394` — no error check, no rollback), and logs a **`ranking_move`** activity event (`:396-409`). This is the B1 corruption path.

TV/book reorders (`handleTVDropOnItem :955-997`, `handleBookDropOnItem :1169-1192`) mirror the whole-tier-upsert shape via `persistTVRankings`/`persistBookRankings` (`:759-789`, `:1001-1031`) but **toast without state rollback** on failure (D2). Post-C3 rollback status: movie drop-on-item = rollback ✓; movie drop-on-container = nothing ✗; TV/book = toast only ✗ (C1's note still current).

### 1.2 Move across tiers (re-tier)

**Movie (the migration comparison flow — the PR #35-aligned entry):** any cross-tier drop (container `:366-371` or on-item `:424-429`) does **not** write; it sets `migrationState = {item, targetTier}` and opens `AddMediaModal` with `preselectedItem` + `preselectedTier` (`:1598-1599`). The modal seeds notes/watched-with from the existing item (`AddMediaModal.tsx:176-180`) and **immediately starts a `RankingSession` against the target tier** (`:182-192`) — the size-table/notes steps are skipped (notes are carried, not editable — D6). On session done → `onAdd({...item, tier: preselectedTier, rank: finalRank})` → `handleAddItem` (`RankingAppPage.tsx:1218-1237`) → `addItem`:
- The full **target** tier is upserted with compacted indices (`:485-516`); the moved row's single DB row flips tier via the `(user_id,tmdb_id)` conflict. The **source tier is never rewritten** → persistent gap (**B2**).
- Event: **`ranking_add`** (`:524-536`), *not* `ranking_move` — the feed says "ranked" for what the toast calls "Moved to {tier}" (`:1233`) (D5).
- `createStub` fires (`:538-545`) → hits `UNIQUE(user_id, media_type, tmdb_id)` → 23505 **update path refreshes tier/template/title/poster/updated_at and preserves watched_date/palette/moods/stub_line** (`stubService.ts:114-133,147-166`). So a re-tier refreshes the stub, never duplicates it.
- The journal sheet pops even for a migration (`setJournalSheetItem`, `:1236`, unconditional — D9).
- **Cancel is safe**: closing the modal clears `migrationState` (`:1592`) with zero writes (contrast re-rank, B3).

**TV/book (plain cross-tier drop):** no comparison flow. `handleTVDrop`/`handleBookDrop` append the item at the end of the target tier, reindex **both** tiers, persist both in one upsert (`:908-936`, `:1149-1163`), and log **`ranking_move`** (`:939-952`, `:1164-1166`) with metadata `{notes?, year?}` — never `watched_with` (call sites don't pass it; `logRankingActivityEvent` builds metadata at `activityService.ts:25-28`).

**Score consumers need no sync:** nothing denormalizes scores. The feed RPC reads `rank_position` live per request (security invoker, RLS-scoped); web UI recomputes from state; iOS recomputes from fetched rows. A reorder/move is fully reflected on the next read. Confirmed: with C3's trigger drop, a whole-tier upsert costs exactly N row-writes + 1 event insert — no hidden amplification.

### 1.3 Edit notes (the surface that doesn't exist)

- Notes live in `user_rankings.notes`, written only by ceremony completion (`AddMediaModal` NotesStep → `proceedFromNotes :340-363` / `handleInsertAt :365-380`) and mirrored into `ranking_add` `metadata.notes`. Displayed as: sticky-note icon on cards (`MediaCard.tsx:105`), profile activity (`activityService.ts:103`), feed metadata. **No edit affordance exists** in `MediaDetailModal` (render-only, `:81,160-185`), `TierRow`, or anywhere post-rank.
- The only mutation route is **re-rank** (§1.4): the modal pre-fills the existing note (`AddMediaModal.tsx:154-171`) and the user can retype it at the NotesStep. Pressing **Skip clears the pre-filled note and watched-with** (`overrideSkip` → `finalNotes = undefined` → upsert `notes: null`, `:343-348` + `RankingAppPage.tsx:512`) — destructive for a step framed as "skip" (D3).
- **Journal interplay (the C2 divergence surface):** web notes and journal are fully disjoint stores. `JournalConversation` only *reads* `user_rankings` (`JournalConversation.tsx:88-91,160-165`); no management op touches `journal_entries`. On iOS, C2's stage-A quick-entry **full-replace upserts `journal_entries` on `(user_id, tmdb_id)` at every plain ceremony finish** (`RankPersistence.swift:91-109`). If iOS C4 implements re-rank/re-tier by re-running the ceremony through `RankPersistence.save` with `writeJournalQuickEntry=true`, a tier move would **clobber a rich journal entry with the ceremony's skeleton moods+line**. Management ops must pass `false` (or probe-first) — gap list #5.

### 1.4 Re-rank (web's only "edit" verb) — delete-first, then ceremony

`onRerank` (TierRow wiring `RankingAppPage.tsx:1534-1548`; deep-link modal `:1674-1681`; button `MediaDetailModal.tsx:401-407`): calls `removeItem(item.id)` (not awaited — full delete + reindex + `ranking_remove` event), then opens the modal with the item preselected. Consequences:
- **Abandoning the modal permanently loses the ranking** (B3) — the item is in neither rankings nor watchlist.
- A *completed* re-rank emits `ranking_remove` + `ranking_add` (never `ranking_move`), refreshes the stub via 23505, and re-pops the journal sheet.
- TierRow passes **localized** items into `onRerank` (`items={localizedItems...}`, `:1523`; `useLocalizedItems` swaps `title` for the zh-CN title, `useLocalizedItems.ts:111-114`; `MediaDetailModal` keeps `initialItem` as-is, `:81`), so completing a re-rank in zh locale **persists the Chinese title** into `user_rankings.title`, `activity_events.media_title`, and `movie_stubs.title` (B4). The migration flow is immune (it looks items up in raw `items`, `:361,418`).

### 1.5 Delete + orphan semantics

`removeItem` (`:550-621`): optimistic state reindex of every tier (only the removed item's tier actually changes), DELETE by `(user_id, tmdb_id)` (**result ignored** — D2), then whole-tier upsert of the affected tier's compacted indices (`:583-605`, toast on error, no rollback), then a `ranking_remove` event (`:607-620`, metadata `{notes?, year?}`). Per the C1 contract, `ranking_remove` is written but **only rendered in the FriendsView mini-feed** (`activityService.ts:56`); the main feed never shows removals.

**What survives a delete (the orphan inventory) — all deliberate-looking, none documented:**

| Artifact | Fate | Why it reads as intended |
|---|---|---|
| `movie_stubs` row | kept; a later re-rank *refreshes* it (23505 update) rather than duplicating | stubs are memorabilia ("ticket wall") |
| `journal_entries` row | kept | journal is a diary, independent of the shelf |
| `activity_events` history | kept forever — `ranking_add`/`ranking_move` cards stay in the feed (append-only, no UPDATE/DELETE policy per C1) | feed = immutable log |
| feed score badge | disappears cleanly — the RPC returns **no row** for a missing ranking and callers hide the badge (RPC header contract) | no dangling-pair corruption |
| `comparison_logs` | kept | telemetry |
| watchlist | **not** restored (delete ≠ un-rank back to bookmark) | product choice |

UX note: the delete affordance is a hover trash icon with **no confirmation** (`MediaCard.tsx:78-88`) — one click, permanent (D4). `handleReset` (`:334-349`) bulk-deletes the active vertical's entire table behind one `window.confirm`, with no events and the same orphan semantics wholesale (D10).

### 1.6 Side effects summary (per C1 metadata contract — all still accurate)

| Op | Event | metadata | `updated_at` churn |
|---|---|---|---|
| reorder (on-item) | none | — | whole tier |
| reorder (on-container, movie) | `ranking_move` | `{notes?, year?}` | 1 row |
| re-tier (movie migration) | **`ranking_add`** | `{notes?, year?, watched_with_user_ids?}` | whole target tier |
| re-tier (TV/book) | `ranking_move` | `{notes?, year?}` | both tiers |
| re-rank | `ranking_remove` + `ranking_add` | as above | 2× whole tier |
| delete | `ranking_remove` | `{notes?, year?}` | remaining tier |

C1 D13 is **still live**: `getTrendingAmongFriends` keys on `updated_at >= cutoff` (`tasteService.ts:334`), so any reorder/ceremony "trends" the whole tier; `MediaDetailModal`'s "Watched {date}" renders `updated_at` (`:200` area) and becomes "last time this tier was touched" (D1).

---

## 2. Findings

### Blocking

**B1 — Movie same-tier drop-on-container writes a duplicate `rank_position` and leaves a gap.**
`handleDrop` same-tier branch (`RankingAppPage.tsx:373-394`) computes `newRank = N-1` (end of tier) and updates **only the moved row**. If the item wasn't already last, the old last item still holds `N-1` (duplicate) and the vacated index `r` is a gap — persisted, and mirrored in optimistic state (only the moved item's rank changes, `:377-388`), so the tier's sort order becomes nondeterministic between the two tied rows. The single `.update` has **no error handling and no rollback** (contrast `handleDropOnItem :472-476`). It also logs `ranking_move` even when the drop is a no-op (item already last). TV/book container drops are immune (they reindex the tier, `:918-919`, `:1156-1157`).
*Fix shape:* route same-tier container drops through the same whole-tier-reindex persist as `handleDropOnItem` (or reuse `persistTVRankings`' pattern); add error handling + rollback; suppress the event on no-op. iOS must port the reindex semantics, not this handler.

**B2 — Movie cross-tier migration never compacts the source tier; the feed score RPC then emits out-of-range scores.**
Migration completion runs `addItem` (`:1218-1237` → `:480-548`), which rewrites only the **target** tier; the source tier keeps positions `0..N-1` minus the departed index — a permanent gap (state `:489` and DB both). `get_feed_ranking_scores` computes `lo + (hi-lo)·(tier_total-1-pos)/(tier_total-1)` (`20260707_feed_ranking_scores_rpc.sql:88-100`): with a gap, the bottom item's `pos = N-1 > tier_total-1`, so the numerator goes negative → **score below the tier floor** (B-tier item badged 4.4; a large D tier can badge negative). Web's own index-based `computeScores` masks it, so the corruption is only visible on feed badges and any `rank_position`-arithmetic consumer (including future iOS code). Gaps persist until some unrelated op rewrites that tier. TV/book cross-tier drops are correct (both tiers compacted, `:925-927`, `:1159`).
*Fix shape:* on migration completion, also rewrite the source tier compacted (web); the RPC could additionally rank by `row_number()` instead of trusting `rank_position` as defense-in-depth. iOS port must persist **both** tiers per move.

**B3 — Re-rank deletes the ranking before the new rank exists; cancel = permanent data loss.**
`onRerank` (`:1534-1548`, `:1674-1681`) fires `removeItem(item.id)` (unawaited: row deleted, tier reindexed, `ranking_remove` emitted) *before* the modal opens. Closing the modal at any step leaves the item deleted — in neither rankings nor watchlist; only the orphaned stub/journal remain. A completed re-rank also spams `remove`+`add` events (never `move`) per §1.6. This is the exact "aborting still saves" bug-class iOS already fixed for inserts (`RankPersistence.swift:4-9`) — the port must NOT reproduce delete-first.
*Fix shape:* defer the delete to ceremony completion (the migration flow already proves the non-destructive shape: no write until `onAdd`), or re-rank in place via the existing `(user_id,tmdb_id)` upsert.

**B4 — zh-locale re-rank persists the Chinese localized title into three shared tables.**
`TierRow` receives `localizedItems` (`:1523`); `useLocalizedItems` replaces `title` with the TMDB zh-CN title (`useLocalizedItems.ts:111-114`); `MediaCard` → `MediaDetailModal` (`initialItem`, kept verbatim at `:81`) → `onRerank(rankedItem)` (`:402`) → `preselectedForRank` → ceremony `onAdd` → `addItem` upserts `title: item.title` (`:502`) and writes `media_title` on the event (`:527-535`) and `title` on the stub refresh (`stubService.ts:125`). Net: one re-rank in zh mode silently swaps the canonical English title for the Chinese one for every viewer (feed cards, friends' profile activity, title-based exclusion nets — the C3 B1 title-net no-op becomes permanent). The migration and deep-link paths are immune (raw `items` lookups, `:361,418,1634`).
*Fix shape:* pass the raw item into `onRerank` (look up by id in `items` inside the handler — one line), or strip localization before persistence. iOS is unaffected today (no localization layer) but the contract doc should pin "persisted `title` is the TMDB default-locale title".

**B5 — iOS ceremony inserts mid-tier WITHOUT shifting the tier — duplicate positions are being written to prod today.**
`RankH2HScreen` produces a mid-tier `finalRank` (`:281`), `RankPersistence.save` passes it straight to `insertRanking` (`RankPersistence.swift:62-75`), which is a **single INSERT** (`RankingRepository.swift:117-123`) — no reindex, no upsert of tier-mates (repo has zero update/delete methods). Every iOS rank into a non-empty tier at position `p < n` mints a second row at `p` and shifts nobody: order nondeterminism for web reads, tied scores from the RPC, and a corrupted base that C4's management ops would then "manage". This predates C4 but C4 is the cycle that must fix it — management semantics are meaningless on non-compacted tiers.
*Fix shape:* iOS insert adopts the web contract: read tier, splice, write the whole tier compacted (upsert on `(user_id,tmdb_id)`) — or the Q4 RPC if adopted.

**B6 — Whole-tier upsert reorders can resurrect concurrently-deleted rows and interleave two-device reorders.**
Every management persist re-sends **full rows** (all media columns) upserted on `(user_id,tmdb_id)` from an in-memory snapshot (`:454-471`, `:583-600`, `:759-789`, `:1001-1031`). Device A deletes a movie; device B (stale snapshot) reorders that tier → B's upsert **re-INSERTS the deleted row** (upsert = insert-or-update), undoing the delete and leaving the tier `n+1` wide with A's compaction gone. Two concurrent reorders interleave per-row last-writer-wins into an ordering neither device chose (dups+gaps possible since each row settles independently). No web fix has shipped for any of the C1-noted race class; what's new here is that C4 is about to hard-code this write shape into Swift.
*Fix shape (decide before the port — Q4):* positions-only writes (`UPDATE ... SET rank_position` per row can't resurrect), a `reorder_tier(user_id, tier, tmdb_ids[])` RPC doing delete-aware transactional compaction, or accept-and-document single-writer assumption. The port should at minimum write positions-only for reorder/move/delete-reindex instead of full rows.

### Deferred

**D1 — Whole-tier `updated_at` churn (C1 D13 still live post-C3).** Reorder/ceremony bumps the tier (`:469,:514,:598`); `getTrendingAmongFriends` keys on it (`tasteService.ts:334`); `MediaDetailModal` renders it as the watched date. Fix candidate unchanged: key trending on `created_at`/events; consider not bumping `updated_at` for pure position rewrites.
**D2 — Error-handling matrix is inconsistent.** `removeItem`'s DELETE result is ignored (`:576-580` — offline delete silently "succeeds" until reload); movie `handleDrop` has zero error handling; TV/book persists toast without state rollback (`:783-787`, `:1025-1029`); only movie `handleDropOnItem` rolls back (`:472-476`). Port target: rollback everywhere.
**D3 — NotesStep "Skip" during re-rank destroys existing notes + watched-with** (`AddMediaModal.tsx:343-348` writing `notes: null`, `watched_with: []` via `:512-513`). Pre-filled data + a button named "Skip" ≠ "clear". Decide intended semantics before porting.
**D4 — Delete is a one-click hover trash with no confirm** (`MediaCard.tsx:78-88`), permanent given B3-class orphan semantics. iOS should add a confirm affordance regardless of web.
**D5 — Re-tier event semantics diverge by vertical:** movie migration emits `ranking_add` (toast says "Moved"), TV/book emit `ranking_move`. Feed copy misrepresents movie moves and re-ranks double-count "ranked" milestones. Standardize (Q2) before iOS writes events.
**D6 — Migration skips the NotesStep** (`AddMediaModal.tsx:174-192`) — notes are carried but not editable during a move; combined with §1.3 there is no notes editor anywhere. Product gap feeding Q3.
**D7 — Dead code: `computeStickyTiers`/`getNaturalTier`/`getTierTolerance`** (`RankingAppPage.tsx:36-105`) have zero callers. Do not port; delete on next web touch.
**D8 — Payload-shape asymmetry:** `addItem` includes `watched_with_user_ids` for every tier-mate (`:513`) while reorder/delete reindex upserts omit the column (`:455-470`, `:584-599`) — safe only because PostgREST updates only supplied columns. A Swift port that encodes nil-as-null would wipe tier-mates' data (same clobber class as C2's journal D5). Pin "omit, never null" in the contract doc.
**D9 — The journal sheet pops after migrations too** (`:1236` unconditional) — a tier move prompts "journal this?" for a movie journaled months ago.
**D10 — `handleReset`** (`:334-349`): vertical-wide DELETE behind one confirm, no activity events, orphans stubs/journals wholesale, and TV/book/movie each reset independently (mediaMode-scoped). Port decision: probably don't ship on iOS.

---

## 3. iOS gap list (what C4 must build)

Today: `RankingRepository` is **insert-only** (`RankingRepository.swift` — no update/delete/upsert methods, no `ranking_move`/`ranking_remove` writers); `FullListScreen` is read-only (header `:1-22`, no context menu/swipe); the feed context menu has mute-only (`FeedScreen.swift:144-145`); `StubsScreen` renders stubs, not rankings, and needs nothing from C4 beyond the 23505-refresh contract already honored by `StubWriter`.

1. **Fix the insert first (B5):** ceremony insert becomes read-tier → splice → whole-tier compacted write. Everything below assumes compacted tiers.
2. **`RankingRepository` management ops** (movie table first; TV/book same shapes later):
   - `reorderWithinTier(tier, orderedIds)` — persist whole tier compacted; **positions-only writes** per B6 unless Q4 lands the RPC.
   - `moveAcrossTiers(item, targetTier, finalRank)` — persist **both** tiers compacted (TV/book semantics, not web-movie's B2); event per Q2's decision.
   - `deleteRanking(tmdbId)` — delete row + compact its tier + `ranking_remove` event `{notes?, year?}`; leave stub/journal/events/watchlist untouched (§1.5 orphan contract, pending Q5 ack).
   - `updateNotes(tmdbId, notes)` — pending Q3; if built, a **notes-column-only UPDATE** (never a full-row upsert — D8's clobber class), mirrored into nothing (events are append-only; journal stays independent).
3. **Screens:** FullListScreen gains reorder (drag or up/down), re-tier (the migration comparison flow — reuse `RankH2HScreen` against the target tier), delete-with-confirm (D4), and the notes affordance per Q3. Feed context menu needs no management entries (web feed has none).
4. **Journal guard:** management ops that re-run the ceremony MUST pass `writeJournalQuickEntry: false` (`RankPersistence.swift:38-44,104-109`) — otherwise the stage-A full-replace clobbers rich journal entries (§1.3). Re-rank/move must also not re-fire quick-entry even on "plain finish".
5. **Event writers:** add `ranking_move`/`ranking_remove` with the §1.6 metadata shapes (reuse `ActivityMetadata`'s omit-empty encoder, `RankingRepository.swift:261-292`).
6. **Do NOT port:** delete-first re-rank (B3), the drop-on-container single-row update (B1), source-tier gaps (B2), localized-title persistence (B4), full-row reindex payloads (B6/D8), sticky-tier dead code (D7).
7. **Contract doc** (`docs/contracts/shared-payloads.md`): the §1.0 invariant, §1.6 event table, orphan semantics, "persisted title = default-locale title", "reindex payloads omit unmanaged columns".

## 4. Open questions

1. **Q1 (B2/B1 web fixes):** fix the movie handlers web-side in C4 (small, contained: route container-drops through the reindex path; compact the source tier on migration) so iOS ports clean semantics — or ship iOS correct-by-construction and leave web for a fix PR? Recommend: web fix PR in-cycle; both bugs actively corrupt prod positions.
2. **Q2 (event for re-tier):** standardize on `ranking_move` (TV/book behavior; feed already renders it) and stop emitting `ranking_add` for migrations? Affects milestone counts and feed copy.
3. **Q3 (edit notes as a product):** does iOS C4 ship a real notes editor (notes-only UPDATE + no event? new event type?), and does web get one too — or does "edit notes" stay ceremony-only? The C2 direction ("journal becomes source of truth") argues for editing the journal entry instead and demoting `user_rankings.notes` to a mirror.
4. **Q4 (write vehicle):** whole-tier upsert (status quo; B6 races), positions-only UPDATEs (no resurrection; still interleavable), or a transactional `reorder_tier` RPC (fixes both, one round trip — same pattern as the C1 score RPC)? Decide before Swift hard-codes one; recommend the RPC.
5. **Q5 (orphan ack):** confirm delete's keep-stub/keep-journal/keep-events semantics are intended product behavior and document them, or schedule cleanup. Also: should delete offer "move back to watchlist"?
6. **Q6 (DB guard):** add defense-in-depth for the §1.0 invariant — e.g. the RPC recomputing positions server-side, or a periodic compaction check? A plain `UNIQUE(user_id, tier, rank_position)` would break the current non-transactional writers (B1/B5 rows already violate it in prod — audit before adding).
