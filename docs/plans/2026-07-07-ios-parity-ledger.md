# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | iOS build in final review | audits/2026-07-07-c0-stub-web-audit.md | #30 | (PR opens after final review) |
| C1 | Feed + notifications | feed UI built on `feat/ios-parity-c1-feed-ui` (PR pending); data layer + web fixes already merged (#32, #34; migrations applied + probes passed 2026-07-08) | audits/2026-07-07-c1-feed-web-audit.md | #32 | #34 MERGED |
| C2 | Journal + AI agent | web fixes merged (PR #33); iOS journal built on `feat/ios-parity-c2-journal` (PR pending) | audits/2026-07-08-c2-journal-web-audit.md | #33 | (PR pending) |
| C3 | Watchlist + Discover | FULLY COMPLETE (Parts A + B) — edge functions deployed, both clients migrated off direct TMDB key, TMDB key DoD met, merged Discover on both platforms (chips + New Releases + card actions), journal wipe fix T0, anon onboarding fixtures | audits/2026-07-08-c3-watchlist-discover-web-audit.md | (Part A: branch `fix/c3-watchlist-discover-web-blocking`; Part B: `feat/c3-part-b-suggestions`) | `feat/ios-parity-c3-watchlist` (Part A) + `feat/c3-part-b-suggestions` (Part B) |
| C4 | Ranking management | COMPLETE — web fixes PR #39 + iOS management UI SHIPPED on `feat/ios-parity-c4-mgmt-ui` (PR pending): edit-mode drag-to-reorder (FullListScreen shelf), long-press menu (move tier / edit notes w/ probe-before-edit + wipe guard / re-rank via corrected ceremony / delete w/ confirm + ranking_remove); ceremony re-rank correction landed (Task 2 — deviation retired) | audits/2026-07-09-c4-ranking-mgmt-web-audit.md | #39 | `feat/ios-parity-c4-mgmt-ui` (PR pending) |
| C5 | TV seasons + books | COMPLETE — web fixes PR #46 + iOS 8-task branch `feat/ios-parity-c5-tv-books` (PR pending): per-media payloads/reads, TMDB TV endpoints, OpenLibrary client, media-generic ceremony (same-media H2H), TV season UI + preselect router + coordinator whole-show identity fix, TV suggestions grid, contracts | audits/2026-07-10-c5-tv-books-web-audit.md | #46 | `feat/ios-parity-c5-tv-books` (PR pending) |
| C6 | zh localization | pending | — | — | — |
| C7 | Smaller items | pending | — | — | — |
| — | iOS design-check | queued after C5–C7 (owner, 2026-07-10); screenshot seed list in progress ledger | — | — | — |

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
- [C3] [adjudication] Q2 movie watchlist visibility = FOLLOWER-VISIBLE (owner, 2026-07-09): aligns with tv/book, unblocks iOS Twin-exclusion; migration `20260709_c3_movie_watchlist_follower_select.sql` in Part A branch
- [C3] [adjudication] Q6 iOS Discover = ONE MERGED SCREEN: social sections (friend recs + trending) now in Part A; engine grid + provenance chips = Part B (owner, 2026-07-09)
- [C3] [adjudication] Q6 web DiscoverView = merged layout: friend sections + engine grid with provenance chips + New Releases row = Part B scope (owner, 2026-07-09)
- [C3] [adjudication] Q5 provenance chips = YES, Part B (pool labels on iOS/web Discover cards)
- [C3] [adjudication] Q4 tmdb-proxy = Part B (key stays in bundles until then)
- [C3] [adjudication] Q7 threshold hard-coded at 3; Q3 MOOT (prod verified 0 bare ids)
- [C4] [blocking] B1 same-tier drop-on-container wrote a duplicate `rank_position` and left a gap (single-row UPDATE, no reindex) + emitted `ranking_move` even on no-op — fixed on `fix/c4-ranking-blocking`: same-tier container drops route through the reindex helper + RPC; event suppressed when order unchanged
- [C4] [blocking] B2 movie cross-tier migration never compacted the source tier — fixed: migration completion calls `set_tier_order` for the source tier (membership minus the departed id), matching TV/book dual-tier behavior
- [C4] [blocking] B3 re-rank deleted the ranking before the new rank existed (cancel = permanent data loss); emitted `ranking_remove`+`ranking_add` instead of `ranking_move` — fixed: delete deferred to ceremony completion; re-rank flow non-destructive; completion emits single `ranking_move`
- [C4] [blocking] B4 re-rank in zh locale persisted the Chinese localized title into `user_rankings`, `activity_events.media_title`, and `movie_stubs.title` — fixed: `onRerank` handler looks up the raw item by id in the unlocalized `items` array before setting `preselectedForRank`
- [C4] [blocking] B5 iOS ceremony insert wrote a mid-tier row without shifting the tier (duplicate positions being written to prod on every iOS rank into a non-empty tier) — fixed: `insertRanking` adopts splice semantics: read tier membership → pure-splice at clamped position → UPSERT the row → `set_tier_order` RPC renumbers the whole tier
- [C4] [blocking] B6 whole-tier full-row upserts could resurrect concurrently-deleted rows (upsert = insert-or-update on stale snapshots) and interleave two-device reorders — fixed: `set_tier_order` RPC is UPDATE-only (cannot INSERT), positions-only (no media columns), and server-side transactional; all reorder/move/delete-compaction writes route through it
- [C4] [adjudication] Q4 positions-only RPC over full-row upserts for all reorder/move/compact operations — owner-reviewable; see `docs/contracts/shared-payloads.md` `## user_rankings ordering` for the full contract
- [C4] [deferred] 10 findings D1–D10 logged in audits/2026-07-09-c4-ranking-mgmt-web-audit.md §2 (updated_at churn D1, inconsistent error-handling rollback D2, NotesStep Skip clears notes D3, one-click delete no confirm D4, re-tier event divergence D5, migration skips notes edit D6, dead computeStickyTiers D7, watched_with_user_ids clobber on payload asymmetry D8, journal sheet pops after migration D9, handleReset bulk-delete no events D10) — not blocking the iOS port
- [C4] [deferred] TV/book re-rank still deletes up-front — same data-loss class as B3; needs the B3 treatment in a later cycle
- [C4] [deferred] iOS `insertRanking` tv/book path is latent-broken: `RankingPayload` carries `director`; `tv_rankings` needs `creator` + NOT NULL `show_tmdb_id`/`season_number`; `book_rankings` needs `author` — fails loudly, unreachable today (no tv/book ceremony on iOS); C5 must extend the payload
- [C4→fixed] iOS ceremony re-rank deviation (was `ranking_add` + target-only splice) — FIXED in the iOS management-UI sub-plan (Task 2): `insertRanking` pre-reads the existing row, compacts the SOURCE tier on a cross-tier re-rank (live membership minus the id), and emits a single `ranking_move` (`{notes?, year?}`, watched-with stripped) via the pure `CeremonyEmission.decide` seam; fresh insert still `ranking_add`. Contract Known-deviations §3 retired. Tests: `TierSpliceTests` +7.
- [C4] [deferred] web `addTVItem`/`addBookItem`: RPC failure is silent (no toast) and `ranking_add` still fires regardless — toast + event gate needed in a later cycle
- [C4] [deferred, iOS mgmt UI] plain-finish re-rank fires the stage-A journal quick-write full-replace: an existing rich journal entry for the movie is replaced by the near-blank quick draft (pre-existing ceremony posture mirroring web stage-A; the new long-press re-rank affordance makes it a first-class path). Candidate fix: skip the quick-write when `InsertOutcome == .moved`, or probe-before-quick-write. `user_rankings.notes` itself is safe (omission pinned).
- [C4] [deferred, iOS mgmt UI] shelf projection carries no notes → move/remove emissions carry `{year?}` only (web carries notes — analytics divergence); re-rank doesn't preseed the existing note in the editor (preservation-by-omission pinned by test); "—" director placeholder can overwrite NULL director on re-rank (pre-existing mapping pattern, worth a C5 cleanup); moveTo/delete are single-shot with no in-flight guard; done-during-inflight sub-second stale window on the optimistic list.
- [C5] [blocking] B1 UniversalSearch "Rank TV" skipped season selection + minted season-less `tv_rankings` rows (`show_tmdb_id=0`, `season_number=0`, `tmdb_id='tv_{showId}'`) — fixed on `fix/c5-tv-books-web-blocking`: `handleSearchRankTV` now passes `showTmdbId: show.tmdbId` + normalized genres; modal preselect router hardened to treat any `^tv_\d+$`-shaped id with no `seasonNumber` as whole-show, deriving `showTmdbId` from the id; b1-router pure seam pinned by tests. Controller B1 corruption-detection query: run `SELECT count(*) FROM tv_rankings WHERE show_tmdb_id = 0 OR (tmdb_id ~ '^tv_\d+$' AND season_number = 0)` before merge to confirm; repair owner-ackable (delete vs repair-to-season per Q8)
- [C5] [blocking] B2 TV/book re-rank was delete-first: cancel = permanent loss, completion = `ranking_remove`+`ranking_add` instead of single `ranking_move` — fixed: `rerankState` marker extended to tv/book (per-vertical); completion upserts on the unique key, then `set_tier_order` for both source (when tier changed) and target tiers; emits ONE `ranking_move` (`{notes?, year?}`, watched-with omitted) matching the movie contract; cancel/close clears marker with zero writes. Contract known-deviations updated (item 2 widened).
- [C5] [blocking] B3 TV re-rank persisted the zh-localized show title into `tv_rankings`, `activity_events.media_title`, and stubs — fixed: TV/book re-rank branches resolve the raw item from the unlocalized `tvItems`/`bookItems` arrays by id before seeding the modal preselect; localized strings never reach persistence paths (parity with movie's B4 fix, `RankingAppPage.tsx:1717`). Books were accidentally immune (ol_ ids never localize) but get the raw-item lookup for shape-consistency.
- [C5] [blocking] B4 `addTVItem`/`addBookItem` emitted `ranking_add` (and the TV stub) regardless of save outcome — fixed: both functions now early-return false before event + stub when `saveSucceeded` is false, exactly matching `addItem`'s movie shape; the ledgered C4 deferred "addTV/addBook silent-fail + ranking_add fires regardless" minor is closed here (the failure toast is also added). iOS already had the correct posture.
- [C5] [blocking] B5 deep-link re-rank in `MediaDetailModal` unconditionally ran the MOVIE ceremony, cross-writing `user_rankings` with tv/book items — fixed: `onRerank` dispatch branches on the found item's source collection: tv items → `setPreselectedTVItem` + AddTVSeasonModal; book items → `setBookItemToRank` + RankingFlowModal; movie → movie ceremony. Route verified — no cross-table writes possible after fix.
- [C5] [deferred] D1-D10 logged in audits/2026-07-10-c5-tv-books-web-audit.md §2 (D1 RankingFlowModal reset on parent re-render, D2 failure toasts overwritten by success toasts on all three verticals, D3 episode_count watchlist column missing, D4 whole-show bookmark deleted on first season rank, D5 zh-mode proxy quota burn on book ids, D6 Specials-filter sentinel invariant unwritten, D7 post-rank journal prompt movie-only, D8 UniversalSearch owned-state show vs season mismatch, D9 persistTVRankings/Book full-row batch signature, D10 book deep link pseudo-movie render) — not blocking the iOS port; dispositions per that doc. NOTE: D2 (success-toast overwrite) now MASKS the failure toast on all three verticals (a failed save reads as "Ranked to S" to the user) — priority bump candidate for an early web-only follow-up ahead of C6.
- [C5] [adjudication] Q1 iOS C5 ships full TV/book ceremony (tier → notes → same-media H2H), matching web; direct placement reserved for management moves only — recommended and ledgered; Q1 is owner-confirmable at plan time.
- [C5] [adjudication] Q3/Q4 — web-parity side-effect scope: journal quick entry stays movie-only on iOS C5 (`writeJournalQuickEntry: false` enforced for tv/book, `RankPersistence` gating keyed on media); TV stubs (Q4) decision deferred to iOS plan — write/not-write both valid pending owner input.
- [C5] [adjudication] Q5 whole-show bookmark removal behavior preserved and ledgered: web deletes the whole-show bookmark when one season is ranked (D4) — iOS coordinator must implement a show-id-aware equality check (`origin.id == item.id || item.id.hasPrefix(origin.id + "_s")`) to handle the id mismatch between whole-show origin and season-ranked result; product decision (keep vs. keep-until-N-seasons) punted to iOS plan.
- [C5] [adjudication] Q6 deep-link re-rank routing fixed in this PR (B5 fix first, then routes correctly per media, inheriting non-destructive B2 semantics for tv/book).
- [C5] [adjudication] Q8 B1 prod backfill: controller runs the corruption-detection query pre-merge; repair (delete vs season-repair) is owner-ackable; no automated backfill written (parity with C3's B2 preventive-only pattern). Q2/Q7 (book search surface on iOS; book global score in tier picker) land in the iOS C5 plan.
- [C5-iOS] [adjudication] Q2 (controller, owner-reviewable) — rank-entry media switch: the entry screen gains a three-way segmented switch (movie / tv / book); tv → show search (typo-retry variants) → season grid (Specials filtered, already-ranked seasons disabled) → ceremony; book → OpenLibrary search (no typo-retry — OL tokenizes) → ceremony. No separate book search surface on iOS this cycle.
- [C5-iOS] [adjudication] Q7 (controller) — book global score seeds `ol_ratings_average` from the OpenLibrary search response, never TMDB. `ol_` ids must never be passed to the TMDB proxy.
- [C5-iOS] [adjudication] Q3/Q4 final: tv stubs written (`media_type = 'tv_season'` to `movie_stubs`); book stubs skipped (DB CHECK constraint blocks them). Journal quick-entry stays movie-only (`writeJournalQuickEntry: false` enforced at `RankPersistence` for tv/book, pinned by test). TV suggestions via `SuggestionsClient.fetch(mediaType: .tv)` wired in the rank-entry screen (Part B client, previously unconsumed); books are search-only, no suggestions engine.
- [C5-iOS] [adjudication] Q5 — whole-show bookmark removal: the coordinator uses `origin.id == item.id || item.id.hasPrefix(origin.id + "_s")` equality to match a whole-show bookmark origin against a season-ranked result. Web deletes the whole-show bookmark on first season rank (D4 — open product question); iOS mirrors this behavior via the show-id-aware equality check.
- [C4→shipped] MOVIE SEARCH: owner reported fuzzy movie search not working — shipped on branch `fix/movie-search-fuzzy` (PR #41). (1) Zero-result typo-retry backoff in `services/tmdbService.ts` via pure `services/searchVariants.ts`; covers UniversalSearch, AddMediaModal, AddTVSeasonModal, onboarding. (2) Letterboxd import's private `searchTMDB` wired through the same variants (the initial investigation claim that `searchMovies` covered the import was wrong — the import never called it; fix round added). (3) HTTP-error responses (non-2xx) do NOT trigger or continue the variant loop. (4) Local fuzzy layer repaired in `services/fuzzySearch.ts`: leading-article strip both sides, word-start windows, best-window scoring in `getBestCorrectedQuery`, 2-char non-ASCII gate. (5) iOS mirror in `ios/Spool/Sources/Spool/Services/TMDBService.swift`: Swift `typoRetryVariants` 1:1 port + Task-cancellation between variants + non-2xx bail; `locale()` now follows device language (zh→zh-CN, en-US fallback) for search + discover seeds, matching web's `getTmdbLocale` surfaces. Tests: web 382 vitest, iOS 381 swift. Migrations: none (client-only). Deferred (unchanged from investigation, plus review finds): no-results-vs-error UX distinction; "already in your list" hint when a correction resolves to an owned title; onboarding stale-request guard; TMDB proxy edge function; OpenLibrary book fuzz; letterboxd non-429 HTTP errors now join MAX_RETRIES backoff (was fail-fast — split-sentinel follow-up); 0.3-threshold boundary test for fuzzySearch; iOS in-app locale toggle would need `locale()` re-sourcing.

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

**iOS gap (audit §4):** closed by C3-iOS Part A — see notes below.

### C3-iOS Part A notes

Built on `feat/ios-parity-c3-watchlist` per
`docs/plans/2026-07-09-c3-ios-watchlist-discover-plan.md` (Tasks 1–6, 458 swift
tests; baseline at branch start was 381).

**Owner adjudications (2026-07-09 — do not relitigate):**

- **Q2** movie watchlist SELECT = FOLLOWER-VISIBLE (aligned with tv/book). Migration
  `20260709_c3_movie_watchlist_follower_select.sql` in branch — APPLY BEFORE MERGE.
  iOS `TasteRepository.getRecommendationsForFriend` now gets real data for
  Twin-exclusion; was silently returning 0 rows under owner-only RLS.
- **Q6** iOS Discover = ONE MERGED SCREEN (friend recs + trending NOW; engine grid +
  provenance chips arrive in Part B). The compass icon lives in the feed header tab;
  the sheet is `.sheet`.
- **Q5** provenance chips = YES, but Part B (pool labels: "Friends loved", "Because
  you ranked X"). Part A cards are unlabeled.
- **Q4** tmdb-proxy ships with Part B (not C3 Part A). `hasTmdbKey()` gating stays;
  both bundles keep the key until then.
- **Q7** generic-vs-smart threshold stays hard-coded at 3 (no owner tuning surface).
- **Q3** MOOT — prod verified 0 bare-format `tmdb_id` rows; no one-shot backfill
  needed.

**What shipped in Part A:**

- `WatchlistRepository` actor (3 tables, §1.1 contract, media-complete — tv/book
  rows land with C5 UI; all read/write/allBookmarkedIds paths tested).
- Watchlist tab (5th tab, **queue** icon in the nav; NOTE: the internal symbol name
  is `queue` — owner taste determines final label, "queue" vs "watchlist"):
  poster grid, media-type segmented switch, movie Rank It + Remove; TV/book render
  Remove only (no Rank It until C5 ceremony).
- Rank-from-watchlist: B5-corrected (delete bookmark only on confirmed
  `RankPersistence.save` success), stale-origin guard (captures originating
  `tmdb_id` before ceremony opens; does not delete if the saved item's id differs),
  id-match guard (compare at delete time; failed delete = fire-and-forget + loud
  log; never gates the rank-success UX).
- Social Discover: `DiscoverRepository` + `DiscoverScreen` (two sections: "From your
  friends" via `friendRecommendations(limit:20)`, "Trending with friends" via
  `trendingAmongFriends(limit:15, days:30)`; cards per audit §1.2 field list;
  pull-to-refresh; empty states for no-friends). Explicit slot comment marks where
  Part B's engine grid slots in below the social sections.
- Twin fix (B3): `TasteRepository.getRecommendationsForFriend` now reads
  `watchlist_items` via `WatchlistRepository.listForUser` (working under Q2's
  follower-SELECT policy); workaround reads removed.
- Q2 migration `20260709_c3_movie_watchlist_follower_select.sql`: pin
  **APPLY-BEFORE-MERGE** — Task 5 Twin read depends on it in prod; everything else
  is additive.
- Contract: `docs/contracts/shared-payloads.md` watchlist section updated (Q2 RLS
  posture, B5 stale-origin/id-match guards, D6 0-or-NULL note).

**Part B MUST-COVER (separate plan — gated on owner setting `TMDB_API_KEY` as a
Supabase Edge Function secret):**

- `suggestions` edge function (§2 of the audit) + companion `tmdb-proxy` (§2.4).
- `SuggestionsClient` on iOS (mirrors `JournalAgentClient`'s invoke pattern).
- Engine grid + provenance chips on iOS `DiscoverScreen` (slot already reserved).
- Web `DiscoverView` migrated to the merged layout: friend sections + engine grid
  with provenance chips + a dedicated "New releases" row (TMDB now-playing/upcoming
  filtered by taste genres; feeds the iMessage agent's release radar later).
- Web `AddMediaModal`/`AddTVSeasonModal`/`MovieOnboardingPage` swap
  `getSmartSuggestions/Backfill` + `buildTasteProfile` for edge-function calls.
- Info.plist TMDB key retired (with `tmdb-proxy` in place).
- Discover card actions (save-for-later + movie tap): iOS Part A cards are inert on
  tap; actions unlock in Part B when `SuggestionsClient` lands.
- New Releases row on web (owner scope addition 2026-07-09).

**Deferred minors from task reviews (not blocking Part A):**

- Exclusion error-posture asymmetry (tv/book exclusion errors logged only; movie
  exclusion errors propagate — align in a later cycle).
- Pull-to-refresh teardown edge (Task teardown on swift concurrency; cosmetic in
  current volume).
- Reload-token dead code in `WatchlistScreen`/`SpoolAppRoot` (unused reload trigger left; W0.3
  delete candidate).
- Revert-duplicate and seed-item cases in WatchlistContractTests — already fixed
  before review merge.

### C3-iOS Part B notes (2026-07-10, branch `feat/c3-part-b-suggestions`)

**What shipped in Part B:**

- `suggestions` edge function deployed (5-pool engine, modes: suggestions / backfill / new_releases; auth + rate-limiting; pure engine in `engine.ts` exercised by vitest).
- `tmdb-proxy` edge function deployed (authenticated GET; hard path allowlist + query safelist; pure rules in `rules.ts` exercised by vitest).
- Both clients migrated off direct TMDB key: web `VITE_TMDB_API_KEY` removed; iOS `Info.plist` `TMDB_API_KEY` retired. **TMDB key DoD met.**
- Web `DiscoverView` merged layout: friend sections + engine grid with provenance pool chips (`similar` / `taste` / `trending` / `variety` / `friend` / `generic`) + New Releases row (TMDB now_playing + upcoming, taste-filtered, date-asc).
- iOS `DiscoverScreen` engine grid: `SuggestionsClient` wired, provenance chips rendered, New Releases section, card actions (save-for-later + rank tap).
- Web `AddMediaModal` / `AddTVSeasonModal` / `MovieOnboardingPage` swap old `getSmartSuggestions/Backfill` + `buildTasteProfile` for edge-function calls via `invokeSuggestions` in `services/tmdbService.ts`.
- Anonymous onboarding: `services/onboardingFixtures.ts` static pool (~48 curated movies) serves `MovieOnboardingPage` when there is no session — restores the try-before-signup funnel after the TMDB key was removed from the web bundle.
- Journal quick-write wipe fix (T0): ceremony stage-A no longer overwrites an existing rich journal entry when `.moved` (`InsertOutcome` guard).
- Contract: `docs/contracts/shared-payloads.md` §suggestions-function and §tmdb-proxy.

**Deferred (ledger open items):**

- `releaseDate` wire field: present internally on `new_release` items but stripped by `toResponseItem`. When wired, New Releases rows on both platforms can display the actual release date. Until then, year-only display.
- `seedTitle` wire field: the title of the S/A-tier seed movie used by the `similar` pool — for the "Because you ranked X" chip. Not yet populated by the engine.
- `region` param for `new_releases`: `movie/now_playing` + `movie/upcoming` are called without a region param (release-date API v1); region handling is a deferred follow-up.
- `social .failed` suppresses engine sections: when the social Discover sections (`friendRecommendations` / `trendingAmongFriends`) error, the engine grid sections should be hidden too (design-cycle item; current posture: sections fail independently).
- Preview-mode search sign-in nudge: anon users who land on the search surface from an onboarding fixture tap see an empty result (search requires auth via tmdb-proxy). A sign-in nudge at that seam is a design-cycle item.
- zh retry label: when the typo-retry backoff produces zero results, the "no results" label is shown in English even in zh locale. Deferred.
- `onboardingFixtures.ts` header threshold: header originally said "≥10 movies" but `REQUIRED_MOVIES = MIN_MOVIES_FOR_SCORES = 5`. **Corrected in this PR** to "≥5 movies".
- CORS `Access-Control-Allow-Origin: *` — both `suggestions` and `tmdb-proxy` ship `*`. Tightening to the deployed Vercel origin is a security audit action item (CORS origin-tightening tension; deferred).

**iOS design-check cycle:** queued after C5–C7 (owner, 2026-07-10); screenshot seed list in progress ledger.

### Search gaps mini-cycle (2026-07-09) — SHIPPED (PR #38)

- CJK and fuzzy matching via trigram fallback (pg_trgm ILIKE over `title` and `review_text`; `similarity()` tie-break) landed in `supabase/migrations/20260709_journal_search_cjk_fuzzy.sql`; iOS journal search cancellation-debounced (300ms).
- Semantic / embedding search was explicitly considered and NOT chosen (owner decision); do not re-propose without a new owner trigger.
- Migration applied to prod + all probes green (`docs/plans/audits/2026-07-09-search-verification.md`); merged in PR #38.

### C4 notes

Web and iOS fixes on `fix/c4-ranking-blocking` per `docs/plans/2026-07-09-c4-blocking-fixes-plan.md`; contract in `docs/contracts/shared-payloads.md` (`## user_rankings ordering`).

**B1-B6 dispositions:**

- **B1** same-tier drop-on-container: now routes through the reindex helper + RPC (same as `handleDropOnItem`); error handling + rollback added; `ranking_move` suppressed when the order didn't change.
- **B2** movie cross-tier migration source gap: `addItem` completion now calls `set_tier_order` for the source tier (membership minus the departed id), matching the existing TV/book dual-tier compaction.
- **B3** re-rank delete-first data loss: delete deferred to ceremony completion; the ceremony's `(user_id,tmdb_id)` upsert replaces the row non-destructively; completion emits `ranking_move` (never `ranking_remove`+`ranking_add`); cancel = zero writes.
- **B4** zh-locale title persistence: `onRerank` handler looks up the raw item by id in the unlocalized `items` array before setting `preselectedForRank`; localized titles never reach persistence paths.
- **B5** iOS duplicate positions: `insertRanking` now reads the target tier, pure-splices the new id at the clamped position, UPSERTs the row, then calls `set_tier_order` to compact the whole tier. Existing corrupted tiers self-heal on the next tier write. A one-shot repair probe (detect duplicate/gapped tiers per user) is in `docs/plans/audits/2026-07-09-c4-verification.md` — controller decides whether to run compaction; owner-ackable.
- **B6** whole-tier upsert resurrection race: all reorder/move/delete-compaction writes now route through `set_tier_order` (UPDATE-only, cannot INSERT, positions-only — no media-column resurrection).

**Q4 adjudication (owner-reviewable):** positions-only `set_tier_order` RPC over full-row upserts. See `docs/contracts/shared-payloads.md` `## user_rankings ordering` for the full contract. Rollback: `DROP FUNCTION public.set_tier_order(text, text, text[]);`.

**10 deferred findings** (D1–D10): see `docs/plans/audits/2026-07-09-c4-ranking-mgmt-web-audit.md` §2.

**iOS management UI** (reorder, re-tier, delete, notes editor affordances) is deliberately NOT in this branch — it needs a short owner design check (where the affordances live in the app) and builds on this corrected base. That is the next C4 sub-plan.

**Known deferred items from task reviews:**

- TV/book re-rank still deletes up-front — same data-loss class as B3; needs the B3 treatment in a later cycle.
- iOS `insertRanking` tv/book path is latent-broken: `RankingPayload` carries `director`; `tv_rankings` needs `creator` + NOT NULL `show_tmdb_id`/`season_number`; `book_rankings` needs `author` — fails loudly, unreachable today (no tv/book ceremony on iOS); C5 must extend the payload.
- Web `addTVItem`/`addBookItem`: RPC failure is silent (no toast) and `ranking_add` still fires regardless — fix in a later cycle.
- MOVIE SEARCH: shipped on branch `fix/movie-search-fuzzy` (PR #41) — see [C4→shipped] audit-findings entry above for full disposition. Web 382 vitest / iOS 381 swift; no migrations.
- ~~**iOS ceremony re-rank event deviation (from final review):**~~ **FIXED — C4 iOS management-UI sub-plan, Task 2** (`fix(ios): ceremony re-rank compacts the source tier and emits ranking_move`). `insertRanking` now PRE-READS the existing `(user_id, tmdb_id)` row's tier; on a re-rank it emits a single `ranking_move` (`{notes?, year?}`, watched-with stripped) via the pure `CeremonyEmission.decide` seam and, when the tier differs, compacts the SOURCE tier too (live membership minus the id) so no gap is left. Fresh insert unchanged (`ranking_add`). Returns an `InsertOutcome` (`.inserted` / `.moved(fromTier:)`) for observability. The contract's Known-deviations §3 is retired. Tests: `TierSpliceTests` (+7 pure decision/mapping/compaction cases). Remaining deferred deviations are now web-only (drag-migration `ranking_add`, TV/book delete-first).
- **TV/book same-tier container drop is now silent (from final review):** the old cross-tier drop handler accidentally emitted `ranking_move` even for same-tier reorders; the new same-tier branch (B1 fix) is silent, aligning with the no-op suppression rule. Deliberate — riding.
- **Deploy ordering (from final review):** `20260709_set_tier_order_rpc.sql` MUST be applied to prod BEFORE the PR merges — merge-first would mint fresh duplicate positions on every ceremony add until the RPC exists.

### C5-iOS notes (2026-07-10, branch `feat/ios-parity-c5-tv-books`)

TV seasons + books on iOS. 8 tasks, plan at `docs/plans/2026-07-10-c5-ios-tv-books-plan.md`. Baselines: iOS 585, web 533. Final count: 741 iOS tests (739 at T7 + 2 final-review pins).

**What shipped:**

- **T1 (per-media payloads):** the upsert body split into a per-media `RankingPayload` enum wrapping `MoviePayloadBody` (movie: `director`), `TVPayloadBody` (`show_tmdb_id Int` + `season_number Int` NOT NULL, `season_title?`, `creator?`, `episode_count?`, `watched_with_user_ids`), `BookPayloadBody` (`author?`, `page_count?`, `isbn?`, `ol_work_key?`, `ol_ratings_average?`, `watched_with_user_ids`). Verified column-for-column against DDL. The C4-deferred latent-break (director on tv/book rows) is closed.
- **T2 (media-parameterized reads):** `getTierItems(tier:media:)` and `getAllRankedItems(media:)` route to the correct table per media. `RankManageModel` and `FullListScreen` un-pinned from `"movie"`.
- **T3 (TMDB TV endpoints):** `searchTVShows` (typo-retry variants, web parity), `getTVShowDetails` (seasons, Specials filtered), `getTVSeasonDetails`, `getTVShowGlobalScore`; `TV_GENRE_MAP` + `normalizeTVGenres` ported. All via the proxy.
- **T4 (OpenLibrary client):** `OpenLibraryService` — keyless direct GET, `ol_{workKey}` id mint, `normalizeBookGenres` + `ALL_BOOK_GENRES` (48 entries, diffed identical to web), debounce + cancellation; `+` force-encoded as `%2B`; deterministic genre tie order.
- **T5 (media-generic ceremony):** H2H pool is SAME-MEDIA (reads from the matching table via T2). TV stubs written, book stubs skipped. Journal quick-entry gated (`writeJournalQuickEntry: false` for tv/book, pinned by test). `CeremonyEmission.decide` unchanged — media-agnostic.
- **T6 (season UI + router + coordinator identity fix):** `RankEntryScreen` gains media switch (movie/tv/book segmented). TV flow: show search → `SeasonSelectScreen` (Specials filtered, ranked seasons disabled) → ceremony. Book flow: OL search → ceremony. Rank-from-watchlist enabled for tv/book. `TVPreselectRouter` (pure) handles whole-show vs season routing + heal-or-refuse for corrupt ids. Coordinator whole-show identity fix: `origin.id == item.id || item.id.hasPrefix(origin.id + "_s")`.
- **T7 (TV suggestions):** `SuggestionsClient.fetch(mediaType: .tv)` wired in the TV search stage of `RankEntryScreen`. Suggestions grid (3-col), consume-splice on pick with backfill refill, session excludes capped 200. Books: search-only, no suggestions. Fix commit (`be7eb3f`): `.onChange` moved to `SearchField` so post-sign-in suggestions load actually fires.
- **T8 (docs):** this ledger + `docs/contracts/shared-payloads.md` tv/book RANKINGS section + preselect-router table + H2H/D6/episode_count invariants + iOS re-rank compliance note widened.

**Corrections caught during build (all adjudicated per plan Q-table):**

- Q2 media switch implemented as owner-reviewable (see adjudications above).
- Q7 book global score from `ol_ratings_average`, never TMDB — `OpenLibraryService` never calls the proxy for `ol_` ids.
- `tvSeasonMovie item.seasonNumber ?? 0` for NULL-field + well-formed-id watchlist rows: pre-existing edge (a row that carries `season_number = NULL` on a `tv_{n}_s{k}`-shaped id); `?? 0` is the safe default but emits `season_number = 0` which readers treat as whole-show — noted here as a future-cycle correction rather than an immediate fix (the scenario is a DB invariant violation that should not occur post-B2).

**Deferred / known items (carry to C6 or later):**

- **Movie-mode in-flow suggestions grid** — web `AddMediaModal` has the identical choreography (~lines 80-124) making this a REAL web-parity gap, not "no precedent" (noted in T7 fix commit `be7eb3f`). Deferred: iOS movie mode on the rank-entry screen shows no suggestions grid today.
- **Per-suggestion save-for-later in the rank flow** — web Discover/AddMedia allows bookmarking a suggestion without ranking it; iOS rank-entry has no save-for-later affordance.
- **Live `isAlreadyOwned` display filter** — web shows a "you own this" label on suggestion cards; iOS does not filter or label owned items in the suggestions grid.
- **TV-search fuzzy local-pool merge** — search results and suggestions are not merged into a unified de-duplicated pool; the two lists are separate UI sections.
- **`tvSeasonMovie seasonNumber ?? 0`** for NULL-field + well-formed-id watchlist rows — see above.
- **Gated-query no auto re-search post-sign-in** — after dismissing the sign-in nudge in the TV search stage, the query field repopulates but no automatic re-search fires; user must retype or tap. UX nicety, not a data contract issue.
- **Preview-mode TV/book unsupported by design** — the signed-in gate is enforced at the rank-entry screen; preview-mode users see movie suggestions only. Deliberate.
- **Notes prefill absent on season-preselect** — iOS `WatchlistItem` carries no `notes` column, so the iOS season-preselect path opens the ceremony with no notes prefill (web carries notes from the watchlist row). Deliberate platform gap, noted in `TVPreselectRouter.swift` header.

**Final whole-branch review fold-ins (2026-07-10):**

- **Preview-queue media gate (fixed):** `RankPersistence.save`'s no-session fallback queued ANY media into the movie-shaped `OnboardingQueue`, whose flush inserts into `user_rankings` unconditionally — an expired session mid-tv/book-ceremony would have minted a `tv_…`/`ol_…` id into the movie table (the C5 corruption class). Now gated by pure `shouldQueuePreviewRanking(media:)` (movie-only; tv/book toast + return false, bookmark stays per B5). Pinned by `MediaGenericCeremonyTests.testPreviewQueueIsMovieOnly`.
- **Book re-rank global-score seed (fixed):** `rankedItem(from:)` hardcoded `globalScore: nil`, making `rerankFromShelf`'s book branch (`item.globalScore.map { $0 / 2 }`) dead code — book re-ranks seeded no engine score. Now maps `ol_ratings_average × 2` from the row (books only; movie/tv still enrich async from TMDB). Pinned by `MediaReadRoutingTests.testBookRowMapsOLRatingIntoGlobalScoreTimesTwo`.
- **Stale movie-only re-rank comments (fixed):** `FullListScreen` header + menu comments still claimed "RE-RANK stays MOVIE-ONLY / TODO(C5-T6)" after T6 shipped all-media re-rank; the T1-ledgered `RankingRow.attribution` comment fix (wrong fallback order + nonexistent web `WatchlistCard` citation) had been dropped from T8 — both corrected.
- **Riding (accepted, no fix):** `RankEntryModel.applyDirectSeasonLoad` has no stale-load guard (unlike `applySeasonLoad`) — confined because `SeasonSelectScreen` owns a fresh model per presentation; T3/T4 riding minors (4.5s-vs-4.0s score timeout, strict fail-whole OL decode, 200-only posture) stay as adjudicated in the task reviews.

**Device smoke owed (PR body):** rank a TV season end-to-end (search → season grid → ceremony → shelf); rank a book end-to-end; whole-show bookmark → Rank It → season grid → bookmark clears.

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

## C3-iOS Part A migration runbook (owner applies, before merge)

One migration in `feat/ios-parity-c3-watchlist`. It is **APPLY-BEFORE-MERGE** —
Task 5 Twin read (`TasteRepository.getRecommendationsForFriend`) depends on the
follower-SELECT policy being live in prod; the rest of Part A is purely additive
client code.

**1. `supabase/migrations/20260709_c3_movie_watchlist_follower_select.sql`** —
Q2: drops owner-only SELECT, recreates two-policy shape (owner SELECT + follower
SELECT mirroring tv/book). Rollback (verbatim in the file):
`DROP POLICY "Users can view followed users watchlist" ON watchlist_items;`
`DROP POLICY "Users can view own watchlist" ON watchlist_items;`
`CREATE POLICY "Users can view own watchlist" ON watchlist_items FOR SELECT USING (auth.uid() = user_id);`

**2. Verification probes (from `docs/plans/audits/2026-07-09-c3-ios-verification.md`):**

- **(1)** owner still reads own `watchlist_items` rows → non-zero count.
- **(2)** follower reads followee's `watchlist_items` rows → non-zero count (SET
  ROLE the follower's sub, SELECT WHERE `user_id = <followee>`).
- **(3)** NON-follower gets 0 rows from followee's `watchlist_items`.
- **(4)** follower cannot INSERT/UPDATE/DELETE a followee's watchlist row → RLS
  denial (42501).
- **(5)** `SELECT policyname FROM pg_policies WHERE tablename = 'watchlist_items' AND cmd = 'SELECT'` → exactly 2 rows: `"Users can view own watchlist"` and `"Users can view followed users watchlist"`.

**3. Merge the PR.**
