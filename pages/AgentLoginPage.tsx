// pages/AgentLoginPage.tsx
//
// The /agent-login route (P4 / Slice B2) — the agent-initiated web login that
// binds the texter's phone to their Spool account.
//
// The iMessage agent "Chris" texts an UNLINKED user a rich link:
//   https://rankspool.com/agent-login#lt=<token>
// The token is single-use, ~15-min TTL, minted agent-side into hana.login_links
// against the SENDER phone. Tapping it opens REAL Safari (the rich link, per the
// P4 owner decision), so every auth method works.
//
// Flow:
//   1. Read location.hash → { token } via parseLoginFragment; stash the token in
//      sessionStorage (survives the Google OAuth round-trip) and strip the hash
//      from the address bar so the token never lingers (mirrors AgentRankPage).
//      On return from /auth/callback the fragment is gone, so we fall back to the
//      stashed token.
//   2. If a session already exists (already signed in on this browser, or the
//      Google round-trip just completed) → skip straight to consume.
//   3. Otherwise render the app's EXISTING auth surface (AuthPage) with
//      redirectTo="/agent-login" so email/password success returns here; Google
//      OAuth returns via /auth/callback, which routes back here when it sees the
//      stashed token. All auth methods AuthPage supports work unchanged.
//   4. On session → consumeLoginToken calls the agent-link edge function
//      { action: 'consume-login-token', token } under the user's JWT, which
//      binds phone ↔ auth.uid() in hana.agent_links and marks the token used.
//   5. States: loading | auth (AuthPage) | success | expired | error. Mobile-
//      first (the page opens in Safari from an iMessage tap).
//
// The fragment parse + consume wiring are pure modules (services/agentLogin*),
// so this file is a thin state machine over them.
//
// Header last reviewed: 2026-07-12

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useAuth } from '../contexts/AuthContext';
import { useTranslation } from '../contexts/LanguageContext';
import { supabase } from '../lib/supabase';
import AuthPage from './AuthPage';
import { parseLoginFragment } from '../services/agentLoginFragment';
import { consumeLoginToken } from '../services/agentLoginConsume';
import {
  clearAgentLoginToken,
  readAgentLoginToken,
  stashAgentLoginToken,
} from '../services/agentLoginToken';

type Phase =
  | { kind: 'loading' }
  | { kind: 'auth' }
  | { kind: 'consuming' }
  | { kind: 'success' }
  | { kind: 'expired' }
  | { kind: 'error' };

const Spinner = () => (
  <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
);

const FullScreen: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div className="min-h-screen bg-background text-foreground flex items-center justify-center p-6">
    <div className="w-full max-w-sm text-center flex flex-col items-center gap-4">
      {children}
    </div>
  </div>
);

const AgentLoginPage: React.FC = () => {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [phase, setPhase] = useState<Phase>({ kind: 'loading' });
  const [token, setToken] = useState<string | null>(null);
  const consumedRef = useRef(false);

  // ── Bootstrap: parse the fragment (or recover the stashed token), strip it ───
  useEffect(() => {
    const parsed = parseLoginFragment(window.location.hash);
    const nextToken = parsed?.token ?? readAgentLoginToken();

    if (parsed?.token) {
      stashAgentLoginToken(parsed.token);
    }

    // Strip the fragment so the token never lingers in history, regardless of
    // whether it parsed. Guarded for non-browser / test contexts.
    try {
      if (window.location.hash) {
        window.history.replaceState(
          null,
          '',
          window.location.pathname + window.location.search,
        );
      }
    } catch {
      /* no-op */
    }

    if (!nextToken) {
      setPhase({ kind: 'expired' });
      return;
    }
    setToken(nextToken);
    // If already signed in, go straight to consume; else show the auth surface.
    setPhase(user ? { kind: 'consuming' } : { kind: 'auth' });
    // Read the fragment exactly once on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── When a session appears while we're on the auth surface → consume ─────────
  useEffect(() => {
    if (!token) return;
    if (user && (phase.kind === 'auth' || phase.kind === 'loading')) {
      setPhase({ kind: 'consuming' });
    }
  }, [user, token, phase.kind]);

  // ── Run the consume call once, in the consuming phase ────────────────────────
  const runConsume = useCallback(async (activeToken: string) => {
    if (consumedRef.current) return;
    consumedRef.current = true;
    const result = await consumeLoginToken(supabase, activeToken);
    clearAgentLoginToken();
    if (result.status === 'linked') {
      setPhase({ kind: 'success' });
    } else if (result.status === 'expired') {
      setPhase({ kind: 'expired' });
    } else {
      setPhase({ kind: 'error' });
    }
  }, []);

  useEffect(() => {
    if (phase.kind === 'consuming' && token) {
      void runConsume(token);
    }
  }, [phase.kind, token, runConsume]);

  // ── Render ───────────────────────────────────────────────────────────────────
  if (phase.kind === 'auth') {
    return <AuthPage redirectTo="/agent-login" />;
  }

  if (phase.kind === 'success') {
    return (
      <FullScreen>
        <h1 className="text-2xl font-bold">{t('agentLogin.successTitle')}</h1>
        <p className="text-foreground">{t('agentLogin.successBody')}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'expired') {
    return (
      <FullScreen>
        <h1 className="text-xl font-bold">{t('agentLogin.title')}</h1>
        <p className="text-muted-foreground">{t('agentLogin.expired')}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'error') {
    return (
      <FullScreen>
        <h1 className="text-xl font-bold">{t('agentLogin.title')}</h1>
        <p className="text-muted-foreground">{t('agentLogin.error')}</p>
      </FullScreen>
    );
  }

  // loading / consuming
  return (
    <FullScreen>
      <Spinner />
      <p className="text-muted-foreground text-sm">{t('agentLogin.loading')}</p>
    </FullScreen>
  );
};

export default AgentLoginPage;
