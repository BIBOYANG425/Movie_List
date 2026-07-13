// agent-link/_shared.ts — pure, import-clean helpers for the agent-link function.
//
// Split out from index.ts (which owns Deno.serve + fetch I/O) so the pure logic
// — phone normalization, the Photon shared-user registration flow, its outcome
// classifier, and the HTTP response mappers — can be unit-tested under vitest
// WITHOUT a Deno runtime (mirrors the tmdb-proxy/rules.ts + suggestions/engine.ts
// convention). No Deno globals, no network calls, no npm imports live here; the
// one function that talks to Photon (registerSharedUser) takes an injected
// `fetch` so tests drive it with a stub.
//
// Ported from bia-roommate lib/george/spectrum.ts (Bobby's proven Photon code):
//   - normalizePhone: a MINIMAL, dependency-free E.164 canonicalizer (the source
//     delegates to @biboyang425/bia-shared/phone's libphonenumber-js validator;
//     an edge function stays import-clean, so we reimplement the deterministic
//     rules that matter here — trust an explicit +country, default US for a bare
//     10-digit North-American number — without pulling libphonenumber into Deno).
//   - registerSharedUser: create -> search fallback -> availability probe, with
//     the same outcomes (ok / pool_unavailable / spectrum_error) and 10-15s
//     AbortSignal timeouts as the source.

// ── Phone normalization (minimal E.164) ──────────────────────────────────────

/**
 * Normalize a user-typed phone to canonical E.164, or null when it can't be.
 *
 * Deterministic rules (a minimal port of canonicalizePhone's essentials):
 *  1. Trim; reduce to digits plus a single LEADING '+'. Embedded '+' is junk.
 *  2. The international '00' prefix is equivalent to a leading '+'.
 *  3. Explicit +country (leading '+'): trust it. Validate as a 8–15 digit E.164
 *     (ITU E.164 caps the national+country digits at 15; 8 is a safe floor that
 *     still admits short country numbers while rejecting obvious junk).
 *  4. No leading '+': a bare 10-digit number defaults to US (+1). An 11-digit
 *     number that already starts with the US country code 1 becomes +<digits>.
 *     Anything else without a country context is rejected (we never blindly
 *     invent a country for an ambiguous length).
 */
export function normalizePhone(raw: string): string | null {
  const trimmed = (raw ?? '').trim()
  if (trimmed === '') return null

  // Reduce to digits + a single leading '+'.
  let cleaned = ''
  let seenPlus = false
  for (const ch of trimmed) {
    if (ch >= '0' && ch <= '9') cleaned += ch
    else if (ch === '+' && !seenPlus && cleaned === '') {
      cleaned = '+'
      seenPlus = true
    }
  }
  // '00' international prefix == leading '+'.
  if (!cleaned.startsWith('+') && cleaned.startsWith('00')) {
    cleaned = `+${cleaned.slice(2)}`
  }
  if (cleaned === '' || cleaned === '+') return null

  if (cleaned.startsWith('+')) {
    const digits = cleaned.slice(1)
    // E.164: country code + national number, up to 15 digits total.
    if (digits.length >= 8 && digits.length <= 15 && /^[1-9]/.test(digits)) {
      return `+${digits}`
    }
    return null
  }

  // No leading '+': apply the US default for North-American shapes.
  if (cleaned.length === 10) {
    // Bare 10-digit national number → default US. First digit of a valid NANP
    // area code is 2–9.
    if (/^[2-9]/.test(cleaned)) return `+1${cleaned}`
    return null
  }
  if (cleaned.length === 11 && cleaned.startsWith('1')) {
    // 1 + 10-digit NANP number.
    if (/^1[2-9]/.test(cleaned)) return `+${cleaned}`
    return null
  }
  // Ambiguous length with no country context: reject rather than guess.
  return null
}

// ── Photon (Spectrum) shared-user registration ───────────────────────────────

