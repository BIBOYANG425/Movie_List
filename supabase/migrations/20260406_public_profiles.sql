-- Add profile_visibility column to profiles table
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS profile_visibility text NOT NULL DEFAULT 'friends'
  CHECK (profile_visibility IN ('public', 'friends', 'private'));

-- Allow anyone to read rankings of users with public profiles
CREATE POLICY "Public profile rankings are readable"
  ON user_rankings FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = user_rankings.user_id
        AND profiles.profile_visibility = 'public'
    )
  );

CREATE POLICY "Public profile TV rankings are readable"
  ON tv_rankings FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = tv_rankings.user_id
        AND profiles.profile_visibility = 'public'
    )
  );

CREATE POLICY "Public profile book rankings are readable"
  ON book_rankings FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = book_rankings.user_id
        AND profiles.profile_visibility = 'public'
    )
  );

-- Index for fast lookup by username (for /u/:username route)
CREATE INDEX IF NOT EXISTS idx_profiles_username ON profiles (username);

-- Index to speed up the RLS subquery
CREATE INDEX IF NOT EXISTS idx_profiles_visibility ON profiles (id, profile_visibility);
