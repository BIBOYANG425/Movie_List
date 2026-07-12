import { supabase } from '../lib/supabase';

// Reads and writes public.agent_preferences — the user's control over Chris's
// "daily reel" (a short morning movie-industry newsletter in Chris's voice).
//
// Direct own-row table under RLS (no RPC): the authenticated client upserts on
// user_id, exactly like the profiles visibility path. `timezone` is stamped from
// the browser (Intl.DateTimeFormat().resolvedOptions().timeZone) on every save so
// Chris delivers at the user's local hour. The agent reads the table with the
// service role from its own scheduler; that is NOT this service's concern.

export type DigestCadence = 'daily' | 'weekly' | 'off';

export interface DigestPreferences {
  cadence: DigestCadence;
  hour: number; // 0..23, local to `timezone`
  timezone: string;
}

// Contract defaults from the migration (daily @ 9, LA). A user who never touched
// the control has no row; the UI renders these.
export const DIGEST_DEFAULTS: DigestPreferences = {
  cadence: 'daily',
  hour: 9,
  timezone: 'America/Los_Angeles',
};

const CADENCES: readonly DigestCadence[] = ['daily', 'weekly', 'off'];

/** Coerce a raw DB cadence string into the union, defaulting unknown values. */
function toCadence(raw: unknown): DigestCadence {
  return CADENCES.includes(raw as DigestCadence)
    ? (raw as DigestCadence)
    : DIGEST_DEFAULTS.cadence;
}

/** Clamp an hour into the DB's 0..23 CHECK range. Pure — exported for tests. */
export function clampHour(hour: number): number {
  if (!Number.isFinite(hour)) return DIGEST_DEFAULTS.hour;
  return Math.min(23, Math.max(0, Math.trunc(hour)));
}

/**
 * A short 12-hour clock label for `hour` (0..23): `12am`, `9am`, `12pm`, `5pm`.
 * Pure + exported so the am/pm / midnight-noon edges are unit tested with no DOM.
 */
export function clockLabel(hour: number): string {
  const h = clampHour(hour);
  const suffix = h < 12 ? 'am' : 'pm';
  const twelve = h % 12 === 0 ? 12 : h % 12;
  return `${twelve}${suffix}`;
}

interface DigestRow {
  trade_digest_cadence: string;
  digest_hour: number;
  timezone: string;
}

/**
 * The signed-in user's digest preferences, or `null` when there's no row yet.
 * A missing row is NOT an error — the caller applies DIGEST_DEFAULTS.
 */
export async function getDigestPreferences(
  userId: string,
): Promise<DigestPreferences | null> {
  const { data, error } = await supabase
    .from('agent_preferences')
    .select('trade_digest_cadence, digest_hour, timezone')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    console.error('Failed to load digest preferences:', error);
    return null;
  }
  if (!data) return null;

  const row = data as DigestRow;
  return {
    cadence: toCadence(row.trade_digest_cadence),
    hour: clampHour(row.digest_hour),
    timezone: row.timezone,
  };
}

/** The browser's IANA timezone, falling back to the contract default. */
function currentTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || DIGEST_DEFAULTS.timezone;
  } catch {
    return DIGEST_DEFAULTS.timezone;
  }
}

/**
 * Upsert the caller's cadence + delivery hour. `timezone` is stamped from the
 * browser on every save (per spec). RLS re-enforces auth.uid() = user_id.
 * Returns true on success.
 */
export async function saveDigestPreferences(
  userId: string,
  cadence: DigestCadence,
  hour: number,
): Promise<boolean> {
  const { error } = await supabase
    .from('agent_preferences')
    .upsert(
      {
        user_id: userId,
        trade_digest_cadence: cadence,
        digest_hour: clampHour(hour),
        timezone: currentTimezone(),
        updated_at: new Date().toISOString(),
      },
      { onConflict: 'user_id' },
    )
    .select('user_id')
    .maybeSingle();

  if (error) {
    console.error('Failed to save digest preferences:', error);
    return false;
  }
  return true;
}
