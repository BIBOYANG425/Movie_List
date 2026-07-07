-- ============================================================================
-- C2 Task 1 — Journal search + likes hardening (audit findings B1, B3, and
-- the search half of B5)
--
-- Plan:  docs/plans/2026-07-08-c2-journal-web-fixes.md (Task 1)
-- Audit: docs/plans/audits/2026-07-08-c2-journal-web-audit.md
--
-- ============================================================================
-- !! ORDERING DEPENDENCY — READ BEFORE APPLYING !!
-- ============================================================================
-- The rewritten search_journal_entries below is SECURITY INVOKER. It performs
-- NO visibility filtering of its own beyond `user_id = target_user_id`; every
-- row it returns is admitted (or refused) by the RLS policies on
-- journal_entries at query time. Its cross-user correctness therefore depends
-- on the RESOLVED-VISIBILITY RLS rewrite shipped in
-- 20260708_journal_visibility_model.sql (plan Task 2):
--   NULL override -> author's profiles.profile_visibility; 'public' -> all
--   authenticated; 'friends' -> follower EXISTS; 'private' -> owner only.
--
-- RUNBOOK ORDER: apply 20260708_journal_visibility_model.sql FIRST, then this
-- file. Under the CURRENT policy (supabase_fix_critical_rls.sql:20-33) the
-- `visibility_override IS NULL` branch is world-readable (finding B2), so an
-- invoker search applied before Task 2 would still surface NULL-visibility
-- rows — exactly what direct table selects already expose today, and strictly
-- LESS than the SECURITY DEFINER RPC this replaces (which leaked even
-- 'private' rows). Applying this file first is therefore a monotonic
-- improvement, but B1 is only fully closed once Task 2's RLS is live.
-- This migration deliberately does NOT touch journal_entries RLS — that is
-- Task 2's file; documenting the dependency here per the plan's self-review
-- note is the extent of the coupling.
--
-- ============================================================================
-- APPLY-THEN-MERGE COMPATIBILITY (old deployed web code, between DB apply and
-- web deploy of this PR):
--   * search: same RPC name/arg names — old callers keep working; results
--     simply omit personal_takeaway (and search_vector), which old mapRow
--     treats as undefined. No breakage.
--   * likes: old code upserts into journal_likes then calls the (dropped)
--     counter RPCs. journal_likes survives as a transitional security_invoker
--     VIEW so old reads (and reviewService.ts, untouched in this task) keep
--     working; old like-writes fail gracefully (PostgREST rejects
--     ON CONFLICT upserts against views -> toggleJournalLike logs and returns
--     false; unlike DELETEs still work through the auto-updatable view; the
--     dropped-RPC calls were already fire-and-forget). Deploy the web build
--     promptly after apply, per the C1 precedent.
--   * side effect: like/unlike now bumps journal_entries.updated_at via the
--     existing BEFORE UPDATE updated_at trigger. No web reader sorts or
--     renders on updated_at today (cards use created_at); flagged for the
--     Task 5 contract doc.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. B1 — drop the definer search RPC (trusts caller-supplied target_user_id,
--    bypasses RLS: any authenticated user could read anyone's private rows).
--    Dropped (not replaced in-place) because the return type changes.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: recreate the previous function verbatim
--   (from supabase_journal_entries.sql:126-138):
--
--   -- 6. RPC: full-text search journal entries
--   CREATE OR REPLACE FUNCTION search_journal_entries(search_query text, target_user_id uuid)
--   RETURNS SETOF journal_entries AS $$
--   BEGIN
--     RETURN QUERY
--     SELECT *
--     FROM journal_entries
--     WHERE user_id = target_user_id
--       AND search_vector @@ plainto_tsquery('english', search_query)
--     ORDER BY ts_rank(search_vector, plainto_tsquery('english', search_query)) DESC
--     LIMIT 50;
--   END;
--   $$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

DROP FUNCTION IF EXISTS search_journal_entries(text, uuid);

-- ────────────────────────────────────────────────────────────────────────────
-- 2. B5 (search half) — rebuild the generated search_vector WITHOUT the
--    personal_takeaway weight. personal_takeaway is adjudicated owner-only;
--    it must not be discoverable through anyone's search, and after this
--    change a takeaway-only match can no longer confirm private text content.
--    A generated column's expression cannot be ALTERed: drop + re-add
--    (this rewrites the table and re-derives the vector for existing rows),
--    then recreate the GIN index that dropped with the column.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: restore the previous column + index verbatim
--   (from supabase_journal_entries.sql:36-41,62-63):
--
--   ALTER TABLE journal_entries DROP COLUMN IF EXISTS search_vector;
--   ALTER TABLE journal_entries ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
--     setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
--     setweight(to_tsvector('english', coalesce(review_text, '')), 'B') ||
--     setweight(to_tsvector('english', coalesce(immutable_array_to_string(favorite_moments, ' '), '')), 'C') ||
--     setweight(to_tsvector('english', coalesce(personal_takeaway, '')), 'D')
--   ) STORED;
--   CREATE INDEX IF NOT EXISTS idx_journal_entries_search_vector
--     ON journal_entries USING GIN (search_vector);

