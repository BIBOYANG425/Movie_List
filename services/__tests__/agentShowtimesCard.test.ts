import { describe, it, expect } from 'vitest';
import {
  buildShowtimesView,
  formatDistance,
  formatAsOfTime,
  formatAsOfDate,
  formatRuntime,
  formatFilmMeta,
  formatDisplayFormat,
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
    // No showings on the fixture → a single header-less flat section.
    const sections = view.cinemas[0].films[0].sections;
    expect(sections).toHaveLength(1);
    expect(sections[0].label).toBeNull();
    const chips = sections[0].chips;
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
    expect(films[0].sections[0].chips[0].href).toBe(`${FANDANGO}Alpha`);
    expect(films[1].sections[0].chips[0].href).toBe(`${FANDANGO}Beta`);
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

describe('formatRuntime', () => {
  it('formats whole minutes as "H HR MM MIN"', () => {
    expect(formatRuntime(115)).toBe('1 HR 55 MIN');
    expect(formatRuntime(60)).toBe('1 HR');
    expect(formatRuntime(45)).toBe('45 MIN');
    expect(formatRuntime(120)).toBe('2 HR');
    expect(formatRuntime(125)).toBe('2 HR 5 MIN');
  });

  it('returns null for missing, zero, or non-finite runtimes', () => {
    expect(formatRuntime(undefined)).toBeNull();
    expect(formatRuntime(null)).toBeNull();
    expect(formatRuntime(0)).toBeNull();
    expect(formatRuntime(-30)).toBeNull();
    expect(formatRuntime(Number.NaN)).toBeNull();
  });
});

describe('formatFilmMeta', () => {
  it('joins runtime and rating with a spaced bar', () => {
    expect(formatFilmMeta({ runtimeMinutes: 115, rating: 'PG' })).toBe('1 HR 55 MIN | PG');
  });

  it('omits the missing piece', () => {
    expect(formatFilmMeta({ runtimeMinutes: 115 })).toBe('1 HR 55 MIN');
    expect(formatFilmMeta({ rating: 'R' })).toBe('R');
  });

  it('returns null when both runtime and rating are absent', () => {
    expect(formatFilmMeta({})).toBeNull();
    expect(formatFilmMeta(null)).toBeNull();
    expect(formatFilmMeta({ rating: '   ' })).toBeNull();
  });
});

describe('formatDisplayFormat', () => {
  it('maps known and unknown format strings to uppercase display labels', () => {
    expect(formatDisplayFormat('Standard')).toBe('STANDARD');
    expect(formatDisplayFormat('IMAX')).toBe('IMAX');
    expect(formatDisplayFormat('Dolby Atmos')).toBe('DOLBY CINEMA');
    expect(formatDisplayFormat('Dolby Cinema')).toBe('DOLBY CINEMA');
    expect(formatDisplayFormat('ScreenX')).toBe('SCREENX');
    expect(formatDisplayFormat('3D')).toBe('3D');
  });
});

describe('buildShowtimesView — hero metadata', () => {
  it('exposes a runtime + rating hero line for an anchored film', () => {
    const view = buildShowtimesView(
      singleFilmPayload({
        film: { title: 'Dune: Part Two', movieGluId: 100, runtimeMinutes: 115, rating: 'PG-13' },
      }),
    );
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.filmMeta).toBe('1 HR 55 MIN | PG-13');
  });

  it('omits the hero line when the film has neither runtime nor rating', () => {
    const view = buildShowtimesView(
      singleFilmPayload({ film: { title: 'Dune: Part Two', movieGluId: 100 } }),
    );
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.filmMeta).toBeNull();
  });

  it('has a null hero line for a "what\'s nearby" (film null) card', () => {
    const view = buildShowtimesView(singleFilmPayload({ film: null }));
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    expect(view.filmMeta).toBeNull();
  });
});

describe('buildShowtimesView — cinema address', () => {
  it('carries a trimmed address when present, else null', () => {
    const withAddr = buildShowtimesView(
      singleFilmPayload({ cinemas: [cinema({ address: '  10250 Santa Monica Blvd  ' })] }),
    );
    if (withAddr.kind !== 'loaded') throw new Error('expected loaded');
    expect(withAddr.cinemas[0].address).toBe('10250 Santa Monica Blvd');

    const noAddr = buildShowtimesView(singleFilmPayload());
    if (noAddr.kind !== 'loaded') throw new Error('expected loaded');
    expect(noAddr.cinemas[0].address).toBeNull();
  });
});

describe('buildShowtimesView — format sections', () => {
  it('groups showings into one section per format in payload order', () => {
    const payload = singleFilmPayload({
      cinemas: [
        cinema({
          films: [
            {
              movieGluId: 100,
              title: 'Dune: Part Two',
              // flat times still present (superset) but showings drive the sections.
              times: [{ start: 's0', label: '6:00 PM' }],
              showings: [
                {
                  format: 'IMAX',
                  times: [{ start: 's1', label: '7:30 PM' }],
                },
                {
                  format: 'Dolby Atmos',
                  times: [
                    { start: 's2', label: '8:00 PM' },
                    { start: 's3', label: '10:15 PM' },
                  ],
                },
                {
                  format: 'Standard',
                  times: [{ start: 's4', label: '9:00 PM' }],
                },
              ],
            },
          ],
        }),
      ],
    });
    const view = buildShowtimesView(payload);
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    const sections = view.cinemas[0].films[0].sections;
    expect(sections.map((s) => s.label)).toEqual(['IMAX', 'DOLBY CINEMA', 'STANDARD']);
    expect(sections[1].chips.map((c) => c.label)).toEqual(['8:00 PM', '10:15 PM']);
    // chips still link to the film's own Fandango search.
    expect(sections[0].chips[0].href).toBe(`${FANDANGO}Dune%3A%20Part%20Two`);
  });

  it('falls back to a single header-less flat section for old payloads (no showings)', () => {
    const view = buildShowtimesView(singleFilmPayload());
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    const sections = view.cinemas[0].films[0].sections;
    expect(sections).toHaveLength(1);
    expect(sections[0].label).toBeNull();
    expect(sections[0].chips.map((c) => c.label)).toEqual(['7:30 PM', '10:00 PM']);
  });

  it('falls back to flat times when showings is an empty array', () => {
    const view = buildShowtimesView(
      singleFilmPayload({
        cinemas: [
          cinema({
            films: [
              {
                movieGluId: 100,
                title: 'Dune: Part Two',
                times: [{ start: 's1', label: '7:30 PM' }],
                showings: [],
              },
            ],
          }),
        ],
      }),
    );
    if (view.kind !== 'loaded') throw new Error('expected loaded');
    const sections = view.cinemas[0].films[0].sections;
    expect(sections).toHaveLength(1);
    expect(sections[0].label).toBeNull();
    expect(sections[0].chips.map((c) => c.label)).toEqual(['7:30 PM']);
  });
});

describe('formatAsOfDate', () => {
  it('formats a valid ISO timestamp to a weekday + short date', () => {
    // Shape only — the runner's timezone can shift the weekday/day.
    const out = formatAsOfDate('2026-07-13T19:30:00Z', 'en-US');
    expect(out).toMatch(/^[A-Za-z]{3},\s[A-Za-z]{3}\s\d{1,2}$/);
  });

  it('returns null for a falsy or invalid timestamp', () => {
    expect(formatAsOfDate('', 'en-US')).toBeNull();
    expect(formatAsOfDate('not-a-date', 'en-US')).toBeNull();
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
