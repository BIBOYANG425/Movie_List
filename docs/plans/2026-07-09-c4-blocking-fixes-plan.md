# C4 Blocking Fixes Implementation Plan (web + iOS correctness; management UI is a separate follow-up)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the six C4-audit blocking findings so ranking positions are trustworthy on both platforms BEFORE the iOS management UI is built: duplicate/gapped `rank_position` writes (B1/B2/B5), the delete-before-ceremony data loss (B3), zh-title corruption (B4), and the resurrect-on-reorder race (B6).

**Architecture:** One migration adds `set_tier_order` — a positions-only, delete-aware, transactional tier-order RPC (SECURITY INVOKER; UPDATE-only so it cannot resurrect; per media table via static branches, no dynamic SQL). Web routes every reorder/move/delete-compaction through it (full-row upserts remain ONLY for genuine ceremony inserts); the re-rank flow becomes non-destructive (no delete until the new rank exists — the `(user_id,tmdb_id)` upsert makes delete-first unnecessary); `onRerank` passes the raw (unlocalized) item. iOS's ceremony insert adopts splice semantics via the same RPC, fixing the live duplicate-position corruption. Controller applies the migration via MCP + probes before merge.

**Tech Stack:** Postgres 17 (plpgsql RPC), TypeScript + vitest, Swift + XCTest.

## Global Constraints

