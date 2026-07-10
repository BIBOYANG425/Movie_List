# C5-iOS TV Seasons + Books Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Bring TV-season and book ranking to Spool iOS with full ceremony parity (Q1, owner-adjudicated), built on the corrected web semantics (PR #46) — payload split first, then reads, clients, model, UI, side effects.

**Architecture:** Follow the audit's dependency-ordered gap list VERBATIM (docs/plans/audits/2026-07-10-c5-tv-books-web-audit.md §3 — the binding spec for every task below). Per-media insert payloads and row decodes unblock everything; the ceremony becomes media-generic with a same-media H2H pool; season selection mirrors the web router contract incl. the hardened/healing rules; books are search-only via a new keyless OpenLibrary client.

**Tech Stack:** Swift + XCTest (`ios/Spool`). No migrations (RPC + policies live). Baselines: iOS 585, web 533 (web untouched).

## Global Constraints

- Binding: audit §1 reference semantics + §3 gap list + the **do-NOT-port list (§3 item 10)**: no season-less rank path, no delete-first re-rank, no localized-title persistence, no pre-save events/stubs, no cross-media routing, no pseudo-movie book detail.
- Contract (docs/contracts/shared-payloads.md): tv id canon `tv_{show}_s{n}` w/ REAL show_tmdb_id; book `ol_{workKey}`; events/stubs ONLY after confirmed save; re-rank = single `ranking_move`; position integrity via `set_tier_order` full-membership; D6: season 0 ("Specials") filtered from season grids; whole-show sentinel 0-or-NULL tolerated on reads.
- **Owner adjudications**: Q1 full ceremony parity (tier → notes → same-media H2H). Q2 (controller, owner-reviewable): the rank entry screen gains a media switch — movie|tv|book; tv = show search → season grid → ceremony; book = OpenLibrary search → ceremony. Q3/Q4 web-parity side effects: tv writes `tv_season` stubs; books write NO stubs (DB CHECK); journal quick-entry stays MOVIE-ONLY (tv/book ceremonies pass `writeJournalQuickEntry: false`). Q5 whole-show bookmark removal after ranking one season = web parity, ledgered as a product question. Q7 (controller): book "global score" seeds from `ol_ratings_average` like web; NEVER call TMDB for `ol_` ids.
- iOS idioms: actors + SpoolClient guards + logging; @MainActor models w/ injected closures (iOS 16 floor); pure tested contract layers RED-first; SpoolTokens idiom; typo-retry + cancellation semantics preserved on new search paths (TV mirrors the movie search; OL search gets debounce + cancellation but NO typo-retry variants — OL's own tokenized matching suffices, web parity).
- Tests `swift test --package-path ios/Spool` green at every task; conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; dated headers bumped.

---

### Task 1: Per-media insert payloads + row decodes (audit §3.1 — everything depends on this)

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankingRepository.swift` (`RankingInsert`/`RankingPayload` ~590-621, `RankingRow` decode); Test `ios/Spool/Tests/SpoolTests/` (extend the payload pin tests).
- TV payload: `show_tmdb_id Int` + `season_number Int` NON-OPTIONAL, `season_title?`, `creator?`, `episode_count?`, `watched_with_user_ids`; book payload: `author?`, `page_count?`, `isbn?`, `ol_work_key?`, `ol_ratings_average?`; `director` becomes MOVIE-ONLY (a non-nil director key on the other tables errors). Key-set pin tests per media (the C2 no-silent-drop convention); nil-notes omission pin survives.
- Per-media `RankingRow` decode (creator/author + vertical columns) for the reads Task 2 parameterizes.
- Commit `feat(ios): per-media ranking payloads and row decodes (tv/book latent-break fixed)`.

### Task 2: Media-parameterized reads + management unpinning (audit §3.2)

**Files:** Modify `RankingRepository.swift` (`getTierItems(tier:media:)`, `getAllRankedItems(media:)` ~56-96), `ios/Spool/Sources/Spool/Services/RankManageModel.swift` (un-pin `"movie"` ~84,381 + production bindings ~254-267), `ios/Spool/Sources/Spool/Screens/FullListScreen.swift` (media switch — segmented, movie default); Tests extend RankManageModelTests.
- The H2H engine walk, shelf, and management ops all ride these reads; drag/menu management works identically per media (the repo ops are already media-parameterized from C4-UI).
- Commit `feat(ios): media-parameterized ranking reads; shelf + management per vertical`.

### Task 3: TMDBService TV endpoints (audit §3.3)

**Files:** Modify `ios/Spool/Sources/Spool/Services/TMDBService.swift`; Test SearchVariants/URL tests extended.
- `searchTVShows` (typo-retry parity with web `tmdbService.ts:866-880` — same variant loop), `getTVShowDetails` (seasons array, FILTER season 0 — D6), `getTVSeasonDetails`, `getTVShowGlobalScore`; port `TV_GENRE_MAP` + `normalizeTVGenres` (web `tmdbService.ts:517-561`) as pure tested functions. All via the proxy (paths allowlisted: search/tv, tv/{id}, tv/{id}/season/{n}).
- Commit `feat(ios): TMDB TV endpoints via proxy — search, details, seasons, genres`.

### Task 4: OpenLibrary client (audit §3.4)

**Files:** Create `ios/Spool/Sources/Spool/Services/OpenLibraryService.swift`; Test new file.
- Keyless direct GET `openlibrary.org/search.json` with the web's exact field list + doc mapping (`services/openLibraryService.ts:41-45,168-186`), `ol_{workKey}` id mint, `normalizeBookGenres` + `ALL_BOOK_GENRES` port, 8s timeout, proper `User-Agent` (OL policy — iOS CAN set it; note web can't), debounce+cancellation semantics at the caller seam (no typo-retry variants — OL tokenizes).
- Commit `feat(ios): OpenLibrary search client — keyless, ol_ id canon, genre normalization`.

### Task 5: Media-generic ceremony + per-media side effects (audit §3.5 + §3.7)

**Files:** Modify `ios/Spool/Sources/Spool/Models.swift` (vertical fields on the rankable model — audit's choice: extend `Movie` with optionals OR per-media types; pick the LEAST invasive that keeps H2H same-media), `RankTierScreen/RankH2HScreen/RankPrintedScreen`, `RankPersistence.swift` (drop the `type:"movie"` pin ~90; media-aware save), `StubWriter` (gains `media_type:'tv_season'`; SKIPS books — DB CHECK); Tests: persistence decision + stub-writer media tests.
- H2H pool SAME-MEDIA ONLY (web parity: AddTVSeasonModal.tsx:399, RankingFlowModal.tsx:106) — the pool read uses Task 2's media param.
- Journal quick-entry: tv/book ceremonies force `writeJournalQuickEntry: false` (Q3 adjudication) — the movie-shaped stage-A path must be unreachable cross-media; test pins it.
- Events: the media-agnostic emitter already handles this (`CeremonyEmission` pure); verify the emission carries the right media table context (check what web writes for tv/book events — media_tier/media_title from the vertical item).
- Commit `feat(ios): media-generic rank ceremony — same-media H2H, per-media stubs, movie-only quick entry`.

### Task 6: Season selection + preselect router + rank-from-watchlist for tv/book (audit §3.6 + §3.9)

**Files:** Create `ios/Spool/Sources/Spool/Screens/SeasonSelectScreen.swift` (or a stage in the rank flow); Modify `RankEntryScreen.swift` (media switch per Q2 — movie|tv|book segmented; tv search → show rows → season grid; book search → book rows → ceremony), `SpoolAppRoot.swift` (flow threading), `WatchlistScreen.swift`/`WatchlistCard` (Rank It enabled for tv/book), `RankFromWatchlistCoordinator.swift` (media threading + the WHOLE-SHOW IDENTITY FIX: `origin.id == movie.id || movie.id.hasPrefix(origin.id + "_s")` — the audit-pinned trap where whole-show→season ranks never removed the bookmark); Tests: router pure seam (port web's `resolveTVPreselectRoute`/`healTVPreselect` semantics incl. hardened+healing rules), coordinator identity matrix.
- Router contract (audit §1.1 table): show preselect (real showTmdbId, falsy seasonNumber) → season grid (ranked seasons disabled, Specials filtered); season preselect → straight to tier with notes prefill; legacy corrupt ids heal (derive show id from the id).
- Commit `feat(ios): TV season selection + book search in the rank flow; whole-show rank-from-watchlist fixed`.

### Task 7: TV suggestions in the add flow (audit §3.8)

**Files:** Modify `RankEntryScreen.swift` (tv mode gains the suggestions grid via `SuggestionsClient.fetch(mediaType: .tv)` — live since Part B, unconsumed); Tests: model choreography.
- Replicate the web modal's suggestions/backfill/refresh + session-exclude behavior (server owns ranked/bookmarked exclusion; `WatchlistRepository.allBookmarkedIds` already pre-expands season→show). Books: NO engine — search-only (web parity).
- Commit `feat(ios): TV suggestions grid in the rank flow`.

### Task 8: Docs + ledger (audit §3.11)

**Files:** `docs/contracts/shared-payloads.md` (tv/book RANKINGS row-shape table; "H2H pool same-media"; preselect-router table; D6 Specials/sentinel invariant; episode_count decision [D3 — record what shipped]); `docs/plans/2026-07-07-ios-parity-ledger.md` (C5 COMPLETE row, Q adjudications incl. Q2/Q7, deferred pointers, iOS known-deviations updates — the contract's iOS movie-only re-rank note widens when tv/book ceremonies land).
- Commit `docs: tv/book ranking contracts; C5 complete`.

## Self-Review Notes

- Task order is the audit's dependency order; Tasks 3 and 4 are independent of each other (both depend only on T1/T2 being merged conceptually, not literally — they're client layers) but run sequentially per SDD.
- The whole-show identity fix (T6) must not regress the stale-origin guard from C3-A's review (origin cleared on entry exits) — the coordinator tests must keep the mismatch matrix green.
- Device smoke owed in the PR: rank a TV season end-to-end (search → season grid → ceremony → shelf), rank a book, whole-show bookmark → Rank It → season → bookmark clears.
