import React, { useState } from 'react';
import { Tier, RankingComparisonItem, RankingComparison } from '../types';
import { TIER_COLORS } from '../constants';
import { ArrowLeftRight, Filter } from 'lucide-react';

interface RankingComparisonViewProps {
    comparison: RankingComparison;
    viewerUsername: string;
}

type FilterMode = 'all' | 'shared' | 'agreements' | 'disagreements';

function tierBadge(tier: string | undefined | null): React.ReactNode {
    if (!tier) return <span className="text-xs text-muted-foreground/60">—</span>;
    const colors = TIER_COLORS[tier as Tier] || 'text-muted-foreground';
    return (
        <span className={`text-xs font-black px-1.5 py-0.5 rounded border ${colors}`}>
            {tier}
        </span>
    );
}

export const RankingComparisonView: React.FC<RankingComparisonViewProps> = ({
    comparison,
    viewerUsername,
}) => {
    const [filter, setFilter] = useState<FilterMode>('all');

    const filtered = comparison.items.filter((item) => {
        switch (filter) {
            case 'shared':
                return item.isShared;
            case 'agreements':
                return item.isShared && item.viewerTier === item.targetTier;
            case 'disagreements':
                return item.isShared && item.viewerTier !== item.targetTier;
            default:
                return true;
        }
    });

    const filters: { key: FilterMode; label: string; count: number }[] = [
        { key: 'all', label: 'All', count: comparison.items.length },
        { key: 'shared', label: 'Shared', count: comparison.sharedCount },
        {
            key: 'agreements',
            label: 'Agree',
            count: comparison.items.filter((i) => i.isShared && i.viewerTier === i.targetTier).length,
        },
        {
            key: 'disagreements',
            label: 'Disagree',
            count: comparison.items.filter((i) => i.isShared && i.viewerTier !== i.targetTier).length,
        },
    ];

    return (
        <div className="space-y-4">
            {/* Header */}
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <ArrowLeftRight size={18} className="text-accent" />
                    <h3 className="text-lg font-bold text-foreground">Ranking Comparison</h3>
                </div>
                <div className="text-xs text-muted-foreground">
                    {comparison.sharedCount} shared of {comparison.viewerTotal + comparison.targetTotal - comparison.sharedCount} total
                </div>
            </div>

            {/* Stat summary */}
            <div className="grid grid-cols-3 gap-3">
                <div className="bg-card border border-border rounded-xl p-3 text-center">
                    <p className="text-lg font-black text-foreground">{comparison.viewerTotal}</p>
                    <p className="text-[10px] text-muted-foreground uppercase tracking-wider">Your Movies</p>
                </div>
                <div className="bg-card border border-gold/20 rounded-xl p-3 text-center">
                    <p className="text-lg font-black text-accent">{comparison.sharedCount}</p>
                    <p className="text-[10px] text-muted-foreground uppercase tracking-wider">In Common</p>
                </div>
                <div className="bg-card border border-border rounded-xl p-3 text-center">
                    <p className="text-lg font-black text-foreground">{comparison.targetTotal}</p>
                    <p className="text-[10px] text-muted-foreground uppercase tracking-wider">{comparison.targetUsername}'s</p>
                </div>
            </div>

            {/* Filter tabs */}
            <div className="flex gap-1.5 bg-card p-1 rounded-lg border border-border">
                {filters.map(({ key, label, count }) => (
                    <button
                        key={key}
                        onClick={() => setFilter(key)}
                        className={`flex-1 px-2 py-1.5 text-xs font-medium rounded-md transition-colors ${filter === key
                                ? 'bg-secondary text-foreground'
                                : 'text-muted-foreground hover:text-muted-foreground'
                            }`}
                    >
                        {label} ({count})
                    </button>
                ))}
            </div>

            {/* Column headers */}
            <div className="grid grid-cols-[1fr_auto_auto_auto] gap-2 px-3 py-2 text-[10px] text-muted-foreground uppercase tracking-wider border-b border-border">
                <span>Movie</span>
                <span className="w-10 text-center">You</span>
                <span className="w-4" />
                <span className="w-10 text-center">{comparison.targetUsername.slice(0, 6)}</span>
            </div>

            {/* Items */}
            <div className="space-y-1 max-h-[400px] overflow-y-auto pr-1 custom-scrollbar">
                {filtered.length === 0 ? (
                    <div className="py-8 text-center text-muted-foreground/60 text-sm">No movies match this filter</div>
                ) : (
                    filtered.map((item) => {
                        const agree = item.isShared && item.viewerTier === item.targetTier;
                        return (
                            <div
                                key={item.mediaItemId}
                                className={`grid grid-cols-[1fr_auto_auto_auto] gap-2 items-center px-3 py-2 rounded-lg transition-colors ${agree
                                        ? 'bg-emerald-500/5 border border-emerald-500/10'
                                        : item.isShared
                                            ? 'bg-card/30 border border-border/50'
                                            : 'border border-transparent'
                                    } hover:bg-secondary/30`}
                            >
                                <div className="flex items-center gap-2 min-w-0">
                                    {item.posterUrl && (
                                        <img
                                            src={item.posterUrl}
                                            alt=""
                                            className="w-6 h-9 rounded object-cover shrink-0"
                                        />
                                    )}
                                    <span className="text-sm text-muted-foreground truncate">{item.mediaTitle}</span>
                                </div>
                                <div className="w-10 text-center">{tierBadge(item.viewerTier)}</div>
                                <div className="w-4 text-center">
                                    {item.isShared && (
                                        <span className={`text-xs ${agree ? 'text-emerald-400' : 'text-muted-foreground/60'}`}>
                                            {agree ? '=' : '≠'}
                                        </span>
                                    )}
                                </div>
                                <div className="w-10 text-center">{tierBadge(item.targetTier)}</div>
                            </div>
                        );
                    })
                )}
            </div>
        </div>
    );
};

export default RankingComparisonView;
