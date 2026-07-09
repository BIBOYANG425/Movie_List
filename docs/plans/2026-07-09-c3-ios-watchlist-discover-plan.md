# C3-iOS Part A — Watchlist + Social Discover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Bring the watchlist (all three media tables) and the social half of Discover (friends' recs + trending) to Spool iOS, with rank-from-watchlist using the CORRECTED B5 semantics — plus the owner-adjudicated movie-watchlist visibility migration.

**Architecture:** Actor repository over the three watchlist tables (§1.1 contract of the C3 audit), thin SwiftUI watchlist tab (poster grid + Rank It/Remove), rank-from-watchlist chained into the existing movie ceremony (bookmark deleted ONLY on confirmed save), and a Supabase-only Discover screen (friend recs + trending sections). Part B (suggestions edge function + tmdb-proxy + engine grid + provenance chips) is a separate follow-up plan gated on the owner setting the TMDB_API_KEY function secret.

**Tech Stack:** Swift + XCTest (`ios/Spool` package), one Postgres RLS migration.

## Global Constraints

- Binding source: `docs/plans/audits/2026-07-08-c3-watchlist-discover-web-audit.md` §1.1 (watchlist contract), §1.2 (Discover semantics), §4 (gap list). Branch `feat/ios-parity-c3-watchlist` off main.
- **Owner adjudications (2026-07-09, do not relitigate):** Q2 movie watchlist = FOLLOWER-VISIBLE (align with tv/book). Q6 iOS Discover = ONE MERGED SCREEN (social sections now; engine grid + provenance chips arrive in Part B). Q5 provenance chips = yes, Part B. Q4 tmdb-proxy ships with Part B. Q7 threshold stays hard-coded (3). Q3 moot (prod verified 0 bare ids; boundaries already normalize).
- **B5 corrected semantics (binding):** rank-from-watchlist deletes the bookmark ONLY on confirmed rank save (`RankPersistence.save` success), never before — iOS copies the corrected web behavior (`shouldRemoveBookmarkAfterRank` gate class), not any older shipped behavior.
- Id formats: movie `tmdb_{n}`, TV `tv_{showId}_s{n}` (season) / `tv_{showId}` (whole-show), book `ol_{workKey}`. Whole-show TV rows: `season_number` may be 0 OR NULL (D6) — treat both as whole-show; never trust `show_tmdb_id = 0` rows (B2).
- Rank-from-watchlist is MOVIES-ONLY on iOS in this cycle (the iOS ceremony is movie-only until C5); TV/book rows render with Remove only, no Rank It affordance.
- iOS tests `swift test --package-path ios/Spool` (baseline 381); no web code changes in Part A. Migrations: implementers never apply; controller applies via MCP + probes before merge; verbatim rollback in each migration file.
- Repo idioms: actor repositories with `SpoolClient.shared` guards + `[RepoName]` logging; @MainActor ObservableObject models with injected closures (iOS 16 floor, no @Observable); pure tested contract layers; SpoolTokens/SpoolFonts/AdmitStub visual language; conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Movie-watchlist follower-visibility migration (Q2)

**Files:** Create `supabase/migrations/20260709_c3_movie_watchlist_follower_select.sql`; Create `docs/plans/audits/2026-07-09-c3-ios-verification.md` (controller probes).
- Replace/extend `watchlist_items`' owner-only SELECT policy so followers can also read, mirroring the tv policy VERBATIM in structure (`supabase_tv_rankings.sql:88-99` — read it and copy the follows-table join direction exactly; book equivalent `supabase_book_rankings.sql:92-103` as cross-check). Owner INSERT/DELETE/UPDATE policies untouched.
- Header: why (Q2 owner adjudication, Twin exclusion + tv/book parity), rollback = drop the new policy + recreate the prior owner-only SELECT verbatim (quote it from `supabase_schema.sql:146`).
- Probes for the verification doc: (1) owner still reads own rows; (2) follower reads followee's movie watchlist rows; (3) NON-follower gets 0 rows; (4) follower cannot INSERT/UPDATE/DELETE followee rows; (5) policy names/count listed post-apply.
- Commit `feat(sql): movie watchlist follower SELECT — Q2 parity with tv/book`.

### Task 2: WatchlistRepository + contract layer

**Files:** Create `ios/Spool/Sources/Spool/Services/WatchlistRepository.swift`, `ios/Spool/Sources/Spool/Services/WatchlistModels.swift`; Test `ios/Spool/Tests/SpoolTests/WatchlistContractTests.swift`.

