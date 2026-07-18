// pages/AgentSeatsPage.tsx
//
// The /agent-seats route — the seat-hold card that opens INSIDE iMessage via a
// Photon mini-app card. It reads one unexpired agent_seat_holds row (anon
// client, like /agent-showtimes — seats/price/purchase-url are not sensitive)
// and, unlike the other agent cards, POLLS every 5s while the status is
// non-terminal so it re-renders as the agent's headful browser drives the hunt
// (hunting -> held -> paid | expired | failed).
//
// States:
//   hunting          — spinner, "Chris is grabbing your seats…"
//   held             — seat labels, total, a live countdown, and a big
//                      "Pay on your phone →" button that opens the AMC
//                      /orders/{id}/purchase URL (which transfers to the user's
//                      own session — confirmed 2026-07-18) via openTicketUrl.
//   awaiting_payment — same as held with a "finish in the tab you opened" note.
//   paid             — confirmation number.
//   expired/failed   — reason + a "grab them yourself" deep-link button.
//
// Pure logic (fragment parse, view derivation, countdown) lives in
// services/agentSeatsCard.ts + services/agentSeatsFragment.ts; this file is a
// thin JSX map + the poll loop.
//
// Header last reviewed: 2026-07-18

import React, { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useTranslation } from '../contexts/LanguageContext';
import { parseSeatsFragment } from '../services/agentSeatsFragment';
import {
  buildSeatsView,
  formatCountdown,
  type SeatHoldPayloadV1,
  type SeatsView,
} from '../services/agentSeatsCard';

type Phase = { kind: 'loading' } | { kind: 'error' } | { kind: 'loaded'; view: SeatsView };

const POLL_MS = 5000;

/** Open the purchase URL: popup first, same-frame fallback (webview blocks popups). */
function openPurchase(href: string): void {
  const win = window.open(href, '_blank', 'noopener');
  if (!win) window.location.assign(href);
}

const Spinner = () => (
  <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
);

const FullScreen: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div className="min-h-screen bg-background text-foreground flex items-center justify-center p-6">
    <div className="w-full max-w-sm text-center flex flex-col items-center gap-4">{children}</div>
  </div>
);

