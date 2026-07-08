# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | iOS build in final review | audits/2026-07-07-c0-stub-web-audit.md | #30 | (PR opens after final review) |
| C1 | Feed + notifications | feed UI built on `feat/ios-parity-c1-feed-ui` (PR pending); data layer + web fixes already merged (#32, #34; migrations applied + probes passed 2026-07-08) | audits/2026-07-07-c1-feed-web-audit.md | #32 | #34 MERGED |
| C2 | Journal + AI agent | web fixes merged (PR #33); iOS journal built on `feat/ios-parity-c2-journal` (PR pending) | audits/2026-07-08-c2-journal-web-audit.md | #33 | (PR pending) |
| C3 | Watchlist + Discover | web blocking fixes in PR (B1/B2/B3a/B4/B5); iOS watchlist+discover port pending | audits/2026-07-08-c3-watchlist-discover-web-audit.md | (PR pending, branch `fix/c3-watchlist-discover-web-blocking`) | — |
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
- [C2] [blocking] B1 `search_journal_entries` SECURITY DEFINER + caller-trusted `target_user_id` leaked any user's private entries to any authenticated user — fixed on `fix/c2-journal-web-blocking` (ba8d5c9, follow-up 0279401): SECURITY INVOKER rewrite, RLS decides rows by construction, `personal_takeaway`/`search_vector` out of the return set
- [C2] [blocking] B2 `visibility_override IS NULL` ("Default") was world-readable, `profiles.profile_visibility` never consulted — fixed (57823ab, follow-up 978afb0): resolved-visibility RLS, `COALESCE(visibility_override, profile_visibility)`
- [C2] [blocking] B3 like-count RPCs manipulable by anyone + web toggle drifted counts in normal use — fixed (ba8d5c9, follow-up 0279401): `journal_entry_likes` table, lock-then-recount trigger owns `like_count`, counter RPCs dropped, cards load initial liked state
- [C2] [blocking] B4 `journal-photos` bucket public with unconditional read — fixed (78cc7f1): private bucket, owner-only prefix policies, 30-day signed URLs re-signed on render
- [C2] [blocking] B5 `personal_takeaway` labeled "(private)" but served to every viewer + full-text indexed — fixed (57823ab/978afb0 client selects + edit-seam; ba8d5c9 search half); RESIDUAL remains, see C2 open item (a)
- [C2] [blocking] B6 'friends'-visibility review bodies emitted into `activity_events` (explore-readable) — fixed (57823ab): emission gated on RESOLVED visibility = 'public', fail-closed profile fetch at emission time
- [C2] [blocking] B7 UTC-derived `watched_date` + mixed-timezone streak math — fixed (b001e2f): `localDateString` defaults (service + composer), pure `computeStreaks` in whole local calendar days
- [C2] [deferred] 16 findings D1–D16 logged in audits/2026-07-08-c2-journal-web-audit.md (feed-card re-emission on every save, tag-notification visibility leak, agent persistence races D3/D7/D8, provenance mislabels, consent auto-grant D11, open LLM proxy D12, spoiler render gap, perf; see doc)
- [C3] [blocking] B5 rank-from-watchlist deleted the bookmark even when the ranking save failed (data loss on transient failure, item in neither list) — fixed on `fix/c3-watchlist-discover-web-blocking` (a61087e): add/addTV/addBook return a success boolean, `shouldRemoveBookmarkAfterRank` gates the delete; iOS C3 copies the CORRECTED semantics, not the shipped behavior
- [C3] [blocking] B2/D5 `handleSearchSaveTV` minted TV bookmarks without `showTmdbId` (→ `show_tmdb_id=0`) and with raw compound genres; ranking them wrote season-less `tv_rankings` — fixed (cd6b902): `tvWatchlistItemFromShow` sets `showTmdbId` + `normalizeTVGenres`. Preventive (prod verified 0 season-less rows, no backfill)
- [C3] [blocking] B1 Letterboxd import wrote bare `String(entry.tmdbId)` (split-format ids corrupt exclusion/taste-regex/cross-user compare/dup rows) — fixed (af7cb92, c2ebcf5): all four import write-time sites (`user_rankings`, `watchlist_items`, `journal_entries`, exclusion reads) route through `canonicalMovieTmdbId`. Preventive (prod verified 0 bare ids, no backfill)
- [C3] [blocking] B3a `watchlist_items` had no UPDATE policy while `addToWatchlist` upserts merge-duplicates (ON CONFLICT DO UPDATE RLS-denied on stale pre-check) — fixed: migration `20260708_c3_watchlist_update_policy.sql` adds owner UPDATE mirroring tv/book
- [C3] [blocking] B4 `trg_recompute_taste` fired O(tier-size) SECURITY DEFINER full-profile recomputes per rank into `user_taste_profiles`, which no client reads (verified LIVE in prod) — fixed: migration `20260708_c3_drop_taste_recompute.sql` drops trigger + `trigger_recompute_taste()` + `recompute_taste_profile(uuid)`; tables `user_taste_profiles`/`movie_credits_cache` PARKED (Q1 owner)
- [C3] [deferred] 14 findings D1–D14 logged in audits/2026-07-08-c3-watchlist-discover-web-audit.md §3 (friend-pool sampling bias, no stale-request guard, variety pagination, dead-code cluster D7, whole-show `season_number 0` vs NULL D6, i18n misses; see doc) — not blocking the iOS port

## C1 adjudications (controller, 2026-07-07 — recorded verbatim, do not relitigate)

- Q1: keep — friends tab excludes the viewer's own events (unchanged web semantics)
- Q2: public-only — explore shows events from `profile_visibility = 'public'` actors only (OWNER REVIEW PENDING — explore may thin out since default visibility is 'friends'; one-line revert path exists in the migration's rollback comment block)
- Q3: windowless boost = legacy client behavior — `boosted_ts = created_at + 2h` for reviews, permanently; the plan's 2h-window pin was a plan-authoring error and the plan's "audit §2b" citation was dangling (no such section exists in the audit)
- Q4: `ranking_move` ported as-is (no dedupe/collapse of consecutive moves)
- Q5: reaction/comment notifications out of scope for C1 (ledgered follow-up)
- D1: `metadata.bracket` stays unwritten (dead read left in place for W0.3)

## C2 adjudications (controller 2026-07-08 — ALL owner-review-pending)

- `visibility_override IS NULL` ("Default") resolves to the author's `profiles.profile_visibility`, NOT world-readable; 'public' means all *authenticated* (anon reads nothing) — owner review pending
- `personal_takeaway` is owner-only everywhere: cross-user selects, search index/RPC, agent context for other users — owner review pending
- Journal photos: private bucket + signed URLs, 30-day expiry, re-signed on every render, never persisted — owner review pending (signed links are bearer tokens for their TTL; accepted trade-off)
- Likes: `journal_entry_likes` table (unique `(entry_id, user_id)`), `like_count` derived from rows by trigger, counter RPCs dropped; the apply-time reconcile zeroes legacy `movie_reviews`-era counts that have no attributable like rows (documented loss) — owner review pending
- Review activity events emitted only when RESOLVED visibility = 'public' (was `!== 'private'`) — owner review pending; public-profile authors' feed presence unchanged, friends-only authors stop appearing in explore

## C2 explicit open items

- (a) **B5 residual:** `personal_takeaway` is still readable via a hand-rolled API select on rows already visible to the caller — enforcement is client-side column lists + search exclusion; RLS stays row-level. The split-table redesign is the real fix; until then the UI's "(private)" label is an unmet promise.
- (b) **Probe-error-vs-no-row fallback in `pickEntryForEdit`:** a transient failure of the owner probe (error, not row-absence) falls back to the takeaway-less passed row, so a save in that window can still wipe the takeaway (rare, documented on the helper; strictly no worse than pre-fix).
- (c) **Letterboxd import UTC date fallback** (`services/letterboxdImportService.ts:498`): rows with no CSV watched date get `new Date().toISOString().split('T')[0]` — same B7 bug class; one-line follow-up (import `localDateString`).
- (d) **Per-card liked-state N+1:** `JournalEntryCard` calls `getLikedEntryIds` per card on mount; batch once at list level (`JournalHomeView`) — iOS should batch from day one.
- (e) **Migration filename order is wrong for tooling:** `20260708_journal_photos_private.sql` sorts FIRST among the C2 files while the runbook requires it LAST (and the visibility file, which must apply first, sorts last) — `supabase db push`/filename-ordered tooling would violate the runbook twice over; owner-manual apply only.
- (f) **Full-replace upsert semantics are the shared root cause** (audit §1.1): any partial caller silently clobbers fields — (a) and (b) are both symptoms. A read-modify-write path or partial-update RPC is the durable fix, and gates the audit §4 ceremony quick-entry recommendation.
- (g) **`JournalEntrySheet` dead code** (audit D15) still carries auto-save-on-dismiss and the old UTC date pattern; delete under roadmap item W0.3 before it is ever re-mounted. iOS ports `JournalConversation` semantics only.
- (h) **Likes bump `journal_entries.updated_at`** via the pre-existing BEFORE UPDATE trigger (no web reader renders `updated_at`; contract doc flags it) — accepted side effect; revisit if `updated_at` ever comes to mean "content edited".

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

### C1-UI notes

Feed UI built on `feat/ios-parity-c1-feed-ui` per `2026-07-08-c1-ios-feed-ui-plan.md` (Tasks 1–6); PR pending (data layer #34 + web fixes #32 already merged, both feed RPCs LIVE in prod). Full pure logic in tested layers (`FeedCards`, `FeedPageAssembler`, `TicketEngagementModel`); final contract re-check found zero closure/repository signature mismatches (compile is the proof) — grep gates: 0 `ISODate`, 0 `import UIKit` in any new `Feed*`/`Ticket*`/`NotificationBellView` file.

**Plan-authoring corrections caught during build (all adjudicated to web/contract):**

- Dicebear: plan prose said `7.x/initials/png`; web governs `8.x/thumbs/svg?seed=encodeURIComponent(username)` — iOS mirrors web byte-for-byte.
- Reaction set: plan/spec said `laugh/sad/mind_blown` (mockup emoji leaked into the spec); the wire contract set is `fire/agree/disagree/want_to_watch/love` — spec corrected, iOS uses the contract set.
- `FeedTicketFlip`: plan's Produces block carried a redundant `card:` param; shipped signature drops it (`FeedTicketFlip(isFlipped:front:back:)` — generic container, card flows through the front/back closures) — better generic API, plan Produces block corrected.

**Accepted platform/behavior deltas:**

- Score-badge rounding tie: iOS `%.1f` is half-even, web `toFixed` is half-up — they diverge only at an exact `.25` tie (`9.25 → 9.2` iOS vs `9.3` web); accepted, sub-perceptual on a display score.
- Web's card-mapping catch path renders the literal string `"Invalid Date"` at runtime; iOS raw-echoes the malformed timestamp instead (iOS is the better behavior).
- Throttle counts dict is per-page-assembly-CALL (created inside `assemblePage`, carried across that call's refill pages, reset on every new call) — matches web's per-`getFeedCards`-call reset.
- Swipe-delete dropped → long-press-only: a `ScrollView` (not a `List`) can't host `swipeActions`; the design doc's swipe claim is retired.

**Deferred / fast-follow (non-goals):**

- Event-type / tier / time-range FILTER UI: the pure pipeline stages exist (`FeedPipeline` type/tier/time filters, `boosted_ts`-below-cutoff early stop); adding the filter chrome is purely additive, no data-layer change.
- `journal_tag` notification deep-link → C2-iOS (the notification renders; the tap-through target is journal, which isn't built yet).
- Throttle-replay equivalence nuance: iOS PERMANENTLY skips throttled-tail milestones within a scroll session, whereas web can re-keep them on a fresh `getFeedCards` call (its dict resets per call and its offset→cursor bridge can re-walk the prefix). iOS's cursor-native paging never re-walks, so a milestone throttled on page N stays skipped for the rest of that scroll. Accepted — the daily cap is the intent; a re-kept milestone on scroll-back would be the surprising behavior.

**Shared-helper hoist candidate:**

- `stableSeed`'s `abs(Int.min)` edge (`abs(digits)` traps when the parsed trailing integer is exactly `Int.min`) is inherited VERBATIM from `StubsScreen`; the fix belongs in a shared-helper hoist, not a divergent copy in the feed layer — do it once, both call sites benefit.

**Task-4 minors carried:**

- Reaction toggle revert restores the FULL counts snapshot including comment count — if a comment landed between the optimistic toggle and its throw, the revert loses that interleaved comment bump until the next reload (edge; self-heals on reload).
- Composer char counter counts the UNTRIMMED draft, so trailing whitespace inflates the displayed count vs the ≤500-after-trim validation (cosmetic).

**Owner device-smoke checklist** (the two feed RPCs are LIVE in prod — migrations already applied — so real feed data should work on device now):

- Feed loads in BOTH friends + explore modes (with real data once you're signed in).
- Flip a ticket → react (fire / agree / disagree / want-to-watch / love) + comment → round-trip persists.
- Notification bell badge appears; opening the sheet marks fetched-unread read (badge clears).
- Settings → profile-visibility row changes value; if set to `public`, your own activity appears in explore.

### C2-iOS notes

Journal built on `feat/ios-parity-c2-journal` per `2026-07-08-c2-ios-journal-plan.md` (Tasks 1–6, 355 tests); final contract re-verify (Task 7) found zero DTO/payload mismatches against the Global Constraints quotes. Contract in `docs/contracts/shared-payloads.md` (`journal_entries` → iOS implementations).

**Built:** full manual journal — ceremony quick-entry (stage-a) + a journal tab in `StubsScreen` + the `JournalComposer` (15 editable fields) + photos + search + likes; emitters (review activity event + `journal_tag` notification) bound with a fail-closed public-only review gate (mirrors the web B6 fix).

**Corrections caught during build (adjudicated to web/contract):**

- `PLATFORM_OPTIONS` is 13 ids, not 14 (the plan/contract "14" miscounted a type-annotation line) — contract + plan text corrected.
- An invalid stored `visibility_override` resolves to `private` (web parity, fail-closed via the raw-string overload).
- Photo-add mints a MINIMAL side-effect-free entry (web parity — no duplicate review event / journal_tag on adding a photo; the full side effects fire only on an explicit save).
- Ceremony quick-entry and write-more are mutually exclusive (`writeJournalQuickEntry: false` on the write-more path) — no double-write / clobber.

**Deferred (own follow-ups, ledgered):**

- AI agent chat — the Kimi journal-agent edge-function client (session / consent / correction flow). Not built this cycle.
- Cross-user journal viewing on other profiles + its storage-policy prerequisite: the `20260708_journal_photos_private.sql` §4 resolved-visibility EXISTS storage-SELECT extension MUST be applied before any cross-user photo surface ships (owner-only SELECT fails closed otherwise).
- `journal_tag` notification deep-link on iOS (the notification renders; tap-through to the tagged entry is not wired).

**Known residuals carried:**

- Write-more probe-miss window can set a fabricated entry id for the photo folder segment (cosmetic — paths stay internally consistent).
- `journal_tag` fires regardless of visibility and re-fires on every save (web D2, mirrored as-is until D2 is fixed on web).

**Owner device-smoke checklist:**

- Rank a movie → tap "write more" → the composer opens seeded with the ceremony moods + one-liner.
- Fill fields including a photo → save → the entry appears in the Stubs/journal tab.
- A plain rank (no "write more") still creates a journal entry (stage-a quick entry).
- Edit an entry → verify `personal_takeaway` survives the edit (the probe-before-edit wipe-guard).
- Set the review public → it appears in the explore feed; a friends/private review does NOT.
- Like an entry; run a search.

## C2 migration runbook (owner applies)

Same precedent as the C1 runbook in PR #32: agent prod-DDL is
permission-gated, so the OWNER runs these files in the Supabase SQL editor
(project `emulyralduiitxuigboj`) in EXACTLY this order.
⚠️ **Filename-ordered tooling (`supabase db push` etc.) would sort them
photos → hardening → visibility — wrong twice over** (the photos file must be
LAST and the visibility file FIRST). Apply manually in the stated sequence;
each file's header documents its own ordering dependency.

**1. `supabase/migrations/20260708_journal_visibility_model.sql`** —
**DONE — applied to prod 2026-07-08.**
resolved-visibility SELECT RLS on `journal_entries` (B2). Its §4 compat-view
drop is a guarded no-op on this first pass (the view doesn't exist yet); it
is deliberately re-run as step 6. If the `DROP POLICY` fails, prod has
drifted from the migration files: stop.

**2. `supabase/migrations/20260708_journal_search_likes_hardening.sql`** —
**DONE — applied to prod 2026-07-08.**
invoker search RPC (B1), takeaway-free `search_vector` rebuild (B5 search
half), `journal_entry_likes` + lock-then-recount trigger + backfill/reconcile
+ counter-RPC drops (B3), transitional `journal_likes` compat view. Its
policies EXISTS-reference `journal_entries` and are only correct under
step 1's policy — hence the order.

**3. Verification probes** — **DONE — all probes passed 2026-07-08.** (C1 style: every data probe wrapped in
`begin; … rollback;`, run in the SQL editor which may `SET ROLE`). Fixtures:
`<OWNER>` = an account with `profiles.profile_visibility = 'friends'`, ≥1
entry with `visibility_override IS NULL` + `review_text` + a distinctive
`personal_takeaway`-only word, and ≥1 entry with
`visibility_override = 'private'` (id = `<HIDDEN_ENTRY_ID>`); `<VIEWER>` = an
authenticated user who does NOT follow `<OWNER>`; `<VISIBLE_ENTRY_ID>` = any
entry whose resolved visibility is 'public' for `<VIEWER>`.

Probe 1 — stranger reads a friends-resolved journal → **0 rows** (pre-fix:
every NULL-override row came back):

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select id, review_text, personal_takeaway
from journal_entries where user_id = '<OWNER>';
rollback;
```

Probe 2 — owner reads their own rows, private entry included, takeaway
present → **all of `<OWNER>`'s rows, `personal_takeaway` populated** (the
column exclusion is client-side — open item (a)):

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<OWNER>"}';
select id, visibility_override, personal_takeaway
from journal_entries where user_id = '<OWNER>';
rollback;
```

Probe 3 — search as stranger → **0 rows**, and the result set structurally
has NO `personal_takeaway` column (23-column RETURNS TABLE):

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select * from search_journal_entries('<word from OWNER review_text>', '<OWNER>');
rollback;
```

Probe 4 — takeaway text is no longer search-indexed: as `<OWNER>`
(`set local request.jwt.claims to '{"sub":"<OWNER>"}'`), search a word that
appears ONLY in a `personal_takeaway` → **0 rows** (pre-fix: weight-D match).

Probe 5 — like-insert on a visible entry succeeds; on an invisible one fails:

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
insert into journal_entry_likes (entry_id, user_id)
values ('<VISIBLE_ENTRY_ID>', '<VIEWER>');   -- expected: INSERT 0 1
rollback;

begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
insert into journal_entry_likes (entry_id, user_id)
values ('<HIDDEN_ENTRY_ID>', '<VIEWER>');    -- expected: 42501 RLS violation
rollback;
```

Probe 6 — recount sanity (no role switch, RLS bypassed) → **drifted = 0**
(legacy `movie_reviews`-era counts are zeroed by design; see adjudications):

```sql
select count(*) as drifted
from journal_entries je
where je.like_count is distinct from
      (select count(*) from journal_entry_likes jel
       where jel.entry_id = je.id);
```

**4. `supabase/migrations/20260708_journal_photos_private.sql` — LAST,
immediately before step 5.** **PENDING — applies immediately before merge.**
The ONLY non-apply-then-merge-compatible file in
the set: the moment `public = false` lands, the currently DEPLOYED bundle's
photo grid breaks (its `getPublicUrl` links 400) and stays broken until the
Vercel deploy of the new build — **this photo outage window lasts until step
5's deploy is live; keep it to minutes.** (Bounded tail: CDN edge caches may
serve already-fetched objects for up to their cacheControl=3600 lifetime.)

**5. Merge the PR** → Vercel deploys the new bundle (signed-URL rendering,
`journal_entry_likes` reads). Verify the deploy is live and photos render
again — the outage window closes here.

**6. Post-deploy (PENDING): re-run the §4 guarded compat-view drop** from
`20260708_journal_visibility_model.sql` (it no-oped in step 1 and, run now,
retires the `journal_likes` view that only pre-deploy bundles still read).
Exact statement, verbatim from the migration:

```sql
DO $drop_compat$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_views
             WHERE schemaname = 'public' AND viewname = 'journal_likes')
  THEN
    EXECUTE 'DROP VIEW public.journal_likes';
  END IF;
END $drop_compat$;
```

### C3 notes

Web fixes on `fix/c3-watchlist-discover-web-blocking` per
`2026-07-08-c3-web-blocking-fixes.md`; contract in
`docs/contracts/shared-payloads.md` (`watchlist_items (+ tv/book variants)`).

**Fixed (in the web PR):**

- **B5** rank-from-watchlist data loss — return-success from add/addTV/addBook, delete the bookmark only on confirmed save (`shouldRemoveBookmarkAfterRank`); the exact flow iOS C3 ports.
- **B2/D5** TV watchlist save now carries `showTmdbId` + normalized genres (`tvWatchlistItemFromShow`) — preventive, prod clean (0 season-less `tv_rankings`).
- **B1** write-time canonical `tmdb_` ids at all 4 Letterboxd import sites incl. `journal_entries` (`canonicalMovieTmdbId`) — preventive, prod clean (0 bare ids).
- **B3a** `watchlist_items` owner UPDATE policy migration (`20260708_c3_watchlist_update_policy.sql`).
- **B4** drop dead taste-recompute trigger + `trigger_recompute_taste()` + `recompute_taste_profile(uuid)` (`20260708_c3_drop_taste_recompute.sql`) — verified LIVE in prod; tables `user_taste_profiles`/`movie_credits_cache` parked.

**Deferred to OWNER (adjudication needed):**

- **Q2 — movie-watchlist visibility (B3b):** follower-visible (align with tv/book, unblocks the iOS Twin exclusion in `TasteRepository.getRecommendationsForFriend`) vs owner-only privacy. Changes what friends can see. Movie SELECT stays owner-only until decided.
- **Q1 — drop `user_taste_profiles` / `movie_credits_cache` tables:** currently PARKED by B4 (trigger+functions dropped, tables left as harmless empty skeletons; keeps the drop reversible). Owner decides the table drop.
- **B1 backfill — N/A:** prod verified 0 bare-format `tmdb_id` rows, so no one-shot `bare→tmdb_` UPDATE is written (Q3 moot). Same for B2 (0 season-less rows).

**Deferred D-items (D1–D14 in the audit §3):** friend-pool sampling bias (D1),
no stale-request guard on suggestion loads (D3), variety pool ignores `page` (D4),
whole-show `season_number 0` vs schema-NULL (D6 — contract doc pins "0-or-NULL"),
dead-code cluster D7 (SharedWatchlistView, `saveActivityMovieToWatchlist`,
`manual:` minters — W0.3 delete candidate), and 9 more. Not blocking the iOS port;
dispositions per the audit doc. **The discover EDGE FUNCTION (audit §2 —
`suggestions` + companion `tmdb-proxy`) is a SEPARATE C3 sub-project** needing
owner infra (TMDB secret in the function store + deploy) and product decisions
(Q4 proxy, Q5 pool provenance, Q6 what "Discover" is on iOS) — not in this web-fix PR.

**iOS gap (audit §4):** no watchlist/discover code exists on iOS. Needed —
`WatchlistRepository` (3 tables, §1.1 contract), the watchlist tab UI,
rank-from-watchlist with the CORRECTED B5 semantics (delete only on confirmed
save), `SuggestionsClient` (`functions.invoke('suggestions')` per §2), and fixing
`TasteRepository.getRecommendationsForFriend` per the B3 adjudication (Q2).

## C3 migration runbook (owner applies)

Same precedent as the C1/C2 runbooks: agent prod-DDL is permission-gated, so the
OWNER applies these files via the Supabase SQL editor / MCP `apply_migration`
(project `emulyralduiitxuigboj`). **Order does NOT matter between the two** — they
touch disjoint objects, and BOTH are apply-then-merge safe (the UPDATE policy is
purely additive; dropping the trigger only stops writes to tables the deployed
code never reads). Apply them, run the probes, then merge the PR.

**1. `supabase/migrations/20260708_c3_watchlist_update_policy.sql`** — B3a: adds
the owner UPDATE policy to `watchlist_items` (mirrors tv/book). Rollback (verbatim
in the file): `DROP POLICY "Users can update own watchlist" ON watchlist_items;`.

**2. `supabase/migrations/20260708_c3_drop_taste_recompute.sql`** — B4: drops
`trg_recompute_taste`, `trigger_recompute_taste()`, `recompute_taste_profile(uuid)`.
Tables `user_taste_profiles` / `movie_credits_cache` PARKED (Q1). Rollback
(byte-verbatim in the file) re-creates worker function → trigger function →
trigger against the still-present parked tables.

**3. Verification probes** — run the 5 probes in
`docs/plans/audits/2026-07-08-c3-migration-verification.md`, each write probe
wrapped `begin; … rollback;`:

- **(a)** `watchlist_items` has exactly one UPDATE policy (`Users can update own watchlist`) → expect `1`.
- **(b)** an authenticated owner UPDATE on their own watchlist row succeeds (`UPDATE 1`, no RLS denial).
- **(c)** `%taste%` triggers on `user_rankings` = `0` (and optionally `trigger_recompute_taste` + `recompute_taste_profile` gone from `pg_proc`). **This hard probe is the discriminator** — trigger-count `0` proves the drop regardless of profile-count movement.
- **(d)** a `user_rankings` upsert no longer grows `user_taste_profiles` (count stable). **Use a FRESH user with no prior taste profile** so the count-grows case discriminates (an existing-profile user only bumps `updated_at`, which a count can't see) — or rely on the hard probe (c) trigger-count=0.
- **(e)** parked tables `user_taste_profiles` + `movie_credits_cache` still EXIST (not dropped).

**4. Merge the PR.** No deploy-window sensitivity — both migrations are
apply-then-merge safe, so applying before or after the merge is fine.