**Interfaces (Produces):** `struct WatchlistItem` (id/tmdbId string, title, year, posterUrl, mediaType movie|tv|book, genres [String], addedAt Date, plus per-media: director/creator/author, showTmdbId Int?, seasonNumber Int?, seasonTitle, pageCount, olWorkKey); `actor WatchlistRepository` with `list(media:) -> [WatchlistItem]` (own rows, `added_at desc`), `listForUser(userId:media:)` (cross-user, RLS decides), `add(item:) -> Bool` (UPSERT on `(user_id, tmdb_id)` — the B3a UPDATE policy landed in C3-web, merge-duplicates is safe), `remove(tmdbId:media:)`, `allBookmarkedIds(media:) -> Set<String>` (exclusion sets — TV expands season ids to show-level per audit §1.4 caller contract).
- Pure contract layer (tested RED-first): row↔model mapping for all three tables (every column of §1.1's table — no silent drops), whole-show detection (`seasonNumber` 0-or-NULL → whole-show), `show_tmdb_id = 0` rows rejected at mapping (B2), id-format helpers.
- Commit `feat(ios): WatchlistRepository — three-table contract, upsert add, ordered reads`.

### Task 3: Watchlist tab UI

**Files:** Create `ios/Spool/Sources/Spool/Screens/WatchlistScreen.swift` (+ card view file if the screen grows); Modify the tab/root navigation to mount it; Test model logic in `ios/Spool/Tests/SpoolTests/WatchlistModelTests.swift`.
- @MainActor `WatchlistModel` (injected repo closures): loads per-media lists, media-type segmented switch (movie primary; tv/book render read-only rows), optimistic remove with revert-on-error + toast, empty states.
- Poster grid in the app's ticket/paper idiom; each card: poster, title, year, added-date; actions: **Rank It** (movies only, hands the item to Task 4's entry point) and **Remove**.
- Commit `feat(ios): watchlist tab — poster grid, remove, movie Rank It`.

### Task 4: Rank-from-watchlist (B5-corrected)

**Files:** Modify `ios/Spool/Sources/Spool/Screens/RankEntryScreen.swift` (or the ceremony entry seam — read how RankEntryScreen receives a preselected movie today), `ios/Spool/Sources/Spool/Services/RankPersistence.swift` (only if a success signal must be threaded — it already returns/throws), WatchlistScreen wiring; Test `ios/Spool/Tests/SpoolTests/RankFromWatchlistTests.swift`.
- Flow: Rank It → ceremony preseeded with the watchlist item's movie (skip search step) → on CONFIRMED save success (`RankPersistence.save` completes without throwing) → `WatchlistRepository.remove` the bookmark; on failure/cancel the bookmark stays. Pure decision helper `shouldRemoveBookmarkAfterRank(saveSucceeded:) -> Bool` mirroring web's gate, tested (mirrors the corrected web semantics, audit finding B5).
- The removal is fire-and-forget AFTER the save (a failed remove logs loudly; the item reappears as owned-filtered, self-healing) — never gate the rank success on the bookmark delete.
- Commit `feat(ios): rank-from-watchlist — bookmark deleted only on confirmed save (B5-corrected)`.

### Task 5: Social Discover (friend recs + trending) + Twin fix

**Files:** Create `ios/Spool/Sources/Spool/Services/DiscoverRepository.swift`, `ios/Spool/Sources/Spool/Screens/DiscoverScreen.swift`; Modify `ios/Spool/Sources/Spool/Services/TasteRepository.swift` (`getRecommendationsForFriend` — its movie-watchlist exclusion read now WORKS under Task 1's policy; align it to read via WatchlistRepository.listForUser and drop any workaround, per the audit's B3 disposition); Test `ios/Spool/Tests/SpoolTests/DiscoverContractTests.swift`.
- `DiscoverRepository.friendRecommendations(limit: 20)`: port `tasteService.getFriendRecommendations` semantics (audit §1.2): friends' S/A `user_rankings` aggregated per movie (friendCount, avgTier, topTier, ≤3 friend profiles), excluding viewer's ranked ∪ watchlisted ids (canonical `tmdb_` compare), sorted friendCount desc then avg tier. `trendingAmongFriends(limit: 15, days: 30)`: friends' rankings with `updated_at >= now()-30d`, ≥2 distinct rankers per movie, sorted rankerCount desc. Both via the user's own client (RLS enforces follow visibility).
- DiscoverScreen: two sections ("From your friends", "Trending with friends") in the app idiom; cards per §1.2's field list; pull-to-refresh; empty states for no-friends. Screen layout leaves an explicit slot below for Part B's engine grid (comment marker, no dead UI).
- Commit `feat(ios): Discover — friend recommendations + trending among friends; Twin exclusion fixed`.

### Task 6: Docs + ledger

**Files:** `docs/contracts/shared-payloads.md` (new `## watchlist_items (three tables)` section: row shapes incl. per-media columns, id-format canon, upsert-on-(user_id,tmdb_id) write shape, D6 0-or-NULL, B2 rejection rule, follower-visible SELECT post-Q2); `docs/plans/2026-07-07-ios-parity-ledger.md` (C3 row → iOS Part A shipped, Q2/Q5/Q6 adjudications recorded, Part B gated on owner TMDB secret; cycle-status table refresh).
- Commit `docs: watchlist contract + C3-iOS Part A ledger`.

## Self-Review Notes

- Task 1 must land in prod (controller MCP apply + probes) before merge; Part A's Task 5 Twin read depends on it in prod, everything else is additive.
- TV/book Rank It deliberately absent (iOS ceremony is movie-only until C5) — the repository is media-complete now so C5 only adds UI.
- Part B (suggestions edge function §2, tmdb-proxy §2.4, SuggestionsClient, merged-grid + provenance chips, web migration to the edge fn, Info.plist key retirement) is its own plan; owner prerequisite: set `TMDB_API_KEY` as a Supabase Edge Function secret.
- Part B scope addition (owner 2026-07-09): WEB DiscoverView also becomes the merged layout — friend sections + engine grid with provenance chips + a dedicated "New releases" row (TMDB now-playing/upcoming filtered by taste genres; same pool later feeds the iMessage agent's release radar).
