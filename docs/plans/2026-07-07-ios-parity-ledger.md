# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | iOS build in final review | audits/2026-07-07-c0-stub-web-audit.md | #30 | (PR opens after final review) |
| C1 | Feed + notifications | web fixes MERGED (#32, migrations applied + probes passed 2026-07-08); iOS data layer in PR #34; UI plan pending owner design input | audits/2026-07-07-c1-feed-web-audit.md | #32 | #34 |
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

### C1-iOS notes

Data layer built on `feat/ios-parity-c1-feed-data` per `2026-07-08-c1-ios-feed-data-plan.md`; final contract re-verification (Task 5) found zero DTO/payload mismatches against the Global Constraints quotes.

**(a) Plan-authoring corrections adjudicated during build (web = reference):**

- Milestone throttle: plan said "per actor per LOCAL calendar day"; web's actual post-#32 logic is GLOBAL across actors, keyed by the event's UTC date (`created_at.slice(0, 10)`). Adjudicated to web; iOS `FeedPipeline.throttleMilestones` mirrors it byte-for-byte (10-char prefix key, cap 3, per resume-session).
- Reply nesting: plan said "orphans surface as top-level"; web's render pass DROPS a reply whose parent is absent from the fetched page, and drops grandchildren (replies to replies) too. Adjudicated to web render parity; iOS `FeedPipelineComments.nest` mirrors the drop. Web's drop behavior is a candidate SHARED fix — if it changes, both platforms change in the same cycle.

**(b) Accepted platform differences (wire contract identical):**

- Over-length comments: iOS throws `CommentError.tooLong`; web silently `slice(0, 500)`s. The shared ≤500-after-trim contract is identical — the DB CHECK `length(btrim(body)) BETWEEN 1 AND 500` backstops both; iOS refuses rather than corrupts.
- Duplicate mute: iOS throws on the UNIQUE-triple 23505; web has no conflict handling either (`addMute` logs and returns false). Contrast reactions: "23505-on-insert = success" is D7's TARGET behavior — iOS implements it first; web's shipped toggle still returns false on any insert error, web fix deferred.

**(c) Part-B (UI plan) caller contract:**

- Pipeline stage order = web's: mutes/type filters BEFORE the milestone throttle; throttle runs LAST over the surviving rows.
- A throttle "session" = ONE page-assembly CALL: the caller owns the counts dict, passes the SAME dict across the refill pages consumed within that call, and resets it on every new call (web resets per `getFeedCards` call). Do NOT carry the dict across a whole scroll session — that would over-throttle vs web.
- Refill loop: `hasMore` = raw page row count == `page_size` (web L293-294); the refill loop is bounded at MAX 10 RPC pages per assembly call (web L213); time-range early exhaustion — stop paging once `boosted_ts` sinks below the range cutoff (web L303-306).
- Repository reads THROW; screens catch to empty state (web fails soft inside the service instead — iOS moved the soft-fail to the screen layer so bugs stay loud in the data layer).
- Notification avatar is the raw `avatar_path` storage path; the UI layer builds the public URL (no `avatar_url` fallback chain).
- `rankingScores` callers catch to empty map — a missing score means "hide the badge", never an error state.

**(d) 500-boundary unit note:** Swift `String.count` counts grapheme clusters, Postgres `length()` counts code points, web `.slice(0, 500)` counts UTF-16 units. The three agree on plain text; for exotic input (ZWJ emoji sequences, combining marks) a body that passes iOS's 500 check can still exceed the DB's 500, and the insert surfaces the raw Postgres CHECK error, not `CommentError.tooLong`. The DB CHECK is the backstop; no client fix planned.

#### Deferred to the UI plan (Part B)

The plan's Task 2 "mapping" mandate was narrowed to the Interfaces block during build — the following web `getFeedCards` stages are NOT in the data layer and ship with Part B, where the `FeedCard` model gets the owner's design input:

- Card mapping, including `toFeedCardType`'s unknown-type → `'ranking'` coercion and the S–D tier guard.
- Profile hydration with the 3-step avatar fallback chain (`avatar_url` → storage public URL from `avatar_path` → dicebear). `ProfileRepository.getProfilesByIds` already returns the needed columns.
- Tier and time-range filter helpers.
- Score-pair collection rule: pairs are collected ONLY for ranking/review cards that have a `media_tmdb_id` (web feedService L357-363).
