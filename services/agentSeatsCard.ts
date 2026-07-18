// services/agentSeatsCard.ts
//
// Pure view model + helpers for the /agent-seats seat-hold card (seat hunt).
// The agent (spool-agent) INSERTs a `hunting` row and PATCHes it as its headful
// browser drives AMC checkout; this card reads the row and polls while the
// status is non-terminal, re-rendering as the hunt lands.
//
// Payload is the versioned seatHoldPayloadV1 the agent writes (kept in sync
// with packages/plugins/spool/src/services/seat-hold-card.ts). This module is
// pure (no window, no fetch, no supabase) so it is unit-testable in node.
//
// Header last reviewed: 2026-07-18

export type SeatHoldStatus =
  | 'hunting'
  | 'held'
  | 'awaiting_payment'
  | 'paid'
  | 'expired'
  | 'failed';

export const TERMINAL_SEAT_HOLD_STATUSES: readonly SeatHoldStatus[] = ['paid', 'expired', 'failed'];

export function isTerminalStatus(status: SeatHoldStatus): boolean {
  return TERMINAL_SEAT_HOLD_STATUSES.includes(status);
}

export interface SeatHoldFilm {
  title: string;
  showtimeStart: string;
  cinemaName: string;
  format?: string;
}

export interface SeatHoldPayloadV1 {
  v: 1;
  status: SeatHoldStatus;
  film: SeatHoldFilm;
  partySize: number;
  seats?: string[];
  split?: boolean;
  totalPrice?: string;
  purchaseUrl?: string;
  holdExpiresAt?: string;
  confirmationNumber?: string;
  failureReason?: string;
  deepLinkFallback: string;
  updatedAt: string;
}

/** The view the page renders. `kind` drives the top-level layout. */
export interface SeatsView {
  status: SeatHoldStatus;
  title: string;
  /** "Fri, Jul 18 • 7:00 PM • Dolby Cinema • AMC The Grove 14" */
  showtimeLabel: string;
  partySize: number;
  seats: string[];
  split: boolean;
  totalPrice: string | null;
  purchaseUrl: string | null;
  holdExpiresAt: string | null;
  confirmationNumber: string | null;
  deepLinkFallback: string;
  /** True while the page should keep polling. */
  polling: boolean;
}

/** Format the showtime + cinema context line for the header. */
export function formatShowtimeLabel(film: SeatHoldFilm, locale = 'en-US'): string {
  const parts: string[] = [];
  const d = new Date(film.showtimeStart);
  if (!Number.isNaN(d.getTime())) {
    parts.push(
      new Intl.DateTimeFormat(locale, { weekday: 'short', month: 'short', day: 'numeric' }).format(d),
    );
    parts.push(new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(d));
  }
  if (film.format) parts.push(film.format);
  parts.push(film.cinemaName);
  return parts.filter(Boolean).join(' • ');
}

export function buildSeatsView(payload: SeatHoldPayloadV1, locale = 'en-US'): SeatsView {
  return {
    status: payload.status,
    title: payload.film.title,
    showtimeLabel: formatShowtimeLabel(payload.film, locale),
    partySize: payload.partySize,
    seats: payload.seats ?? [],
    split: payload.split ?? false,
    totalPrice: payload.totalPrice ?? null,
    purchaseUrl: payload.purchaseUrl ?? null,
    holdExpiresAt: payload.holdExpiresAt ?? null,
    confirmationNumber: payload.confirmationNumber ?? null,
    deepLinkFallback: payload.deepLinkFallback,
    polling: !isTerminalStatus(payload.status),
  };
}

/**
 * Remaining hold time as mm:ss, or null when there is no deadline or it has
 * passed. `nowMs` is injected so the countdown is testable.
 */
export function formatCountdown(holdExpiresAt: string | null, nowMs: number): string | null {
  if (!holdExpiresAt) return null;
  const end = new Date(holdExpiresAt).getTime();
  if (Number.isNaN(end)) return null;
  const remaining = Math.floor((end - nowMs) / 1000);
  if (remaining <= 0) return null;
  const m = Math.floor(remaining / 60);
  const s = remaining % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}
