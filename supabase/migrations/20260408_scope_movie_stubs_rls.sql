-- ============================================================
-- Scope movie_stubs SELECT policy
-- The original policy (20260325_movie_stubs.sql) used USING (true),
-- which exposed every user's watch history to any authenticated client.
-- This migration replaces it with a scoped policy that only allows
-- reads from the owner OR users whose profile_visibility is 'public'.
-- ============================================================

DROP POLICY IF EXISTS "Stubs are publicly readable" ON movie_stubs;

CREATE POLICY "Stubs visible to owner or public profiles"
  ON movie_stubs FOR SELECT USING (
    auth.uid() = user_id
    OR EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = movie_stubs.user_id
        AND profiles.profile_visibility = 'public'
    )
  );
