import React, { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { LandingHero } from '../components/landing/LandingHero';
import { FeaturePanel } from '../components/landing/FeaturePanel';
import { PosterMosaic } from '../components/landing/PosterMosaic';
import { LandingCTA } from '../components/landing/LandingCTA';
import { INITIAL_RANKINGS, LANDING_FEATURED_IDS } from '../constants';
import { RankedItem } from '../types';

const TARGET_MOSAIC_COUNT = 8;

const LandingPage: React.FC = () => {
  const navigate = useNavigate();

  const featuredItems = useMemo(() => {
    const selected = LANDING_FEATURED_IDS
      .map((id) => INITIAL_RANKINGS.find((item) => item.id === id))
      .filter((item): item is RankedItem => Boolean(item));

    if (selected.length > 0) return selected;
    return INITIAL_RANKINGS.slice(0, 4);
  }, []);

  const mosaicItems = useMemo(() => {
    const pool = [...featuredItems, ...INITIAL_RANKINGS.filter((item) => !featuredItems.some((f) => f.id === item.id))];

    if (pool.length === 0) return [];

    const list = [...pool];
    let idx = 0;
    while (list.length < TARGET_MOSAIC_COUNT) {
      list.push(pool[idx % pool.length]);
      idx += 1;
    }

    return list.slice(0, TARGET_MOSAIC_COUNT);
  }, [featuredItems]);

  const handleEnterApp = () => {
    navigate('/app');
  };

  return (
    <div className="landing-root min-h-screen pb-20">
      <div className="landing-light-leak landing-light-leak-left" aria-hidden="true" />
      <div className="landing-light-leak landing-light-leak-right" aria-hidden="true" />

      <main className="mx-auto flex w-full max-w-[1240px] flex-col gap-8 px-4 py-6 sm:px-6 sm:py-8 lg:px-10 lg:py-10">
        <LandingHero onEnterApp={handleEnterApp} />
        <FeaturePanel />
        <PosterMosaic items={mosaicItems} />
        <LandingCTA onEnterApp={handleEnterApp} />
      </main>

      <div className="landing-mobile-cta md:hidden">
        <button onClick={handleEnterApp} className="landing-cta-primary w-full min-h-11 justify-center">
          Enter Marquee
        </button>
      </div>
    </div>
  );
};

export default LandingPage;
