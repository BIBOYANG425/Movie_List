import { supabase } from '../lib/supabase';
import { UserDataConsent } from '../types';

// ── Constants ────────────────────────────────────────────────────────────────

export const CURRENT_CONSENT_VERSION = 1;

// ── Helpers ──────────────────────────────────────────────────────────────────

interface ConsentRow {
  user_id: string;
  consent_product_improvement: boolean;
  consent_anonymized_research: boolean;
  consent_voice_storage: boolean;
  consent_version: number;
  consented_at: string | null;
  last_updated_at: string;
  created_at: string;
}

function mapRow(row: ConsentRow): UserDataConsent {
  return {
    userId: row.user_id,
    consentProductImprovement: row.consent_product_improvement,
    consentAnonymizedResearch: row.consent_anonymized_research,
    consentVoiceStorage: row.consent_voice_storage,
    consentVersion: row.consent_version,
    consentedAt: row.consented_at ?? undefined,
    lastUpdatedAt: row.last_updated_at,
    createdAt: row.created_at,
  };
}

// ── CRUD ─────────────────────────────────────────────────────────────────────

export async function getConsent(
  userId: string,
): Promise<UserDataConsent | null> {
  const { data: row, error } = await supabase
    .from('user_data_consent')
    .select('*')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    console.error('Failed to fetch consent:', error);
    return null;
  }
  if (!row) return null;

  return mapRow(row as ConsentRow);
}

export async function upsertConsent(
  userId: string,
  flags: Partial<{
    consentProductImprovement: boolean;
    consentAnonymizedResearch: boolean;
    consentVoiceStorage: boolean;
  }>,
): Promise<UserDataConsent | null> {
  const payload: Record<string, unknown> = {
    user_id: userId,
    consent_version: CURRENT_CONSENT_VERSION,
    consented_at: new Date().toISOString(),
  };

  if (flags.consentProductImprovement !== undefined) {
    payload.consent_product_improvement = flags.consentProductImprovement;
  }
  if (flags.consentAnonymizedResearch !== undefined) {
    payload.consent_anonymized_research = flags.consentAnonymizedResearch;
  }
  if (flags.consentVoiceStorage !== undefined) {
    payload.consent_voice_storage = flags.consentVoiceStorage;
  }

  const { data: row, error } = await supabase
    .from('user_data_consent')
    .upsert(payload, { onConflict: 'user_id' })
    .select()
    .single();

  if (error) {
    console.error('Failed to upsert consent:', error);
    return null;
  }

  return mapRow(row as ConsentRow);
}

export async function hasConsent(
  userId: string,
  flag: 'product_improvement' | 'anonymized_research' | 'voice_storage',
): Promise<boolean> {
  const columnMap: Record<typeof flag, string> = {
    product_improvement: 'consent_product_improvement',
    anonymized_research: 'consent_anonymized_research',
    voice_storage: 'consent_voice_storage',
  };

  const column = columnMap[flag];

  const { data: row, error } = await supabase
    .from('user_data_consent')
    .select(column)
    .eq('user_id', userId)
    .maybeSingle();

  if (error || !row) return false;

  return (row as unknown as Record<string, boolean>)[column] === true;
}

export async function needsConsentPrompt(
  userId: string,
): Promise<boolean> {
  const { data: row, error } = await supabase
    .from('user_data_consent')
    .select('consent_version')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    console.error('Failed to check consent prompt:', error);
    return true;
  }

  // No record exists — needs prompt
  if (!row) return true;

  // Consent version is outdated — needs prompt
  return (row as { consent_version: number }).consent_version < CURRENT_CONSENT_VERSION;
}
