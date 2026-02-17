-- PostgreSQL 15+
-- Marquee: unified media ranking schema

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TYPE media_type AS ENUM ('MOVIE', 'PLAY');
CREATE TYPE ranking_tier AS ENUM ('S', 'A', 'B', 'C', 'D');

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username citext NOT NULL UNIQUE,
  email citext NOT NULL UNIQUE,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_username_format CHECK (username ~ '^[a-zA-Z0-9_]{3,32}$')
);

CREATE TABLE media_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  media_type media_type NOT NULL,
  title text NOT NULL,
  release_year integer,
  tmdb_id bigint,
  attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_attributes_object CHECK (jsonb_typeof(attributes) = 'object'),
  CONSTRAINT chk_play_tmdb_null CHECK (media_type <> 'PLAY' OR tmdb_id IS NULL),
  CONSTRAINT chk_release_year CHECK (
    release_year IS NULL OR release_year BETWEEN 1800 AND 2200
  )
);

-- tmdb_id is unique only for MOVIE rows when present
CREATE UNIQUE INDEX uq_media_items_movie_tmdb_id
  ON media_items (tmdb_id)
  WHERE media_type = 'MOVIE' AND tmdb_id IS NOT NULL;

CREATE TABLE user_rankings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_item_id uuid NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  tier ranking_tier NOT NULL,
  rank_position double precision NOT NULL,
  visual_score numeric(3,1) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_media UNIQUE (user_id, media_item_id),
  CONSTRAINT uq_user_tier_rank_position UNIQUE (user_id, tier, rank_position),
  CONSTRAINT chk_rank_position_finite CHECK (
    isfinite(rank_position) AND rank_position = rank_position
  ),
  CONSTRAINT chk_visual_score_0_10 CHECK (visual_score >= 0.0 AND visual_score <= 10.0),
  CONSTRAINT chk_visual_score_by_tier CHECK (
    (tier = 'S' AND visual_score BETWEEN 9.0 AND 10.0) OR
    (tier = 'A' AND visual_score BETWEEN 8.0 AND 8.9) OR
    (tier = 'B' AND visual_score BETWEEN 7.0 AND 7.9) OR
    (tier = 'C' AND visual_score BETWEEN 6.0 AND 6.9) OR
    (tier = 'D' AND visual_score BETWEEN 0.0 AND 5.9)
  )
);

CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_media_items_updated_at
BEFORE UPDATE ON media_items
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_user_rankings_updated_at
BEFORE UPDATE ON user_rankings
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Indexing strategy

-- 1) Get User X ranked list sorted by Tier then Rank
CREATE INDEX idx_user_rankings_user_tier_rank
  ON user_rankings (user_id, tier, rank_position);

-- 2) Smart JSON filtering
CREATE INDEX idx_media_items_attributes_gin
  ON media_items
  USING gin (attributes jsonb_path_ops);

-- Optional fast path for exact ->> genre lookup form
CREATE INDEX idx_media_items_genre_btree
  ON media_items ((attributes ->> 'genre'));

-- Rebalance helper (when fractional gaps become too small)
CREATE OR REPLACE FUNCTION rebalance_tier_positions(p_user_id uuid, p_tier ranking_tier)
RETURNS void
LANGUAGE sql
AS $$
  WITH ordered AS (
    SELECT
      id,
      (row_number() OVER (ORDER BY rank_position, id) * 1000.0)::double precision AS new_pos
    FROM user_rankings
    WHERE user_id = p_user_id AND tier = p_tier
  )
  UPDATE user_rankings ur
  SET rank_position = o.new_pos,
      updated_at = now()
  FROM ordered o
  WHERE ur.id = o.id;
$$;

-- Insert between neighbors with fractional rank + interpolated visual score
CREATE OR REPLACE FUNCTION insert_ranking_between(
  p_user_id uuid,
  p_media_item_id uuid,
  p_tier ranking_tier,
  p_prev_ranking_id uuid DEFAULT NULL,
  p_next_ranking_id uuid DEFAULT NULL
)
RETURNS user_rankings
LANGUAGE plpgsql
AS $$
DECLARE
  v_prev user_rankings%ROWTYPE;
  v_next user_rankings%ROWTYPE;
  v_min_score numeric(3,1);
  v_max_score numeric(3,1);
  v_new_rank double precision;
  v_raw_score numeric;
  v_inserted user_rankings%ROWTYPE;