export type SpectrumCreds = { projectId: string; projectSecret: string }

export type SignupOutcome =
  | { ok: true; assignedPhoneNumber: string; alreadyRegistered: boolean }
  | { ok: false; error: 'pool_unavailable' | 'spectrum_error' }

export const SPECTRUM_BASE = 'https://spectrum.photon.codes'

interface SpectrumUser {
  phoneNumber: string
  assignedPhoneNumber: string
}

/** Basic base64(projectId:projectSecret). base64-encode via btoa (Deno + browsers). */
export function authHeader(projectId: string, projectSecret: string): string {
  return `Basic ${btoa(`${projectId}:${projectSecret}`)}`
}

async function findExisting(
  fetchImpl: typeof fetch,
  projectId: string,
  auth: string,
  phone: string,
): Promise<SpectrumUser | null> {
  const res = await fetchImpl(
    `${SPECTRUM_BASE}/projects/${projectId}/users/?search=${encodeURIComponent(phone)}`,
    { headers: { authorization: auth }, signal: AbortSignal.timeout(10_000) },
  ).catch(() => null)
  if (!res || !res.ok) return null
  const data = await res.json().catch(() => null)
  const users = (data?.data?.users ?? []) as SpectrumUser[]
  return users.find((u) => u.phoneNumber === phone) ?? null
}

/**
 * Register a phone as a Spectrum "shared" user and return the pool number it
 * was assigned (the number THAT phone must text). Idempotent: an already-
 * registered phone falls back to a search lookup and reuses its assignment.
 *
 * Ported verbatim in shape from bia-roommate spectrum.ts: create → search
 * fallback → availability probe. `fetchImpl` is injected so tests can drive the
 * three network paths without real I/O.
 */
export async function registerSharedUser(
  phoneE164: string,
  creds: SpectrumCreds,
  fetchImpl: typeof fetch = fetch,
): Promise<SignupOutcome> {
  const auth = authHeader(creds.projectId, creds.projectSecret)

  const res = await fetchImpl(`${SPECTRUM_BASE}/projects/${creds.projectId}/users/`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: auth },
    body: JSON.stringify({ type: 'shared', phoneNumber: phoneE164 }),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => null)

  if (res) {
    const data = await res.json().catch(() => null)
    const assigned = data?.data?.assignedPhoneNumber as string | undefined
    if (res.ok && data?.succeed && assigned) {
      return { ok: true, assignedPhoneNumber: assigned, alreadyRegistered: false }
    }
  }

  // Create failed — most commonly this phone is already registered. Look it up
  // and reuse the existing assignment before giving up.
  const existing = await findExisting(fetchImpl, creds.projectId, auth, phoneE164)
  if (existing?.assignedPhoneNumber) {
    return { ok: true, assignedPhoneNumber: existing.assignedPhoneNumber, alreadyRegistered: true }
  }

  // Distinguish "pool exhausted" from a generic failure when the availability
  // endpoint answers.
  const avail = await fetchImpl(
    `${SPECTRUM_BASE}/projects/${creds.projectId}/imessage/shared/availability?phoneNumber=${encodeURIComponent(phoneE164)}`,
    { headers: { authorization: auth }, signal: AbortSignal.timeout(10_000) },
  ).catch(() => null)
  if (avail?.ok) {
    const a = await avail.json().catch(() => null)
    if (a?.succeed && a?.data?.available === false) return { ok: false, error: 'pool_unavailable' }
  }
  return { ok: false, error: 'spectrum_error' }
}

// ── HTTP response mappers ─────────────────────────────────────────────────────

export interface HttpResult {
  status: number
  body: Record<string, unknown>
}

/** Map a Photon SignupOutcome to the HTTP status + error body the client sees. */
export function outcomeToHttp(outcome: SignupOutcome): HttpResult | null {
  if (outcome.ok) return null // caller proceeds to mint the code
  if (outcome.error === 'pool_unavailable') {
    return { status: 503, body: { error: 'pool_unavailable' } }
  }
  return { status: 502, body: { error: 'spectrum_error' } }
}

