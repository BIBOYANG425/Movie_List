# C3 Part B — Suggestions Edge Function + Merged Discover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move the 5-pool suggestion engine server-side (`suggestions` edge function), ship the `tmdb-proxy`, migrate both clients onto them (retiring the TMDB key from both bundles), and deliver the owner-adjudicated merged Discover on BOTH platforms (engine grid + provenance chips + New Releases row + card actions).

**Architecture:** Two Deno edge functions. `suggestions` implements the C3 audit §2 spec VERBATIM (JWT-forwarded user-RLS reads, per-media pool engine, modes `suggestions`/`backfill` + new mode `new_releases`, pool provenance in the response, per-user token bucket, TMDB key from the secret store — the owner has already set `TMDB_API_KEY`). `tmdb-proxy` is the §2.4 allowlisted GET passthrough for everything else (search/details/person/season/zh-titles). Web and iOS swap their TMDB fetch layers to the proxy and their suggestion calls to the function; Discover becomes the merged surface everywhere.

**Tech Stack:** Deno/TypeScript (edge functions; no deno binary locally — pure logic goes in testable modules exercised by vitest via plain-TS imports where feasible, else controller probes), React+TS+vitest, Swift+XCTest.

## Global Constraints

- **Binding spec:** `docs/plans/audits/2026-07-08-c3-watchlist-discover-web-audit.md` §1.3-§1.6 (engine semantics incl. every quirk to preserve: overfetch +2/+1, random similar-pick, page jitters, coin-flip decade, take-order similar3/taste4/trending2/variety2/friend1, numeric dedup, refill-without-friend, final shuffle, backfill cap 20, threshold 3, per-media genre tables + `normalizeTVGenres`, TV excludeIds pre-expanded to show-level) and §2/§2.4 (request/response JSON, auth, error codes, caching = none + token bucket, proxy allowlist). Owner adjudications (ledgered): merged Discover both platforms; provenance chips; New Releases row (TMDB now-playing/upcoming filtered by taste genres); Q7 threshold hard-coded.
- **B1 fix class at the server boundary:** exclusion sets normalize both `tmdb_{n}` and bare `{n}` movie ids; TV season ids expand to show ids (audit §2 step 1).
- New mode `new_releases`: `{ mediaType: "movie", mode: "new_releases", limit?: ≤10 }` → TMDB `/movie/now_playing` + `/movie/upcoming` (locale region-free v1), filtered to the caller's top-3 weighted taste genres when `totalRanked ≥ 3` (else unfiltered popular), excluding ranked ∪ watchlisted, poster-required, `pool: "new_release"`, sorted by release date ascending (soonest first).
- Secrets: `TMDB_API_KEY` is SET in the function secret store (owner 2026-07-09). Implementers never deploy; the controller deploys via MCP + probes before merge. Verbatim redeploy/rollback notes in each function header.
- Web tests `npx vitest run services/__tests__/` (baseline 382) + `npx tsc --noEmit`; iOS `swift test --package-path ios/Spool` (baseline 522 post-#44). Branch `feat/c3-part-b-suggestions` off main (post-#44).
- Bundle-key retirement is DoD: after this branch, `VITE_TMDB_API_KEY` and the Info.plist `TMDB_API_KEY` are unused by app code (grep-clean except .env.example/docs); `hasTmdbKey()`-style gates swap to session-auth gates. The SIMULATOR harness Info.plist keeps its Supabase keys; its TMDB key line gets removed.
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 0 (DISPATCH FIRST — data-loss fix, owner-ordered 2026-07-10): re-rank must not wipe rich journal entries

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankPersistence.swift` (the stage-A quick-write call) and/or `ios/Spool/Sources/Spool/Services/JournalQuickEntry.swift`; Test `ios/Spool/Tests/SpoolTests/` (extend the quick-entry tests).
- Today: ceremony finish fires `JournalQuickEntry.write` — a full-replace upsert on `(user_id, tmdb_id)`. On a RE-RANK (`InsertOutcome == .moved`) of a movie with an existing RICH journal entry (review text, moments, photos, visibility), the near-blank quick draft replaces it. C4-UI final review finding, ledgered; owner ordered the fix here.
- **Fix shape (probed merge, not a blanket skip):** thread `InsertOutcome` (RankPersistence already receives it) into the quick-write decision. `.inserted` → unchanged (fresh rank, quick write as today). `.moved` → if the ceremony captured NO new moods/one-liner, skip the quick-write entirely; if it DID capture input, use the C2 probe-before-edit machinery (fetch the full owner row first, merge ONLY moods + one-liner onto it, preserving every other field — the exact pattern `JournalDraftModel` uses). Never full-replace on `.moved`.
- Verify WEB's posture first (does the web ceremony write journal entries at all on re-rank? grep the rank completion path): if web has the same wipe class, ledger it as a web follow-up in Task 7 (do NOT fix web in this task); if web is clean, note why in the report.
- RED-first: `.moved` + no input → no journal write; `.moved` + new moods → merged row preserves review_text/photos/takeaway/visibility; `.inserted` unchanged.
- Commit `fix(ios): re-rank ceremony merges journal quick-entry instead of full-replacing (wipe fix)`.

### Task 1: `suggestions` edge function

**Files:** Create `supabase/functions/suggestions/index.ts` (+ `engine.ts` pure module: profile build, exclusion normalization, pool assembly/refill/shuffle seams with injected fetchers); Create `docs/plans/audits/2026-07-10-c3b-verification.md` (controller probes: auth 401, validation 400, movie+tv suggestions shape incl. `pool` field, backfill cap, new_releases mode, threshold fallback, RLS isolation — a user sees only their own exclusions, token-bucket 429).
- Port §1.3/§1.4 semantics verbatim from `services/tmdbService.ts` (movie ~304-591, tv ~1500-1849) — the web file is the reference; preserve the quirks list above. Auth/CORS/validation mirroring `journal-agent/index.ts`. Response per §2 (`items[]` with `pool`, `totalRanked`).
- Pure `engine.ts` written import-clean (no Deno globals) so vitest can exercise assembly/exclusion/threshold via `services/__tests__/suggestionsEngine.test.ts` (add to web suite — RED-first for: exclusion normalization both id forms + TV expansion, take-order + refill-without-friend, dedup, threshold fallback, new_releases genre filter).
- Commit `feat(edge): suggestions — 5-pool engine server-side with pool provenance + new_releases mode`.

### Task 2: `tmdb-proxy` edge function

**Files:** Create `supabase/functions/tmdb-proxy/index.ts`; extend the verification doc (allowlist accepted paths, non-allowlisted 403, traversal rejected, 5s upstream timeout, auth 401).
- §2.4 verbatim: authenticated GET `?path=…`, allowlist exactly: `search/movie|tv|person`, `movie/{id}` (+`append_to_response`), `movie/{id}/similar|recommendations`, `tv/{id}`, `tv/{id}/season/{n}`, `person/{id}`, `person/{id}/movie_credits`, `trending/*`, `discover/*`, `movie/now_playing`, `movie/upcoming`. Same token bucket; never echo upstream bodies on error.
- Commit `feat(edge): tmdb-proxy — allowlisted authenticated TMDB passthrough`.

### Task 3: Web fetch layer onto the proxy + modal/onboarding swap

**Files:** Modify `services/tmdbService.ts` (single fetch seam → proxy URL + session token; delete direct-key usage), `hooks/useLocalizedItems.ts`, `components/journal/CastSelector.tsx`, `services/letterboxdImportService.ts` (proxy), `components/media/AddMediaModal.tsx`, `components/media/AddTVSeasonModal.tsx`, `pages/MovieOnboardingPage.tsx` (suggestions/backfill → `supabase.functions.invoke('suggestions')`, keep the consume/refill choreography client-side per §2 "What stays client-side"); Tests extend `services/__tests__/`.
- The Task-1-shipped engine owns exclusions server-side; the modals still pass `sessionExcludeIds` (≤200) for session-local consumed ids. Signed-out → keep the existing fixture/generic behavior gates (session-auth gate replaces `hasTmdbKey()`).
- Typo-retry backoff (PR #41) lives in tmdbService and must survive the proxy swap byte-identically (same variants, same zero-result/non-2xx rules — non-2xx now includes proxy 401/429).
- Commit `feat(web): TMDB via proxy; suggestions via edge function (key leaves the bundle)`.

### Task 4: Web merged Discover

**Files:** Modify `components/DiscoverView.tsx` (+ split files if it grows): friend sections (existing) + engine grid (suggestions fn, provenance chips: "friends loved" / "because you ranked …" / "trending" / "variety" / "new") + New Releases row (`new_releases` mode); save-to-watchlist stays; Refresh = page+1 re-request. Tests for any pure mapping (chip label from pool key).
- Commit `feat(web): merged Discover — engine grid with provenance chips + New Releases row`.

### Task 5: iOS SuggestionsClient + proxy routing + key retirement

**Files:** Create `ios/Spool/Sources/Spool/Services/SuggestionsClient.swift` (functions.invoke pattern per JournalAgent precedent if one exists — else supabase-swift `functions.invoke`; both modes + new_releases; response decode incl. `pool`); Modify `ios/Spool/Sources/Spool/Services/TMDBService.swift` (all fetches → tmdb-proxy with the user's session token; typo-retry + cancellation semantics preserved; `getGenericSuggestions` deleted in favor of the fn's threshold fallback; fixtures fallback when signed out stays); remove `TMDB_API_KEY` from the simulator harness `Info.plist.example` + docs. Tests: decode fixtures, proxy URL builder, RED-first.
- Commit `feat(ios): SuggestionsClient + TMDB via proxy — key leaves the bundle`.

### Task 6: iOS merged Discover grid + card actions

**Files:** Modify `ios/Spool/Sources/Spool/Screens/DiscoverScreen.swift` (+ `DiscoverModels.swift`/model): engine grid mounts in the reserved Part-B slot (provenance chips per pool), New Releases row, and card actions — **save for later** (WatchlistRepository.add) and **rank it** (enter ceremony preseeded, no watchlist origin) on BOTH the social sections and the engine grid (closes the Part-A "cards inert" deferral). Consume/refill choreography client-side. Tests: model choreography (consume → refill from backfill pool, re-request <3), action wiring.
- Commit `feat(ios): Discover engine grid — provenance chips, New Releases, card actions`.

### Task 7: Docs + ledger

**Files:** `docs/contracts/shared-payloads.md` (new `## suggestions function` section: request/response JSON incl. `pool` + `new_releases`, auth, error codes, sessionExcludeIds cap; `## tmdb-proxy` allowlist); `docs/plans/2026-07-07-ios-parity-ledger.md` (C3 COMPLETE both parts; key-retirement DoD met; deferred leftovers).
- Commit `docs: suggestions + proxy contracts; C3 complete`.

## Self-Review Notes

- Controller deploy order before merge: deploy `suggestions` + `tmdb-proxy` via MCP, run the verification probes (secret presence is implicitly probed by a live TMDB call), THEN merge — old clients never call the functions; new clients require them (same apply-before-merge logic as migrations).
- The web engine code in tmdbService becomes dead after Task 3; delete in Task 3 (not deferred) so the parity CI's dead-code posture stays honest — but keep `typoRetryVariants`/`fuzzySearch` (still client-side).
- New Releases uses region-free release dates v1 (no locale/region param) — region handling is a deferred follow-up (ledger it in Task 7).
