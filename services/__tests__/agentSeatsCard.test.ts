import { describe, it, expect } from 'vitest';
import { parseSeatsFragment } from '../agentSeatsFragment';
import {
  buildSeatsView,
  formatCountdown,
  formatShowtimeLabel,
  isTerminalStatus,
  type SeatHoldPayloadV1,
} from '../agentSeatsCard';

const UUID = '11111111-2222-4333-8444-555555555555';

const payload = (over: Partial<SeatHoldPayloadV1> = {}): SeatHoldPayloadV1 => ({
  v: 1,
  status: 'held',
  film: { title: 'The Odyssey', showtimeStart: '2026-07-18T19:00:00', cinemaName: 'AMC The Grove 14', format: 'Dolby Cinema' },
  partySize: 2,
  seats: ['F10', 'F11'],
  totalPrice: '$48.36',
  purchaseUrl: 'https://www.amctheatres.com/orders/abc/purchase',
  holdExpiresAt: '2026-07-18T18:12:00.000Z',
  deepLinkFallback: 'https://www.amctheatres.com/showtimes/all/2026-07-18/thegrove/all/1',
  updatedAt: '2026-07-18T18:02:00.000Z',
  ...over,
});

describe('parseSeatsFragment', () => {
  it('reads the hold id from #h=<uuid>', () => {
    expect(parseSeatsFragment(`#h=${UUID}`)).toEqual({ holdId: UUID });
    expect(parseSeatsFragment(`h=${UUID}`)).toEqual({ holdId: UUID });
  });
  it('rejects missing / malformed ids', () => {
    expect(parseSeatsFragment('')).toBeNull();
    expect(parseSeatsFragment('#h=')).toBeNull();
    expect(parseSeatsFragment('#h=not-a-uuid')).toBeNull();
    expect(parseSeatsFragment('#c=' + UUID)).toBeNull(); // wrong param
  });
});

describe('isTerminalStatus', () => {
  it('paid/expired/failed are terminal; the rest keep polling', () => {
    expect(['paid', 'expired', 'failed'].every(isTerminalStatus as (s: string) => boolean)).toBe(true);
    expect(['hunting', 'held', 'awaiting_payment'].some(isTerminalStatus as (s: string) => boolean)).toBe(false);
  });
});

describe('formatShowtimeLabel', () => {
  it('joins date, time, format, cinema with bullets', () => {
    const label = formatShowtimeLabel(payload().film);
    expect(label).toContain('Dolby Cinema');
    expect(label).toContain('AMC The Grove 14');
    expect(label).toContain(' • ');
  });
});

describe('buildSeatsView', () => {
  it('held: carries seats, total, purchaseUrl, and keeps polling', () => {
    const v = buildSeatsView(payload());
    expect(v.status).toBe('held');
    expect(v.seats).toEqual(['F10', 'F11']);
    expect(v.totalPrice).toBe('$48.36');
    expect(v.purchaseUrl).toContain('/purchase');
    expect(v.polling).toBe(true);
  });
  it('paid: stops polling', () => {
    expect(buildSeatsView(payload({ status: 'paid', confirmationNumber: 'ABC123' })).polling).toBe(false);
  });
  it('failed: not polling, deep link retained', () => {
    const v = buildSeatsView(payload({ status: 'failed', failureReason: 'no seats' }));
    expect(v.polling).toBe(false);
    expect(v.deepLinkFallback).toContain('amctheatres.com');
  });
});

describe('formatCountdown', () => {
  const end = '2026-07-18T18:12:00.000Z';
  it('mm:ss remaining', () => {
    expect(formatCountdown(end, Date.parse('2026-07-18T18:07:30.000Z'))).toBe('4:30');
    expect(formatCountdown(end, Date.parse('2026-07-18T18:11:55.000Z'))).toBe('0:05');
  });
  it('null when passed, absent, or malformed', () => {
    expect(formatCountdown(end, Date.parse('2026-07-18T18:12:01.000Z'))).toBeNull();
    expect(formatCountdown(null, Date.now())).toBeNull();
    expect(formatCountdown('not-a-date', Date.now())).toBeNull();
  });
});