/**
 * Classify a mint_agent_link_code RPC failure. The RPC raises a plpgsql
 * exception whose message contains "too many active link codes" when the
 * per-user live-code cap (5) is hit → surface 429 too_many_codes. Anything else
 * is an opaque 500.
 */
export function classifyMintError(rpcMessage: string | null | undefined): HttpResult {
  const msg = (rpcMessage ?? '').toLowerCase()
  if (msg.includes('too many active link codes') || msg.includes('too many')) {
    return { status: 429, body: { error: 'too_many_codes' } }
  }
  return { status: 500, body: { error: 'mint_failed' } }
}

/**
 * Shape the 200 body for POST from the Photon outcome + minted code. Keys match
 * the M2b iOS contract exactly.
 */
export function buildLinkResponse(
  outcome: Extract<SignupOutcome, { ok: true }>,
  code: string,
  expiresAt: string,
): Record<string, unknown> {
  return {
    assignedPhoneNumber: outcome.assignedPhoneNumber,
    code,
    expiresAt,
    alreadyRegistered: outcome.alreadyRegistered,
  }
}

/**
 * Shape the GET status body from get_agent_link_status rows
 * ({ phone, linked_at }[]) into { links: [{ phone, linkedAt }] }.
 */
export function buildStatusResponse(
  rows: Array<{ phone: string; linked_at: string }>,
): { links: Array<{ phone: string; linkedAt: string }> } {
  return {
    links: (rows ?? []).map((r) => ({ phone: r.phone, linkedAt: r.linked_at })),
  }
}

// ── Agent-initiated web login (consume-login-token, P4 / Slice B2) ────────────

/**
 * Pull the login token out of a POST body of shape
 * `{ action: 'consume-login-token', token }`. Returns the trimmed token, or null
 * when the body is not that action or the token is missing/blank. Kept pure so
 * the index.ts router can branch on it and tests can exercise the validation.
 */
export function parseConsumeLoginBody(body: unknown): string | null {
  const b = body as Record<string, unknown> | null | undefined
  if (!b || b.action !== 'consume-login-token') return null
  const token = b.token
  if (typeof token !== 'string') return null
  const trimmed = token.trim()
  return trimmed === '' ? null : trimmed
}

/**
 * Map the consume_agent_login_token RPC's single status row to the HTTP result
 * the web surface consumes. The RPC already collapses unknown / expired /
 * consumed / relation-not-found into 'expired' (one opaque shape — no leak of
 * which). 'already_linked' is a success (idempotent re-tap). Any unrecognized
 * status is a 500 the page renders as its generic error.
 */
export function consumeStatusToHttp(status: string | null | undefined): HttpResult {
  switch (status) {
    case 'linked':
      return { status: 200, body: { ok: true } }
    case 'already_linked':
      return { status: 200, body: { ok: true, alreadyLinked: true } }
    case 'expired':
      return { status: 400, body: { error: 'expired' } }
    default:
      return { status: 500, body: { error: 'consume_failed' } }
  }
}

/**
 * Classify a consume_agent_login_token RPC *transport* failure (non-2xx from
 * PostgREST). If the definer function still surfaced a relation-not-found (e.g.
 * the exception guard was bypassed by a schema-cache miss), the message names
 * the missing relation — map that to the same opaque 'expired'. Everything else
 * is an opaque 500.
 */
export function classifyConsumeError(rpcMessage: string | null | undefined): HttpResult {
  const msg = (rpcMessage ?? '').toLowerCase()
  if (
    msg.includes('login_links') ||
    msg.includes('does not exist') ||
    msg.includes('undefined_table') ||
    msg.includes('schema "hana"')
  ) {
    return { status: 400, body: { error: 'expired' } }
  }
  return { status: 500, body: { error: 'consume_failed' } }
}
