import { supabase } from '../lib/supabase';
import {
  AgentSession,
  AgentMessage,
  AgentMessageRole,
  AgentGeneration,
  SessionCompletionStatus,
} from '../types';
import { hasConsent } from './consentService';

// ── Context type for Edge Function calls ────────────────────────────────────

export interface AgentContext {
  movie: { title: string; year: string; genres: string[]; director?: string };
  ranking: { tier: string; score: number; primaryGenre?: string };
  userProfile: {
    moodHistory: string[];
    topGenres: Record<string, number>;
    recentJournalCount: number;
  };
}

// ── Row interfaces ──────────────────────────────────────────────────────────

interface SessionRow {
  id: string;
  user_id: string;
  movie_tmdb_id: string | null;
  ranking_id: string | null;
  context_snapshot: Record<string, unknown>;
  model_version: string;
  prompt_version: string;
  completion_status: string;
  turn_count: number;
  input_modality: string;
  started_at: string;
  completed_at: string | null;
  created_at: string;
}

interface MessageRow {
  id: string;
  session_id: string;
  user_id: string;
  sequence_number: number;
  role: string;
  content: string;
  content_source: string | null;
  latency_ms: number | null;
  created_at: string;
}

interface GenerationRow {
  id: string;
  session_id: string;
  user_id: string;
  raw_llm_output: string;
  generated_review_text: string | null;
  generated_mood_tags: string[];
  generated_favorite_moments: string[];
  generated_personal_takeaway: string | null;
  generated_standout_performances: string[];
  confidence_scores: Record<string, unknown>;
  prompt_template_hash: string;
  model_id: string;
  token_count: number | null;
  generation_latency_ms: number | null;
  created_at: string;
}

// ── Map functions ───────────────────────────────────────────────────────────

function mapSessionRow(row: SessionRow): AgentSession {
  return {
    id: row.id,
    userId: row.user_id,
    movieTmdbId: row.movie_tmdb_id ?? undefined,
    rankingId: row.ranking_id ?? undefined,
    contextSnapshot: row.context_snapshot,
    modelVersion: row.model_version,
    promptVersion: row.prompt_version,
    completionStatus: row.completion_status as SessionCompletionStatus,
    turnCount: row.turn_count,
    inputModality: row.input_modality as AgentSession['inputModality'],
    startedAt: row.started_at,
    completedAt: row.completed_at ?? undefined,
    createdAt: row.created_at,
  };
}

function mapMessageRow(row: MessageRow): AgentMessage {
  return {
    id: row.id,
    sessionId: row.session_id,
    userId: row.user_id,
    sequenceNumber: row.sequence_number,
    role: row.role as AgentMessageRole,
    content: row.content,
    contentSource: row.content_source as AgentMessage['contentSource'],
    latencyMs: row.latency_ms ?? undefined,
    createdAt: row.created_at,
  };
}

function mapGenerationRow(row: GenerationRow): AgentGeneration {
  return {
    id: row.id,
    sessionId: row.session_id,
    userId: row.user_id,
    rawLlmOutput: row.raw_llm_output,
    generatedReviewText: row.generated_review_text ?? undefined,
    generatedMoodTags: row.generated_mood_tags ?? [],
    generatedFavoriteMoments: row.generated_favorite_moments ?? [],
    generatedPersonalTakeaway: row.generated_personal_takeaway ?? undefined,
    generatedStandoutPerformances: row.generated_standout_performances ?? [],
    confidenceScores: row.confidence_scores,
    promptTemplateHash: row.prompt_template_hash,
    modelId: row.model_id,
    tokenCount: row.token_count ?? undefined,
    generationLatencyMs: row.generation_latency_ms ?? undefined,
    createdAt: row.created_at,
  };
}

// ── Session management ──────────────────────────────────────────────────────

