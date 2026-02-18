import React from 'react';
import { ArrowRight } from 'lucide-react';

export interface LandingCTAProps {
  onEnterApp: () => void;
}

export const LandingCTA: React.FC<LandingCTAProps> = ({ onEnterApp }) => {
  return (
    <section className="landing-panel reveal-up" style={{ animationDelay: '900ms' }}>
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div>
          <p className="landing-display text-3xl text-[color:var(--text-primary)]">Ready to Start Ranking?</p>
          <p className="landing-body mt-2 text-sm text-[color:var(--text-muted)]">
            Fast setup, cinematic UI, and a ranking workflow built for movie obsessives.
          </p>
        </div>
        <button onClick={onEnterApp} className="landing-cta-primary min-h-11">
          Enter Marquee
          <ArrowRight size={18} />
        </button>
      </div>
    </section>
  );
};
