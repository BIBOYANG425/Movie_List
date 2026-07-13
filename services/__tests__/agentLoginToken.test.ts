import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  AGENT_LOGIN_TOKEN_KEY,
  clearAgentLoginToken,
  readAgentLoginToken,
  stashAgentLoginToken,
} from '../agentLoginToken';

// The sessionStorage handoff that survives the Google OAuth round-trip (P4 /
// Slice B2). The node test env has no window; we install a minimal in-memory
// sessionStorage so the pure read/write/clear helpers run, and prove the
// try/catch swallows a throwing storage (private mode) rather than crashing the
// login flow.

function fakeStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
  };
}

describe('agentLoginToken — round-trip', () => {
  beforeEach(() => {
    (globalThis as any).window = { sessionStorage: fakeStorage() };
  });
  afterEach(() => {
    delete (globalThis as any).window;
  });

  it('stash then read returns the token', () => {
    stashAgentLoginToken('tok-42');
    expect(readAgentLoginToken()).toBe('tok-42');
  });

  it('uses the namespaced key', () => {
    stashAgentLoginToken('tok');
    expect((globalThis as any).window.sessionStorage.getItem(AGENT_LOGIN_TOKEN_KEY)).toBe('tok');
  });

  it('clear removes the token', () => {
    stashAgentLoginToken('tok');
    clearAgentLoginToken();
    expect(readAgentLoginToken()).toBeNull();
  });

  it('read is null when nothing stashed', () => {
    expect(readAgentLoginToken()).toBeNull();
  });
});

describe('agentLoginToken — storage failure is non-fatal', () => {
  beforeEach(() => {
    (globalThis as any).window = {
      sessionStorage: {
        getItem: () => {
          throw new Error('blocked');
        },
        setItem: () => {
          throw new Error('blocked');
        },
        removeItem: () => {
          throw new Error('blocked');
        },
      },
    };
  });
  afterEach(() => {
    delete (globalThis as any).window;
  });

  it('stash swallows the throw', () => {
    expect(() => stashAgentLoginToken('tok')).not.toThrow();
  });

  it('read returns null on a throwing store', () => {
    expect(readAgentLoginToken()).toBeNull();
  });

  it('clear swallows the throw', () => {
    expect(() => clearAgentLoginToken()).not.toThrow();
  });
});
