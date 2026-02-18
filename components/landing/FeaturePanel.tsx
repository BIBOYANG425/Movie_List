import React from 'react';
import { BarChart3, BookMarked, Sparkles } from 'lucide-react';

const features = [
  {
    title: 'Rank With Confidence',
    description: 'Drop films into tiers, compare matchups, and build your canon with precision.',
    Icon: BarChart3,
  },
  {
    title: 'Discover Socially',
    description: 'Surface crowd favorites and underrated gems through a visual ranking workflow.',
    Icon: Sparkles,
  },
  {
    title: 'Track Watchlist',
    description: 'Bookmark films now, rank them later, and never lose momentum in your queue.',
    Icon: BookMarked,
  },
];

export const FeaturePanel: React.FC = () => {
  return (
    <section id="features" className="space-y-4">
      <p className="landing-mono text-xs tracking-[0.3em] text-[color:var(--accent-pop)]">CORE CAPABILITIES</p>
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {features.map(({ title, description, Icon }, index) => (
          <article
            key={title}
            className="landing-feature-card reveal-up"
            style={{ animationDelay: `${480 + index * 120}ms` }}
          >
            <div className="landing-feature-icon">
              <Icon size={18} />
            </div>
            <h2 className="landing-display mt-4 text-2xl text-[color:var(--text-primary)]">{title}</h2>
            <p className="landing-body mt-3 text-sm leading-relaxed text-[color:var(--text-muted)]">{description}</p>
          </article>
        ))}
      </div>
    </section>
  );
};
