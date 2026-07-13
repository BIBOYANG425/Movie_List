import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createCeremonyDriver, CeremonyStep } from '../../hooks/useRankingCeremony';
import { SessionChoice } from '../rankingSession';
import { Tier, RankedItem } from '../../types';

// PARITY GUARANTEE for the /agent-rank route.
//
// The defect: the /agent-rank ceremony must run the EXACT same head-to-head
// placement loop the main webapp runs — not a fork with fewer/odd comparisons.
// The fix routes BOTH surfaces through the single shared ceremony driver
// (useRankingCeremony / createCeremonyDriver). These tests lock that:
//   1. Given a seeded tier list + a FIXED choice sequence, the main-flow driver
//      (with comparison logging, as AddMediaModal wires it) and the agent-flow
//      driver (no logging, as AgentRankPage → RankingFlowModal wires it) place
//      the film at the IDENTICAL rank, step-for-step.
//   2. Structurally, neither modal instantiates its own RankingSession — the
//      only ranking engine either can reach is the shared driver.

const GENRES = ['Drama', 'Action', 'Comedy', 'Horror', 'Sci-Fi'];

function mkItem(i: number, tier: Tier): RankedItem {
  return {
    id: `m${i}`,
    title: `Movie ${i}`,
    genres: [GENRES[i % GENRES.length]],
    tier,
    rank: i,
    globalScore: 5 + (i % 5),
  } as RankedItem;
}

const mkTier = (tier: Tier, count: number): RankedItem[] =>
  Array.from({ length: count }, (_, i) => mkItem(i, tier));

const film = (): RankedItem =>
  ({ id: 'the-film', title: 'The Film', genres: ['Drama'], tier: Tier.A, rank: 0, globalScore: 7.5 } as RankedItem);

/** Drive one ceremony to completion with a fixed choice sequence; capture the
 *  full comparison trace + final rank. This is exactly what a modal does. */
function runCeremony(
  item: RankedItem,
  tier: Tier,
  allItems: RankedItem[],
  choices: SessionChoice[],
  withLogging: boolean,
): { trace: string[]; rank: number } {
  const logs: string[] = [];
  const driver = createCeremonyDriver(
    withLogging
      ? {
          newSessionId: () => 'fixed-run',
          onCompare: (l) => logs.push(`log:${l.movieBId}:${l.winner}`),
          getLogContext: () => ({ item, tier }),
        }
      : undefined,
  );

  const trace: string[] = [];
  let step: CeremonyStep = driver.begin(item, tier, allItems);
  let i = 0;
  while (step.kind === 'compare') {
    trace.push(`${step.comparison.round}:${step.comparison.phase}:${step.comparison.movieB.id}`);
    if (i >= choices.length) throw new Error(`ran out of choices at step ${i}`);
    step = driver.choose(choices[i++]);
  }
  if (step.kind !== 'placed') throw new Error('ceremony did not place the film');
  // Logging is a side channel; it must not perturb the trace or the rank.
  if (withLogging) expect(logs.length).toBe(trace.length);
  return { trace, rank: step.rank };
}

describe('agent-rank ↔ main-flow ceremony parity', () => {
  const scenarios: { name: string; count: number; choices: SessionChoice[] }[] = [
    { name: 'small tier (3), new keeps winning', count: 3, choices: ['new', 'new', 'new'] },
    { name: 'small tier (3), existing then new', count: 3, choices: ['existing', 'new'] },
    { name: 'seed tier (8), mixed choices', count: 8, choices: ['existing', 'new', 'existing', 'new', 'existing'] },
    { name: 'seed tier (12), too_tough finalizes', count: 12, choices: ['existing', 'too_tough'] },
    { name: 'engine tier (25), new-heavy', count: 25, choices: Array(40).fill('new') },
  ];

  for (const s of scenarios) {
    it(`places identically for both drivers — ${s.name}`, () => {
      const seeded = mkTier(Tier.A, s.count);
      const mainFlow = runCeremony(film(), Tier.A, seeded, s.choices, true);
      const agentFlow = runCeremony(film(), Tier.A, seeded, s.choices, false);

      // Same comparison sequence, step for step.
      expect(agentFlow.trace).toEqual(mainFlow.trace);
      // Same final placement.
      expect(agentFlow.rank).toBe(mainFlow.rank);
      // A real placement index within the tier.
      expect(agentFlow.rank).toBeGreaterThanOrEqual(0);
      expect(agentFlow.rank).toBeLessThanOrEqual(s.count);
    });
  }
});

describe('no forked engine — modals reach ranking only via the shared driver', () => {
  const read = (rel: string) => readFileSync(resolve(__dirname, rel), 'utf8');

  it('AddMediaModal (main flow) consumes useRankingCeremony and never news RankingSession', () => {
    const src = read('../../components/media/AddMediaModal.tsx');
    expect(src).toContain("from '../../hooks/useRankingCeremony'");
    expect(src).not.toMatch(/new\s+RankingSession/);
  });

  it('RankingFlowModal (agent + book flow) consumes useRankingCeremony and never news RankingSession', () => {
    const src = read('../../components/media/RankingFlowModal.tsx');
    expect(src).toContain("from '../../hooks/useRankingCeremony'");
    expect(src).not.toMatch(/new\s+RankingSession/);
  });

  it('AgentRankPage drives the ceremony through the shared RankingFlowModal', () => {
    const src = read('../../pages/AgentRankPage.tsx');
    expect(src).toContain('RankingFlowModal');
    expect(src).not.toMatch(/new\s+RankingSession/);
  });
});
