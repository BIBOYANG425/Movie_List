# C3 Web Blocking Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix four of the five C3-audit blocking findings that need no owner adjudication (B5 data loss, B2 corrupt-TV-rows, B1 id normalization, B3a missing RLS policy, B4 dead recompute trigger), so the web reference is correct before the iOS watchlist/discover port. The two owner-gated tails (B3b visibility, table drop) are deferred.

**Architecture:** Mostly `RankingAppPage.tsx`/`letterboxdImportService.ts` code fixes plus two small prod migrations (watchlist UPDATE policy; drop the dead taste-recompute trigger+functions, park the tables). Migrations applied by the controller via Supabase MCP after review, before merge — both are additive/removal-only and compatible with deployed code.

**Tech Stack:** TypeScript + vitest; Postgres (Supabase) RLS/trigger DDL.

## Global Constraints

- Binding source: `docs/plans/audits/2026-07-08-c3-watchlist-discover-web-audit.md` (findings B1-B5 + fixes). **Prod state verified 2026-07-08:** zero bare-format `tmdb_id` rows and zero season-less `tv_rankings` exist (so B1/B2 are PURELY PREVENTIVE — no data backfill, Q3 moot); `trg_recompute_taste` IS live in prod (B4 is a real fix, not cleanup); `watchlist_items` has DELETE/INSERT/SELECT but NO UPDATE policy (B3a confirmed).
- **Deferred to owner (do NOT implement):** B3b movie-watchlist follower-visibility (Q2 — changes what friends see); dropping `user_taste_profiles`/`movie_credits_cache` tables (Q1 — B4 drops only the trigger+functions and PARKS the tables, harmless empty skeletons, reversible).
- Canonical id form is `tmdb_{n}` for movies; TV `tv_{showId}[_s{n}]`; books `ol_{key}`. B1 normalizes at write time only.
- Behavior-preserving except the explicit bug fixes; the B5 fix changes `addItem/addTVItem/addBookItem` to report success so the caller only deletes the watchlist row on a confirmed save (this reverses the shipped data-loss behavior deliberately — iOS C3 must copy the CORRECTED semantics).
- Migration files `supabase/migrations/20260708_c3_*`; implementers never apply them. Every migration carries verbatim rollback.
- Web tests `npx vitest run services/__tests__/`, `npx tsc --noEmit` green. Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: B5 — rank-from-watchlist data loss (return success, delete-on-success)

**Files:** Modify `pages/RankingAppPage.tsx` (`addItem` ~516-521 + its `handleAddItem` caller ~1204-1206; `addTVItem`/`handleAddTVItem` ~779-784/1192-1197; `addBookItem`/`handleAddBookItem` ~1183-1190). Test: `services/__tests__/` — extract the "should delete watchlist row?" decision into a pure tested helper if the logic isn't already isolable; otherwise a component-behavior note (this repo has no component test harness — prefer extracting a pure `shouldRemoveBookmarkAfterRank(saveSucceeded: boolean): boolean` used by all three handlers).

- Read the three add/handle pairs first. Change `addItem`/`addTVItem`/`addBookItem` from `void` to return a success boolean (true on resolved upsert, false on the caught error — keep the toast). In each `handleAdd*`, guard the `removeFromWatchlist(...)` call on that success value (only delete the bookmark when the rank actually saved). Preserve the existing ordering (delete only after `onAdd` resolves).
- Extract `shouldRemoveBookmarkAfterRank(saveSucceeded)` (returns `saveSucceeded`) as a one-line pure export + a vitest test (true→true, false→false) so the corrected contract is pinned for the iOS port.
- Commit `fix(web): rank-from-watchlist keeps the bookmark when the save fails (B5 data loss)`.

### Task 2: B2 + D5 — UniversalSearch TV save sets showTmdbId + normalized genres

**Files:** Modify `pages/RankingAppPage.tsx` (`handleSearchSaveTV` ~1341-1352). Test: pure helper if extractable.

