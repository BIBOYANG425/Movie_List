-- SPOOL Genre-Anchored Ranking — Database Migration
-- Adds primary_genre support, prediction logging, and enhanced comparison logging.
-- Run against your Supabase project after deploying code changes.

-- 1. Add primary_genre column to user_rankings
ALTER TABLE user_rankings
  ADD COLUMN IF NOT EXISTS primary_genre text;

-- Backfill existing rows: use first element of genres array
UPDATE user_rankings
  SET primary_genre = genres[1]
  WHERE primary_genre IS NULL AND array_length(genres, 1) > 0;

-- 2. Index for genre-anchored queries
CREATE INDEX IF NOT EXISTS idx_rankings_user_tier_genre
  ON user_rankings(user_id, tier, primary_genre);

-- 3. Enhanced comparison logging
ALTER TABLE comparison_logs
  ADD COLUMN IF NOT EXISTS phase text;

ALTER TABLE comparison_logs
  ADD COLUMN IF NOT EXISTS question_text text;

-- 4. Prediction logs table
CREATE TABLE IF NOT EXISTS prediction_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  ranking_id uuid REFERENCES user_rankings(id) ON DELETE CASCADE,
  predicted_score float NOT NULL,
  final_score float NOT NULL,
  prediction_error float NOT NULL,
  signal_weights jsonb NOT NULL DEFAULT '{}',
  feature_contributions jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_prediction_logs_ranking
  ON prediction_logs(ranking_id);

CREATE INDEX IF NOT EXISTS idx_prediction_logs_user
  ON prediction_logs(user_id, created_at DESC);

-- 5. RLS for prediction_logs
ALTER TABLE prediction_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own prediction logs" ON prediction_logs;
CREATE POLICY "Users can view own prediction logs" ON prediction_logs
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own prediction logs" ON prediction_logs;
CREATE POLICY "Users can insert own prediction logs" ON prediction_logs
  FOR INSERT WITH CHECK (auth.uid() = user_id);