export async function createSession(
  userId: string,
  movieTmdbId: string,
  rankingId: string | undefined,
  contextSnapshot: Record<string, unknown>,
  promptVersion: string,
): Promise<AgentSession | null> {
  // Check consent before creating session
  const allowed = await hasConsent(userId, 'product_improvement');
  if (!allowed) return null;

  const payload: Record<string, unknown> = {
    user_id: userId,
    movie_tmdb_id: movieTmdbId,
    context_snapshot: contextSnapshot,
    prompt_version: promptVersion,
  };

  if (rankingId) {
    payload.ranking_id = rankingId;
  }

  const { data: row, error } = await supabase
    .from('agent_sessions')
    .insert(payload)
    .select()
    .single();

  if (error) {
    console.error('Failed to create agent session:', error);
    return null;
  }

  return mapSessionRow(row as SessionRow);
}

export async function endSession(
  sessionId: string,
  status: SessionCompletionStatus,
): Promise<boolean> {
  const { error } = await supabase
    .from('agent_sessions')
    .update({
      completion_status: status,
      completed_at: new Date().toISOString(),
    })
    .eq('id', sessionId);

  if (error) {
    console.error('Failed to end agent session:', error);
    return false;
  }

  return true;
}

export async function getSession(
  sessionId: string,
): Promise<AgentSession | null> {
  const { data: row, error } = await supabase
    .from('agent_sessions')
    .select('*')
    .eq('id', sessionId)
    .maybeSingle();

  if (error) {
    console.error('Failed to get agent session:', error);
    return null;
  }
  if (!row) return null;

  return mapSessionRow(row as SessionRow);
}

// ── Message management ──────────────────────────────────────────────────────

