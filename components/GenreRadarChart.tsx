import React, { useMemo } from 'react';
import { GenreProfileItem } from '../types';

interface GenreRadarChartProps {
    genres: GenreProfileItem[];
    comparisonGenres?: GenreProfileItem[];
    viewerLabel?: string;
    comparisonLabel?: string;
    size?: number;
}

const TIER_COLORS: Record<string, string> = {
    S: '#f59e0b',
    A: '#22c55e',
    B: '#3b82f6',
    C: '#8b5cf6',
    D: '#ef4444',
};

const TIER_BG_COLORS: Record<string, string> = {
    S: 'rgba(245, 158, 11, 0.15)',
    A: 'rgba(34, 197, 94, 0.15)',
    B: 'rgba(59, 130, 246, 0.15)',
    C: 'rgba(139, 92, 246, 0.15)',
    D: 'rgba(239, 68, 68, 0.15)',
};

export const GenreRadarChart: React.FC<GenreRadarChartProps> = ({
    genres,
    comparisonGenres,
    viewerLabel = 'You',
    comparisonLabel = 'Friend',
    size = 280,
}) => {
    // Take top 8 genres for the radar
    const topGenres = useMemo(() => genres.slice(0, 8), [genres]);
    const maxCount = useMemo(
        () => Math.max(...topGenres.map((g) => g.count), 1),
        [topGenres],
    );

    if (topGenres.length === 0) {
        return (
            <div className="flex items-center justify-center h-48 text-zinc-500 text-sm">
                No genre data yet. Rank some movies first!
            </div>
        );
    }

    const cx = size / 2;
    const cy = size / 2;
    const radius = size / 2 - 40;
    const angleStep = (2 * Math.PI) / topGenres.length;

    // Build polygon points for main user
    const userPoints = topGenres.map((g, i) => {
        const angle = angleStep * i - Math.PI / 2;
        const r = (g.count / maxCount) * radius;
        return { x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle) };
    });

    // Build polygon for comparison user
    const comparisonPoints = comparisonGenres
        ? topGenres.map((g, i) => {
            const angle = angleStep * i - Math.PI / 2;
            const match = comparisonGenres.find((cg) => cg.genre === g.genre);
            const r = match ? (match.count / maxCount) * radius : 0;
            return { x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle) };
        })
        : null;

    const toPolygon = (pts: { x: number; y: number }[]) =>
        pts.map((p) => `${p.x},${p.y}`).join(' ');

    // Concentric rings
    const rings = [0.25, 0.5, 0.75, 1.0];

    return (
        <div className="flex flex-col items-center gap-4">
            <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
                {/* Concentric ring guides */}
                {rings.map((scale) => (
                    <polygon
                        key={scale}
                        points={topGenres
                            .map((_, i) => {
                                const angle = angleStep * i - Math.PI / 2;
                                const r = scale * radius;
                                return `${cx + r * Math.cos(angle)},${cy + r * Math.sin(angle)}`;
                            })
                            .join(' ')}
                        fill="none"
                        stroke="rgba(113, 113, 122, 0.2)"
                        strokeWidth="1"
                    />
                ))}

                {/* Axis lines */}
                {topGenres.map((_, i) => {
                    const angle = angleStep * i - Math.PI / 2;
                    return (
                        <line
                            key={i}
                            x1={cx}
                            y1={cy}
                            x2={cx + radius * Math.cos(angle)}
                            y2={cy + radius * Math.sin(angle)}
                            stroke="rgba(113, 113, 122, 0.15)"
                            strokeWidth="1"
                        />
                    );
                })}

                {/* Comparison polygon (behind) */}
                {comparisonPoints && (
                    <polygon
                        points={toPolygon(comparisonPoints)}
                        fill="rgba(139, 92, 246, 0.12)"
                        stroke="#8b5cf6"
                        strokeWidth="1.5"
                        strokeDasharray="4 3"
                        opacity="0.7"
                    />
                )}

                {/* User polygon */}
                <polygon
                    points={toPolygon(userPoints)}
                    fill="rgba(245, 158, 11, 0.15)"
                    stroke="#f59e0b"
                    strokeWidth="2"
                />

                {/* Data dots */}
                {userPoints.map((p, i) => (
                    <circle
                        key={`dot-${i}`}
                        cx={p.x}
                        cy={p.y}
                        r="3.5"
                        fill="#f59e0b"
                        stroke="#18181b"
                        strokeWidth="1.5"
                    />
                ))}

                {/* Genre labels */}
                {topGenres.map((g, i) => {
                    const angle = angleStep * i - Math.PI / 2;
                    const labelR = radius + 22;
                    const lx = cx + labelR * Math.cos(angle);
                    const ly = cy + labelR * Math.sin(angle);
                    const anchor =
                        Math.abs(Math.cos(angle)) < 0.1
                            ? 'middle'
                            : Math.cos(angle) > 0
                                ? 'start'
                                : 'end';
                    return (
                        <text
                            key={`label-${i}`}
                            x={lx}
                            y={ly}
                            textAnchor={anchor}
                            dominantBaseline="middle"
                            fill="#a1a1aa"
                            fontSize="10"
                            fontWeight="500"
                        >
                            {g.genre}
                        </text>
                    );
                })}
            </svg>

            {/* Legend */}
            {comparisonGenres && (
                <div className="flex items-center gap-6 text-xs">
                    <div className="flex items-center gap-1.5">
                        <span className="w-3 h-0.5 bg-amber-500 rounded-full inline-block" />
                        <span className="text-zinc-400">{viewerLabel}</span>
                    </div>
                    <div className="flex items-center gap-1.5">
                        <span
                            className="w-3 h-0.5 rounded-full inline-block"
                            style={{ background: '#8b5cf6' }}
                        />
                        <span className="text-zinc-400">{comparisonLabel}</span>
                    </div>
                </div>
            )}

            {/* Genre breakdown list */}
            <div className="w-full grid grid-cols-2 gap-2 mt-2">
                {topGenres.map((g) => (
                    <div
                        key={g.genre}
                        className="flex items-center gap-2 px-3 py-2 rounded-lg"
                        style={{ backgroundColor: TIER_BG_COLORS[g.avgTier] || 'rgba(63,63,70,0.3)' }}
                    >
                        <span
                            className="w-6 h-6 rounded-md flex items-center justify-center text-[10px] font-bold text-black"
                            style={{ backgroundColor: TIER_COLORS[g.avgTier] || '#71717a' }}
                        >
                            {g.avgTier}
                        </span>
                        <div className="flex-1 min-w-0">
                            <span className="text-xs text-zinc-200 font-medium truncate block">
                                {g.genre}
                            </span>
                            <span className="text-[10px] text-zinc-500">
                                {g.count} movies · {g.percentage}%
                            </span>
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
};

export default GenreRadarChart;