ALTER TABLE journal_entries DROP COLUMN IF EXISTS search_vector;

ALTER TABLE journal_entries ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
  setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(review_text, '')), 'B') ||
  setweight(to_tsvector('english', coalesce(immutable_array_to_string(favorite_moments, ' '), '')), 'C')
) STORED;

CREATE INDEX idx_journal_entries_search_vector
  ON journal_entries USING GIN (search_vector);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. B1 fix — SECURITY INVOKER search. Row filtering matches the RLS by
--    construction: the function body is a plain SELECT on journal_entries
--    executed with the caller's privileges, so the planner appends the
--    caller's RLS predicate to it — the function CANNOT return a row a direct
--    `SELECT ... FROM journal_entries` by the same caller would not return.
--    target_user_id is kept for wire compat with deployed clients and for the
--    §1 reference semantics (searching another user's journal tab), but it is
--    now only a narrowing filter, never a trust boundary.
--    personal_takeaway and search_vector are excluded from the return set
--    (B5: owner-only field must not ride along; owners read it via direct
--    selects, which no search consumer renders anyway).
-- ────────────────────────────────────────────────────────────────────────────

CREATE FUNCTION search_journal_entries(search_query text, target_user_id uuid)
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
    AND je.search_vector @@ plainto_tsquery('english', search_query)
  ORDER BY ts_rank(je.search_vector, plainto_tsquery('english', search_query)) DESC
  LIMIT 50;
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. B3 — table-backed likes. New journal_entry_likes table (adjudicated
--    name), unique (entry_id, user_id) via the primary key.
--    RLS:
--      * INSERT: own row AND the entry is currently readable by the caller —
--        the EXISTS runs under the caller's journal_entries RLS, which closes
--        the audit §1.2 note "can like entries they cannot read", and is
--        transitively correct once Task 2's resolved-visibility RLS lands.
--      * DELETE: own row, unconditional (you can always withdraw a like, even
--        if the entry has since become invisible to you).
--      * SELECT: rows are visible iff the underlying entry is visible (the
--        old journal_likes SELECT USING (true) let anyone enumerate likers).
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE journal_entry_likes (
  entry_id uuid NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entry_id, user_id)
);

CREATE INDEX idx_journal_entry_likes_user
  ON journal_entry_likes (user_id);

ALTER TABLE journal_entry_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "journal_entry_likes_select" ON journal_entry_likes
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM journal_entries je
      WHERE je.id = journal_entry_likes.entry_id
    )
  );

CREATE POLICY "journal_entry_likes_insert" ON journal_entry_likes
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1 FROM journal_entries je
      WHERE je.id = journal_entry_likes.entry_id
    )
  );

CREATE POLICY "journal_entry_likes_delete" ON journal_entry_likes
  FOR DELETE USING (auth.uid() = user_id);

