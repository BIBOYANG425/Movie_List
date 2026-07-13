import { describe, it, expect, vi } from 'vitest'
import {
  authHeader,
  buildLinkResponse,
  buildStatusResponse,
  classifyConsumeError,
  classifyMintError,
  consumeStatusToHttp,
  normalizePhone,
  outcomeToHttp,
  parseConsumeLoginBody,
  registerSharedUser,
  SPECTRUM_BASE,
  type SignupOutcome,
} from '../../supabase/functions/agent-link/_shared'

// Imports the SAME _shared.ts that supabase/functions/agent-link/index.ts uses.
// _shared.ts is import-clean (no Deno globals, no network at import time) so
// vitest compiles it directly. registerSharedUser takes an injected fetch, so
// its three network paths are exercised without real I/O.

// ── normalizePhone ────────────────────────────────────────────────────────────

describe('normalizePhone — bare North-American numbers default to US', () => {
  it('bare 10-digit → +1', () => {
    expect(normalizePhone('2135550142')).toBe('+12135550142')
  })
  it('formatted 10-digit → +1 (punctuation stripped)', () => {
    expect(normalizePhone('(213) 555-0142')).toBe('+12135550142')
  })
  it('11-digit starting with 1 → +1<digits>', () => {
    expect(normalizePhone('12135550142')).toBe('+12135550142')
  })
  it('11-digit "1 (213) 555-0142" → +12135550142', () => {
    expect(normalizePhone('1 (213) 555-0142')).toBe('+12135550142')
  })
})

describe('normalizePhone — explicit +country is trusted', () => {
  it('already-canonical E.164 is idempotent', () => {
    expect(normalizePhone('+12135550142')).toBe('+12135550142')
  })
  it('trims surrounding whitespace', () => {
    expect(normalizePhone('  +12135550142  ')).toBe('+12135550142')
  })
  it('a full +86 number is trusted, never re-prefixed', () => {
    expect(normalizePhone('+8615522499291')).toBe('+8615522499291')
  })
  it('the "00" international prefix becomes a leading +', () => {
    expect(normalizePhone('008615522499291')).toBe('+8615522499291')
  })
})

describe('normalizePhone — rejects junk / ambiguous', () => {
  it('empty string → null', () => {
    expect(normalizePhone('')).toBeNull()
  })
  it('whitespace-only → null', () => {
    expect(normalizePhone('   ')).toBeNull()
  })
  it('non-numeric junk → null', () => {
    expect(normalizePhone('not-a-phone')).toBeNull()
  })
  it('too-short bare number (no country context) → null', () => {
    expect(normalizePhone('5550142')).toBeNull()
  })
  it('9-digit ambiguous number with no country → null', () => {
    expect(normalizePhone('213555014')).toBeNull()
  })
  it('bare 10-digit whose area code starts with 0/1 → null (invalid NANP)', () => {
    expect(normalizePhone('0135550142')).toBeNull()
    expect(normalizePhone('1235550142')).toBeNull()
  })
  it('+ with too few digits → null', () => {
    expect(normalizePhone('+123')).toBeNull()
  })
  it('+ with more than 15 digits → null', () => {
    expect(normalizePhone('+1234567890123456')).toBeNull()
  })
  it('embedded (non-leading) + is dropped, digits stand alone', () => {
    // "21+35550142" → cleaned "2135550142" → bare 10-digit US.
    expect(normalizePhone('21+35550142')).toBe('+12135550142')
  })
})

// ── authHeader ────────────────────────────────────────────────────────────────

describe('authHeader — Basic base64(projectId:projectSecret)', () => {
  it('base64-encodes id:secret', () => {
    expect(authHeader('proj', 'secret')).toBe(`Basic ${btoa('proj:secret')}`)
  })
})

// ── registerSharedUser (injected fetch) ───────────────────────────────────────

const creds = { projectId: 'pid', projectSecret: 'psecret' }

function jsonResponse(body: unknown, ok = true): Response {
  return {
    ok,
    status: ok ? 200 : 500,
    json: () => Promise.resolve(body),
  } as unknown as Response
}

