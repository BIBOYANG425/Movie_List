# C1 Web Feed Blocking Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four blocking findings from the C1 web feed audit (N+1 scores, explore privacy leak, explore reactions RLS, unstable pagination) so the web reference is correct before the iOS feed port.

**Architecture:** Two SQL RPCs move feed math into Postgres (`get_feed_ranking_scores` for the score N+1; `get_feed_page` for keyset pagination that preserves the 2-hour review boost). Two RLS migrations scope explore to public profiles and extend reactions/comments to whatever explore can show. `feedService.ts` adopts the RPCs; pure helpers stay unit-tested. Migrations are applied to prod (project `emulyralduiitxuigboj`) by the controller AFTER review and BEFORE code merge — both RPCs are additive and the RLS changes are compatible with the currently-deployed code.

**Tech Stack:** Postgres 17 (Supabase), PostgREST RPC via supabase-js, TypeScript + vitest.

## Global Constraints

- The audit doc is the binding source: `docs/plans/audits/2026-07-07-c1-feed-web-audit.md`. Its §2 contains the full `get_feed_ranking_scores` migration sketch — use it verbatim as the starting point; its §1 defines the reference semantics that must NOT change except where a finding says so.
- Adjudicated decisions (controller, 2026-07-07, owner review pending — do not relitigate): Q1 friends-tab excludes self (unchanged); **Q2 explore = 'public' profiles only**; **Q3 keep the 2h review boost** via expression keyset in `get_feed_page`; Q4 `ranking_move` ported as-is; Q5 reaction/comment notifications out of scope; D1 `metadata.bracket` stays unwritten (dead read left for W0.3).
- All RPCs `security invoker` — RLS must keep applying to the caller. No `security definer` anywhere.
- Score parity is behavior-critical: `get_feed_ranking_scores` must reproduce `computeTierScore` exactly (tier ranges S 9.0–10.0, A 7.0–8.9, B 5.0–6.9, C 3.0–4.9, D 0.1–2.9; single-item = midpoint rounded to 1dp; linear interpolation rounded to 1dp). A vitest test must compare RPC-shape SQL math against `computeTierScore` outputs via the existing fixture-free unit approach (pure TS reimplementation of the SQL expression compared to `computeTierScore` across a grid).
- Migration files land in `supabase/migrations/` with date prefix `20260707_*`; the controller applies them via the Supabase MCP — implementers NEVER apply migrations or touch prod.
- Feed card shapes consumed by `SocialFeedView`/FeedCard components must not change (§1.7 of the audit lists the load-bearing fields).
- Web tests: `npx vitest run services/__tests__/`, `npx tsc --noEmit`. Existing suites stay green.
- Conventional commits; end bodies with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `get_feed_ranking_scores` RPC migration + feedService adoption (fixes B1)

**Files:**
- Create: `supabase/migrations/20260707_feed_ranking_scores_rpc.sql` (from audit §2 sketch, finalized)
- Modify: `services/feedService.ts:84-138` (`getRankingScores` becomes one `supabase.rpc('get_feed_ranking_scores', { pairs })` call + result mapping; delete the per-user/per-tier query loops)
- Test: `services/__tests__/feedScores.test.ts` (new)

**Interfaces:**
- Produces: SQL function `get_feed_ranking_scores(pairs jsonb) returns table(user_id uuid, tmdb_id text, score numeric)` — `pairs` is `[{"user_id": "...", "tmdb_id": "...", "media_type": "movie"|"tv_season"|"book"}]`. TS: `getRankingScores(pairs: ScorePair[]): Promise<Map<string, number>>` keyed `${userId}:${tmdbId}` (existing key format — verify at line ~130 before changing).

**Steps:**
- [ ] Write the migration from the audit §2 sketch: UNION ALL over `user_rankings`/`tv_rankings`/`book_rankings`, `count(*) over (partition by src, user_id, tier)` + `row_number()` for position, inline `(values ('S',9.0,10.0),('A',7.0,8.9),('B',5.0,6.9),('C',3.0,4.9),('D',0.1,2.9))` tier ranges, single-item midpoint + linear interpolation both `round(x, 1)`. Filter early: join against `jsonb_to_recordset(pairs)` so only requested (user, item) rows compute. `security invoker`, `stable`, `grant execute to authenticated`.
- [ ] Write the parity test FIRST (RED against a TS transcription of the SQL expression before it exists as an exported helper): factor the SQL's math into an exported pure TS mirror `sqlTierScore(position, total, tierMin, tierMax)` in the test file itself, compare against `computeTierScore` from `services/rankingAlgorithm` for every (position, total) in totals 1..25 × all 5 tiers — must be exactly equal after rounding to 1dp.
- [ ] Adopt in `feedService.getRankingScores`: build `pairs` from the cards (existing dedupe logic stays), one `.rpc()` call, map rows to the existing `Map` key format, missing pairs default as today (verify current default — audit §1.4). Keep the function signature identical so `getFeedCards` is untouched by this task.
- [ ] `npx vitest run services/__tests__/feedScores.test.ts` green; full services sweep green; `npx tsc --noEmit` clean.
- [ ] Commit: `fix(web): feed scores via single get_feed_ranking_scores RPC, kills ~100-query N+1`.

