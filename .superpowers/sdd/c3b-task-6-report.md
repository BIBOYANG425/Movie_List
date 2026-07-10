# C3 Part B — Task 6 report: iOS merged Discover grid + card actions

Branch: `feat/c3-part-b-suggestions` · files touched:
`ios/Spool/Sources/Spool/Screens/DiscoverScreen.swift`,
`ios/Spool/Sources/Spool/Screens/FeedScreen.swift`,
`ios/Spool/Sources/Spool/App/SpoolAppRoot.swift`,
`ios/Spool/Tests/SpoolTests/DiscoverEngineModelTests.swift` (new).

## What shipped

Closed Part A's "cards inert" deferral. The Discover screen (presented as a
`.sheet` from FeedScreen) now mounts, below the two social sections:

1. **New Releases row** — horizontal scroll of ≤10 `mode: .newReleases` movie
   suggestions, each chipped "new".
2. **"for you" engine grid** — 2-column grid of 12 `mode: .suggestions` items,
   provenance chip per card, a Refresh (page+1 / whole-set swap) pill, and an
   error-vs-empty split.

Every card (social + engine) gained two actions: **save for later**
(`WatchlistRepository.add`, optimistic + toast, de-duped per id) and **rank it**
(RAW card → `Movie` → root ceremony preseed).

The two engine sections load independently of the social state machine (they're
auth-gated, not friends-gated), so a connected-but-friendless viewer still gets
engine suggestions — the no-friends nudge is now an inline section, not a
full-screen replacement.

## Rank-it handoff choreography

The constraint: Discover is a `.sheet` presented by `FeedScreen`, but the rank
ceremony lives at `SpoolAppRoot` (a `flow`-driven full screen). A card action
inside the sheet can't push the ceremony under itself.

Threaded a closure the same shape as the existing `onOpenActor` handoff:

- `DiscoverModel.rankIt(item/rec/trending)` maps the RAW card → `Movie`
  (`DiscoverCardCopy.movie(from:)`; engine `voteAverage` rides along) and fires
  an injected `OnRankIt`.
- `DiscoverScreen` takes `onRankIt: ((Movie) -> Void)?` and binds it onto the
  `@StateObject` model on `.onAppear` via `model.bindRankIt(_:)` — the
  `RankManageModel.bindRerank` precedent, since the production model is built in
  `init` before the closure is known.
- `FeedScreen` wires `onRankIt` to: **dismiss the sheet first** (`showDiscover =
  false`), then call up `onRankFromDiscover?(movie)`.
- `SpoolAppRoot.rankItFromDiscover(_:)` seeds `rankMovie`, clears
  `rankWatchlistOrigin` (NO origin — a Discover rank must never delete a
  bookmark), enters `flow = .tier`, and async-enriches `voteAverage` from TMDB
  only when the card didn't carry it (social recs have none; engine items do).

This mirrors `rerankFromShelf` exactly (RAW item, no origin, no up-front delete)
— the cleanest existing pattern for "enter the ceremony from a non-search
surface." Documented in the DiscoverScreen header + inline comments.

## Chip copy decisions

iOS is EN-only in views today (hardcoded strings per every existing screen), so
the pool→copy map lives in `DiscoverCardCopy.chipCopy(for:)` rather than an i18n
table. Copy is the verbatim twin of web `i18n/en.ts`:

| pool | copy |
|------|------|
| friend | friends loved |
| taste | your taste |
| similar | because you ranked |
| trending | trending |
| variety | something different |
| generic | popular |
| new_release | new |
| backfill / unknown / nil | popular (fallback) |

`backfill` has no distinct story and any `.unknown(_)` / nil pool falls back to
"popular" — never a raw enum or blank chip (web `discoverChips` fallback parity).
The New Releases row passes a `chipOverride` of "new" (web hardcodes
`chipLabelKeyForPool('new_release')`).

## Error-vs-empty split (per section)

`DiscoverModel.SectionState` = `.loading | .ready([SuggestionItem]) | .empty |
.error`. Classification (`sectionState(for:)`):
- `SuggestionsError.notAuthenticated` → `.empty` (screen is auth-gated anyway;
  web's 401 → empty).
- `.http` / `.transport` / `.decoding` / any other throw → `.error` with a retry
  affordance (web's outage → error+retry).
- A successful read of zero items → `.empty`.

`loadEngineIfNeeded` / `loadNewReleasesIfNeeded` load once per mount (idempotent);
`refreshEngine` advances the page and whole-set swaps; `retryNewReleases`
re-fetches. Loading shows striped skeleton cards.

## Test evidence

New file `DiscoverEngineModelTests.swift` — 21 XCTest methods, zero network
(all IO injected as fakes, the `WatchlistModelTests`/`FeedFeedModelTests` idiom):

- **chip mapping** (2): every known pool → its EN copy; backfill/unknown/nil →
  "popular".
- **engine choreography** (6): ready caps at 12; notAuthenticated→empty;
  http→error; transport→error; empty result→empty; Refresh advances page +
  whole-set swaps; loadIfNeeded idempotent.
- **new-releases choreography** (3): ready caps at 10; notAuthenticated→empty;
  http→error then retry recovers to ready.
- **card actions** (6): save calls `add` with the right movie item + toasts;
  save failure toasts `.error`; save idempotent per id; rank-it fires the closure
  with the RAW mapped movie (incl. voteAverage passthrough).
- **social-card actions** (4): save/rank on FriendRecommendation + TrendingMovie.
- **section independence** (1): engine loads for a no-friends viewer while social
  state is `.noFriends`.

Verify:
- `swift build --package-path ios/Spool` → **Build complete**, no errors/warnings.
- `swift test --package-path ios/Spool` → **579 executed, 0 failures** (baseline
  558 + 21 new).

## Fix round 1

- The original brief's "consume/refill choreography" line was stale: the
  server-side pool-management move landed in Task 5 (the edge function now owns
  all pool selection and exclusions). The shipped implementation uses whole-set
  swap (page+1 on Refresh, replace not append), which matches the binding web
  twin at HEAD — deviation now explicit. This is not a regression; the brief
  description predates the Task 5 server-side move.

- Title-locale tension: on a zh device, `SuggestionsClient.locale()` sends
  `zh-CN` and the server returns zh titles. The rank-it path persists the zh
  title into `user_rankings` unchanged — this is exact parity with web at the
  same seam (web's `locale` is also device-derived and the ceremony writes
  whatever title the card carries). A contract doc touch-up (noting the
  locale-derived title in the rank ceremony) is owed in Task 7.

## Ledgered / follow-ups

- New Releases shows the year only (the `suggestions` wire carries `year`, no full
  release date) — web has the same limitation; ledgered, not a regression.
- Save-for-later's `savedIds` is per-session optimistic state (de-dups taps +
  drives the "saved" affordance); owned/bookmarked items are excluded server-side
  for the grid, so there's no client-side owned pre-filter on engine items. The
  social cards are also unfiltered client-side (Part A's `friendRecommendations`
  already excludes the viewer's ranked ∪ watchlisted ids server-side).
