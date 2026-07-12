// pages/AgentShowtimesPage.tsx
//
// The /agent-showtimes route (S2b) — the showtimes card that opens INSIDE
// iMessage via a Photon mini-app card. Unlike /agent-rank, this route carries
// NO JWT: showtimes are PUBLIC data, so it reads one unexpired row of the card
// payload with the anon supabase client.
//
// Flow:
//   1. Read location.hash → { cardId } via parseShowtimesFragment.
//   2. anon `agent_showtimes_cards.select('payload, expires_at').eq('id', id)
//      .maybeSingle()`. RLS only returns rows with expires_at > now(), so a
//      missing OR expired row both come back null → friendly "expired" state.
//   3. buildShowtimesView(payload) → a pure view model; an empty cinemas array
//      collapses to the "nothing showing near you" empty state.
//   4. Render mobile-first: header (film title or "what's playing near you") +
//      subline (location label + "times as of <local>"), then cinemas sorted by
//      distance, each a card of films → rows of tappable time chips that link
//      out to Fandango via lib/ticketLinkout.ts. Single-film cards skip the
//      per-cinema film header (it would just repeat the page header).
//
// Pure logic (fragment parse, view derivation, distance/time formatting) lives
// in services/agentShowtimesCard.ts + services/agentShowtimesFragment.ts so it
// is unit-testable in the node test env; this file is a thin JSX map over it.
//
// Header last reviewed: 2026-07-12

import React, { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useTranslation } from '../contexts/LanguageContext';
import { parseShowtimesFragment } from '../services/agentShowtimesFragment';
import {
  buildShowtimesView,
  formatAsOfTime,
  type ShowtimesCardPayloadV1,
  type ShowtimesView,
} from '../services/agentShowtimesCard';

type Phase =
  | { kind: 'loading' }
  | { kind: 'error' }
  | { kind: 'loaded'; view: ShowtimesView };

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

const AgentShowtimesPage: React.FC = () => {
  const { t, locale } = useTranslation();
  const [phase, setPhase] = useState<Phase>({ kind: 'loading' });

  const timeLocale = useMemo(() => (locale === 'zh' ? 'zh-CN' : 'en-US'), [locale]);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      const parsed = parseShowtimesFragment(window.location.hash);
      if (!parsed) {
        if (!cancelled) setPhase({ kind: 'error' });
        return;
      }

      const { data, error } = await supabase
        .from('agent_showtimes_cards')
        .select('payload, expires_at')
        .eq('id', parsed.cardId)
        .maybeSingle();

      if (cancelled) return;

      // RLS hides expired rows, so missing OR expired both land here as null.
      if (error || !data?.payload) {
        setPhase({ kind: 'error' });
        return;
      }

      const view = buildShowtimesView(data.payload as ShowtimesCardPayloadV1);
      setPhase({ kind: 'loaded', view });
    })();

    return () => {
      cancelled = true;
    };
    // Run once on mount — the fragment is read a single time.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (phase.kind === 'loading') {
    return (
      <FullScreen>
        <Spinner />
        <p className="text-muted-foreground text-sm">{t('agentShowtimes.loading')}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'error') {
    return (
      <FullScreen>
        <p className="text-muted-foreground">{t('agentShowtimes.expired')}</p>
      </FullScreen>
    );
  }

  const { view } = phase;

  if (view.kind === 'empty') {
    return (
      <FullScreen>
        <p className="text-muted-foreground">{t('agentShowtimes.empty')}</p>
      </FullScreen>
    );
  }

  const heading = view.filmTitle
    ? `${t('agentShowtimes.title')} ${view.filmTitle}`
    : t('agentShowtimes.nearbyHeading');

  const asOfLabel = formatAsOfTime(view.asOf, timeLocale);
  const subParts = [
    view.locationLabel,
    asOfLabel ? t('agentShowtimes.asOf').replace('{time}', asOfLabel) : null,
  ].filter((p): p is string => Boolean(p));

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="w-full max-w-md mx-auto px-4 py-6 flex flex-col gap-5">
        {/* Header */}
        <header className="flex flex-col gap-2">
          {view.poster && (
            <img
              src={view.poster}
              alt={view.filmTitle ?? ''}
              className="w-24 aspect-[2/3] object-cover rounded-xl shadow-lg"
            />
          )}
          <h1 className="text-2xl font-bold leading-tight">{heading}</h1>
          {subParts.length > 0 && (
            <p className="text-muted-foreground text-sm">{subParts.join(' · ')}</p>
          )}
        </header>

        {/* Cinemas */}
        <div className="flex flex-col gap-4">
          {view.cinemas.map((cinema) => (
            <section
              key={cinema.cinemaId}
              className="bg-card rounded-2xl p-4 flex flex-col gap-3"
            >
              <div className="flex items-baseline justify-between gap-3">
                <h2 className="text-lg font-semibold leading-tight">{cinema.name}</h2>
                {cinema.distanceLabel && (
                  <span className="text-muted-foreground text-sm whitespace-nowrap">
                    {cinema.distanceLabel}
                  </span>
                )}
              </div>

              {cinema.films.map((film) => (
                <div key={film.movieGluId} className="flex flex-col gap-2">
                  {!view.singleFilm && (
                    <h3 className="text-base font-medium text-foreground/90">
                      {film.title}
                    </h3>
                  )}
                  <div className="flex flex-wrap gap-2">
                    {film.chips.map((chip) => (
                      <a
                        key={`${film.movieGluId}-${chip.start}`}
                        href={chip.href}
                        target="_blank"
                        rel="noopener"
                        className="px-3 py-2 rounded-full bg-secondary text-secondary-foreground text-sm font-medium active:scale-[0.97] transition-transform"
                      >
                        {chip.label}
                      </a>
                    ))}
                  </div>
                </div>
              ))}
            </section>
          ))}
        </div>
      </div>
    </div>
  );
};

export default AgentShowtimesPage;
