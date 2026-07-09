-- ============================================================================
-- journal-search-gaps Task 1 — CJK + fuzzy matching in search_journal_entries
--
-- Plan:  docs/plans/2026-07-09-journal-search-gaps-plan.md (Task 1)
-- Verify: docs/plans/audits/2026-07-09-search-verification.md
--
-- ============================================================================
-- WHAT THIS DOES
-- ============================================================================
-- Upgrades search_journal_entries IN PLACE (CREATE OR REPLACE — same 23-column
-- return, same signature, same LANGUAGE sql STABLE SECURITY INVOKER, same pinned
-- search_path, same LIMIT 50). The ONLY change to the deployed §3 body
-- (20260708_journal_search_likes_hardening.sql) is the WHERE and ORDER BY: a
-- pg_trgm-backed substring/fuzzy branch is OR'd onto the existing English
-- tsvector path, and similarity() is added as a tie-break to ORDER BY. Two
-- trigram GIN indexes (title, review_text) accelerate the ILIKE branch.
--
-- ============================================================================
-- WHY TRIGRAM-ILIKE, NOT A DIFFERENT TEXT-SEARCH CONFIG (e.g. 'simple')
-- ============================================================================
-- The primary path stays the English tsvector (good stemming/ranking for the
-- common case). It has two gaps this migration closes:
--   1. CJK (Chinese/Japanese/Korean) text. Postgres full-text search tokenizes
--      on whitespace/punctuation; it CANNOT segment CJK where words are not
--      space-delimited. Swapping the config to 'simple' would not help — 'simple'
--      still tokenizes on the same boundaries, so a run of Han characters with no
--      spaces collapses to one giant token that only matches an identical whole
--      string, never a substring like a single 难过 inside a longer review.
--      Real CJK segmentation needs an extension (pg_bigm / zhparser / pgroonga)
--      that is not installed here. The standard no-new-extension answer is
--      trigram substring matching: ILIKE '%q%' accelerated by a pg_trgm GIN
--      index matches CJK substrings (and Latin substrings) regardless of word
--      boundaries. pg_trgm ships with Postgres and is enabled on Supabase.
--   2. Fuzzy / partial-word English ('matri' -> 'The Matrix'). tsvector matches
--      whole lexemes only; ILIKE '%matri%' matches the substring, and
--      similarity() ranks fuzzier matches for the ORDER BY tie-break.
--
-- plainto_tsquery('english', q) on a pure-CJK query yields an EMPTY tsquery,
-- which matches nothing and NEVER errors — the ILIKE branch carries those rows.
-- Short queries (<3 chars, incl. a single CJK char) still MATCH via ILIKE
-- because ILIKE does not require trigram length; the GIN index simply won't
-- accelerate 1-2 char queries (sequential-scan fallback), which is acceptable
-- because LIMIT 50 bounds the result and journal_entries is per-user small.
-- EMPTY-QUERY GUARD: `length(trim(search_query)) = 0` short-circuits the ILIKE
-- branches to FALSE so an empty/whitespace query does not ILIKE '%%' (which
-- would match every row) — it falls through to the tsvector branch (also empty),
-- yielding zero rows, matching the pre-migration behavior for an empty query.
-- WILDCARD PASSTHROUGH: user-supplied `%` or `_` characters in search_query are
-- passed verbatim into the ILIKE predicate and act as ILIKE wildcards (over-match
-- only); results remain bounded by user scoping, RLS, and LIMIT 50.
--
-- ============================================================================
-- TAKEAWAY-EXCLUSION INVARIANT (do not regress the C2 B5 privacy leak)
-- ============================================================================
-- personal_takeaway is owner-only and adjudicated unmatchable AND unreturned.
-- The trigram/ILIKE branches touch ONLY title and review_text; the tsvector
-- (rebuilt in 20260708 §2 WITHOUT the takeaway weight) already excludes it; the
-- return table has no personal_takeaway column. Adding a trigram index or an
-- ILIKE predicate over personal_takeaway would recreate the C2 B5 leak — a
-- takeaway-only search term must return ZERO rows (verification probe (4)).
-- RLS on journal_entries still does all row filtering under SECURITY INVOKER;
-- this function body remains a plain SELECT and re-implements no visibility.
--
-- ============================================================================
-- ROLLBACK (verbatim — the extension is left installed; harmless, other tables
-- may use pg_trgm later)
-- ============================================================================
-- Drop the two trigram indexes, then restore the §3 function body verbatim
-- (from 20260708_journal_search_likes_hardening.sql:123-161):
--
--   DROP INDEX IF EXISTS idx_journal_entries_title_trgm;
--   DROP INDEX IF EXISTS idx_journal_entries_review_trgm;
--
--   CREATE OR REPLACE FUNCTION search_journal_entries(search_query text, target_user_id uuid)
--   RETURNS TABLE (
--     id uuid,
--     user_id uuid,
--     tmdb_id text,
--     title text,
--     poster_url text,
--     rating_tier text,
--     review_text text,
--     contains_spoilers boolean,
--     mood_tags text[],
--     vibe_tags text[],
--     favorite_moments text[],
--     standout_performances jsonb,
--     watched_date date,
--     watched_location text,
--     watched_with_user_ids uuid[],
--     watched_platform text,
--     is_rewatch boolean,
--     rewatch_note text,
--     photo_paths text[],
--     visibility_override text,
--     like_count integer,
--     created_at timestamptz,
--     updated_at timestamptz
--   ) AS $$
--     SELECT
--       je.id, je.user_id, je.tmdb_id, je.title, je.poster_url, je.rating_tier,
--       je.review_text, je.contains_spoilers, je.mood_tags, je.vibe_tags,
--       je.favorite_moments, je.standout_performances, je.watched_date,
--       je.watched_location, je.watched_with_user_ids, je.watched_platform,
--       je.is_rewatch, je.rewatch_note, je.photo_paths, je.visibility_override,
--       je.like_count, je.created_at, je.updated_at
--     FROM journal_entries je
--     WHERE je.user_id = target_user_id
--       AND je.search_vector @@ plainto_tsquery('english', search_query)
--     ORDER BY ts_rank(je.search_vector, plainto_tsquery('english', search_query)) DESC
--     LIMIT 50;
--   $$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public;
--
-- (The extension is intentionally NOT dropped on rollback.)
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. pg_trgm — trigram similarity + GIN operator classes. Ships with Postgres,
--    enabled on Supabase. Idempotent; left installed on rollback.
-- ────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Trigram GIN indexes on the two matchable columns ONLY (title, review_text).
--    These accelerate the ILIKE '%q%' branch below, including CJK substrings and
--    partial words. Nullable columns are fine — NULL rows simply never match.
--    Deliberately NO index on personal_takeaway (takeaway-exclusion invariant).
-- ────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_journal_entries_title_trgm
  ON journal_entries USING GIN (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_journal_entries_review_trgm
  ON journal_entries USING GIN (review_text gin_trgm_ops);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. CREATE OR REPLACE the search RPC — base body copied verbatim from
--    20260708_journal_search_likes_hardening.sql §3; ONLY the WHERE and ORDER BY
--    change (tsvector OR trigram-ILIKE over title/review_text; similarity()
--    tie-break). Signature, 23-column return, attributes, LIMIT 50 unchanged.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION search_journal_entries(search_query text, target_user_id uuid)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  tmdb_id text,
  title text,
  poster_url text,
  rating_tier text,
  review_text text,
  contains_spoilers boolean,
  mood_tags text[],
  vibe_tags text[],
  favorite_moments text[],
  standout_performances jsonb,
  watched_date date,
  watched_location text,
  watched_with_user_ids uuid[],
  watched_platform text,
  is_rewatch boolean,
  rewatch_note text,
  photo_paths text[],
  visibility_override text,
  like_count integer,
  created_at timestamptz,
  updated_at timestamptz
) AS $$
  SELECT
    je.id, je.user_id, je.tmdb_id, je.title, je.poster_url, je.rating_tier,
    je.review_text, je.contains_spoilers, je.mood_tags, je.vibe_tags,
    je.favorite_moments, je.standout_performances, je.watched_date,
    je.watched_location, je.watched_with_user_ids, je.watched_platform,
    je.is_rewatch, je.rewatch_note, je.photo_paths, je.visibility_override,
    je.like_count, je.created_at, je.updated_at
  FROM journal_entries je
  WHERE je.user_id = target_user_id
    AND (
      je.search_vector @@ plainto_tsquery('english', search_query)
      OR (
        length(trim(search_query)) > 0
        AND (
          je.title ILIKE '%' || search_query || '%'
          OR je.review_text ILIKE '%' || search_query || '%'
        )
      )
    )
  ORDER BY
    ts_rank(je.search_vector, plainto_tsquery('english', search_query)) DESC,
    GREATEST(
      similarity(je.title, search_query),
      similarity(coalesce(je.review_text, '')::text, search_query)
    ) DESC
  LIMIT 50;
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public;