const AgentSeatsPage: React.FC = () => {
  const { t, locale } = useTranslation();
  const [phase, setPhase] = useState<Phase>({ kind: 'loading' });
  const [nowMs, setNowMs] = useState<number>(() => Date.now());

  const timeLocale = useMemo(() => (locale === 'zh' ? 'zh-CN' : 'en-US'), [locale]);

  // Load + poll while non-terminal.
  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const parsed = parseSeatsFragment(window.location.hash);
    if (!parsed) {
      setPhase({ kind: 'error' });
      return;
    }

    const tick = async () => {
      const { data, error } = await supabase
        .from('agent_seat_holds')
        .select('payload, expires_at')
        .eq('id', parsed.holdId)
        .maybeSingle();
      if (cancelled) return;

      if (error || !data?.payload) {
        setPhase({ kind: 'error' });
        return;
      }
      const view = buildSeatsView(data.payload as SeatHoldPayloadV1, timeLocale);
      setPhase({ kind: 'loaded', view });
      setNowMs(Date.now());

      // Keep polling only while the hunt is live and the tab is visible.
      if (view.polling && !document.hidden) {
        timer = setTimeout(tick, POLL_MS);
      }
    };

    void tick();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
    // Run once on mount; the poll loop reschedules itself.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 1s clock so the countdown ticks between polls (only while held).
  useEffect(() => {
    if (phase.kind !== 'loaded' || !phase.view.polling) return;
    const id = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(id);
  }, [phase]);

  if (phase.kind === 'loading') {
    return (
      <FullScreen>
        <Spinner />
        <p className="text-muted-foreground text-sm">{t('agentSeats.loading')}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'error') {
    return (
      <FullScreen>
        <p className="text-muted-foreground">{t('agentSeats.expired')}</p>
      </FullScreen>
    );
  }

  const { view } = phase;
  const countdown = formatCountdown(view.holdExpiresAt, nowMs);

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="w-full max-w-md mx-auto px-4 py-8 flex flex-col gap-6">
        {/* Header */}
        <header className="flex flex-col gap-1">
          <h1 className="text-2xl font-bold leading-tight">{view.title}</h1>
          <p className="text-muted-foreground text-sm">{view.showtimeLabel}</p>
        </header>

        {/* HUNTING */}
        {view.status === 'hunting' && (
          <div className="bg-card rounded-2xl p-6 flex flex-col items-center gap-4 text-center">
            <Spinner />
            <p className="text-foreground/90">
              {t('agentSeats.hunting').replace('{n}', String(view.partySize))}
            </p>
          </div>
        )}

        {/* HELD / AWAITING PAYMENT */}
        {(view.status === 'held' || view.status === 'awaiting_payment') && (
          <div className="bg-card rounded-2xl p-5 flex flex-col gap-4">
            <div className="flex items-baseline justify-between gap-3">
              <span className="text-xs font-bold uppercase tracking-wider text-foreground/70">
                {t('agentSeats.yourSeats')}
              </span>
              {countdown && (
                <span className="text-gold text-sm font-medium tabular-nums">
                  {t('agentSeats.holdCountdown').replace('{time}', countdown)}
                </span>
              )}
            </div>

            <div className="flex flex-wrap gap-2">
              {view.seats.map((s) => (
                <span
                  key={s}
                  className="border border-gold text-gold rounded-full py-1.5 px-4 text-base font-semibold"
                >
                  {s}
                </span>
              ))}
            </div>

            {view.split && (
              <p className="text-muted-foreground text-xs">{t('agentSeats.splitNote')}</p>
            )}

            {view.totalPrice && (
              <div className="flex items-baseline justify-between">
                <span className="text-muted-foreground text-sm">{t('agentSeats.total')}</span>
                <span className="text-xl font-bold">{view.totalPrice}</span>
              </div>
            )}

            {view.purchaseUrl && (
              <button
                type="button"
                onClick={() => openPurchase(view.purchaseUrl!)}
                className="w-full bg-gold text-black rounded-full py-3.5 text-base font-bold active:scale-[0.98] transition-transform"
              >
                {t('agentSeats.payButton')}
              </button>
            )}
            <p className="text-muted-foreground text-xs text-center">
              {t('agentSeats.payNote')}
            </p>
          </div>
        )}

        {/* PAID */}
        {view.status === 'paid' && (
          <div className="bg-card rounded-2xl p-6 flex flex-col gap-3 text-center">
            <p className="text-2xl">🎟️</p>
            <p className="text-foreground/90 font-semibold">{t('agentSeats.paid')}</p>
            <div className="flex flex-wrap gap-2 justify-center">
              {view.seats.map((s) => (
                <span key={s} className="text-gold font-semibold">
                  {s}
                </span>
              ))}
            </div>
            {view.confirmationNumber && (
              <p className="text-muted-foreground text-sm">
                {t('agentSeats.confirmation').replace('{number}', view.confirmationNumber)}
              </p>
            )}
          </div>
        )}

        {/* EXPIRED / FAILED */}
        {(view.status === 'expired' || view.status === 'failed') && (
          <div className="bg-card rounded-2xl p-6 flex flex-col gap-4 text-center">
            <p className="text-foreground/90">
              {view.status === 'expired' ? t('agentSeats.lapsed') : t('agentSeats.failed')}
            </p>
            {view.seats.length > 0 && (
              <p className="text-muted-foreground text-sm">
                {t('agentSeats.tryTheseSeats').replace('{seats}', view.seats.join(', '))}
              </p>
            )}
            <button
              type="button"
              onClick={() => openPurchase(view.deepLinkFallback)}
              className="w-full border border-border rounded-full py-3 text-base font-medium active:scale-[0.98] transition-transform"
            >
              {t('agentSeats.grabYourself')}
            </button>
          </div>
        )}
      </div>
    </div>
  );
};

export default AgentSeatsPage;
