import React, { useEffect, useState } from 'react';
import { Crown, Layers, Plus, Users, X } from 'lucide-react';
import {
    GroupRanking,
    GroupRankingConsensus,
    GroupRankingEntry,
    Tier,
} from '../types';
import {
    createGroupRanking,
    getMyGroupRankings,
    getGroupRankingEntries,
    addGroupRankingEntry,
    inviteToGroupRanking,
} from '../services/friendsService';

const TIER_COLORS: Record<string, string> = {
    S: '#f59e0b', A: '#22c55e', B: '#3b82f6', C: '#8b5cf6', D: '#ef4444',
};
const TIER_NUMERIC: Record<string, number> = { S: 5, A: 4, B: 3, C: 2, D: 1 };
const NUMERIC_TIER: Record<number, string> = { 5: 'S', 4: 'A', 3: 'B', 2: 'C', 1: 'D' };

function buildConsensus(entries: GroupRankingEntry[]): GroupRankingConsensus[] {
    const byMovie = new Map<string, GroupRankingEntry[]>();
    for (const e of entries) {
        const existing = byMovie.get(e.tmdbId);
        if (existing) existing.push(e);
        else byMovie.set(e.tmdbId, [e]);
    }

    const results: GroupRankingConsensus[] = [];
    for (const [tmdbId, movieEntries] of byMovie) {
        const tiers = movieEntries.map((e) => ({
            userId: e.userId,
            username: e.username || '',
            tier: e.tier,
        }));
        const numericTiers = tiers.map((t) => TIER_NUMERIC[t.tier] ?? 3);
        const avg = numericTiers.reduce((a, b) => a + b, 0) / numericTiers.length;
        const rounded = Math.round(avg);
        const consensusTier = (NUMERIC_TIER[Math.max(1, Math.min(5, rounded))] || 'C') as Tier;

        // Divergence: standard deviation of numeric tiers
        const variance =
            numericTiers.reduce((sum, v) => sum + (v - avg) ** 2, 0) / numericTiers.length;
        const divergence = Math.round(Math.sqrt(variance) * 10) / 10;

        const first = movieEntries[0];
        results.push({
            tmdbId,
            title: first.title,
            posterUrl: first.posterUrl,
            year: first.year,
            tiers,
            consensusTier,
            avgTierNumeric: Math.round(avg * 10) / 10,
            divergenceScore: divergence,
        });
    }

    results.sort((a, b) => b.avgTierNumeric - a.avgTierNumeric);
    return results;
}

interface GroupRankingViewProps {
    userId: string;
}

