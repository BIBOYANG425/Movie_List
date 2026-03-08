-- TV Rankings & Watchlist Tables
-- Phase 1: Core TV support (separate tables from movie rankings)

-- ── tv_rankings ─────────────────────────────────────────────────────────────

CREATE TABLE tv_rankings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,             -- "tv_{showId}_s{seasonNum}"
  show_tmdb_id integer NOT NULL,
  season_number integer NOT NULL,
  title text NOT NULL,               -- show name
  season_title text,                 -- "Season 1" or custom name
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'tv_season',
  genres text[] NOT NULL DEFAULT '{}',
  creator text,
  tier text NOT NULL CHECK (tier IN ('S','A','B','C','D')),
  rank_position integer NOT NULL,
  notes text,
  bracket text DEFAULT 'Commercial',
  primary_genre text,
  episode_count integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, tmdb_id)
);

-- Indexes
CREATE INDEX idx_tv_rankings_user_tier ON tv_rankings(user_id, tier);
CREATE INDEX idx_tv_rankings_user_show ON tv_rankings(user_id, show_tmdb_id);

-- RLS
ALTER TABLE tv_rankings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own tv rankings"
  ON tv_rankings FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view followed users tv rankings"
  ON tv_rankings FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = tv_rankings.user_id
    )
  );

CREATE POLICY "Users can insert own tv rankings"
  ON tv_rankings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own tv rankings"
  ON tv_rankings FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own tv rankings"
  ON tv_rankings FOR DELETE
  USING (auth.uid() = user_id);

-- ── tv_watchlist_items ──────────────────────────────────────────────────────

CREATE TABLE tv_watchlist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,
  show_tmdb_id integer NOT NULL,
  season_number integer,             -- NULL = whole show bookmark
  title text NOT NULL,
  season_title text,
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'tv_season',
  genres text[] NOT NULL DEFAULT '{}',
  creator text,
  added_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, tmdb_id)
);

-- Indexes
CREATE INDEX idx_tv_watchlist_user ON tv_watchlist_items(user_id);

-- RLS
ALTER TABLE tv_watchlist_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own tv watchlist"
  ON tv_watchlist_items FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view followed users tv watchlist"
  ON tv_watchlist_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = tv_watchlist_items.user_id
    )
  );

CREATE POLICY "Users can insert own tv watchlist items"
  ON tv_watchlist_items FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own tv watchlist items"
  ON tv_watchlist_items FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own tv watchlist items"
  ON tv_watchlist_items FOR DELETE
  USING (auth.uid() = user_id);