describe('registerSharedUser — create succeeds', () => {
  it('returns the assigned number, alreadyRegistered=false', async () => {
    const fetchImpl = vi.fn().mockResolvedValueOnce(
      jsonResponse({ succeed: true, data: { assignedPhoneNumber: '+13103441486' } }),
    ) as unknown as typeof fetch

    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({
      ok: true,
      assignedPhoneNumber: '+13103441486',
      alreadyRegistered: false,
    })
    // POST to /users/ with Basic auth + shared body.
    const [url, init] = (fetchImpl as unknown as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(url).toBe(`${SPECTRUM_BASE}/projects/pid/users/`)
    expect(init.method).toBe('POST')
    expect(init.headers.authorization).toBe(authHeader('pid', 'psecret'))
    expect(JSON.parse(init.body)).toEqual({ type: 'shared', phoneNumber: '+12135550142' })
  })
})

describe('registerSharedUser — create fails, search fallback reuses assignment', () => {
  it('returns existing assignment with alreadyRegistered=true', async () => {
    const fetchImpl = vi
      .fn()
      // create → not-ok
      .mockResolvedValueOnce(jsonResponse({ succeed: false }, false))
      // search → matching user
      .mockResolvedValueOnce(
        jsonResponse({
          data: {
            users: [
              { phoneNumber: '+12135550142', assignedPhoneNumber: '+13103441486' },
            ],
          },
        }),
      ) as unknown as typeof fetch

    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({
      ok: true,
      assignedPhoneNumber: '+13103441486',
      alreadyRegistered: true,
    })
  })

  it('search fallback ignores a non-matching phone', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ succeed: false }, false))
      .mockResolvedValueOnce(
        jsonResponse({
          data: {
            users: [{ phoneNumber: '+19998887777', assignedPhoneNumber: '+13109999999' }],
          },
        }),
      )
      // availability probe → available true (not exhausted) → spectrum_error
      .mockResolvedValueOnce(jsonResponse({ succeed: true, data: { available: true } })) as unknown as typeof fetch

    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({ ok: false, error: 'spectrum_error' })
  })
})

describe('registerSharedUser — pool exhausted', () => {
  it('availability available=false → pool_unavailable', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ succeed: false }, false)) // create fail
      .mockResolvedValueOnce(jsonResponse({ data: { users: [] } })) // search empty
      .mockResolvedValueOnce(
        jsonResponse({ succeed: true, data: { available: false } }),
      ) as unknown as typeof fetch

    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({ ok: false, error: 'pool_unavailable' })
  })
})

describe('registerSharedUser — generic failure', () => {
  it('all paths fail / network errors → spectrum_error', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(null) as unknown as typeof fetch
    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({ ok: false, error: 'spectrum_error' })
  })

  it('create returns ok but no assignedPhoneNumber → falls through to search', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ succeed: true, data: {} })) // no assigned
      .mockResolvedValueOnce(jsonResponse({ data: { users: [] } })) // search empty
      .mockResolvedValueOnce(jsonResponse({ succeed: true, data: { available: true } })) as unknown as typeof fetch
    const out = await registerSharedUser('+12135550142', creds, fetchImpl)
    expect(out).toEqual({ ok: false, error: 'spectrum_error' })
  })
})

// ── outcomeToHttp ─────────────────────────────────────────────────────────────

describe('outcomeToHttp — Photon outcome → HTTP', () => {
  it('ok outcome → null (caller proceeds to mint)', () => {
    const ok: SignupOutcome = { ok: true, assignedPhoneNumber: '+1310', alreadyRegistered: false }
    expect(outcomeToHttp(ok)).toBeNull()
  })
  it('pool_unavailable → 503', () => {
    expect(outcomeToHttp({ ok: false, error: 'pool_unavailable' })).toEqual({
      status: 503,
      body: { error: 'pool_unavailable' },
    })
  })
  it('spectrum_error → 502', () => {
    expect(outcomeToHttp({ ok: false, error: 'spectrum_error' })).toEqual({
      status: 502,
      body: { error: 'spectrum_error' },
    })
  })
})

// ── classifyMintError ─────────────────────────────────────────────────────────

describe('classifyMintError — RPC failure → HTTP', () => {
  it('rate-limit message → 429 too_many_codes', () => {
    expect(
      classifyMintError('too many active link codes — use an existing one or wait for expiry'),
    ).toEqual({ status: 429, body: { error: 'too_many_codes' } })
  })
  it('matches case-insensitively', () => {
    expect(classifyMintError('TOO MANY ACTIVE LINK CODES')).toEqual({
      status: 429,
      body: { error: 'too_many_codes' },
    })
  })
  it('other message → 500 mint_failed', () => {
    expect(classifyMintError('not authenticated')).toEqual({
      status: 500,
      body: { error: 'mint_failed' },
    })
  })
  it('null / undefined → 500 mint_failed', () => {
    expect(classifyMintError(null)).toEqual({ status: 500, body: { error: 'mint_failed' } })
    expect(classifyMintError(undefined)).toEqual({ status: 500, body: { error: 'mint_failed' } })
  })
})