export async function appendMessage(
  sessionId: string,
  userId: string,
  role: AgentMessageRole,
  content: string,
  latencyMs?: number,
): Promise<AgentMessage | null> {
  // Compute next sequence number by querying current max
  const { data: maxRow, error: maxError } = await supabase
    .from('agent_messages')
    .select('sequence_number')
    .eq('session_id', sessionId)
    .order('sequence_number', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (maxError) {
    console.error('Failed to query max sequence_number:', maxError);
    return null;
  }

  const nextSeq = maxRow
    ? (maxRow as { sequence_number: number }).sequence_number + 1
    : 0;

  const contentSource = role === 'user' ? 'typed' : 'generated';

  const payload: Record<string, unknown> = {
    session_id: sessionId,
    user_id: userId,
    sequence_number: nextSeq,
    role,
    content,
    content_source: contentSource,
  };

  if (latencyMs !== undefined) {
    payload.latency_ms = latencyMs;
  }

  const { data: row, error } = await supabase
    .from('agent_messages')
    .insert(payload)
    .select()
    .single();

  if (error) {
    console.error('Failed to append agent message:', error);
    return null;
  }

  return mapMessageRow(row as MessageRow);
}

export async function getSessionMessages(
  sessionId: string,
): Promise<AgentMessage[]> {
  const { data: rows, error } = await supabase
    .from('agent_messages')
    .select('*')
    .eq('session_id', sessionId)
    .order('sequence_number', { ascending: true });

  if (error) {
    console.error('Failed to get session messages:', error);
    return [];
  }

  return (rows as MessageRow[]).map(mapMessageRow);
}

// ── Generation management ───────────────────────────────────────────────────

export async function recordGeneration(
  sessionId: string,
  userId: string,
  rawOutput: string,
  parsedFields: {
    reviewText?: string;
    moodTags: string[];
    favoriteMoments: string[];
    personalTakeaway?: string;
    standoutPerformances: string[];
  },
  promptHash: string,
  modelId: string,
  latencyMs?: number,
): Promise<AgentGeneration | null> {
  const payload: Record<string, unknown> = {
    session_id: sessionId,
    user_id: userId,
    raw_llm_output: rawOutput,
    generated_mood_tags: parsedFields.moodTags,
    generated_favorite_moments: parsedFields.favoriteMoments,
    generated_standout_performances: parsedFields.standoutPerformances,
    prompt_template_hash: promptHash,
    model_id: modelId,
  };

  if (parsedFields.reviewText !== undefined) {
    payload.generated_review_text = parsedFields.reviewText;
  }
  if (parsedFields.personalTakeaway !== undefined) {
    payload.generated_personal_takeaway = parsedFields.personalTakeaway;
  }
  if (latencyMs !== undefined) {
    payload.generation_latency_ms = latencyMs;
  }

  const { data: row, error } = await supabase
    .from('agent_generations')
    .insert(payload)
    .select()
    .single();

  if (error) {
    console.error('Failed to record agent generation:', error);
    return null;
  }

  return mapGenerationRow(row as GenerationRow);
}

export async function getGeneration(
  sessionId: string,
): Promise<AgentGeneration | null> {
  const { data: row, error } = await supabase
    .from('agent_generations')
    .select('*')
    .eq('session_id', sessionId)
    .maybeSingle();

  if (error) {
    console.error('Failed to get agent generation:', error);
    return null;
  }
  if (!row) return null;

  return mapGenerationRow(row as GenerationRow);
}

// ── Edge Function callers ───────────────────────────────────────────────────

export async function sendAgentMessage(
  sessionId: string,
  userMessage: string,
  context: AgentContext,
): Promise<{ reply: string } | null> {
  // Get the session to find the userId
  const session = await getSession(sessionId);
  if (!session) {
    console.error('sendAgentMessage: session not found');
    return null;
  }

  // Append the user message first
  const userMsg = await appendMessage(
    sessionId,
    session.userId,
    'user',
    userMessage,
  );
  if (!userMsg) {
    console.error('sendAgentMessage: failed to append user message');
    return null;
  }

  // Build message history for the Edge Function
  const messages = await getSessionMessages(sessionId);
  const edgeFunctionMessages = messages.map((m) => ({
    role: m.role === 'agent' ? ('assistant' as const) : ('user' as const),
    content: m.content,
  }));

  // Call Edge Function and measure latency
  const start = performance.now();

  const { data, error } = await supabase.functions.invoke('journal-agent', {
    body: {
      messages: edgeFunctionMessages,
      context,
      action: 'chat',
    },
  });

  const latencyMs = Math.round(performance.now() - start);

  if (error) {
    console.error('sendAgentMessage: Edge Function error:', error);
    return null;
  }

  const reply = data?.reply;
  if (!reply || typeof reply !== 'string') {
    console.error('sendAgentMessage: invalid reply from Edge Function:', data);
    return null;
  }

  // Append the agent reply
  const agentMsg = await appendMessage(
    sessionId,
    session.userId,
    'agent',
    reply,
    latencyMs,
  );
  if (!agentMsg) {
    console.error('sendAgentMessage: failed to append agent message');
    // Still return the reply since we got it, even if storing failed
  }

  return { reply };
}

export async function requestReviewGeneration(
  sessionId: string,
  context: AgentContext,
): Promise<AgentGeneration | null> {
  // Get the session to find the userId
  const session = await getSession(sessionId);
  if (!session) {
    console.error('requestReviewGeneration: session not found');
    return null;
  }

  // Build message history for the Edge Function
  const messages = await getSessionMessages(sessionId);
  const edgeFunctionMessages = messages.map((m) => ({
    role: m.role === 'agent' ? ('assistant' as const) : ('user' as const),
    content: m.content,
  }));

  // Call Edge Function and measure latency
  const start = performance.now();

  const { data, error } = await supabase.functions.invoke('journal-agent', {
    body: {
      messages: edgeFunctionMessages,
      context,
      action: 'generate_review',
    },
  });

  const latencyMs = Math.round(performance.now() - start);

  if (error) {
    console.error('requestReviewGeneration: Edge Function error:', error);
    return null;
  }

  if (!data?.generation || !data?.raw_output) {
    console.error(
      'requestReviewGeneration: invalid response from Edge Function:',
      data,
    );
    return null;
  }

  const gen = data.generation as {
    review_text?: string;
    mood_tags?: string[];
    favorite_moments?: string[];
    personal_takeaway?: string;
    standout_performances?: string[];
  };

  // Record the generation
  const generation = await recordGeneration(
    sessionId,
    session.userId,
    data.raw_output as string,
    {
      reviewText: gen.review_text,
      moodTags: gen.mood_tags ?? [],
      favoriteMoments: gen.favorite_moments ?? [],
      personalTakeaway: gen.personal_takeaway,
      standoutPerformances: gen.standout_performances ?? [],
    },
    session.promptVersion,
    session.modelVersion,
    latencyMs,
  );

  return generation;
}
