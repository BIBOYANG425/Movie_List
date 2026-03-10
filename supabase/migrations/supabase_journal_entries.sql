-- ============================================================
-- Journal Entries Migration
-- Replaces movie_reviews with a rich personal film diary
-- ============================================================

-- Helper: immutable wrapper for array_to_string (needed for generated column)
CREATE OR REPLACE FUNCTION immutable_array_to_string(arr text[], sep text)
RETURNS text AS $$
  SELECT array_to_string(arr, sep);
$$ LANGUAGE sql IMMUTABLE;

-- 1. Core table: journal_entries
CREATE TABLE IF NOT EXISTS journal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  poster_url text,
  rating_tier text CHECK (rating_tier IN ('S', 'A', 'B', 'C', 'D')),
  review_text text,
  contains_spoilers boolean NOT NULL DEFAULT false,
  mood_tags text[] DEFAULT '{}',
  vibe_tags text[] DEFAULT '{}',
  favorite_moments text[] DEFAULT '{}',
  standout_performances jsonb DEFAULT '[]'::jsonb,
  watched_date date DEFAULT CURRENT_DATE,
  watched_location text,
  watched_with_user_ids uuid[] DEFAULT '{}',
  watched_platform text,
  is_rewatch boolean NOT NULL DEFAULT false,
  rewatch_note text,
  personal_takeaway text,
  photo_paths text[] DEFAULT '{}',
  visibility_override text CHECK (visibility_override IN ('public', 'friends', 'private')),
  like_count integer NOT NULL DEFAULT 0,
  search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(review_text, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(immutable_array_to_string(favorite_moments, ' '), '')), 'C') ||
    setweight(to_tsvector('english', coalesce(personal_takeaway, '')), 'D')
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, tmdb_id)
);

-- 2. Journal likes table
CREATE TABLE IF NOT EXISTS journal_likes (
  entry_id uuid NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entry_id, user_id)
);

-- 3. Indexes
CREATE INDEX IF NOT EXISTS idx_journal_entries_user_created
  ON journal_entries (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_journal_entries_tmdb_id
  ON journal_entries (tmdb_id);

CREATE INDEX IF NOT EXISTS idx_journal_entries_search_vector
  ON journal_entries USING GIN (search_vector);

CREATE INDEX IF NOT EXISTS idx_journal_entries_mood_tags
  ON journal_entries USING GIN (mood_tags);

CREATE INDEX IF NOT EXISTS idx_journal_entries_vibe_tags
  ON journal_entries USING GIN (vibe_tags);

CREATE INDEX IF NOT EXISTS idx_journal_entries_tier
  ON journal_entries (rating_tier);

CREATE INDEX IF NOT EXISTS idx_journal_entries_platform
  ON journal_entries (watched_platform);

CREATE INDEX IF NOT EXISTS idx_journal_likes_user
  ON journal_likes (user_id);

-- 4. RLS
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_likes ENABLE ROW LEVEL SECURITY;

-- journal_entries: owner full CRUD, others can SELECT
CREATE POLICY "journal_entries_select" ON journal_entries
  FOR SELECT USING (true);

CREATE POLICY "journal_entries_insert" ON journal_entries
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "journal_entries_update" ON journal_entries
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "journal_entries_delete" ON journal_entries
  FOR DELETE USING (auth.uid() = user_id);

-- journal_likes: owner insert/delete, all can SELECT
CREATE POLICY "journal_likes_select" ON journal_likes
  FOR SELECT USING (true);

CREATE POLICY "journal_likes_insert" ON journal_likes
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "journal_likes_delete" ON journal_likes
  FOR DELETE USING (auth.uid() = user_id);

-- 5. RPC: increment/decrement journal likes (atomic)
CREATE OR REPLACE FUNCTION increment_journal_likes(entry_id_param uuid)
RETURNS void AS $$
BEGIN
  UPDATE journal_entries
  SET like_count = like_count + 1
  WHERE id = entry_id_param;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION decrement_journal_likes(entry_id_param uuid)
RETURNS void AS $$
BEGIN
  UPDATE journal_entries
  SET like_count = GREATEST(like_count - 1, 0)
  WHERE id = entry_id_param;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. RPC: full-text search journal entries
CREATE OR REPLACE FUNCTION search_journal_entries(search_query text, target_user_id uuid)
RETURNS SETOF journal_entries AS $$
BEGIN
  RETURN QUERY
  SELECT *
  FROM journal_entries
  WHERE user_id = target_user_id
    AND search_vector @@ plainto_tsquery('english', search_query)
  ORDER BY ts_rank(search_vector, plainto_tsquery('english', search_query)) DESC
  LIMIT 50;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 7. Data migration: copy existing movie_reviews into journal_entries
INSERT INTO journal_entries (user_id, tmdb_id, title, poster_url, rating_tier, review_text, contains_spoilers, like_count, created_at, updated_at)
SELECT
  mr.user_id,
  mr.tmdb_id,
  mr.title,
  mr.poster_url,
  mr.rating_tier,
  mr.body,
  mr.contains_spoilers,
  mr.like_count,
  mr.created_at,
  mr.updated_at
FROM movie_reviews mr
ON CONFLICT (user_id, tmdb_id) DO NOTHING;

-- 8. Updated_at trigger
CREATE OR REPLACE FUNCTION update_journal_entries_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER journal_entries_updated_at
  BEFORE UPDATE ON journal_entries
  FOR EACH ROW
  EXECUTE FUNCTION update_journal_entries_updated_at();

-- 9. Storage bucket for journal photos
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('journal-photos', 'journal-photos', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Storage policies for journal-photos bucket
CREATE POLICY "journal_photos_select" ON storage.objects
  FOR SELECT USING (bucket_id = 'journal-photos');

CREATE POLICY "journal_photos_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'journal-photos' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "journal_photos_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'journal-photos' AND auth.uid()::text = (storage.foldername(name))[1]);
