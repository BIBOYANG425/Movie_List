import React from 'react';
import { MovieStub } from '../../types';
import { TIER_LABELS } from '../../constants';

interface StubCardProps {
  stub: MovieStub;
  size?: 'mini' | 'full';
  onClick?: () => void;
}

const TIER_HEX: Record<string, string> = {
  S: '#A855F7',
  A: '#3B82F6',
  B: '#10B981',
  C: '#F59E0B',
  D: '#EF4444',
};

export const StubCard: React.FC<StubCardProps> = ({ stub, size = 'full', onClick }) => {
  const tierColor = TIER_HEX[stub.tier] ?? '#71717a';
  const [c1, c2, c3] = stub.palette.length >= 2
    ? stub.palette
    : [tierColor, '#1a1a2e', '#0f0f1a'];
  const isSTier = stub.tier === 'S';

  if (size === 'mini') {
    return (
      <button
        onClick={onClick}
        className="group relative w-full aspect-[2/3] rounded-md overflow-hidden transition-transform hover:scale-105 active:scale-95"
        title={stub.title}
      >
        {stub.posterPath ? (
          <img
            src={stub.posterPath.startsWith('http') ? stub.posterPath : `https://image.tmdb.org/t/p/w92${stub.posterPath}`}
            alt={stub.title}
            className="w-full h-full object-cover"
          />
        ) : (
          <div
            className="w-full h-full"
            style={{ background: `linear-gradient(135deg, ${c1}, ${c2})` }}
          />
        )}
        {/* Tier badge */}
        <span
          className="absolute bottom-0.5 right-0.5 text-[8px] font-bold rounded-sm px-1 leading-tight"
          style={{ backgroundColor: tierColor, color: '#fff' }}
        >
          {stub.tier}
        </span>
        {/* Gold shimmer for S-tier */}
        {isSTier && (
          <div className="absolute inset-0 bg-gradient-to-br from-yellow-400/20 via-transparent to-yellow-600/10 pointer-events-none" />
        )}
      </button>
    );
  }

  // Full stub (expanded / detail / shareable)
  return (
    <div
      onClick={onClick}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      className={`relative flex rounded-lg overflow-hidden shadow-xl ${onClick ? 'cursor-pointer hover:shadow-2xl transition-shadow' : ''}`}
      style={{
        width: '100%',
        maxWidth: 360,
        aspectRatio: '2 / 1',
        background: `linear-gradient(135deg, ${c1}dd, ${c2}cc, ${c3 ?? c2}99)`,
        border: isSTier ? '1.5px solid #D4AF37' : '1px solid rgba(255,255,255,0.08)',
      }}
    >
      {/* Content area (left 70%) */}
      <div className="flex-1 flex flex-col justify-between p-3 min-w-0" style={{ flex: '0 0 68%' }}>
        {/* Title + Date */}
        <div className="space-y-0.5">
          <h3 className="text-sm font-serif font-semibold text-white truncate leading-tight drop-shadow-sm">
            {stub.title}
          </h3>
          <p className="text-[10px] text-white/60 font-sans">
            {formatWatchedDate(stub.watchedDate)}
          </p>
        </div>

        {/* Mood tags */}
        {stub.moodTags.length > 0 && (
          <div className="flex gap-1 flex-wrap">
            {stub.moodTags.slice(0, 3).map((tag) => (
              <span
                key={tag}
                className="text-[9px] px-1.5 py-0.5 rounded-full bg-white/15 text-white/80 font-sans"
              >
                {tag}
              </span>
            ))}
          </div>
        )}

        {/* Stub line (AI-enriched) */}
        {stub.stubLine && (
          <p className="text-[11px] italic text-white/75 font-serif leading-snug line-clamp-2 drop-shadow-sm">
            {stub.isAiEnriched && <span className="not-italic mr-0.5">&#10024;</span>}
            &ldquo;{stub.stubLine}&rdquo;
          </p>
        )}

        {/* Tier badge */}
        <div className="flex items-center gap-1.5">
          <span
            className="text-[10px] font-bold px-1.5 py-0.5 rounded-sm"
            style={{ backgroundColor: tierColor, color: '#fff' }}
          >
            {stub.tier}
          </span>
          <span className="text-[9px] text-white/50 font-sans">
            {TIER_LABELS[stub.tier as keyof typeof TIER_LABELS]}
          </span>
        </div>
      </div>

      {/* Poster area (right 32%) */}
      <div className="relative" style={{ flex: '0 0 32%' }}>
        {stub.posterPath ? (
          <img
            src={stub.posterPath.startsWith('http') ? stub.posterPath : `https://image.tmdb.org/t/p/w185${stub.posterPath}`}
            alt=""
            className="w-full h-full object-cover"
          />
        ) : (
          <div className="w-full h-full bg-white/10" />
        )}
        {/* Torn/perforated edge on the left side of poster area */}
        <div
          className="absolute left-0 top-0 bottom-0 w-2"
          style={{
            background: `repeating-linear-gradient(
              to bottom,
              transparent,
              transparent 4px,
              rgba(0,0,0,0.3) 4px,
              rgba(0,0,0,0.3) 6px
            )`,
          }}
        />
      </div>

      {/* S-tier gold foil overlay */}
      {isSTier && (
        <div className="absolute inset-0 pointer-events-none bg-gradient-to-br from-yellow-400/10 via-transparent to-amber-500/10" />
      )}
    </div>
  );
};

function formatWatchedDate(dateStr: string): string {
  try {
    const d = new Date(dateStr + 'T00:00:00');
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  } catch {
    return dateStr;
  }
}
