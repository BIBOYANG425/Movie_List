# C5 Web Blocking Fixes Implementation Plan (TV/books correctness before the iOS port)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the five C5-audit blocking findings so web TV/book ranking semantics are correct BEFORE iOS copies them: corrupt whole-show rank rows (B1), delete-first re-rank data loss (B2), localized-title persistence (B3), failure-blind emissions/stubs (B4), and cross-media ceremony routing (B5).

**Architecture:** All fixes port the already-shipped MOVIE patterns (C4) to the TV/book branches of `pages/RankingAppPage.tsx` and the modal routers — no new primitives. Non-destructive re-rank reuses the `rerankState`-marker + upsert-replace + `set_tier_order` machinery; routing fixes make season selection and media dispatch unconditional.

**Tech Stack:** TypeScript + vitest. No migrations (a B1 prod-corruption detection query runs controller-side, repair owner-ackable).

## Global Constraints

- Binding source: `docs/plans/audits/2026-07-10-c5-tv-books-web-audit.md` (B1-B5 fix shapes, §1 reference semantics). Branch `fix/c5-tv-books-web-blocking` off main.
- Contract (docs/contracts/shared-payloads.md): re-rank emits ONE `ranking_move` ({notes?, year?}, never watched-with), never remove+add; position integrity via `set_tier_order` full-membership; title-locale pin (persisted titles = default-locale; the strict pin applies to re-rank/raw-item paths); TV id canon `tv_{show}_s{n}` / whole-show `tv_{show}` with REAL show_tmdb_id (never 0 on new season rows).
- Event/side-effect gating: emissions and stub writes fire ONLY after confirmed save success (movie parity).
- Tests `npx vitest run services/__tests__/` (baseline 504) + `npx tsc --noEmit`. Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do NOT restructure the ceremonies; these are surgical parity fixes.

---

### Task 1: Routing fixes — B1 (Rank TV skips season selection) + B5 (deep-link re-rank cross-media)

**Files:** Modify `pages/RankingAppPage.tsx` (UniversalSearch "Rank TV" handler ~1493-1505; deep-link re-rank router), `components/media/AddTVSeasonModal.tsx` (preselect router ~204-233) if needed; Test in `services/__tests__/` where pure seams exist.
- B1: the UniversalSearch rank-TV path must route through season selection exactly like the Save path (C3's `tvWatchlistItemFromShow` fix class): a show preselect (showTmdbId set, falsy seasonNumber) goes to the season grid; never mint `tv_{id}` rows with `show_tmdb_id=0`. Follow the audit's pinned router contract.
- B5: the deep-link "Re-rank" handler must dispatch by media type — TV items → AddTVSeasonModal path, book items → RankingFlowModal, movie → movie ceremony (today all route into the movie ceremony, cross-writing user_rankings + a movie stub). Route + verify the ids never cross tables.
- Commit `fix(web): TV rank routing honors season selection; deep-link re-rank dispatches by media (B1/B5)`.

### Task 2: Non-destructive TV/book re-rank + raw titles — B2 + B3

**Files:** Modify `pages/RankingAppPage.tsx` (TV/book re-rank entry points — remove the up-front `removeTVItem`/`removeBookItem`; mirror the movie `rerankState` pattern incl. the id-guard + watched-with-omission lessons), `components/media/AddTVSeasonModal.tsx` / `components/RankingFlowModal.tsx` only if completion seams need a param.
- B2: cancel at any step = zero persistence; completion upserts on the unique key + `set_tier_order` compaction (target + source when tier changed); emission = ONE `ranking_move`, never `ranking_remove`+`ranking_add`. Port the movie flow's guards verbatim (id-guarded isRerank; stale-marker cleared on every exit; no-op semantics).
- B3: resolve the RAW item from state before seeding the preselect (tv AND book branches) — localized titles never reach persistence; comment pinning the contract.
- Commit `fix(web): non-destructive TV/book re-rank emitting ranking_move; raw titles (B2/B3)`.

### Task 3: Failure-blind emissions and stubs — B4

**Files:** Modify `pages/RankingAppPage.tsx` (`handleAddTVItem`/`handleAddBookItem` completion paths — gate `ranking_add`/`ranking_move` emission AND the tv_season stub write on save success, movie parity; the ledgered "addTV/addBook silent-fail + ranking_add fires" C4 minor dies here too: add the failure toast).
- Commit `fix(web): TV/book emissions and stubs gate on confirmed save (B4)`.

### Task 4: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C5 row: web blocking fixes in PR; B1-B5 dispositions; deferred D1-D10 pointer; C4-minor closure note), `docs/contracts/shared-payloads.md` (only if a contract line proves stale — the re-rank MUST was already scoped to "web movie ceremony"; WIDEN it to all three web media now that B2 lands, keeping known-deviations accurate).
- Commit `docs: C5 web blocking dispositions; re-rank contract covers all web media`.

## Self-Review Notes

- Controller runs the B1 corruption-detection query via MCP before merge (count tv_rankings rows with `show_tmdb_id = 0` or whole-show-shaped ids that should be seasons; report; repair owner-ackable) — same pattern as C4's probe.
- The iOS C5 plan builds on the CORRECTED semantics (audit gap list, dependency order); it is a separate plan after this PR merges.