// ── buildLinkResponse ─────────────────────────────────────────────────────────

describe('buildLinkResponse — 200 POST body (M2b contract)', () => {
  it('maps outcome + minted code into the exact iOS shape', () => {
    expect(
      buildLinkResponse(
        { ok: true, assignedPhoneNumber: '+13103441486', alreadyRegistered: true },
        'K7QRN9', // arbitrary code string
        '2026-07-11T20:15:00Z',
      ),
    ).toEqual({
      assignedPhoneNumber: '+13103441486',
      code: 'K7QRN9',
      expiresAt: '2026-07-11T20:15:00Z',
      alreadyRegistered: true,
    })
  })
})

// ── buildStatusResponse ───────────────────────────────────────────────────────

describe('buildStatusResponse — GET body (M2b contract)', () => {
  it('maps rows {phone, linked_at} → {phone, linkedAt}', () => {
    expect(
      buildStatusResponse([
        { phone: '+12135550142', linked_at: '2026-07-11T20:00:00Z' },
        { phone: '+8615522499291', linked_at: '2026-07-10T10:00:00Z' },
      ]),
    ).toEqual({
      links: [
        { phone: '+12135550142', linkedAt: '2026-07-11T20:00:00Z' },
        { phone: '+8615522499291', linkedAt: '2026-07-10T10:00:00Z' },
      ],
    })
  })
  it('empty / missing rows → { links: [] }', () => {
    expect(buildStatusResponse([])).toEqual({ links: [] })
    expect(buildStatusResponse(undefined as unknown as [])).toEqual({ links: [] })
  })
})

// ── consume-login-token helpers (P4 / Slice B2) ───────────────────────────────

describe('parseConsumeLoginBody', () => {
  it('returns the trimmed token for the consume action', () => {
    expect(parseConsumeLoginBody({ action: 'consume-login-token', token: '  tok-1  ' })).toBe(
      'tok-1',
    )
  })
  it('returns null when the action is not consume-login-token', () => {
    expect(parseConsumeLoginBody({ action: 'something-else', token: 'x' })).toBeNull()
    expect(parseConsumeLoginBody({ token: 'x' })).toBeNull()
  })
  it('returns null when the token is missing, blank, or not a string', () => {
    expect(parseConsumeLoginBody({ action: 'consume-login-token' })).toBeNull()
    expect(parseConsumeLoginBody({ action: 'consume-login-token', token: '   ' })).toBeNull()
    expect(parseConsumeLoginBody({ action: 'consume-login-token', token: 42 })).toBeNull()
  })
  it('returns null for a null / non-object body', () => {
    expect(parseConsumeLoginBody(null)).toBeNull()
    expect(parseConsumeLoginBody(undefined)).toBeNull()
    expect(parseConsumeLoginBody('nope')).toBeNull()
  })
})

describe('consumeStatusToHttp', () => {
  it('linked → 200 { ok: true }', () => {
    expect(consumeStatusToHttp('linked')).toEqual({ status: 200, body: { ok: true } })
  })
  it('already_linked → 200 { ok: true, alreadyLinked: true }', () => {
    expect(consumeStatusToHttp('already_linked')).toEqual({
      status: 200,
      body: { ok: true, alreadyLinked: true },
    })
  })
  it('expired → 400 { error: expired } (one shape for unknown/expired/consumed)', () => {
    expect(consumeStatusToHttp('expired')).toEqual({ status: 400, body: { error: 'expired' } })
  })
  it('unknown / missing status → 500 consume_failed', () => {
    expect(consumeStatusToHttp('weird')).toEqual({ status: 500, body: { error: 'consume_failed' } })
    expect(consumeStatusToHttp(undefined)).toEqual({
      status: 500,
      body: { error: 'consume_failed' },
    })
  })
})

describe('classifyConsumeError — relation-not-found tolerance', () => {
  it('maps a missing hana.login_links relation to the opaque expired', () => {
    expect(classifyConsumeError('relation "hana.login_links" does not exist').status).toBe(400)
    expect(classifyConsumeError('relation "hana.login_links" does not exist').body).toEqual({
      error: 'expired',
    })
  })
  it('maps a missing hana schema to expired', () => {
    expect(classifyConsumeError('schema "hana" does not exist').body).toEqual({ error: 'expired' })
  })
  it('maps any other RPC failure to an opaque 500', () => {
    expect(classifyConsumeError('deadlock detected')).toEqual({
      status: 500,
      body: { error: 'consume_failed' },
    })
    expect(classifyConsumeError(null)).toEqual({ status: 500, body: { error: 'consume_failed' } })
  })
})
