// services/agentLoginConsume.ts
//
// The consume-call wiring for /agent-login (P4 / Slice B2).
//
// Once the user has a live Supabase session (they were already signed in, or
// just signed in / signed up on the reused auth surface), the page redeems the
// single-use login token by calling the agent-link edge function under the
// user's JWT:
//
//   supabase.functions.invoke('agent-link', {
//     body: { action: 'consume-login-token', token },
//   })
//
// `functions.invoke` automatically attaches the current session's access token
// as the Authorization header — exactly what the edge function's verify_jwt +
// in-function getUser() expect (the caller is the freshly signed-in user, and
// the phone to bind comes from the token row, not the client).
//
// The edge function returns:
//   200 { ok: true }                    → linked
//   200 { ok: true, alreadyLinked: true }→ linked (idempotent re-tap)
//   400 { error: 'expired' }             → token unknown / expired / consumed
//                                          (one shape for all three — no leak),
//                                          AND the login_links table not existing
//                                          yet (agent deploy creates it).
//   * (anything else)                    → generic error
//
// A non-2xx response surfaces through `functions.invoke` as `error` (a
// FunctionsHttpError) whose `.context` is the raw Response; we read its JSON to
// recover the `{ error }` shape. This module is import-clean of window/DOM so it
// runs in the node test env; the client is injected so tests drive it with a
// fake and the page passes the real module supabase.
//
// Header last reviewed: 2026-07-12

export type ConsumeLoginResult =
  | { status: 'linked'; alreadyLinked: boolean }
  | { status: 'expired' }
  | { status: 'error' };

// A minimal structural type for the piece of the supabase client we touch, so
// this stays testable without importing the whole SDK type surface.
export interface FunctionsInvoker {
  functions: {
    invoke: (
      name: string,
      options: { body: unknown },
    ) => Promise<{ data: unknown; error: unknown }>;
  };
}

/** Pull the JSON body ({ error } | { ok }) off a FunctionsHttpError's Response. */
async function readErrorBody(error: unknown): Promise<Record<string, unknown> | null> {
  const context = (error as { context?: unknown })?.context;
  if (context && typeof (context as Response).json === 'function') {
    try {
      return (await (context as Response).json()) as Record<string, unknown>;
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Redeem the login token under the caller's JWT. Never throws — every failure
 * collapses to a rendered state ('expired' | 'error'), because this is the last
 * step of a one-shot funnel and there is no useful retry surface for the user
 * beyond "text chris again".
 */
export async function consumeLoginToken(
  client: FunctionsInvoker,
  token: string,
): Promise<ConsumeLoginResult> {
  try {
    const { data, error } = await client.functions.invoke('agent-link', {
      body: { action: 'consume-login-token', token },
    });

    if (error) {
      const body = await readErrorBody(error);
      if (body?.error === 'expired') return { status: 'expired' };
      return { status: 'error' };
    }

    const ok = (data as { ok?: boolean } | null)?.ok === true;
    if (ok) {
      const alreadyLinked =
        (data as { alreadyLinked?: boolean } | null)?.alreadyLinked === true;
      return { status: 'linked', alreadyLinked };
    }

    // A 200 that is not { ok: true } (e.g. a defensive { error: 'expired' }
    // returned with a 2xx by some proxy) — read the error field if present.
    if ((data as { error?: string } | null)?.error === 'expired') {
      return { status: 'expired' };
    }
    return { status: 'error' };
  } catch {
    return { status: 'error' };
  }
}
