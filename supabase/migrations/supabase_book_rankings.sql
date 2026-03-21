-- Book Rankings & Watchlist Tables
-- Phase: Book support (separate tables from movie/TV rankings)

-- ── book_rankings ─────────────────────────────────────────────────────────────

CREATE TABLE book_rankings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,             -- "ol_{workKey}" e.g. "ol_OL27448W"
  title text NOT NULL,
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'book',
  genres text[] NOT NULL DEFAULT '{}',
  author text,
  tier text NOT NULL CHECK (tier IN ('S','A','B','C','D')),
  rank_position integer NOT NULL,
  notes text,
  bracket text DEFAULT 'Commercial',
  primary_genre text,
  page_count integer,
  isbn text,
  ol_work_key text,
  ol_ratings_average real,
  watched_with_user_ids uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, tmdb_id)
);

-- Indexes
CREATE INDEX idx_book_rankings_user_tier ON book_rankings(user_id, tier);
CREATE INDEX idx_book_rankings_watched_with ON book_rankings USING gin(watched_with_user_ids);

-- RLS
ALTER TABLE book_rankings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own book rankings"
  ON book_rankings FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view followed users book rankings"
  ON book_rankings FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = book_rankings.user_id
    )
  );

CREATE POLICY "Users can insert own book rankings"
  ON book_rankings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own book rankings"
  ON book_rankings FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own book rankings"
  ON book_rankings FOR DELETE
  USING (auth.uid() = user_id);

-- ── book_watchlist_items ──────────────────────────────────────────────────────

CREATE TABLE book_watchlist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'book',
  genres text[] NOT NULL DEFAULT '{}',
  author text,
  page_count integer,
  isbn text,
  ol_work_key text,
  ol_ratings_average real,
  added_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, tmdb_id)
);

-- Indexes
CREATE INDEX idx_book_watchlist_user ON book_watchlist_items(user_id);

-- RLS
ALTER TABLE book_watchlist_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own book watchlist"
  ON book_watchlist_items FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view followed users book watchlist"
  ON book_watchlist_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = book_watchlist_items.user_id
    )
  );

CREATE POLICY "Users can insert own book watchlist items"
  ON book_watchlist_items FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own book watchlist items"
  ON book_watchlist_items FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own book watchlist items"
  ON book_watchlist_items FOR DELETE
  USING (auth.uid() = user_id);
