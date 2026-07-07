# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | iOS build in final review | audits/2026-07-07-c0-stub-web-audit.md | #30 | (PR opens after final review) |
| C1 | Feed + notifications | web fixes in review → PR pending | audits/2026-07-07-c1-feed-web-audit.md | (PR pending, branch fix/c1-feed-web-blocking) | — |
| C2 | Journal + AI agent | pending | — | — | — |
| C3 | Watchlist + Discover | pending | — | — | — |
| C4 | Ranking management | pending | — | — | — |
| C5 | TV seasons + books | pending | — | — | — |
| C6 | zh localization | pending | — | — | — |
| C7 | Smaller items | pending | — | — | — |

## Audit findings

Format per entry: `[cycle] [blocking|deferred] finding — disposition`.

- [C0] [blocking] stubService upsert clobbered `palette` on every re-rank — fixed in PR #30 (a44ae3f)
- [C0] [blocking] stub `watched_date` UTC (evening ranks land on tomorrow), live + backfill paths — fixed in PR #30 (a44ae3f, 8fbcaac); forward-only, historical rows keep UTC dates
- [C0] [deferred] 6 findings logged in audits/2026-07-07-c0-stub-web-audit.md (rewatches unrepresentable in one-stub-per-item model; backfill date is a proxy; and 4 more, see doc)
- [C0] [deferred, review] pin `process.env.TZ` in stubService date tests so a UTC-methods regression fails on UTC CI; defensive try/catch in `insertStubOrUpdateOnConflict`; fold both into the iOS C0 cycle or W1.x
- [C0] [resolved] iOS legacy insertStub violated the write contract (sent palette/mood_tags/stub_line, GMT dates, no conflict handling) — deleted; StubWriter is the only stub write path
- [C1] [blocking] B1 ~100-query N+1 in `getRankingScores` on every feed page — fixed: single `get_feed_ranking_scores` RPC (5de49be)
- [C1] [blocking] B2 explore RLS ignored `profile_visibility` (privacy leak) — fixed: explore SELECT policy rewritten to own/followed/public-profile actors per Q2 (b4fc47a)
- [C1] [blocking] B3 reactions/comments RLS never extended for explore (counts read 0, toggles silently fail) — fixed: engagement policies now track event visibility transitively (b4fc47a)
- [C1] [blocking] B4 offset pagination + client re-sort (duplicates, skips, premature end, O(n²) refetch) — fixed: `get_feed_page` keyset RPC over the boosted ordering key (a81944e, f52d90b)
- [C1] [deferred] 12 findings (D1–D12) logged in audits/2026-07-07-c1-feed-web-audit.md §3 — not blocking the iOS port; dispositions per that doc
- [C1] [note] milestone-throttle resume semantics changed with keyset pagination: the 3/day cap now counts per-call from the resumed cursor onward (was prefix-wide, because the legacy code re-fetched the whole feed prefix every page) — accepted (`services/feedService.ts:269-274`)
- [C1] [note] D-tier score rounding: for D-tier populations ≥ 57 the RPC's numeric half-away-from-zero rounding can sit +0.1 above the legacy client's float result — accepted divergence, documented in `supabase/migrations/20260707_feed_ranking_scores_rpc.sql` (701a0ff)
- [C1] [note] audit §1.7 claimed the notifications type CHECK "was never pruned" of party/poll/group types — stale: `20260325_drop_parties_polls_groups.sql:17-25` pruned it to the 6 live types; the contract doc records the pruned CHECK

## C1 adjudications (controller, 2026-07-07 — recorded verbatim, do not relitigate)

- Q1: keep — friends tab excludes the viewer's own events (unchanged web semantics)
- Q2: public-only — explore shows events from `profile_visibility = 'public'` actors only (OWNER REVIEW PENDING — explore may thin out since default visibility is 'friends'; one-line revert path exists in the migration's rollback comment block)
- Q3: windowless boost = legacy client behavior — `boosted_ts = created_at + 2h` for reviews, permanently; the plan's 2h-window pin was a plan-authoring error and the plan's "audit §2b" citation was dangling (no such section exists in the audit)
- Q4: `ranking_move` ported as-is (no dedupe/collapse of consecutive moves)
- Q5: reaction/comment notifications out of scope for C1 (ledgered follow-up)
- D1: `metadata.bracket` stays unwritten (dead read left in place for W0.3)

## Behavior notes awaiting owner ack

- [C1] Q2 explore = public-only profiles (see C1 adjudications): explore may thin out until users opt into public visibility; revert is one statement via the rollback block in `supabase/migrations/20260707_explore_visibility_rls.sql`.

(PR #29's tier-migration size-table change was acked by merge on 2026-07-07.)

## Deferred minors carried from the engine-unification branch

- Corpus v2: misaligned-seed fixture case, cross-language undo replay, `tsc --noEmit` step in CI
- Style: MARK casing (SpoolRankingEngineTests), 2-space indent block (rankingAlgorithm.ts), dead `Bracket` import (RankingFlowModal)
- `sessionRef` not nulled on start-done paths in the 4 web surfaces (unreachable; fold into W1.3)
- Session-level self-comparison filter (`id !== newItem.id`) with test (upstream-guarded today)
