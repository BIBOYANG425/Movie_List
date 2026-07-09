# Journal Search Gaps Implementation Plan (mini-cycle)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the journal search's three known gaps — Chinese text is nearly unsearchable (English-only stemming), no fuzzy/substring matching, and iOS searches per keystroke — without new infra and without changing the RPC's wire contract.

**Architecture:** One migration upgrades `search_journal_entries` in place: keep the English tsvector as the primary ranked path, add a `pg_trgm`-backed substring/fuzzy branch (trigram GIN indexes on `title` and `review_text`) that makes CJK and typo'd/partial queries match; same signature, same 23-column return, same SECURITY INVOKER + LIMIT 50, ranking = ts_rank primary then trigram similarity. iOS gains a 300 ms debounce in `JournalListModel.search`. Web needs zero code change (wire identical). Owner-authorized MCP apply + probes before merge (C1/C3 precedent).

**Tech Stack:** Postgres 17 pg_trgm (available on Supabase), SQL migration; Swift (JournalListModel) + XCTest.

## Global Constraints

- Branch `fix/journal-search-gaps` off main (8815127). The RPC's WIRE CONTRACT IS FROZEN: name `search_journal_entries(search_query text, target_user_id uuid)`, SECURITY INVOKER, `LANGUAGE sql STABLE`, pinned search_path, the exact 23-column return table (no `personal_takeaway`, no `search_vector`), LIMIT 50 — both deployed clients call it today; only the MATCHING may improve.
- `personal_takeaway` must remain unmatchable AND unreturned: the trigram branch may only touch `title` and `review_text` (+ the existing tsvector which already excludes takeaway). Adding a trigram index or ILIKE over takeaway would recreate the C2 B5 leak — forbidden.
- RLS does the row filtering (invoker) — the function body stays a plain SELECT; no visibility re-implementation.
- Migration file `supabase/migrations/20260709_journal_search_cjk_fuzzy.sql`; verbatim rollback (the current function body is quoted in `20260708_journal_search_likes_hardening.sql` §3); implementers never apply — controller applies via MCP + probes.
- iOS: suite (355) stays green; debounce must be cancellation-based (`Task.sleep` + cancel prior), not timer polling; RED-first test for the debounce decision seam.
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Migration — CJK + fuzzy matching in `search_journal_entries`

**Files:** Create `supabase/migrations/20260709_journal_search_cjk_fuzzy.sql`; Create `docs/plans/audits/2026-07-09-search-verification.md` (controller probes).

- `CREATE EXTENSION IF NOT EXISTS pg_trgm;` (Supabase-available; note in header).
- Trigram GIN indexes: `ON journal_entries USING GIN (title gin_trgm_ops)` and `(review_text gin_trgm_ops)` (nullable ok — nulls simply don't match). Names `idx_journal_entries_title_trgm` / `idx_journal_entries_review_trgm`.
- `CREATE OR REPLACE` the function (same signature/columns/attributes — copy the current body from `20260708_journal_search_likes_hardening.sql` §3 as the base) with the WHERE becoming:
  `je.user_id = target_user_id AND ( je.search_vector @@ plainto_tsquery('english', search_query) OR je.title ILIKE '%' || search_query || '%' OR je.review_text ILIKE '%' || search_query || '%' )`
  and ORDER BY `ts_rank(je.search_vector, plainto_tsquery('english', search_query)) DESC, GREATEST(similarity(je.title, search_query), similarity(coalesce(je.review_text,'')::text, search_query)) DESC` then LIMIT 50. (ILIKE with the trigram GIN index gives CJK substring + partial-word matching; similarity() breaks ties for fuzzy ranking. plainto_tsquery on a pure-CJK query yields an empty tsquery that matches nothing — the ILIKE branch carries those. Note in the header: empty tsquery from `plainto_tsquery` never errors; short queries (<3 chars incl. single CJK chars) still match via ILIKE since ILIKE doesn't require trigram length — the index just won't accelerate 1-2 char queries; acceptable, LIMIT 50 bounds it. Guard: skip the ILIKE branches when `length(trim(search_query)) = 0`.)
- Header documents: why trigram-ILIKE not `simple` config (Postgres can't segment CJK; trigram substring matching is the standard no-extension answer), the takeaway exclusion invariant, and the verbatim rollback (old function body + DROP INDEX + note the extension is left installed).
- Verification doc probes (controller runs post-apply, using a `begin/set local role/rollback` pattern like C2's): (1) EN word still matches via tsvector; (2) a CJK substring in review_text matches (insert a fixture row in-transaction, search '难过' style substring); (3) partial-word 'matri' matches 'The Matrix' title; (4) takeaway-only text does NOT match (fixture with the term only in personal_takeaway → 0 rows); (5) return columns unchanged (23, no takeaway); (6) stranger-visibility probe unchanged (RLS still filters).
- Commit `fix(sql): journal search matches CJK + partial text via trigram fallback`.

### Task 2: iOS debounce in `JournalListModel.search`

**Files:** Modify `ios/Spool/Sources/Spool/Services/JournalListModel.swift` (~155, `func search(query:)`); Test extend `ios/Spool/Tests/SpoolTests/JournalListModelTests.swift`.

- Hold a `private var searchTask: Task<Void, Never>?`; `search(query:)` cancels the prior task, and for a non-empty query sleeps ~300 ms (`try? await Task.sleep(nanoseconds: 300_000_000)`) then checks `Task.isCancelled` before firing the RPC. Empty query cancels + returns to list mode immediately (no debounce on clearing). Keep the existing mode/entries/fail-soft semantics untouched.
- Make the delay injectable (`debounceNanos` var, default 300ms) so tests run fast. RED-first tests: rapid successive `search` calls fire the RPC exactly once with the LAST query; clearing during the debounce window cancels (zero RPC calls); a completed search still populates results (existing tests keep passing).
- Commit `fix(ios): debounce journal search input`.

### Task 3: Docs + apply

**Files:** Modify `docs/contracts/shared-payloads.md` (Search RPC paragraph: matching now tsvector OR trigram-ILIKE over title/review_text only; takeaway still unmatchable; wire unchanged) + `docs/plans/2026-07-07-ios-parity-ledger.md` (mini-cycle row + note).
- Controller then: apply migration via MCP → run the 6 probes → PR → CI → merge.
- Commit `docs: journal search CJK/fuzzy notes`.

## Self-Review Notes

- The wire freeze means zero web/iOS call-site changes — the only client change is the debounce (UX, not contract).
- The takeaway-leak invariant is restated in Task 1's WHERE construction and probed by (4) — the one way this migration could regress C2's B5.
- Rollback is single-statement-per-object and quoted verbatim; the extension stays (harmless, other tables may use it later).
