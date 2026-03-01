-- ============================================================
-- Journal Agent + Training Data Architecture — Database Migration
-- Layers 1-5: Consent, Agent Sessions, Messages, Generations,
--             Corrections, Emotional Patterns, Training Examples
--
-- Tables (in dependency order):
--   1. user_data_consent       (Layer 0 — consent gate)
--   2. agent_sessions          (Layer 1 — conversation sessions)
--   3. agent_messages          (Layer 2 — append-only message log)
--   4. agent_generations       (Layer 3 — LLM outputs with per-field columns)
--   5. user_corrections        (Layer 3 — gold correction data)
--   6. emotional_patterns      (Layer 4 — anonymized, service_role only)
--   7. training_examples       (Layer 5 — training pipeline, service_role only)
--
-- Run against your Supabase project after deploying code changes.
-- ============================================================

-- ============================================================
-- 1. user_data_consent
-- ============================================================
CREATE TABLE IF NOT EXISTS user_data_consent (
  user_id uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  consent_product_improvement boolean NOT NULL DEFAULT true,
  consent_anonymized_research boolean NOT NULL DEFAULT false,
  consent_voice_storage boolean NOT NULL DEFAULT false,
  consent_version int NOT NULL DEFAULT 1,
  consented_at timestamptz,
  last_updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- updated_at trigger for user_data_consent
CREATE OR REPLACE FUNCTION update_user_data_consent_last_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.last_updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS user_data_consent_last_updated_at ON user_data_consent;
CREATE TRIGGER user_data_consent_last_updated_at
  BEFORE UPDATE ON user_data_consent
  FOR EACH ROW
  EXECUTE FUNCTION update_user_data_consent_last_updated_at();

-- RLS
ALTER TABLE user_data_consent ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own consent" ON user_data_consent;
CREATE POLICY "Users can view own consent" ON user_data_consent
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own consent" ON user_data_consent;
CREATE POLICY "Users can insert own consent" ON user_data_consent
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own consent" ON user_data_consent;
CREATE POLICY "Users can update own consent" ON user_data_consent
  FOR UPDATE USING (auth.uid() = user_id);

-- No DELETE policy (audit trail)

-- ============================================================
-- 2. agent_sessions
-- ============================================================
CREATE TABLE IF NOT EXISTS agent_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  movie_tmdb_id text,
  ranking_id uuid REFERENCES user_rankings(id) ON DELETE SET NULL,
  context_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  model_version text NOT NULL DEFAULT 'kimi-2.5',
  prompt_version text NOT NULL,
  completion_status text NOT NULL DEFAULT 'in_progress'
    CHECK (completion_status IN ('in_progress','completed','abandoned','error')),
  turn_count int NOT NULL DEFAULT 0,
  input_modality text NOT NULL DEFAULT 'text'
    CHECK (input_modality IN ('text','voice')),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_agent_sessions_user_created
  ON agent_sessions(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_agent_sessions_status
  ON agent_sessions(completion_status);

-- RLS
ALTER TABLE agent_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own agent sessions" ON agent_sessions;
CREATE POLICY "Users can view own agent sessions" ON agent_sessions
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own agent sessions" ON agent_sessions;
CREATE POLICY "Users can insert own agent sessions" ON agent_sessions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own agent sessions" ON agent_sessions;
CREATE POLICY "Users can update own agent sessions" ON agent_sessions
  FOR UPDATE USING (auth.uid() = user_id);

-- No DELETE policy

-- ============================================================
-- 3. agent_messages
-- ============================================================
CREATE TABLE IF NOT EXISTS agent_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  sequence_number int NOT NULL,
  role text NOT NULL CHECK (role IN ('agent','user')),
  content text NOT NULL,
  content_source text CHECK (content_source IN ('voice_transcription','typed','generated')),
  latency_ms int,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(session_id, sequence_number)
);

-- Trigger: increment agent_sessions.turn_count on message INSERT
CREATE OR REPLACE FUNCTION increment_agent_session_turn_count()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE agent_sessions
  SET turn_count = turn_count + 1
  WHERE id = NEW.session_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS agent_messages_increment_turn_count ON agent_messages;
CREATE TRIGGER agent_messages_increment_turn_count
  AFTER INSERT ON agent_messages
  FOR EACH ROW
  EXECUTE FUNCTION increment_agent_session_turn_count();

-- RLS
ALTER TABLE agent_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own agent messages" ON agent_messages;
CREATE POLICY "Users can view own agent messages" ON agent_messages
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own agent messages" ON agent_messages;
CREATE POLICY "Users can insert own agent messages" ON agent_messages
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- No UPDATE/DELETE policies (append-only)

-- ============================================================
-- 4. agent_generations
-- ============================================================
CREATE TABLE IF NOT EXISTS agent_generations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  raw_llm_output text NOT NULL,
  generated_review_text text,
  generated_mood_tags text[] NOT NULL DEFAULT '{}',
  generated_favorite_moments text[] NOT NULL DEFAULT '{}',
  generated_personal_takeaway text,
  generated_standout_performances text[] NOT NULL DEFAULT '{}',
  confidence_scores jsonb NOT NULL DEFAULT '{}'::jsonb,
  prompt_template_hash text NOT NULL,
  model_id text NOT NULL,
  token_count int,
  generation_latency_ms int,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(session_id)
);