### Task 2: Explore privacy + reactions RLS migrations (fixes B2 + B3)

**Files:**
- Create: `supabase/migrations/20260707_explore_visibility_rls.sql`
- Create: `supabase/migrations/20260707_reactions_comments_explore_rls.sql`
- Test: none executable locally (RLS is DB-side); instead write `docs/plans/audits/2026-07-07-c1-rls-verification.md` with the exact SQL probes the controller runs against prod after applying (as unprivileged-role simulations via `set local role`/`set local request.jwt.claims`).

**Steps:**
- [ ] Explore policy: replace the phase-5 `activity_events` public-read policy (audit §1.6 names it — read the original migration first, drop by exact name) with: readable when `actor_id = auth.uid()` OR actor is followed by `auth.uid()` (existing follower clause, keep verbatim) OR actor's `profiles.profile_visibility = 'public'` (Q2 decision). Use an EXISTS subquery against `profiles`; verify the `profile_visibility` column name/values from the profiles migration before writing.
- [ ] Reactions/comments policies: extend `activity_reactions` + `activity_comments` SELECT/INSERT policies so a user can read/write reactions and comments on any event they can SELECT under the new events policy (EXISTS against `activity_events` — PostgREST evaluates the events policy transitively). Read the current policy definitions first (audit §1.3 cites the migration file) and preserve their author-only UPDATE/DELETE clauses.
- [ ] The verification doc lists: leak probe (as a non-follower, select a 'friends'-visibility user's events — expect 0 rows), public probe (expect rows), reaction-insert probe on a public actor's event (expect success), and the pre-fix failing case for regression comparison.
- [ ] Commit: `fix(web): explore respects profile_visibility; reactions/comments RLS covers explore scope`.

### Task 3: `get_feed_page` keyset pagination RPC + adoption (fixes B4)

(Correction: the §2b citation was erroneous; boost semantics were adjudicated windowless to match the legacy client — see ledger.)

**Files:**
- Create: `supabase/migrations/20260707_feed_page_rpc.sql`
- Modify: `services/feedService.ts` (`getFeedCards` fetch/sort/slice core — audit §1.1 lines; replace offset+refetch+client-resort with cursor calls; keep card assembly, mutes, and score enrichment untouched)
- Test: `services/__tests__/feedPagination.test.ts` (new — pure cursor-encoding helpers + boost-window edge cases)

**Interfaces:**
- Produces: SQL `get_feed_page(mode text, cursor_rank timestamptz, cursor_id uuid, page_size int) returns setof activity_events` where ordering key is `rank_ts = greatest(created_at, case when event_type = 'review' and created_at > now() - interval '2 hours' then now() end)`… **STOP — this is the audit's sketch region; the audit §2b defines the exact boost-preserving expression `boosted_ts`; use it verbatim.** Keyset predicate `(boosted_ts, id) < (cursor_rank, cursor_id)`, order desc, limit `page_size`. `security invoker` so the Task 2 policy scopes rows per-mode; `mode` only switches the friends-filter clause (follower EXISTS) vs explore (no extra clause — policy does the work). TS: `getFeedCards` keeps its public signature; internal cursor type `{ boostedTs: string; id: string } | null`; `hasMore` = `rows.length === PAGE_SIZE`.
- [ ] Pure helper tests first (cursor encode/decode round-trip; boost window boundary: review created 1h59m ago sorts above a ranking_add created 30m ago, review at 2h01m does not).
- [ ] Adopt, keeping visible ordering identical for page 1 (boost preserved). Delete the `fetchLimit = limit+offset+20` refetch and the client-side re-sort.
- [ ] Full sweep + tsc green. Commit: `fix(web): keyset feed pagination via get_feed_page RPC, review boost preserved`.

### Task 4: Contract doc + ledger

**Files:**
- Modify: `docs/contracts/shared-payloads.md` (new section: `activity_events` — all 6 event types + full metadata shape per type from audit §1.2, marked as the shape BOTH clients must write from C1 on; note iOS currently writes none — gap closes in the C1 iOS PR. New section: `notifications` — types written today (`new_follower`, `journal_tag`), rendered-only types, orphaned types)
- Modify: `docs/plans/2026-07-07-ios-parity-ledger.md` (C1 row → web fixes in PR; findings: 4 blocking with dispositions, 12 deferred pointer, Q1–Q5/D1 adjudications recorded verbatim with "owner review pending" on Q2/Q3)
- [ ] Verify every documented metadata field against the writing call sites before committing (a wrong contract doc is worse than none). Commit: `docs: activity_events + notifications contracts, C1 ledger`.

---

## Self-Review Notes

- Task order matters only for 1→3 (both touch feedService; 3 rebases on 1's committed state). Task 2 is independent.
- The controller (not implementers) applies migrations to prod and runs the Task 2 verification probes, in this order: apply all three migrations → probes → merge PR → post-deploy smoke. Rollback plan: RPCs are additive (DROP FUNCTION reverts); the RLS migration includes the prior policy definition in a comment block for one-statement restore.
- Spec coverage: B1→Task 1, B2+B3→Task 2, B4→Task 3, contract/ledger duty→Task 4. Q-decisions embedded in Global Constraints.
