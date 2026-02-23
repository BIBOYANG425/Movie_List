import React from 'react';
import { TasteCompatibility } from '../types';
import { TIER_COLORS } from '../constants';
import { Tier } from '../types';

interface TasteCompatibilityBadgeProps {
    taste: TasteCompatibility;
    compact?: boolean;
}

function scoreColor(score: number): string {
    if (score >= 80) return 'text-emerald-400';
    if (score >= 60) return 'text-yellow-400';
    if (score >= 40) return 'text-orange-400';
    return 'text-red-400';
}

function scoreRingColor(score: number): string {
    if (score >= 80) return '#34d399';
    if (score >= 60) return '#fbbf24';
    if (score >= 40) return '#fb923c';
    return '#f87171';
}

function scoreLabel(score: number): string {
    if (score >= 90) return 'Soul Mates 🎬';
    if (score >= 80) return 'Great Match';
    if (score >= 60) return 'Similar Taste';
    if (score >= 40) return 'Some Overlap';
    if (score >= 20) return 'Different Vibes';
    return 'Polar Opposites';
}

export const TasteCompatibilityBadge: React.FC<TasteCompatibilityBadgeProps> = ({
    taste,
    compact = false,
}) => {
    const circumference = 2 * Math.PI * 40;
    const progress = circumference - (taste.score / 100) * circumference;
    const color = scoreRingColor(taste.score);

    if (compact) {
        return (
            <div className="flex items-center gap-2 px-3 py-1.5 rounded-full bg-zinc-800/50 border border-zinc-700/50">
                <div className="relative w-6 h-6">
                    <svg viewBox="0 0 100 100" className="w-full h-full -rotate-90">
                        <circle cx="50" cy="50" r="40" fill="none" stroke="#27272a" strokeWidth="8" />
                        <circle
                            cx="50" cy="50" r="40" fill="none"
                            stroke={color} strokeWidth="8" strokeLinecap="round"
                            strokeDasharray={circumference}
                            strokeDashoffset={progress}
                            className="transition-all duration-700"
                        />
                    </svg>
                </div>
                <span className={`text-sm font-bold ${scoreColor(taste.score)}`}>{taste.score}%</span>
                <span className="text-xs text-zinc-500">match</span>
            </div>
        );
    }

    return (
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-5">
            <div className="flex items-center gap-5">
                {/* Score ring */}
                <div className="relative w-20 h-20 shrink-0">
                    <svg viewBox="0 0 100 100" className="w-full h-full -rotate-90">
                        <circle cx="50" cy="50" r="40" fill="none" stroke="#27272a" strokeWidth="6" />
                        <circle
                            cx="50" cy="50" r="40" fill="none"
                            stroke={color} strokeWidth="6" strokeLinecap="round"
                            strokeDasharray={circumference}
                            strokeDashoffset={progress}
                            className="transition-all duration-1000"
                        />
                    </svg>
                    <div className="absolute inset-0 flex items-center justify-center">
                        <span className={`text-lg font-black ${scoreColor(taste.score)}`}>{taste.score}%</span>
                    </div>
                </div>

                {/* Details */}
                <div className="flex-1 min-w-0">
                    <h3 className={`text-sm font-bold ${scoreColor(taste.score)}`}>
                        {scoreLabel(taste.score)}
                    </h3>
                    <p className="text-xs text-zinc-500 mt-0.5">
                        Based on {taste.sharedCount} shared {taste.sharedCount === 1 ? 'movie' : 'movies'}
                    </p>
                    <div className="flex items-center gap-3 mt-2 text-xs">
                        <span className="text-emerald-400">
                            {taste.agreements} agree
                        </span>
                        <span className="text-yellow-400">
                            {taste.nearAgreements} close
                        </span>
                        <span className="text-red-400">
                            {taste.disagreements} differ
                        </span>
                    </div>
                </div>
            </div>

            {/* Top shared movies */}
            {taste.topShared.length > 0 && (
                <div className="mt-4 pt-4 border-t border-zinc-800/50">
                    <h4 className="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-2">
                        You Both Love
                    </h4>
                    <div className="flex flex-wrap gap-2">
                        {taste.topShared.map((movie) => (
                            <div
                                key={movie.mediaItemId}
                                className="flex items-center gap-1.5 px-2 py-1 rounded-lg bg-zinc-800/50 border border-zinc-700/50"
                            >
                                <span className={`text-[10px] font-bold px-1 rounded ${TIER_COLORS[movie.viewerTier as Tier] || 'text-zinc-400'}`}>
                                    {movie.viewerTier}
                                </span>
                                <span className="text-xs text-zinc-300 truncate max-w-[120px]">{movie.mediaTitle}</span>
                            </div>
                        ))}
                    </div>
                </div>
            )}

            {/* Biggest divergences */}
            {taste.biggestDivergences.length > 0 && taste.biggestDivergences.some(d => Math.abs(d.tierDifference) >= 2) && (
                <div className="mt-3 pt-3 border-t border-zinc-800/50">
                    <h4 className="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-2">
                        Biggest Disagreements
                    </h4>
                    <div className="space-y-1.5">
                        {taste.biggestDivergences
                            .filter(d => Math.abs(d.tierDifference) >= 2)
                            .slice(0, 3)
                            .map((movie) => (
                                <div
                                    key={movie.mediaItemId}
                                    className="flex items-center gap-2 text-xs text-zinc-400"
                                >
                                    <span className="truncate flex-1">{movie.mediaTitle}</span>
                                    <span className={`font-bold ${TIER_COLORS[movie.viewerTier as Tier] || ''}`}>
                                        {movie.viewerTier}
                                    </span>
                                    <span className="text-zinc-600">vs</span>
                                    <span className={`font-bold ${TIER_COLORS[movie.targetTier as Tier] || ''}`}>
                                        {movie.targetTier}
                                    </span>
                                </div>
                            ))}
                    </div>
                </div>
            )}
        </div>
    );
};

export default TasteCompatibilityBadge;
