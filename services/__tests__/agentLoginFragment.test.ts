import { describe, it, expect } from 'vitest';
import { parseLoginFragment } from '../agentLoginFragment';

// The /agent-login fragment parser (P4 / Slice B2). Pure — no window, no fetch —
// so it runs straight in the node test environment. Guards the URL contract the
// agent must compose: `#lt=<token>` (single-use login token, never a JWT).

describe('parseLoginFragment — happy paths', () => {
  it('parses a token with a leading #', () => {
    expect(parseLoginFragment('#lt=abc123')).toEqual({ token: 'abc123' });
  });

  it('parses a bare param string (no leading #)', () => {
    expect(parseLoginFragment('lt=xyz789')).toEqual({ token: 'xyz789' });
  });

  it('preserves a token that contains url-safe base64 chars', () => {
    const tok = 'A1b2-C3d4_E5f6.g7';
    expect(parseLoginFragment(`#lt=${tok}`)).toEqual({ token: tok });
  });

  it('ignores any extra params (only lt is read)', () => {
    expect(parseLoginFragment('#lt=tok&foo=bar')).toEqual({ token: 'tok' });
  });

  it('reads lt regardless of param order', () => {
    expect(parseLoginFragment('#foo=bar&lt=tok')).toEqual({ token: 'tok' });
  });
});

describe('parseLoginFragment — null cases (render the friendly state)', () => {
  it('returns null for an empty hash', () => {
    expect(parseLoginFragment('')).toBeNull();
    expect(parseLoginFragment('#')).toBeNull();
  });

  it('returns null when the token param is missing', () => {
    expect(parseLoginFragment('#t=jwt')).toBeNull();
    expect(parseLoginFragment('#foo=bar')).toBeNull();
  });

  it('returns null for an empty token value', () => {
    expect(parseLoginFragment('#lt=')).toBeNull();
  });
});
