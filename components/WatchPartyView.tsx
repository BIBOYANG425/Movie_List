import React, { useEffect, useState } from 'react';
import {
    Calendar,
    Check,
    Clock,
    Film,
    HelpCircle,
    MapPin,
    Plus,
    Tv,
    Users,
    X,
} from 'lucide-react';
import {
    WatchParty,
    WatchPartyMember,
    RsvpStatus,
} from '../types';
import {
    createWatchParty,
    getMyWatchParties,
    getPartyMembers,
    inviteToParty,
    rsvpToParty,
} from '../services/friendsService';

const RSVP_STYLES: Record<RsvpStatus, { bg: string; text: string; label: string }> = {
    going: { bg: 'bg-emerald-500/15', text: 'text-emerald-400', label: 'Going' },
    maybe: { bg: 'bg-amber-500/15', text: 'text-amber-400', label: 'Maybe' },
    not_going: { bg: 'bg-red-500/15', text: 'text-red-400', label: "Can't Go" },
    pending: { bg: 'bg-zinc-700/30', text: 'text-zinc-400', label: 'Pending' },
};

interface WatchPartyViewProps {
    userId: string;
}

function timeUntil(dateStr: string): string {
    const now = Date.now();
    const target = new Date(dateStr).getTime();
    const diff = target - now;
    if (diff <= 0) return 'Now!';
    const days = Math.floor(diff / 86_400_000);
    const hours = Math.floor((diff % 86_400_000) / 3_600_000);
    if (days > 0) return `${days}d ${hours}h`;
    const mins = Math.floor((diff % 3_600_000) / 60_000);
    return `${hours}h ${mins}m`;
}

function formatDate(dateStr: string): string {
    return new Date(dateStr).toLocaleDateString('en-US', {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        hour: 'numeric',
        minute: '2-digit',
    });
}

