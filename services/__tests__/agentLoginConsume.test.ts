import { describe, it, expect, vi } from 'vitest';
import { consumeLoginToken, type FunctionsInvoker } from '../agentLoginConsume';

// The consume-call wiring for /agent-login (P4 / Slice B2). The supabase client
// is injected (FunctionsInvoker structural type) so we drive every edge-function
// outcome without real I/O. Proves the call shape (agent-link, action +
// token) and the mapping of each response to a rendered state.

/** A FunctionsInvoker whose invoke resolves to a fixed { data, error }. */
function invoker(result: { data: unknown; error: unknown }) {
  const invoke = vi.fn(async () => result);
  return { client: { functions: { invoke } } as FunctionsInvoker, invoke };
}

/** A FunctionsHttpError-shaped error: `.context` is the raw Response. */
function httpError(status: number, body: unknown) {
  return {
    name: 'FunctionsHttpError',
    context: { json: async () => body, status },
  };
}

describe('consumeLoginToken — call shape', () => {
  it('invokes agent-link with the consume action and token under the JWT', async () => {
    const { client, invoke } = invoker({ data: { ok: true }, error: null });
    await consumeLoginToken(client, 'tok-1');
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledWith('agent-link', {
      body: { action: 'consume-login-token', token: 'tok-1' },
    });
  });
});

describe('consumeLoginToken — success mapping', () => {
  it('maps { ok: true } to linked (alreadyLinked false)', async () => {
    const { client } = invoker({ data: { ok: true }, error: null });
    expect(await consumeLoginToken(client, 't')).toEqual({
      status: 'linked',
      alreadyLinked: false,
    });
  });

  it('maps { ok: true, alreadyLinked: true } to linked (alreadyLinked true)', async () => {
    const { client } = invoker({ data: { ok: true, alreadyLinked: true }, error: null });
    expect(await consumeLoginToken(client, 't')).toEqual({
      status: 'linked',
      alreadyLinked: true,
    });
  });
});

describe('consumeLoginToken — error mapping', () => {
  it('maps a 400 { error: expired } (FunctionsHttpError) to expired', async () => {
    const { client } = invoker({ data: null, error: httpError(400, { error: 'expired' }) });
    expect(await consumeLoginToken(client, 't')).toEqual({ status: 'expired' });
  });

  it('maps a non-expired edge error to the generic error state', async () => {
    const { client } = invoker({
      data: null,
      error: httpError(500, { error: 'consume_failed' }),
    });
    expect(await consumeLoginToken(client, 't')).toEqual({ status: 'error' });
  });

  it('maps an error with no readable body to the generic error state', async () => {
    const { client } = invoker({ data: null, error: { name: 'FunctionsFetchError' } });
    expect(await consumeLoginToken(client, 't')).toEqual({ status: 'error' });
  });

  it('treats a thrown invoke as the generic error state', async () => {
    const invoke = vi.fn(async () => {
      throw new Error('network down');
    });
    const client = { functions: { invoke } } as FunctionsInvoker;
    expect(await consumeLoginToken(client, 't')).toEqual({ status: 'error' });
  });

  it('maps a 2xx body that is not { ok } but carries error:expired to expired', async () => {
    const { client } = invoker({ data: { error: 'expired' }, error: null });
    expect(await consumeLoginToken(client, 't')).toEqual({ status: 'expired' });
  });
});