-- RLS
ALTER TABLE agent_generations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own agent generations" ON agent_generations;
CREATE POLICY "Users can view own agent generations" ON agent_generations
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own agent generations" ON agent_generations;
CREATE POLICY "Users can insert own agent generations" ON agent_generations
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own agent generations" ON agent_generations;
CREATE POLICY "Users can update own agent generations" ON agent_generations
  FOR UPDATE USING (auth.uid() = user_id);

-- ============================================================
-- 5. user_corrections
-- ============================================================
CREATE TABLE IF NOT EXISTS user_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_id uuid NOT NULL REFERENCES agent_generations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  field_name text NOT NULL,
  correction_type text NOT NULL
    CHECK (correction_type IN ('accept','edit','add','remove','rewrite')),
  original_value text NOT NULL,
  final_value text NOT NULL,
  edit_distance int,
  time_spent_editing_ms int,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_corrections_generation
  ON user_corrections(generation_id);

CREATE INDEX IF NOT EXISTS idx_user_corrections_user
  ON user_corrections(user_id);

CREATE INDEX IF NOT EXISTS idx_user_corrections_field_type
  ON user_corrections(field_name, correction_type);

-- RLS
ALTER TABLE user_corrections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own corrections" ON user_corrections;
CREATE POLICY "Users can view own corrections" ON user_corrections
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own corrections" ON user_corrections;
CREATE POLICY "Users can insert own corrections" ON user_corrections
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- No UPDATE/DELETE policies (immutable gold data)

-- ============================================================
-- 6. emotional_patterns (Layer 4 — service_role access only)
-- ============================================================
CREATE TABLE IF NOT EXISTS emotional_patterns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  anonymized_user_id text NOT NULL,
  stimulus jsonb NOT NULL DEFAULT '{}'::jsonb,
  emotional_response jsonb NOT NULL DEFAULT '{}'::jsonb,
  expression_characteristics jsonb NOT NULL DEFAULT '{}'::jsonb,
  viewing_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  behavioral_signals jsonb NOT NULL DEFAULT '{}'::jsonb,
  temporal_context jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_emotional_patterns_stimulus_genre
  ON emotional_patterns USING GIN ((stimulus->'genre'));

CREATE INDEX IF NOT EXISTS idx_emotional_patterns_primary_emotions
  ON emotional_patterns USING GIN ((emotional_response->'primary_emotions'));

-- RLS enabled, NO user policies — service_role only
ALTER TABLE emotional_patterns ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 7. training_examples (Layer 5 — service_role access only)
-- ============================================================
CREATE TABLE IF NOT EXISTS training_examples (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  example_type text NOT NULL,
  input jsonb NOT NULL DEFAULT '{}'::jsonb,
  output_generated jsonb NOT NULL DEFAULT '{}'::jsonb,
  output_corrected jsonb NOT NULL DEFAULT '{}'::jsonb,
  quality_signals jsonb NOT NULL DEFAULT '{}'::jsonb,
  consent_tier text NOT NULL CHECK (consent_tier IN ('product_improvement','anonymized_research')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- RLS enabled, NO user policies — service_role only
ALTER TABLE training_examples ENABLE ROW LEVEL SECURITY;
