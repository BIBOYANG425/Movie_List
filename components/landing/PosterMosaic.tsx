import React from 'react';
import { RankedItem } from '../../types';

export interface PosterMosaicProps {
  items: RankedItem[];
}

export const PosterMosaic: React.FC<PosterMosaicProps> = ({ items }) => {
  return (
    <section id="visual-demo" className="landing-panel space-y-4">
      <div className="flex items-end justify-between gap-4">
        <div>
          <p className="landing-mono text-xs tracking-[0.3em] text-[color:var(--accent-pop)]">TEXTURE & ATMOSPHERE</p>
          <h2 className="landing-display mt-2 text-3xl text-[color:var(--text-primary)]">Posters, Light, and Motion</h2>
        </div>
        <p className="landing-body hidden text-sm text-[color:var(--text-muted)] md:block">
          Subtle grain and warm highlights layered over real film artwork.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        {items.map((item, index) => (
          <article
            key={`${item.id}-${index}`}
            className="landing-mosaic-card reveal-up"
            style={{ animationDelay: `${600 + index * 60}ms` }}
          >
            <img
              src={item.posterUrl}
              alt={item.title}
              loading="lazy"
              className="aspect-[2/3] h-full w-full object-cover"
            />
            <div className="landing-mosaic-overlay">
              <p className="landing-body text-sm text-white">{item.title}</p>
              <p className="landing-mono text-[11px] text-white/80">{item.year}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  );
};