BEGIN
  IF p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL AND p_prev_ranking_id = p_next_ranking_id THEN
    RAISE EXCEPTION 'prev and next ranking ids must be different';
  END IF;

  SELECT
    CASE p_tier WHEN 'S' THEN 9.0 WHEN 'A' THEN 8.0 WHEN 'B' THEN 7.0 WHEN 'C' THEN 6.0 ELSE 0.0 END,
    CASE p_tier WHEN 'S' THEN 10.0 WHEN 'A' THEN 8.9 WHEN 'B' THEN 7.9 WHEN 'C' THEN 6.9 ELSE 5.9 END
  INTO v_min_score, v_max_score;

  IF p_prev_ranking_id IS NOT NULL THEN
    SELECT * INTO v_prev
    FROM user_rankings
    WHERE id = p_prev_ranking_id AND user_id = p_user_id AND tier = p_tier
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'prev ranking % not found for user/tier', p_prev_ranking_id;
    END IF;
  END IF;

  IF p_next_ranking_id IS NOT NULL THEN
    SELECT * INTO v_next
    FROM user_rankings
    WHERE id = p_next_ranking_id AND user_id = p_user_id AND tier = p_tier
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'next ranking % not found for user/tier', p_next_ranking_id;
    END IF;
  END IF;

  IF p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL THEN
    IF v_prev.rank_position >= v_next.rank_position THEN
      RAISE EXCEPTION 'prev.rank_position must be < next.rank_position';
    END IF;

    IF (v_next.rank_position - v_prev.rank_position) < 1e-9 THEN
      PERFORM rebalance_tier_positions(p_user_id, p_tier);

      SELECT * INTO v_prev
      FROM user_rankings
      WHERE id = p_prev_ranking_id
      FOR UPDATE;

      SELECT * INTO v_next
      FROM user_rankings
      WHERE id = p_next_ranking_id
      FOR UPDATE;
    END IF;
  END IF;

  v_new_rank :=
    CASE
      WHEN p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL THEN (v_prev.rank_position + v_next.rank_position) / 2.0
      WHEN p_prev_ranking_id IS NOT NULL THEN v_prev.rank_position + 1000.0
      WHEN p_next_ranking_id IS NOT NULL THEN v_next.rank_position - 1000.0
      ELSE 1000.0
    END;

  v_raw_score :=
    CASE
      WHEN p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL THEN (v_prev.visual_score + v_next.visual_score) / 2.0
      WHEN p_prev_ranking_id IS NOT NULL THEN (v_prev.visual_score + v_min_score) / 2.0
      WHEN p_next_ranking_id IS NOT NULL THEN (v_max_score + v_next.visual_score) / 2.0
      ELSE (v_min_score + v_max_score) / 2.0
    END;

  v_raw_score := LEAST(v_max_score::numeric, GREATEST(v_min_score::numeric, v_raw_score));

  INSERT INTO user_rankings (user_id, media_item_id, tier, rank_position, visual_score)
  VALUES (p_user_id, p_media_item_id, p_tier, v_new_rank, round(v_raw_score, 1))
  RETURNING * INTO v_inserted;

  RETURN v_inserted;
END;
$$;

-- Scenario math (A-tier insertion between 1000.0 and 2000.0):
-- new_rank_position = (1000.0 + 2000.0) / 2 = 1500.0
-- if neighbor scores are 8.8 and 8.2, new_visual_score = round((8.8 + 8.2) / 2, 1) = 8.5

-- Seed data

INSERT INTO users (id, username, email, password_hash)
VALUES
('11111111-1111-1111-1111-111111111111', 'marquee_admin', 'admin@marquee.app', '$2b$12$examplehashvalue');

INSERT INTO media_items (id, media_type, title, release_year, tmdb_id, attributes, created_by_user_id)
VALUES
(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
  'MOVIE',
  'Dune: Part Two',
  2024,
  693134,
  '{
    "director": "Denis Villeneuve",
    "cast": ["Timothee Chalamet", "Zendaya", "Rebecca Ferguson"],
    "genres": ["Science Fiction", "Adventure", "Drama"],
    "genre": "Science Fiction",
    "runtime_minutes": 166,
    "release_date": "2024-03-01",
    "language": "en",
    "source": "tmdb"
  }'::jsonb,
  '11111111-1111-1111-1111-111111111111'
),
(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',
  'MOVIE',
  'Barbie',
  2023,
  346698,
  '{
    "director": "Greta Gerwig",
    "cast": ["Margot Robbie", "Ryan Gosling", "America Ferrera"],
    "genres": ["Comedy", "Fantasy", "Adventure"],
    "genre": "Comedy",
    "runtime_minutes": 114,
    "release_date": "2023-07-21",
    "language": "en",
    "source": "tmdb"
  }'::jsonb,
  '11111111-1111-1111-1111-111111111111'
),
(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3',
  'MOVIE',
  'The Godfather',
  1972,
  238,
  '{
    "director": "Francis Ford Coppola",
    "cast": ["Marlon Brando", "Al Pacino", "James Caan"],
    "genres": ["Crime", "Drama"],
    "genre": "Crime",
    "runtime_minutes": 175,
    "release_date": "1972-03-24",
    "language": "en",
    "source": "tmdb"
  }'::jsonb,
  '11111111-1111-1111-1111-111111111111'
),
(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1',
  'PLAY',
  'Hamilton',
  2015,
  NULL,
  '{
    "creator": "Lin-Manuel Miranda",
    "cast": ["Lin-Manuel Miranda", "Leslie Odom Jr.", "Phillipa Soo"],
    "genres": ["Musical", "Historical", "Drama"],
    "genre": "Musical",
    "runtime_minutes": 160,
    "premiere_date": "2015-08-06",
    "venue": "Richard Rodgers Theatre",
    "source": "manual"
  }'::jsonb,
  '11111111-1111-1111-1111-111111111111'
);

INSERT INTO user_rankings (id, user_id, media_item_id, tier, rank_position, visual_score)
VALUES
('cccccccc-cccc-cccc-cccc-ccccccccccc1', '11111111-1111-1111-1111-111111111111', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1', 'S', 1000.0, 9.8),
('cccccccc-cccc-cccc-cccc-ccccccccccc2', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa3', 'A', 1000.0, 8.8),
('cccccccc-cccc-cccc-cccc-ccccccccccc3', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1', 'A', 2000.0, 8.2),
('cccccccc-cccc-cccc-cccc-ccccccccccc4', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2', 'C', 1000.0, 6.4);