- Binding source: `docs/plans/audits/2026-07-09-c4-ranking-mgmt-web-audit.md` (findings B1–B6 fix shapes; §1 reference semantics). Branch `fix/c4-ranking-blocking` off main.
- **Position-integrity invariant (the contract this plan establishes):** per `(user_id, tier)` and per media table, `rank_position` is contiguous `0..n-1`, no duplicates. Every management write must preserve it; `set_tier_order` is the single primitive that enforces it.
- **Q4 adjudication (controller, owner-reviewable):** positions-only RPC over per-row full-row upserts. `set_tier_order(p_media text, p_tier text, p_tmdb_ids text[])`: for `auth.uid()`'s rows in the given media table, one UPDATE sets `tier = p_tier, rank_position = <ordinality of the id among those that EXIST>` for ids in the array (missing ids skipped — delete-aware compaction via `row_number()` over the surviving order); rows of that user+tier NOT in the array are untouched (callers must pass the full intended tier membership — document loudly). UPDATE-only ⇒ cannot resurrect. `p_media` CHECK'd against `('movie','tv','book')` with three static branches (user_rankings/tv_rankings/book_rankings). SECURITY INVOKER (the own-rows UPDATE RLS policies exist on all three tables). Returns the updated row count.
- Events: fixing B3 changes re-rank emissions from `ranking_remove`+`ranking_add` to a single `ranking_move` (metadata `{notes?, year?}` per the C1 contract). No-op drops emit nothing (B1's spurious event). These are the only event changes.
- **Title locale pin (B4):** the persisted `title` in `user_rankings`/`activity_events.media_title`/`movie_stubs.title` is the TMDB default-locale title, never a localized one. Contract doc gets this line.
- Orphan semantics on delete (audit-documented, now deliberate): only the ranking row is removed (+ tier compaction + `ranking_remove` event); stubs, journal entries, feed history, comparison logs survive; watchlist is NOT restored. Document, don't change.
- Migrations: `supabase/migrations/20260709_set_tier_order_rpc.sql`; implementers never apply; verbatim rollback. Web tests `npx vitest run services/__tests__/` + `npx tsc --noEmit`; iOS `swift test --package-path ios/Spool` (baseline 359). Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `set_tier_order` RPC migration (B6 foundation)

**Files:** Create `supabase/migrations/20260709_set_tier_order_rpc.sql`; Create `docs/plans/audits/2026-07-09-c4-verification.md` (controller probes).
- Implement per the Q4 adjudication above (plpgsql; `unnest(p_tmdb_ids) WITH ORDINALITY` joined to the user's existing rows, `row_number() OVER (ORDER BY ordinality)` - 1 as the new position; single UPDATE per branch; RAISE on unknown `p_media`; empty array = no-op returning 0). Header: the invariant, the full-membership caller contract, why UPDATE-only (resurrect-proof), rollback (`DROP FUNCTION`).
- Probes for the verification doc: (1) reorder happy path (contiguity after); (2) delete-aware — pass an id that doesn't exist, surviving ids compact 0..n-1; (3) cannot-resurrect — a deleted row stays deleted after a stale-membership call; (4) cross-user no-op (invoker + RLS: another user's ids unaffected, count 0); (5) tier-move — ids previously in another tier get `tier` updated; (6) unknown p_media raises.
- Commit `feat(sql): set_tier_order — positions-only, delete-aware tier reorder RPC`.

### Task 2: Web adopts the RPC for all reorder/move/compact paths (B1, B2, B6)

**Files:** Modify `pages/RankingAppPage.tsx` (movie `handleDrop` same-tier ~373-394 [B1], `handleDropOnItem` ~454-476, cross-tier drop, migration completion `addItem` source-tier compaction ~1218-1237/480-548 [B2], `removeItem` reindex ~605; the TV/book reorder/move/delete persists ~918-927/1001-1031/1156-1159 — replace their whole-tier full-row upserts with RPC calls too [B6]); Test `services/__tests__/tierOrder.test.ts` (new — the pure order-computation helpers).
- Extract pure helpers (tested RED-first): `tierOrderAfterReorder(ids, from, to) -> [id]`, `tierOrderAfterRemoval(ids, removedId) -> [id]`, `ordersAfterCrossTierMove(sourceIds, targetIds, movedId, targetIndex) -> {source, target}` — the RPC's inputs. Views compute the intended membership; `supabase.rpc('set_tier_order', {p_media, p_tier, p_tmdb_ids})` persists positions; full-row upsert remains ONLY where a NEW row is created (ceremony add path keeps its row upsert for the new/moved item's own row — tier order then set via the RPC).
- B1 specifics: same-tier container drop uses reindex-to-end via the helper + RPC; error handling + optimistic rollback (mirror `handleDropOnItem`'s pattern); suppress the `ranking_move` event when the order didn't change.
- B2 specifics: migration completion additionally calls the RPC for the SOURCE tier (membership minus the departed id).
- Commit `fix(web): all tier reorders/moves/compactions via set_tier_order (B1/B2/B6)`.

### Task 3: Non-destructive re-rank + raw-title (B3, B4)

**Files:** Modify `pages/RankingAppPage.tsx` (`onRerank` ~1534-1548/1674-1681 [B3]; the TierRow/MediaDetailModal `onRerank` argument path ~1523/402 [B4]); `components/media/MediaDetailModal.tsx` only if the raw-item lookup must happen there (prefer the RankingAppPage handler: look up the raw item by id in `items` — one line).
- B3: remove the up-front `removeItem` call. The ceremony's completion upserts the row on `(user_id,tmdb_id)` (same movie → same key → replace) and the Task-2 RPC compacts BOTH tiers (old tier loses the id: pass its membership minus the id; new tier gains it). Cancel at any step = nothing changed. Emission: completion emits `ranking_move` (not add), nothing emits `ranking_remove`. If the old and new tier are equal, it's a reorder (same-tier semantics).
- B4: the `onRerank` handler resolves the RAW item from `items` by id before setting `preselectedForRank` — localized titles never reach persistence. Add a comment pinning the title-locale contract.
- Tests: pure helper for the re-rank membership math if extractable; otherwise trace-in-report (view handler).
- Commit `fix(web): non-destructive re-rank emitting ranking_move; raw title on re-rank (B3/B4)`.

### Task 4: iOS ceremony insert splices the tier (B5)

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankingRepository.swift` (insertRanking gains splice semantics), `ios/Spool/Sources/Spool/Services/RankPersistence.swift` (passes what it already has); Test `ios/Spool/Tests/SpoolTests/TierSpliceTests.swift` (new).
- `insertRanking` becomes: fetch the target tier's ordered `tmdb_id`s (existing read or add one), pure-splice the new id at `rankPosition` (`spliceTierOrder(ids, newId, at) -> [String]`, clamped, tested RED-first incl. end/empty/out-of-range), INSERT the new row (upsert on `(user_id,tmdb_id)` — re-ranks on iOS hit the same path safely), then `rpc('set_tier_order', p_media from the item type, tier, splicedIds)`. A failed RPC after a successful insert logs loudly (positions self-heal on the next tier write; note it).
- Preview/queue paths (OnboardingQueue flush) route through the same method — verify, don't fork.
- Commit `fix(ios): ceremony insert splices the tier via set_tier_order — no more duplicate positions (B5)`.

### Task 5: Docs + ledger

**Files:** `docs/contracts/shared-payloads.md` (new `## user_rankings ordering` section: the position-integrity invariant, the `set_tier_order` contract incl. full-membership rule, the title-locale pin, the deliberate orphan semantics on delete, re-rank = `ranking_move`); `docs/plans/2026-07-07-ios-parity-ledger.md` (C4 row: blocking fixes in PR, B1-B6 dispositions, Q4 adjudication owner-reviewable, 10 deferred pointer; note the iOS management UI is the next sub-plan pending an owner design check).
- Commit `docs: ranking order contract + C4 ledger`.

## Self-Review Notes

- Order: T1 must land before T2-T4 reference the RPC (they only write files — the controller applies T1's migration before merge, so deployed-code compatibility holds: old code never calls the new RPC; new code merges after apply, same as C1/C3).
- B5 is the live-corruption fix and rides this branch so prod stops minting duplicates ASAP; existing corrupted tiers self-heal on the next tier write (any reorder/add), and a one-shot repair probe is included in the verification doc (detect: duplicate/gapped tiers per user — report count; the controller decides whether to run a compaction UPDATE, owner-ackable).
- The iOS management UI (edit notes / reorder / move / delete surfaces) is deliberately NOT here — it needs a short owner design check (where the affordances live) and builds on this corrected base.
