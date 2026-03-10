-- =============================================================
-- Smart Suggestions Foundation: Taste Engine Tables, RPC, Trigger
-- =============================================================

-- 1. movie_credits_cache — shared TMDB credits cache
CREATE TABLE IF NOT EXISTS movie_credits_cache (
  tmdb_id      integer PRIMARY KEY,
  directors    jsonb   NOT NULL DEFAULT '[]',
  top_cast     jsonb   NOT NULL DEFAULT '[]',
  genres       text[]  NOT NULL DEFAULT '{}',
  runtime      integer,
  release_year integer,
  fetched_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_movie_credits_cache_fetched_at
  ON movie_credits_cache(fetched_at);

ALTER TABLE movie_credits_cache ENABLE ROW LEVEL SECURITY;

-- Anyone can read the cache
CREATE POLICY "movie_credits_cache_select"
  ON movie_credits_cache FOR SELECT
  USING (true);

-- Authenticated users can insert
CREATE POLICY "movie_credits_cache_insert"
  ON movie_credits_cache FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- Authenticated users can update
CREATE POLICY "movie_credits_cache_update"
  ON movie_credits_cache FOR UPDATE
  TO authenticated
  USING (true)
  WITH CHECK (true);


-- 2. user_taste_profiles — one row per user, recomputed on ranking changes
CREATE TABLE IF NOT EXISTS user_taste_profiles (
  user_id            uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  weighted_genres    jsonb   NOT NULL DEFAULT '{}',
  top_directors      jsonb   NOT NULL DEFAULT '[]',
  top_actors         jsonb   NOT NULL DEFAULT '[]',
  decade_distribution jsonb  NOT NULL DEFAULT '{}',
  avg_runtime        integer,
  underexposed_genres text[] NOT NULL DEFAULT '{}',
  top_movie_ids      integer[] NOT NULL DEFAULT '{}',
  total_ranked       integer NOT NULL DEFAULT 0,
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_taste_profiles_updated_at
  ON user_taste_profiles(updated_at);

ALTER TABLE user_taste_profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own taste profile
CREATE POLICY "user_taste_profiles_select_own"
  ON user_taste_profiles FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Users can read friends' taste profiles (mutual follow not required, just following)
CREATE POLICY "user_taste_profiles_select_friends"
  ON user_taste_profiles FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid()
        AND following_id = user_taste_profiles.user_id
    )
  );

-- Users can insert their own taste profile
CREATE POLICY "user_taste_profiles_insert_own"
  ON user_taste_profiles FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can update their own taste profile
CREATE POLICY "user_taste_profiles_update_own"
  ON user_taste_profiles FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Users can delete their own taste profile
CREATE POLICY "user_taste_profiles_delete_own"
  ON user_taste_profiles FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());


