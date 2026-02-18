import React from 'react';
import { Clapperboard, PlayCircle } from 'lucide-react';
import { INITIAL_RANKINGS, LANDING_FEATURED_IDS } from '../../constants';

export interface LandingHeroProps {
  onEnterApp: () => void;
}

export const LandingHero: React.FC<LandingHeroProps> = ({ onEnterApp }) => {
  const selected = LANDING_FEATURED_IDS
    .map((id) => INITIAL_RANKINGS.find((item) => item.id === id))
    .filter((item): item is (typeof INITIAL_RANKINGS)[number] => Boolean(item));

  const heroPosters = (selected.length > 0 ? selected : INITIAL_RANKINGS).slice(0, 3);

  return (
    <section className="landing-panel reveal-up" style={{ animationDelay: '0ms' }}>
      <div className="grid gap-8 xl:grid-cols-[1.45fr_0.9fr]">
        <div className="space-y-6">
          <div className="grid gap-3 sm:grid-cols-3">
            {heroPosters.map((movie, index) => (
              <article
                key={movie.id}
                className="group overflow-hidden rounded-2xl border border-white/10 bg-white/5 reveal-up"
                style={{ animationDelay: `${120 + index * 120}ms` }}
              >
                <div className="aspect-[5/3] overflow-hidden">
                  <img
                    src={movie.posterUrl}
                    alt={movie.title}
                    className="h-full w-full object-cover transition duration-500 group-hover:scale-105"
                  />
                </div>
                <p className="px-3 py-2 text-xs text-[color:var(--text-muted)] landing-body">{movie.title}</p>
              </article>
            ))}
          </div>

          <div className="space-y-4 reveal-up" style={{ animationDelay: '240ms' }}>
            <p className="landing-mono text-xs tracking-[0.25em] text-[color:var(--accent-pop)]">SOCIAL RANKING REIMAGINED</p>
            <h1 className="landing-display text-4xl leading-[1.05] text-[color:var(--text-primary)] sm:text-5xl xl:text-6xl">
              Cinematic Immersion Meets Personal Discovery
            </h1>
            <p className="landing-body max-w-xl text-base leading-relaxed text-[color:var(--text-muted)] sm:text-lg">
              Build your canon, compare films head-to-head, and track the movies that deserve a spot in your next watch run.
            </p>
          </div>

          <div className="flex flex-wrap gap-3 reveal-up" style={{ animationDelay: '360ms' }}>
            <button onClick={onEnterApp} className="landing-cta-primary">
              <Clapperboard size={18} />
              Enter Marquee
            </button>
            <a href="#visual-demo" className="landing-cta-secondary">
              <PlayCircle size={18} />
              Watch The Layout
            </a>
          </div>
        </div>

        <aside className="landing-side-panel reveal-up" style={{ animationDelay: '360ms' }}>
          <p className="landing-display text-xl font-semibold text-[color:var(--text-primary)]">The UI: Interaction & Layout</p>
          <div className="landing-mini-rating mt-4">
            <span>★</span>
            <span>★</span>
            <span>★</span>
            <span>★</span>
            <span className="landing-rating-pop">★</span>
          </div>
          <p className="landing-body mt-2 text-sm text-[color:var(--text-muted)]">Satisfying ranking mechanics with fast movie-first flow.</p>

          <div className="mt-5 grid grid-cols-2 gap-3">
            {heroPosters.concat(heroPosters).slice(0, 4).map((movie, index) => (
              <div key={`${movie.id}-${index}`} className="overflow-hidden rounded-xl border border-white/10 bg-black/30">
                <img src={movie.posterUrl} alt={movie.title} className="aspect-[2/3] h-full w-full object-cover" />
              </div>
            ))}
          </div>
        </aside>
      </div>
    </section>
  );
};
