# Movie Search Fuzzy-Matching Fix Plan (mini-cycle)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make typo'd / space-broken movie+TV searches return results on every surface (owner report 2026-07-09: "fuzzy movie search is not working"), per the investigation findings.

**Architecture:** TMDB has zero typo tolerance ("shawshenk" → 0) but strong prefix matching ("shawsh" → 4), both verified live. So: a pure query-variant generator + zero-result retry backoff INSIDE `searchMovies`/`searchTVShows` covers every web surface for free (UniversalSearch, AddMediaModal, AddTVSeasonModal, onboarding, Letterboxd import all call them); the same backoff is mirrored in the iOS TMDBService; and the dead local-fuzzy layer (`fuzzySearch.ts` — leading-article slice bug, whole-title compare) is repaired so the modal's correction chip works. Client-only: no migrations, no contract changes.

**Tech Stack:** TypeScript + vitest; Swift + XCTest.

## Global Constraints

- Binding source: the 2026-07-09 movie-search investigation (surfaces map + root causes, recorded in `docs/plans/2026-07-07-ios-parity-ledger.md` C4 notes bullet "MOVIE SEARCH").
- Branch `fix/movie-search-fuzzy` off main (post-#39). Web tests `npx vitest run services/__tests__/` (baseline 362) + `npx tsc --noEmit`; iOS `swift test --package-path ios/Spool` (baseline 370).
- Retry fires ONLY on the zero-result path (debounce already rate-limits; worst case +3 requests). Variants ordered cheapest-first, capped at 3, first non-empty result wins and is returned unchanged (no result mixing).
- Verified-live variant behaviors to preserve: collapse inner spaces (`"matri x"` → `"matrix"` works); progressive trailing-char chop on the last token (`"shawshenk"` → `"shawsh"` works via TMDB prefix matching); drop last token (multi-word queries).
- Locale behavior unchanged on web (`language=` follows app locale). iOS `locale()` stops hardcoding `en-US` and follows the app locale (web parity).
- NOT in scope (ledgered deferred): no-results-vs-error UX distinction, "already in your list" hint, onboarding stale-request guard, TMDB proxy edge function, OpenLibrary book fuzz.
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Pure variant generator + zero-result retry in tmdbService (web)

**Files:** Modify `services/tmdbService.ts` (`searchMovies` ~849, `searchTVShows` ~1219); Create `services/searchVariants.ts`; Test `services/__tests__/searchVariants.test.ts`.

**Interfaces:**
- Produces: `typoRetryVariants(q: string): string[]` — ordered, deduped, original excluded, max 3: (1) inner-whitespace collapse if the query has an inner space; (2) last token chopped by 1 then 2 trailing chars (only while the chopped token stays ≥ 4 chars); (3) last token dropped entirely (only if ≥ 2 tokens and the remainder is ≥ 3 chars). Trim + single-space normalize first. Queries < 4 chars or CJK-containing (`/[぀-ヿ㐀-鿿]/`) return `[]` (TMDB handles CJK; chopping CJK is nonsense).
- RED-first cases: `"matri x"` → `["matrix", ...]` first; `"shawshenk"` → `["shawshen","shawshe"]` (no drop — single token); `"dark knigt"` → collapse absent, chops then `"dark"`; `"ab"` → `[]`; `"肖申克"` → `[]`; dedup when collapse == chop result; original never included.
- In `searchMovies`/`searchTVShows`: after the primary fetch maps to 0 results, loop `typoRetryVariants(query)` sequentially, return the first non-empty mapped result set; all errors keep the existing swallow-to-`[]` posture. No behavior change when the primary query has results.
- Wire the existing stale-request guards untouched (the retry happens inside the service call, so callers' requestId logic is unaffected).
- Commit `fix(web): zero-result typo-retry backoff in TMDB search (covers all search surfaces)`.

### Task 2: Repair the dead local-fuzzy layer (web modal correction)

**Files:** Modify `services/fuzzySearch.ts`; Test `services/__tests__/fuzzySearch.test.ts` (extend or create).

- Fix the leading-article misalignment: normalize BOTH sides (lowercase, strip leading `the |a |an `) before comparing; compare the query against the normalized title's prefix of the same length (not `slice(0, q.length + 2)` of the raw title) AND against each word-start suffix of the title (so "shawshenk" matches "The **Shawshank** Redemption").
- `getBestCorrectedQuery`: score against the best-matching word-window of each candidate title (same normalized prefix logic), not the whole-title distance — a 9-char query must be able to correct against a 24-char title.
- Allow 2-char queries when the query contains non-ASCII (keep min 3 for ASCII).
- Preserve exported signatures — call sites in AddMediaModal/AddTVSeasonModal unchanged.
- RED-first: "shawshenk" vs "The Shawshank Redemption" matches; "matrix" vs "The Matrix" matches; unrelated titles still rejected at 0.3; 2-char CJK passes the gate, 2-char ASCII does not.
- Commit `fix(web): local fuzzy matcher handles leading articles and partial-title typos`.

### Task 3: iOS mirror — variant backoff + locale parity

**Files:** Modify `ios/Spool/Sources/Spool/Services/TMDBService.swift` (search ~106-131, `locale()` ~135); Create `ios/Spool/Tests/SpoolTests/SearchVariantsTests.swift`.

- Port `typoRetryVariants` as a pure static (same rules/thresholds as Task 1 — copy the ordered-variant spec above verbatim into Swift; test cases mirror Task 1's).
- In the search path: on 0 mapped results, try variants sequentially (respect existing Task-cancellation checks between requests — bail on cancel); errors keep the swallow-to-`[]` posture.
- `locale()`: follow the app locale (same source the rest of the app uses for zh/en — find the existing locale accessor; do not invent a new one) instead of hardcoded `"en-US"`; keep `en-US` as the fallback.
- Commit `fix(ios): TMDB search typo-retry backoff + locale parity with web`.

### Task 4: Ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (update the C4 "MOVIE SEARCH" bullet: shipped, PR #, what landed, deferred UX items list).

- Commit `docs: movie search fuzzy fix ledger`.

## Self-Review Notes

- Task 1's variant spec is duplicated verbatim into Task 3 by design (implementers see only their own task).
- No cross-task type dependencies: web and iOS generators are independent twins pinned by mirrored test suites.
- The retry lives in the SERVICE so the fix covers surfaces (incl. Letterboxd import) without touching their components; the modal-only fuzzy layer (Task 2) is additive polish on top.
