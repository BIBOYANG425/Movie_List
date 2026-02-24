-- Spool Adaptive Ranking System — Database Migration
-- Run this against your Supabase project after deploying the code changes.

-- 1. Add bracket column to user_rankings
ALTER TABLE user_rankings
  ADD COLUMN IF NOT EXISTS bracket text DEFAULT 'Commercial';

-- 2. Comparison log for analytics and algo training
CREATE TABLE IF NOT EXISTS comparison_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  movie_a_tmdb_id text NOT NULL,
  movie_b_tmdb_id text NOT NULL,
  winner text NOT NULL CHECK (winner IN ('a','b','skip')),
  round integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comp_logs_user ON comparison_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_comp_logs_session ON comparison_logs(session_id);

-- 3. RLS for comparison_logs
ALTER TABLE comparison_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own comparison logs" ON comparison_logs
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own comparison logs" ON comparison_logs
  FOR INSERT WITH CHECK (auth.uid() = user_id);
