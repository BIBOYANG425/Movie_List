-- ============================================================
-- Ticket Stubs (票根) Migration
-- Visual ticket stub artifacts for ranked movies and TV seasons
-- ============================================================

CREATE TABLE IF NOT EXISTS movie_stubs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  -- Media reference
  media_type text NOT NULL CHECK (media_type IN ('movie', 'tv_season')),
  tmdb_id text NOT NULL,
  title text NOT NULL,
  poster_path text,

  -- Ranking data
  tier text NOT NULL CHECK (tier IN ('S', 'A', 'B', 'C', 'D')),

  -- Date
  watched_date date NOT NULL DEFAULT CURRENT_DATE,

  -- Stub content (AI enrichment fields — populated later)
  mood_tags text[] DEFAULT '{}',
  stub_line text,
  is_ai_enriched boolean NOT NULL DEFAULT false,

  -- Visual
  palette text[] NOT NULL DEFAULT '{}',
  template_id text NOT NULL DEFAULT 'default',

  -- Social
  shared_externally boolean NOT NULL DEFAULT false,

  -- Journal link
  journal_entry_id uuid,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- One stub per media item per user
  UNIQUE(user_id, media_type, tmdb_id)
);

-- Indexes for calendar queries
CREATE INDEX idx_stubs_user_date ON movie_stubs(user_id, watched_date);
CREATE INDEX idx_stubs_calendar ON movie_stubs(user_id, watched_date DESC);

-- RLS: stubs are PUBLIC (calendar is a public profile feature)
ALTER TABLE movie_stubs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Stubs are publicly readable"
  ON movie_stubs FOR SELECT USING (true);

CREATE POLICY "Users can insert own stubs"
  ON movie_stubs FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own stubs"
  ON movie_stubs FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own stubs"
  ON movie_stubs FOR DELETE USING (auth.uid() = user_id);
