import React from 'react';
import { MovieStub } from '../../types';
import { MOOD_TAGS } from '../../constants';

interface MonthlyRecapCardProps {
  stubs: MovieStub[];
  monthLabel: string;
  totalStubs: number;
  sTierCount: number;
  topMood?: [string, number];
  username: string;
  displayName?: string;
  currentStreak?: number;
}

const TIER_HEX: Record<string, string> = {
  S: '#FCD34D',
  A: '#4ADE80',
  B: '#60A5FA',
  C: '#A78BFA',
  D: '#F87171',
};

export const MonthlyRecapCard = React.forwardRef<HTMLDivElement, MonthlyRecapCardProps>(
  ({ stubs, monthLabel, totalStubs, sTierCount, topMood, username, displayName, currentStreak }, ref) => {
    const name = displayName || username;
    const displayStubs = stubs.slice(0, 8);
    const moodDef = topMood ? MOOD_TAGS.find((m) => m.id === topMood[0]) : undefined;

    return (
      <div
        ref={ref}
        style={{
          width: 360,
          padding: 24,
          background: 'linear-gradient(145deg, #0F1419 0%, #1C2128 100%)',
          borderRadius: 16,
          fontFamily: "'Source Sans 3', sans-serif",
        }}
      >
        {/* Header */}
        <div style={{ marginBottom: 4 }}>
          <div
            style={{
              fontSize: 22,
              fontWeight: 700,
              color: '#D4C5B0',
              fontFamily: "'Cormorant Garamond', serif",
            }}
          >
            {monthLabel}
          </div>
          <div style={{ fontSize: 11, color: '#6B7280' }}>
            {name} · @{username}
          </div>
        </div>

        {/* Poster grid */}
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginTop: 16 }}>
          {displayStubs.map((stub) => {
            const posterUrl = stub.posterPath
              ? `https://image.tmdb.org/t/p/w185${stub.posterPath}`
              : null;
            return (
              <div key={stub.id} style={{ position: 'relative', width: 72 }}>
                {posterUrl ? (
                  <img
                    src={posterUrl}
                    alt={stub.title}
                    crossOrigin="anonymous"
                    style={{
                      width: 72,
                      height: 108,
                      objectFit: 'cover',
                      borderRadius: 6,
                      border: '1px solid rgba(255,255,255,0.08)',
                    }}
                  />
                ) : (
                  <div
                    style={{
                      width: 72,
                      height: 108,
                      borderRadius: 6,
                      background: stub.palette.length >= 2
                        ? `linear-gradient(135deg, ${stub.palette[0]}, ${stub.palette[1]})`
                        : '#1C2128',
                      border: '1px solid rgba(255,255,255,0.08)',
                    }}
                  />
                )}
                <div
                  style={{
                    position: 'absolute',
                    top: 3,
                    left: 3,
                    background: TIER_HEX[stub.tier] || '#71717a',
                    color: '#000',
                    fontSize: 8,
                    fontWeight: 800,
                    padding: '1px 4px',
                    borderRadius: 3,
                  }}
                >
                  {stub.tier}
                </div>
                <div
                  style={{
                    marginTop: 3,
                    fontSize: 8,
                    color: '#9BA3AB',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  {stub.title}
                </div>
              </div>
            );
          })}
        </div>

        {/* Stats row */}
        <div
          style={{
            marginTop: 16,
            display: 'flex',
            gap: 16,
            padding: '10px 12px',
            background: 'rgba(255,255,255,0.03)',
            borderRadius: 8,
          }}
        >
          <div>
            <div style={{ fontSize: 18, fontWeight: 700, color: '#E5E7EB' }}>{totalStubs}</div>
            <div style={{ fontSize: 9, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
              Watched
            </div>
          </div>
          {sTierCount > 0 && (
            <div>
              <div style={{ fontSize: 18, fontWeight: 700, color: '#FCD34D' }}>{sTierCount}</div>
              <div style={{ fontSize: 9, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                S-Tier
              </div>
            </div>
          )}
          {moodDef && (
            <div>
              <div style={{ fontSize: 18 }}>{moodDef.emoji}</div>
              <div style={{ fontSize: 9, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                {moodDef.label}
              </div>
            </div>
          )}
          {(currentStreak ?? 0) > 0 && (
            <div style={{ marginLeft: 'auto' }}>
              <div style={{ fontSize: 18, fontWeight: 700, color: '#FB923C' }}>{currentStreak}</div>
              <div style={{ fontSize: 9, color: '#6B7280', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Day streak
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div
          style={{
            marginTop: 16,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <div
              style={{
                width: 18,
                height: 18,
                borderRadius: '50%',
                background: '#D4C5B0',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 9,
                fontWeight: 800,
                color: '#0F1419',
              }}
            >
              S
            </div>
            <span style={{ fontSize: 11, color: '#6B7280', fontWeight: 600 }}>spool</span>
          </div>
          <div style={{ fontSize: 10, color: '#4B5563' }}>spool.app/u/{username}</div>
        </div>
      </div>
    );
  },
);

MonthlyRecapCard.displayName = 'MonthlyRecapCard';
