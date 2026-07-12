import { describe, it, expect } from 'vitest';
import {
  buildShowtimesView,
  formatDistance,
  formatAsOfTime,
  sortCinemasByDistance,
  type ShowtimesCardPayloadV1,
  type CinemaV1,
} from '../agentShowtimesCard';

// The /agent-showtimes card view model (S2b). The web page is a thin JSX map
// over buildShowtimesView, so these tests ARE the render coverage in the node
// test env: cinema names, distance format, chips (labels + linkout hrefs),
// single-film header elision, and the empty-cinemas → empty-state branch.

const FANDANGO = 'https://www.fandango.com/search?q=';

function cinema(over: Partial<CinemaV1> = {}): CinemaV1 {
  return {
    cinemaId: 1,
    name: 'AMC Century City',
    distance: 2.34,
    films: [
      {
        movieGluId: 100,
        title: 'Dune: Part Two',
        times: [
          { start: '2026-07-12T19:30:00-07:00', label: '7:30 PM' },
          { start: '2026-07-12T22:00:00-07:00', label: '10:00 PM' },
        ],
      },
    ],
    ...over,
  };
}

function singleFilmPayload(over: Partial<ShowtimesCardPayloadV1> = {}): ShowtimesCardPayloadV1 {
  return {
    v: 1,
    asOf: '2026-07-12T18:00:00-07:00',
    territory: 'US',
    location: { lat: 34.05, lng: -118.42, label: 'Century City' },
    film: { title: 'Dune: Part Two', movieGluId: 100, poster: 'https://img/poster.jpg' },
    cinemas: [cinema()],
    ...over,
  };
}

describe('formatDistance', () => {
  it('formats miles to one decimal with a "mi" unit', () => {
    expect(formatDistance(2.34)).toBe('2.3 mi');
    expect(formatDistance(3)).toBe('3.0 mi');
    expect(formatDistance(0)).toBe('0.0 mi');
  });

  it('returns null for an unknown (null) distance', () => {
    expect(formatDistance(null)).toBeNull();
  });

  it('returns null for a non-finite distance', () => {
    expect(formatDistance(Number.NaN)).toBeNull();
    expect(formatDistance(Number.POSITIVE_INFINITY)).toBeNull();
  });
});

describe('sortCinemasByDistance', () => {
  it('sorts ascending with null distances last, stable for ties', () => {
    const a = cinema({ cinemaId: 1, name: 'A', distance: 5 });
    const b = cinema({ cinemaId: 2, name: 'B', distance: null });
    const c = cinema({ cinemaId: 3, name: 'C', distance: 1.2 });
    const d = cinema({ cinemaId: 4, name: 'D', distance: null });
    const sorted = sortCinemasByDistance([a, b, c, d]).map((x) => x.name);
    expect(sorted).toEqual(['C', 'A', 'B', 'D']);
  });

  it('does not mutate the input array', () => {
    const input = [cinema({ cinemaId: 1, distance: 9 }), cinema({ cinemaId: 2, distance: 1 })];
    const copy = [...input];
    sortCinemasByDistance(input);
    expect(input).toEqual(copy);
  });
});

describe('buildShowtimesView — single-film card', () => {
  it('exposes the film title and elides per-cinema film headers', () => {
    const view = buildShowtimesView(singleFilmPayload());
    expect(view.kind).toBe('loaded');
    if (view.kind !== 'loaded') return;
    expect(view.filmTitle).toBe('Dune: Part Two');
    expect(view.singleFilm).toBe(true);
    expect(view.poster).toBe('https://img/poster.jpg');
    expect(view.locationLabel).toBe('Century City');
  });

  it('renders cinema name and formatted distance', () => {
    const view = buildShowtimesView(singleFilmPayload());
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.cinemas[0].name).toBe('AMC Century City');
    expect(view.cinemas[0].distanceLabel).toBe('2.3 mi');
  });

  it('builds time chips with labels and Fandango linkout hrefs', () => {
    const view = buildShowtimesView(singleFilmPayload());
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    const chips = view.cinemas[0].films[0].chips;
    expect(chips.map((c) => c.label)).toEqual(['7:30 PM', '10:00 PM']);
    expect(chips[0].href).toBe(`${FANDANGO}Dune%3A%20Part%20Two`);
    expect(chips[1].href).toBe(`${FANDANGO}Dune%3A%20Part%20Two`);
  });

  it('carries a null distanceLabel when the cinema distance is null', () => {
    const view = buildShowtimesView(
      singleFilmPayload({ cinemas: [cinema({ distance: null })] }),
    );
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.cinemas[0].distanceLabel).toBeNull();
  });
});

describe('buildShowtimesView — "what\'s nearby" card (film null)', () => {
  it('has no filmTitle and keeps per-cinema film headers (singleFilm false)', () => {
    const view = buildShowtimesView(singleFilmPayload({ film: null }));
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.filmTitle).toBeNull();
    expect(view.singleFilm).toBe(false);
    expect(view.poster).toBeNull();
  });

  it('links each film chip to that film\'s own Fandango search', () => {
    const payload = singleFilmPayload({
      film: null,
      cinemas: [
        cinema({
          films: [
            { movieGluId: 1, title: 'Alpha', times: [{ start: 's1', label: '1:00 PM' }] },
            { movieGluId: 2, title: 'Beta', times: [{ start: 's2', label: '2:00 PM' }] },
          ],
        }),
      ],
    });
    const view = buildShowtimesView(payload);
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    const films = view.cinemas[0].films;
    expect(films[0].chips[0].href).toBe(`${FANDANGO}Alpha`);
    expect(films[1].chips[0].href).toBe(`${FANDANGO}Beta`);
  });

  it('sorts cinemas by distance (nulls last) in the built view', () => {
    const payload = singleFilmPayload({
      film: null,
      cinemas: [
        cinema({ cinemaId: 1, name: 'Far', distance: 8 }),
        cinema({ cinemaId: 2, name: 'Unknown', distance: null }),
        cinema({ cinemaId: 3, name: 'Near', distance: 0.5 }),
      ],
    });
    const view = buildShowtimesView(payload);
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.cinemas.map((c) => c.name)).toEqual(['Near', 'Far', 'Unknown']);
  });
});

describe('buildShowtimesView — empty state', () => {
  it('collapses an empty cinemas array to the empty state', () => {
    expect(buildShowtimesView(singleFilmPayload({ cinemas: [] }))).toEqual({ kind: 'empty' });
  });
});

describe('formatAsOfTime', () => {
  it('formats a valid ISO timestamp to a short local time', () => {
    // The exact clock value depends on the runner's timezone, so assert the
    // shape ("<h>:<mm> AM/PM" for en-US) rather than a fixed hour.
    const out = formatAsOfTime('2026-07-12T19:30:00Z', 'en-US');
    expect(out).toMatch(/^\d{1,2}:\d{2}\s?(AM|PM)$/);
  });

  it('returns null for a falsy or invalid timestamp', () => {
    expect(formatAsOfTime('', 'en-US')).toBeNull();
    expect(formatAsOfTime('not-a-date', 'en-US')).toBeNull();
  });
});