export const GroupRankingView: React.FC<GroupRankingViewProps> = ({ userId }) => {
    const [groups, setGroups] = useState<GroupRanking[]>([]);
    const [loading, setLoading] = useState(true);
    const [showCreate, setShowCreate] = useState(false);
    const [selectedGroup, setSelectedGroup] = useState<GroupRanking | null>(null);
    const [entries, setEntries] = useState<GroupRankingEntry[]>([]);
    const [consensus, setConsensus] = useState<GroupRankingConsensus[]>([]);

    // Create form
    const [newName, setNewName] = useState('');
    const [newDesc, setNewDesc] = useState('');

    const loadGroups = async () => {
        setLoading(true);
        const data = await getMyGroupRankings(userId);
        setGroups(data);
        setLoading(false);
    };

    useEffect(() => {
        if (userId) loadGroups();
    }, [userId]);

    const handleCreate = async () => {
        if (!newName.trim()) return;
        const group = await createGroupRanking(userId, newName.trim(), newDesc.trim() || undefined);
        if (group) {
            setGroups((g) => [group, ...g]);
            setShowCreate(false);
            setNewName('');
            setNewDesc('');
        }
    };

    const handleSelectGroup = async (group: GroupRanking) => {
        setSelectedGroup(group);
        const e = await getGroupRankingEntries(group.id);
        setEntries(e);
        setConsensus(buildConsensus(e));
    };

    if (loading) {
        return (
            <div className="flex items-center justify-center py-12">
                <div className="w-6 h-6 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    // Detail view — consensus board
    if (selectedGroup) {
        return (
            <div className="space-y-4">
                <button
                    onClick={() => { setSelectedGroup(null); setConsensus([]); }}
                    className="text-xs text-zinc-500 hover:text-zinc-300 flex items-center gap-1"
                >
                    ← Back to groups
                </button>

                <div className="flex items-center justify-between">
                    <div>
                        <h3 className="text-lg font-bold">{selectedGroup.name}</h3>
                        {selectedGroup.description && (
                            <p className="text-xs text-zinc-500 mt-0.5">{selectedGroup.description}</p>
                        )}
                    </div>
                    <span className="text-xs text-zinc-500 flex items-center gap-1">
                        <Users size={12} /> {selectedGroup.memberCount ?? 0} members
                    </span>
                </div>

                {consensus.length === 0 ? (
                    <div className="text-center py-12 text-zinc-500">
                        <Layers size={32} className="mx-auto mb-2 opacity-40" />
                        <p className="text-sm">No movies ranked yet. Add movies from your personal rankings!</p>
                    </div>
                ) : (
                    <div className="space-y-2">
                        {consensus.map((movie) => (
                            <div
                                key={movie.tmdbId}
                                className="flex items-center gap-3 p-3 rounded-xl bg-zinc-900/60 border border-zinc-800/30"
                            >
                                {movie.posterUrl ? (
                                    <img src={movie.posterUrl} alt="" className="w-10 h-[60px] rounded-lg object-cover flex-shrink-0" />
                                ) : (
                                    <div className="w-10 h-[60px] rounded-lg bg-zinc-800 flex-shrink-0" />
                                )}

                                <div className="flex-1 min-w-0">
                                    <h4 className="text-sm font-semibold text-zinc-100 truncate">{movie.title}</h4>
                                    <p className="text-[11px] text-zinc-500 mt-0.5">{movie.year}</p>

                                    {/* Individual tier badges */}
                                    <div className="flex gap-1 mt-1.5 flex-wrap">
                                        {movie.tiers.map((t) => (
                                            <span
                                                key={t.userId}
                                                className="inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded text-[9px] font-bold"
                                                style={{
                                                    backgroundColor: `${TIER_COLORS[t.tier]}20`,
                                                    color: TIER_COLORS[t.tier],
                                                }}
                                                title={`${t.username}: ${t.tier}`}
                                            >
                                                {t.username?.slice(0, 6)}: {t.tier}
                                            </span>
                                        ))}
                                    </div>
                                </div>

                                {/* Consensus tier */}
                                <div className="flex flex-col items-center gap-1 flex-shrink-0">
                                    <span
                                        className="w-9 h-9 rounded-lg flex items-center justify-center text-sm font-bold text-black"
                                        style={{ backgroundColor: TIER_COLORS[movie.consensusTier] || '#71717a' }}
                                    >
                                        {movie.consensusTier}
                                    </span>
                                    {movie.divergenceScore > 1.5 && (
                                        <span className="text-[9px] text-red-400 font-semibold">🔥 Split</span>
                                    )}
                                </div>
                            </div>
                        ))}
                    </div>
                )}
            </div>
        );
    }

    return (
        <div className="space-y-4">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <Crown size={18} className="text-indigo-500" />
                    <h2 className="text-lg font-bold">Group Rankings</h2>
                </div>
                <button
                    onClick={() => setShowCreate(!showCreate)}
                    className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-indigo-500/15 text-indigo-400 text-xs font-semibold hover:bg-indigo-500/25 transition-colors"
                >
                    <Plus size={14} /> New Group
                </button>
            </div>

            {showCreate && (
                <div className="bg-zinc-900/60 rounded-xl border border-zinc-800/30 p-4 space-y-3">
                    <input
                        type="text"
                        placeholder="Group name..."
                        value={newName}
                        onChange={(e) => setNewName(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-indigo-500 focus:outline-none"
                    />
                    <input
                        type="text"
                        placeholder="Description (optional)"
                        value={newDesc}
                        onChange={(e) => setNewDesc(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-indigo-500 focus:outline-none"
                    />
                    <div className="flex gap-2 justify-end">
                        <button onClick={() => setShowCreate(false)} className="px-3 py-1.5 rounded-lg text-xs text-zinc-500 hover:text-zinc-300">
                            Cancel
                        </button>
                        <button
                            onClick={handleCreate}
                            disabled={!newName.trim()}
                            className="px-4 py-1.5 rounded-lg bg-indigo-600 text-white text-xs font-semibold hover:bg-indigo-500 disabled:opacity-40 transition-colors"
                        >
                            Create Group
                        </button>
                    </div>
                </div>
            )}

            {groups.length === 0 ? (
                <div className="text-center py-16 text-zinc-500">
                    <Crown size={40} className="mx-auto mb-3 opacity-40" />
                    <p className="text-sm">No group rankings yet. Create one and invite friends!</p>
                </div>
            ) : (
                <div className="space-y-2">
                    {groups.map((group) => (
                        <button
                            key={group.id}
                            onClick={() => handleSelectGroup(group)}
                            className="w-full flex items-center gap-3 p-3 rounded-xl bg-zinc-900/60 border border-zinc-800/30 hover:border-zinc-700 transition-all text-left"
                        >
                            <div className="w-10 h-10 rounded-lg bg-indigo-500/15 flex items-center justify-center flex-shrink-0">
                                <Layers size={18} className="text-indigo-400" />
                            </div>
                            <div className="flex-1 min-w-0">
                                <h3 className="text-sm font-semibold text-zinc-100 truncate">{group.name}</h3>
                                {group.description && (
                                    <p className="text-[11px] text-zinc-500 truncate">{group.description}</p>
                                )}
                            </div>
                            <div className="flex flex-col items-end gap-0.5 flex-shrink-0 text-[10px] text-zinc-500">
                                <span className="flex items-center gap-0.5"><Users size={10} /> {group.memberCount ?? 0}</span>
                                <span>{group.entryCount ?? 0} movies</span>
                            </div>
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};

export default GroupRankingView;