- Read `handleSearchSaveTV` and the correct in-modal path (`AddTVSeasonModal.tsx:169-183`) for the reference shape. Set `showTmdbId: show.tmdbId` and apply `normalizeTVGenres(...)` (the same normalizer every other TV write uses — import it) instead of raw compound genres. Verify `show.tmdbId` is the numeric show id in scope at that call site.
- Defensive routing (B2 fix's second half): confirm that with `showTmdbId` set, `rankFromWatchlist` → AddTVSeasonModal's show-level check (`showTmdbId && !seasonNumber`) now correctly routes whole-show bookmarks through season selection rather than the direct-to-tier branch. If the check keys on the int being truthy, a real `showTmdbId` fixes it; note the trace in the report. Do not change AddTVSeasonModal unless the routing still misfires.
- Commit `fix(web): TV watchlist save carries showTmdbId + normalized genres (B2/D5)`.

### Task 3: B1 — write-time tmdb_id normalization (preventive; no backfill)

**Files:** Modify `services/letterboxdImportService.ts` (~424, ~461 — the bare `String(entry.tmdbId)` writes to `user_rankings` and `watchlist_items`). Test: `services/__tests__/`.

- Extract/confirm a pure `canonicalMovieTmdbId(rawId: string | number): string` that yields `tmdb_{n}` (idempotent: `tmdb_603`→`tmdb_603`, `603`→`tmdb_603`, `"603"`→`tmdb_603`). If a normalizer already exists (grep `tmdb_` builders in tmdbService/DiscoverView), reuse it. Apply at both import write sites so imports can never mint bare ids again.
- vitest: idempotency + bare→prefixed + numeric→prefixed.
- NOTE in the report: prod has 0 bare ids today (verified), so this is purely preventive; no backfill migration is written (Q3 moot). The audit's other bare-id sources (`activityService` `manual:` minters) are dead code (D7) — do not touch.
- Commit `fix(web): letterboxd import writes canonical tmdb_ ids (B1 preventive)`.

### Task 4: B3a + B4 — watchlist UPDATE policy; drop dead taste-recompute trigger

**Files:** Create `supabase/migrations/20260708_c3_watchlist_update_policy.sql`, `supabase/migrations/20260708_c3_drop_taste_recompute.sql`.

- **B3a:** add the owner UPDATE policy to `watchlist_items` mirroring the tv/book tables' policy shape (read `supabase_tv_rankings.sql:105-108` for the exact form — `USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id)`). Verbatim rollback (DROP POLICY). This unblocks the merge-duplicates upsert's ON CONFLICT DO UPDATE path.
- **B4:** drop `trg_recompute_taste` (trigger), `trigger_recompute_taste`/`recompute_taste_profile` (functions — verify exact names via `select tgname, tgfoid::regproc from pg_trigger where tgrelid='user_rankings'::regclass and tgname like '%taste%'` semantics from the migration file `supabase_smart_suggestions.sql:100-316`). PARK the tables `user_taste_profiles`/`movie_credits_cache` (do NOT drop — Q1 owner decision; they become harmless empty skeletons once the trigger stops writing). Rollback comment quotes the trigger+function definitions verbatim from `supabase_smart_suggestions.sql`.
- Write `docs/plans/audits/2026-07-08-c3-migration-verification.md`: probes the controller runs post-apply — (1) `watchlist_items` now has an UPDATE policy; (2) an authenticated owner UPDATE on own watchlist row succeeds; (3) `select count(*) from pg_trigger where tgrelid='user_rankings'::regclass and tgname like '%taste%'` = 0; (4) a `user_rankings` upsert no longer writes `user_taste_profiles` (row count stable).
- Commit `fix(web): watchlist UPDATE policy + drop dead taste-recompute trigger (B3a/B4)`.

### Task 5: Contract doc + ledger

**Files:** Modify `docs/contracts/shared-payloads.md` (add `watchlist_items` + tv/book variants row shapes per §1.1; the corrected rank-from-watchlist "delete only on save success" contract; id-format canon `tmdb_`/`tv_{id}[_s{n}]`/`ol_`; TV whole-show `season_number 0-or-NULL` per D6); `docs/plans/2026-07-07-ios-parity-ledger.md` (C3 row → web fixes in PR; findings B1-B5 dispositions with prod-verified notes; deferred: B3b Q2 owner visibility, table-drop Q1 owner, all 14 D-items pointer).
- Verify every documented shape against the actual table DDL before writing.
- Commit `docs: watchlist contract + C3 ledger`.

## Self-Review Notes

- B5 (Task 1) is the highest-value fix — real data loss on every transient save failure, and the exact flow iOS C3 will port; the corrected contract is pinned by a pure test.
- B1/B2 are preventive (prod clean today) — no migrations, no owner ack.
- Task 4's two migrations are apply-then-merge safe: the UPDATE policy is purely additive; dropping the trigger only stops writes to unread tables (deployed code never reads them). Runbook order doesn't matter between the two.
- Deferred owner items (B3b, table drop) are ledgered with the exact adjudication needed, not silently dropped.