export const WatchPartyView: React.FC<WatchPartyViewProps> = ({ userId }) => {
    const [parties, setParties] = useState<WatchParty[]>([]);
    const [loading, setLoading] = useState(true);
    const [showCreate, setShowCreate] = useState(false);
    const [selectedParty, setSelectedParty] = useState<WatchParty | null>(null);
    const [members, setMembers] = useState<WatchPartyMember[]>([]);

    // Create form state
    const [newTitle, setNewTitle] = useState('Movie Night');
    const [newDate, setNewDate] = useState('');
    const [newLocation, setNewLocation] = useState('');
    const [newNotes, setNewNotes] = useState('');

    const loadParties = async () => {
        setLoading(true);
        const data = await getMyWatchParties(userId);
        setParties(data);
        setLoading(false);
    };

    useEffect(() => {
        if (userId) loadParties();
    }, [userId]);

    const handleCreate = async () => {
        if (!newTitle.trim() || !newDate) return;
        const party = await createWatchParty(userId, {
            title: newTitle.trim(),
            scheduledAt: new Date(newDate).toISOString(),
            location: newLocation.trim() || undefined,
            notes: newNotes.trim() || undefined,
        });
        if (party) {
            setParties((p) => [party, ...p]);
            setShowCreate(false);
            setNewTitle('Movie Night');
            setNewDate('');
            setNewLocation('');
            setNewNotes('');
        }
    };

    const handleSelectParty = async (party: WatchParty) => {
        setSelectedParty(party);
        const m = await getPartyMembers(party.id);
        setMembers(m);
    };

    const handleRsvp = async (partyId: string, rsvp: RsvpStatus) => {
        await rsvpToParty(partyId, userId, rsvp);
        setMembers((prev) =>
            prev.map((m) =>
                m.userId === userId ? { ...m, rsvp, respondedAt: new Date().toISOString() } : m,
            ),
        );
    };

    if (loading) {
        return (
            <div className="flex items-center justify-center py-12">
                <div className="w-6 h-6 border-2 border-violet-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    // Detail view
    if (selectedParty) {
        const myRsvp = members.find((m) => m.userId === userId)?.rsvp ?? 'pending';
        return (
            <div className="space-y-4">
                <button
                    onClick={() => setSelectedParty(null)}
                    className="text-xs text-zinc-500 hover:text-zinc-300 flex items-center gap-1"
                >
                    ← Back to parties
                </button>

                <div className="bg-zinc-900/60 rounded-2xl border border-zinc-800/30 p-5 space-y-4">
                    <div className="flex gap-4">
                        {selectedParty.moviePosterUrl && (
                            <img
                                src={selectedParty.moviePosterUrl}
                                alt=""
                                className="w-16 h-24 rounded-lg object-cover flex-shrink-0"
                            />
                        )}
                        <div className="flex-1">
                            <h3 className="text-lg font-bold">{selectedParty.title}</h3>
                            {selectedParty.movieTitle && (
                                <p className="text-sm text-indigo-400 mt-0.5"><Film size={12} className="inline mr-1" />{selectedParty.movieTitle}</p>
                            )}
                            <div className="flex items-center gap-3 mt-2 text-xs text-zinc-400">
                                <span className="flex items-center gap-1"><Calendar size={12} />{formatDate(selectedParty.scheduledAt)}</span>
                                {selectedParty.location && (
                                    <span className="flex items-center gap-1"><MapPin size={12} />{selectedParty.location}</span>
                                )}
                            </div>
                            {selectedParty.status === 'upcoming' && (
                                <span className="inline-flex items-center gap-1 mt-2 px-2 py-0.5 rounded-full bg-violet-500/15 text-violet-400 text-[10px] font-semibold">
                                    <Clock size={10} /> {timeUntil(selectedParty.scheduledAt)}
                                </span>
                            )}
                        </div>
                    </div>

                    {selectedParty.notes && (
                        <p className="text-sm text-zinc-400 border-t border-zinc-800/30 pt-3">{selectedParty.notes}</p>
                    )}

                    {/* RSVP buttons */}
                    <div className="border-t border-zinc-800/30 pt-3">
                        <p className="text-xs text-zinc-500 mb-2">Your RSVP:</p>
                        <div className="flex gap-2">
                            {(['going', 'maybe', 'not_going'] as RsvpStatus[]).map((status) => {
                                const style = RSVP_STYLES[status];
                                const isActive = myRsvp === status;
                                return (
                                    <button
                                        key={status}
                                        onClick={() => handleRsvp(selectedParty.id, status)}
                                        className={`flex-1 py-2 rounded-lg text-xs font-semibold transition-all ${isActive
                                                ? `${style.bg} ${style.text} ring-1 ring-current`
                                                : 'bg-zinc-800/50 text-zinc-500 hover:text-zinc-300'
                                            }`}
                                    >
                                        {status === 'going' && <Check size={12} className="inline mr-1" />}
                                        {status === 'maybe' && <HelpCircle size={12} className="inline mr-1" />}
                                        {status === 'not_going' && <X size={12} className="inline mr-1" />}
                                        {style.label}
                                    </button>
                                );
                            })}
                        </div>
                    </div>

                    {/* Members */}
                    <div className="border-t border-zinc-800/30 pt-3">
                        <p className="text-xs text-zinc-500 mb-2">
                            Guests ({members.filter((m) => m.rsvp === 'going').length} going)
                        </p>
                        <div className="space-y-1.5">
                            {members.map((m) => {
                                const style = RSVP_STYLES[m.rsvp];
                                return (
                                    <div key={m.userId} className="flex items-center gap-2">
                                        <div className="w-6 h-6 rounded-full bg-zinc-700 overflow-hidden flex-shrink-0">
                                            {m.avatarUrl ? (
                                                <img src={m.avatarUrl} alt="" className="w-full h-full object-cover" />
                                            ) : (
                                                <div className="w-full h-full bg-indigo-600 flex items-center justify-center text-[9px] text-white font-bold">
                                                    {m.username?.[0]?.toUpperCase() || '?'}
                                                </div>
                                            )}
                                        </div>
                                        <span className="text-xs text-zinc-300 flex-1">{m.displayName || m.username}</span>
                                        <span className={`text-[10px] font-semibold ${style.text}`}>{style.label}</span>
                                    </div>
                                );
                            })}
                        </div>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="space-y-4">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <Tv size={18} className="text-violet-500" />
                    <h2 className="text-lg font-bold">Watch Parties</h2>
                </div>
                <button
                    onClick={() => setShowCreate(!showCreate)}
                    className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-violet-500/15 text-violet-400 text-xs font-semibold hover:bg-violet-500/25 transition-colors"
                >
                    <Plus size={14} /> New Party
                </button>
            </div>

            {/* Create form */}
            {showCreate && (
                <div className="bg-zinc-900/60 rounded-xl border border-zinc-800/30 p-4 space-y-3">
                    <input
                        type="text"
                        placeholder="Party title..."
                        value={newTitle}
                        onChange={(e) => setNewTitle(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-violet-500 focus:outline-none"
                    />
                    <input
                        type="datetime-local"
                        value={newDate}
                        onChange={(e) => setNewDate(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 border border-zinc-700 focus:border-violet-500 focus:outline-none"
                    />
                    <input
                        type="text"
                        placeholder="Location (optional)"
                        value={newLocation}
                        onChange={(e) => setNewLocation(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-violet-500 focus:outline-none"
                    />
                    <textarea
                        placeholder="Notes (optional)"
                        value={newNotes}
                        onChange={(e) => setNewNotes(e.target.value)}
                        rows={2}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-violet-500 focus:outline-none resize-none"
                    />
                    <div className="flex gap-2 justify-end">
                        <button onClick={() => setShowCreate(false)} className="px-3 py-1.5 rounded-lg text-xs text-zinc-500 hover:text-zinc-300">
                            Cancel
                        </button>
                        <button
                            onClick={handleCreate}
                            disabled={!newTitle.trim() || !newDate}
                            className="px-4 py-1.5 rounded-lg bg-violet-600 text-white text-xs font-semibold hover:bg-violet-500 disabled:opacity-40 transition-colors"
                        >
                            Create Party
                        </button>
                    </div>
                </div>
            )}

            {/* Party list */}
            {parties.length === 0 ? (
                <div className="text-center py-16 text-zinc-500">
                    <Tv size={40} className="mx-auto mb-3 opacity-40" />
                    <p className="text-sm">No watch parties yet. Create one to get started!</p>
                </div>
            ) : (
                <div className="space-y-2">
                    {parties.map((party) => (
                        <button
                            key={party.id}
                            onClick={() => handleSelectParty(party)}
                            className="w-full flex items-center gap-3 p-3 rounded-xl bg-zinc-900/60 border border-zinc-800/30 hover:border-zinc-700 transition-all text-left"
                        >
                            {party.moviePosterUrl ? (
                                <img src={party.moviePosterUrl} alt="" className="w-10 h-[60px] rounded-lg object-cover flex-shrink-0" />
                            ) : (
                                <div className="w-10 h-[60px] rounded-lg bg-zinc-800 flex items-center justify-center flex-shrink-0">
                                    <Tv size={16} className="text-zinc-600" />
                                </div>
                            )}
                            <div className="flex-1 min-w-0">
                                <h3 className="text-sm font-semibold text-zinc-100 truncate">{party.title}</h3>
                                <p className="text-[11px] text-zinc-500 mt-0.5 flex items-center gap-2">
                                    <span className="flex items-center gap-1"><Calendar size={10} />{formatDate(party.scheduledAt)}</span>
                                    {party.location && <span className="flex items-center gap-1"><MapPin size={10} />{party.location}</span>}
                                </p>
                            </div>
                            <div className="flex flex-col items-end gap-1 flex-shrink-0">
                                {party.status === 'upcoming' && (
                                    <span className="text-[10px] font-semibold text-violet-400 bg-violet-500/15 px-2 py-0.5 rounded-full">
                                        {timeUntil(party.scheduledAt)}
                                    </span>
                                )}
                                {party.goingCount !== undefined && (
                                    <span className="text-[10px] text-zinc-500 flex items-center gap-0.5">
                                        <Users size={10} /> {party.goingCount} going
                                    </span>
                                )}
                            </div>
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};

export default WatchPartyView;