-- 3. RPC function: recompute_taste_profile
--    Recomputes a user's taste profile from their rankings + credits cache.
--    Uses SECURITY DEFINER so the trigger can call it for any user.
CREATE OR REPLACE FUNCTION recompute_taste_profile(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total        integer;
  v_genres       jsonb := '{}';
  v_directors    jsonb := '{}';
  v_actors       jsonb := '{}';
  v_decades      jsonb := '{}';
  v_avg_runtime  integer;
  v_underexposed text[];
  v_top_ids      integer[];
  v_tier_weight  integer;
  rec            record;

  -- Full TMDB genre list for underexposed calculation
  all_genres     text[] := ARRAY[
    'Action','Adventure','Animation','Comedy','Crime','Documentary',
    'Drama','Family','Fantasy','History','Horror','Music','Mystery',
    'Romance','Sci-Fi','TV Movie','Thriller','War','Western'
  ];
  g              text;
  ranked_genres  text[];
BEGIN
  -- Count total rankings
  SELECT count(*)::integer INTO v_total
  FROM user_rankings
  WHERE user_id = target_user_id;

  -- If no rankings, delete taste profile and return
  IF v_total = 0 THEN
    DELETE FROM user_taste_profiles WHERE user_id = target_user_id;
    RETURN;
  END IF;

  -- Iterate over each ranking joined with credits cache
  FOR rec IN
    SELECT
      ur.tier,
      ur.tmdb_id AS raw_tmdb_id,
      replace(ur.tmdb_id, 'tmdb_', '')::int AS numeric_tmdb_id,
      mcc.directors AS credit_directors,
      mcc.top_cast AS credit_cast,
      mcc.genres AS credit_genres,
      mcc.runtime AS credit_runtime,
      mcc.release_year AS credit_year
    FROM user_rankings ur
    LEFT JOIN movie_credits_cache mcc
      ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
    WHERE ur.user_id = target_user_id
  LOOP
    -- Determine tier weight
    v_tier_weight := CASE rec.tier
      WHEN 'S' THEN 5
      WHEN 'A' THEN 4
      WHEN 'B' THEN 3
      WHEN 'C' THEN 2
      WHEN 'D' THEN 1
      ELSE 1
    END;

    -- Accumulate genre scores (from credits cache if available)
    IF rec.credit_genres IS NOT NULL THEN
      FOREACH g IN ARRAY rec.credit_genres LOOP
        v_genres := jsonb_set(
          v_genres,
          ARRAY[g],
          to_jsonb(COALESCE((v_genres->>g)::integer, 0) + v_tier_weight)
        );
      END LOOP;
    END IF;

    -- Accumulate director scores from credits cache
    IF rec.credit_directors IS NOT NULL AND jsonb_array_length(rec.credit_directors) > 0 THEN
      FOR i IN 0..jsonb_array_length(rec.credit_directors) - 1 LOOP
        DECLARE
          director_name text := rec.credit_directors->>i;
        BEGIN
          v_directors := jsonb_set(
            v_directors,
            ARRAY[director_name],
            to_jsonb(COALESCE((v_directors->>director_name)::integer, 0) + v_tier_weight)
          );
        END;
      END LOOP;
    END IF;

    -- Accumulate actor scores from credits cache
    IF rec.credit_cast IS NOT NULL AND jsonb_array_length(rec.credit_cast) > 0 THEN
      FOR i IN 0..jsonb_array_length(rec.credit_cast) - 1 LOOP
        DECLARE
          actor_name text := rec.credit_cast->>i;
        BEGIN
          v_actors := jsonb_set(
            v_actors,
            ARRAY[actor_name],
            to_jsonb(COALESCE((v_actors->>actor_name)::integer, 0) + v_tier_weight)
          );
        END;
      END LOOP;
    END IF;

    -- Accumulate decade distribution
    IF rec.credit_year IS NOT NULL THEN
      DECLARE
        decade text := ((rec.credit_year / 10) * 10)::text || 's';
      BEGIN
        v_decades := jsonb_set(
          v_decades,
          ARRAY[decade],
          to_jsonb(COALESCE((v_decades->>decade)::integer, 0) + 1)
        );
      END;
    END IF;
  END LOOP;

  -- Compute average runtime from credits cache
  SELECT avg(mcc.runtime)::integer INTO v_avg_runtime
  FROM user_rankings ur
  JOIN movie_credits_cache mcc
    ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
  WHERE ur.user_id = target_user_id
    AND mcc.runtime IS NOT NULL;

  -- Identify underexposed genres: all TMDB genres minus those with >= 2 ranked movies
  ranked_genres := ARRAY(
    SELECT g2
    FROM (
      SELECT unnest(mcc.genres) AS g2, count(*) AS cnt
      FROM user_rankings ur
      JOIN movie_credits_cache mcc
        ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
      WHERE ur.user_id = target_user_id
      GROUP BY g2
      HAVING count(*) >= 2
    ) sub
  );
  v_underexposed := ARRAY(
    SELECT unnest(all_genres)
    EXCEPT
    SELECT unnest(ranked_genres)
  );

  -- Collect S and A tier tmdb_ids
  v_top_ids := ARRAY(
    SELECT replace(ur.tmdb_id, 'tmdb_', '')::int
    FROM user_rankings ur
    WHERE ur.user_id = target_user_id
      AND ur.tier IN ('S', 'A')
    ORDER BY ur.rank_position
  );

  -- Sort directors: take top entries by score descending
  v_directors := (
    SELECT coalesce(jsonb_agg(jsonb_build_object('name', kv.key, 'score', kv.value::int) ORDER BY kv.value::int DESC), '[]'::jsonb)
    FROM jsonb_each_text(v_directors) kv
  );

  -- Sort actors: take top entries by score descending
  v_actors := (
    SELECT coalesce(jsonb_agg(jsonb_build_object('name', kv.key, 'score', kv.value::int) ORDER BY kv.value::int DESC), '[]'::jsonb)
    FROM jsonb_each_text(v_actors) kv
  );

  -- Upsert into user_taste_profiles
  INSERT INTO user_taste_profiles (
    user_id, weighted_genres, top_directors, top_actors,
    decade_distribution, avg_runtime, underexposed_genres,
    top_movie_ids, total_ranked, updated_at
  ) VALUES (
    target_user_id, v_genres, v_directors, v_actors,
    v_decades, v_avg_runtime, v_underexposed,
    v_top_ids, v_total, now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    weighted_genres     = EXCLUDED.weighted_genres,
    top_directors       = EXCLUDED.top_directors,
    top_actors          = EXCLUDED.top_actors,
    decade_distribution = EXCLUDED.decade_distribution,
    avg_runtime         = EXCLUDED.avg_runtime,
    underexposed_genres = EXCLUDED.underexposed_genres,
    top_movie_ids       = EXCLUDED.top_movie_ids,
    total_ranked        = EXCLUDED.total_ranked,
    updated_at          = EXCLUDED.updated_at;
END;
$$;


-- 4. Trigger function: fires after INSERT/UPDATE/DELETE on user_rankings
CREATE OR REPLACE FUNCTION trigger_recompute_taste()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  affected_user_id uuid;
BEGIN
  -- Determine which user was affected
  IF TG_OP = 'DELETE' THEN
    affected_user_id := OLD.user_id;
  ELSE
    affected_user_id := NEW.user_id;
  END IF;

  PERFORM recompute_taste_profile(affected_user_id);
  RETURN NULL;
END;
$$;

-- Create the trigger on user_rankings
DROP TRIGGER IF EXISTS trg_recompute_taste ON user_rankings;
CREATE TRIGGER trg_recompute_taste
  AFTER INSERT OR UPDATE OR DELETE ON user_rankings
  FOR EACH ROW
  EXECUTE FUNCTION trigger_recompute_taste();