GRANT SELECT, INSERT, DELETE ON journal_entry_likes TO authenticated;
GRANT ALL ON journal_entry_likes TO service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Move existing like rows, then replace journal_likes with a transitional
--    compatibility VIEW under the old name. The view keeps two readers alive:
--    (a) old deployed web bundles between apply and deploy, and
--    (b) services/reviewService.ts liked-state reads (:97, :163), which this
--        task does not touch (its cross-user selects are rewritten in Task 2;
--        migrate its journal_likes reads to journal_entry_likes there, then
--        drop this view in a later cleanup migration).
--    security_invoker => base-table RLS is evaluated as the querying user, so
--    the view leaks nothing the new table would not.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: DROP VIEW journal_likes; then recreate the previous table,
--   policies, and index verbatim (from supabase_journal_entries.sql:47-53,
--   77-78,82,97-105) and copy the rows back:
--
--   -- 2. Journal likes table
--   CREATE TABLE IF NOT EXISTS journal_likes (
--     entry_id uuid NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
--     user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
--     created_at timestamptz NOT NULL DEFAULT now(),
--     PRIMARY KEY (entry_id, user_id)
--   );
--
--   CREATE INDEX IF NOT EXISTS idx_journal_likes_user
--     ON journal_likes (user_id);
--
--   ALTER TABLE journal_likes ENABLE ROW LEVEL SECURITY;
--
--   -- journal_likes: owner insert/delete, all can SELECT
--   CREATE POLICY "journal_likes_select" ON journal_likes
--     FOR SELECT USING (true);
--
--   CREATE POLICY "journal_likes_insert" ON journal_likes
--     FOR INSERT WITH CHECK (auth.uid() = user_id);
--
--   CREATE POLICY "journal_likes_delete" ON journal_likes
--     FOR DELETE USING (auth.uid() = user_id);
--
--   INSERT INTO journal_likes (entry_id, user_id, created_at)
--   SELECT entry_id, user_id, created_at FROM journal_entry_likes
--   ON CONFLICT (entry_id, user_id) DO NOTHING;

INSERT INTO journal_entry_likes (entry_id, user_id, created_at)
SELECT entry_id, user_id, created_at
FROM journal_likes
ON CONFLICT (entry_id, user_id) DO NOTHING;

DROP TABLE journal_likes;

CREATE VIEW journal_likes
WITH (security_invoker = true) AS
  SELECT entry_id, user_id, created_at
  FROM journal_entry_likes;

COMMENT ON VIEW journal_likes IS
  'TRANSITIONAL compat alias for journal_entry_likes (C2 Task 1, 20260708). '
  'Kept for pre-deploy web bundles and reviewService.ts reads; drop after '
  'Task 2 migrates reviewService off the old name.';

GRANT SELECT, INSERT, DELETE ON journal_likes TO authenticated;
GRANT ALL ON journal_likes TO service_role;

-- ────────────────────────────────────────────────────────────────────────────
-- 6. B3 fix — counter choice: TRIGGER-MAINTAINED journal_entries.like_count,
--    per the audit's suggested fix ("replace both RPCs with triggers on
--    likes INSERT/DELETE — count derived from actual rows"). Chosen over a
--    view because:
--      (a) every reader consumes like_count as a physical column — the
--          select('*') paths in journalService/reviewService, the search RPC
--          above, and the shared-payloads row contract the iOS port mirrors;
--          a counting view would force rewriting all of them in this change;
--      (b) list reads stay O(1) on the hot path (no join/GROUP BY per page);
--      (c) with the definer RPCs dropped (§8), this trigger is the ONLY
--          writer of like_count, and it RECOUNTS rows instead of doing
--          arithmetic, so the counter can neither drift nor be manipulated.
--
--    SECURITY DEFINER justification (required comment per plan global
--    constraint): the liker is generally NOT the entry owner, and the
--    journal_entries UPDATE policy is owner-only — an invoker trigger would
--    silently update 0 rows (the same failure class the audit notes for
--    turn_count in D8). Hardened auth predicate, stated first: the function
--    accepts NO caller arguments and reads NOTHING caller-controlled — the
--    entry id comes only from a NEW/OLD row that journal_entry_likes RLS has
--    already admitted (own-row + entry-visible on INSERT, own-row on DELETE),
--    and the written value is count(*) of committed rows, never an increment
--    a caller could replay. search_path is pinned.
-- ────────────────────────────────────────────────────────────────────────────

CREATE FUNCTION sync_journal_entry_like_count()
RETURNS trigger AS $$
DECLARE
  target_entry uuid;
BEGIN
  target_entry := COALESCE(NEW.entry_id, OLD.entry_id);
  UPDATE journal_entries
  SET like_count = (
    SELECT count(*) FROM journal_entry_likes
    WHERE entry_id = target_entry
  )
  WHERE id = target_entry;
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION sync_journal_entry_like_count() FROM PUBLIC;

CREATE TRIGGER journal_entry_likes_sync_count
  AFTER INSERT OR DELETE ON journal_entry_likes
  FOR EACH ROW
  EXECUTE FUNCTION sync_journal_entry_like_count();

-- ────────────────────────────────────────────────────────────────────────────
-- 7. Reconcile like_count with reality — the drift, and the choice:
--    The old counters are known-drifted (audit B3): the definer RPCs were
--    callable unboundedly by anyone; the web toggle double-incremented in
--    normal use (upsert-hit still incremented, cards never loaded liked
--    state); decrements floored at 0; and rows migrated from movie_reviews
--    carried like_count values with NO corresponding like rows at all.
--    RECONCILIATION CHOICE: recount from journal_entry_likes rows — the only
--    option consistent with the adjudicated "counts derived" model. This
--    corrects inflated counts downward and zeroes legacy movie_reviews
--    counts whose likers were never recorded (accepted, documented loss:
--    those likes have no attributable rows to preserve, and keeping
--    unattributable counts would freeze the manipulation the fix removes).
--    The updated_at trigger is suspended so a bookkeeping recount does not
--    bump every entry's timestamp.
-- ────────────────────────────────────────────────────────────────────────────

ALTER TABLE journal_entries DISABLE TRIGGER journal_entries_updated_at;

UPDATE journal_entries je
SET like_count = (
  SELECT count(*) FROM journal_entry_likes jel
  WHERE jel.entry_id = je.id
)
WHERE je.like_count IS DISTINCT FROM (
  SELECT count(*) FROM journal_entry_likes jel
  WHERE jel.entry_id = je.id
);

ALTER TABLE journal_entries ENABLE TRIGGER journal_entries_updated_at;

-- ────────────────────────────────────────────────────────────────────────────
-- 8. B3 — drop the manipulation-prone counter RPCs (SECURITY DEFINER,
--    callable by any authenticated user with any entry id, unbounded, never
--    tied to a like row).
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: recreate the previous functions verbatim
--   (from supabase_journal_entries.sql:107-124):
--
--   -- 5. RPC: increment/decrement journal likes (atomic)
--   CREATE OR REPLACE FUNCTION increment_journal_likes(entry_id_param uuid)
--   RETURNS void AS $$
--   BEGIN
--     UPDATE journal_entries
--     SET like_count = like_count + 1
--     WHERE id = entry_id_param;
--   END;
--   $$ LANGUAGE plpgsql SECURITY DEFINER;
--
--   CREATE OR REPLACE FUNCTION decrement_journal_likes(entry_id_param uuid)
--   RETURNS void AS $$
--   BEGIN
--     UPDATE journal_entries
--     SET like_count = GREATEST(like_count - 1, 0)
--     WHERE id = entry_id_param;
--   END;
--   $$ LANGUAGE plpgsql SECURITY DEFINER;

DROP FUNCTION IF EXISTS increment_journal_likes(uuid);
DROP FUNCTION IF EXISTS decrement_journal_likes(uuid);
