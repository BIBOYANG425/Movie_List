import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
    Plus,
    Users,
    ThumbsUp,
    Film,
    Trash2,
    UserPlus,
    ChevronRight,
    Bookmark,
} from 'lucide-react';
import {
    SharedWatchlist,
    SharedWatchlistItem,
    SharedWatchlistMember,
} from '../../types';

interface SharedWatchlistViewProps {
    watchlists: SharedWatchlist[];
    currentUserId: string;
    onCreateWatchlist?: (name: string) => void;
    onOpenWatchlist?: (watchlistId: string) => void;
    onDeleteWatchlist?: (watchlistId: string) => void;
}

interface SharedWatchlistDetailViewProps {
    watchlist: SharedWatchlist;
    currentUserId: string;
    onVote?: (watchlistId: string, itemId: string) => void;
    onAddItem?: (watchlistId: string) => void;
    onInviteMember?: (watchlistId: string) => void;
    onBack?: () => void;
}

// ── List View ────────────────────────────────────────────────────────────────

export const SharedWatchlistListView: React.FC<SharedWatchlistViewProps> = ({
    watchlists,
    currentUserId,
    onCreateWatchlist,
    onOpenWatchlist,
    onDeleteWatchlist,
}) => {
    const [newName, setNewName] = useState('');
    const [showCreate, setShowCreate] = useState(false);

    const handleCreate = () => {
        if (newName.trim()) {
            onCreateWatchlist?.(newName.trim());
            setNewName('');
            setShowCreate(false);
        }
    };

    return (
        <div className="space-y-4">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <Bookmark size={18} className="text-violet-400" />
                    <h2 className="text-lg font-bold text-foreground">Shared Watchlists</h2>
                </div>
                <button
                    onClick={() => setShowCreate(!showCreate)}
                    className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg bg-violet-500/10 text-violet-400 border border-violet-500/20 hover:bg-violet-500/20 transition-colors"
                >
                    <Plus size={14} />
                    New
                </button>
            </div>

            {showCreate && (
                <div className="flex gap-2 animate-fade-in">
                    <input
                        type="text"
                        value={newName}
                        onChange={(e) => setNewName(e.target.value)}
                        placeholder="Watchlist name..."
                        className="flex-1 px-3 py-2 text-sm bg-secondary border border-border rounded-lg text-foreground placeholder-muted-foreground focus:outline-none focus:border-violet-500"
                        maxLength={100}
                        onKeyDown={(e) => e.key === 'Enter' && handleCreate()}
                    />
                    <button
                        onClick={handleCreate}
                        disabled={!newName.trim()}
                        className="px-4 py-2 text-sm font-semibold rounded-lg bg-violet-500 text-foreground hover:bg-violet-600 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                        Create
                    </button>
                </div>
            )}

            {watchlists.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-16 text-muted-foreground/60">
                    <Users size={40} className="mb-3 opacity-30" />
                    <p className="text-sm font-medium text-muted-foreground">No shared watchlists yet</p>
                    <p className="text-xs mt-1 opacity-60 max-w-xs text-center">
                        Create one to start picking movies to watch together with friends.
                    </p>
                </div>
            ) : (
                <div className="space-y-2">
                    {watchlists.map((wl) => (
                        <button
                            key={wl.id}
                            onClick={() => onOpenWatchlist?.(wl.id)}
                            className="w-full flex items-center gap-3 p-3 rounded-xl bg-card border border-border hover:border-border transition-colors text-left group"
                        >
                            <div className="w-10 h-10 rounded-xl bg-violet-500/10 border border-violet-500/20 flex items-center justify-center shrink-0">
                                <Film size={18} className="text-violet-400" />
                            </div>
                            <div className="flex-1 min-w-0">
                                <p className="text-sm font-semibold text-foreground truncate">{wl.name}</p>
                                <div className="flex items-center gap-2 mt-0.5 text-xs text-muted-foreground">
                                    <span>{wl.memberCount} {wl.memberCount === 1 ? 'member' : 'members'}</span>
                                    <span className="text-muted-foreground/40">·</span>
                                    <span>{wl.itemCount} {wl.itemCount === 1 ? 'movie' : 'movies'}</span>
                                </div>
                            </div>
                            <ChevronRight size={16} className="text-muted-foreground/60 group-hover:text-muted-foreground transition-colors" />
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};

// ── Detail View ──────────────────────────────────────────────────────────────

export const SharedWatchlistDetailView: React.FC<SharedWatchlistDetailViewProps> = ({
    watchlist,
    currentUserId,
    onVote,
    onAddItem,
    onInviteMember,
    onBack,
}) => {
    return (
        <div className="space-y-5">
            {/* Header */}
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                    {onBack && (
                        <button
                            onClick={onBack}
                            className="p-1.5 rounded-lg hover:bg-secondary text-muted-foreground hover:text-foreground transition-colors"
                        >
                            ←
                        </button>
                    )}
                    <div>
                        <h2 className="text-lg font-bold text-foreground">{watchlist.name}</h2>
                        <p className="text-xs text-muted-foreground">
                            Created by {watchlist.creatorUsername}
                        </p>
                    </div>
                </div>
                <div className="flex gap-2">
                    <button
                        onClick={() => onInviteMember?.(watchlist.id)}
                        className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg bg-secondary text-muted-foreground border border-border hover:border-border transition-colors"
                    >
                        <UserPlus size={13} />
                        Invite
                    </button>
                    <button
                        onClick={() => onAddItem?.(watchlist.id)}
                        className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg bg-violet-500/10 text-violet-400 border border-violet-500/20 hover:bg-violet-500/20 transition-colors"
                    >
                        <Plus size={13} />
                        Add Movie
                    </button>
                </div>
            </div>

            {/* Members */}
            {watchlist.members && watchlist.members.length > 0 && (
                <div className="flex items-center gap-1.5">
                    <span className="text-xs text-muted-foreground mr-1">Members:</span>
                    <div className="flex -space-x-2">
                        {watchlist.members.slice(0, 6).map((member) => (
                            <Link key={member.userId} to={`/profile/${member.userId}`}>
                                <img
                                    src={member.avatarUrl || `https://api.dicebear.com/8.x/thumbs/svg?seed=${member.username}`}
                                    alt={member.username}
                                    title={member.displayName || member.username}
                                    className="w-7 h-7 rounded-full border-2 border-background object-cover hover:ring-2 hover:ring-violet-500/50 transition-all"
                                />
                            </Link>
                        ))}
                        {watchlist.members.length > 6 && (
                            <div className="w-7 h-7 rounded-full bg-secondary border-2 border-background flex items-center justify-center text-[10px] font-bold text-muted-foreground">
                                +{watchlist.members.length - 6}
                            </div>
                        )}
                    </div>
                </div>
            )}

            {/* Items */}
            {(!watchlist.items || watchlist.items.length === 0) ? (
                <div className="flex flex-col items-center justify-center py-12 text-muted-foreground/60">
                    <Film size={36} className="mb-2 opacity-30" />
                    <p className="text-sm text-muted-foreground">No movies added yet</p>
                    <p className="text-xs mt-1 opacity-60">Add some movies for the group to vote on!</p>
                </div>
            ) : (
                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
                    {watchlist.items.map((item) => (
                        <div
                            key={item.id}
                            className="group relative rounded-xl overflow-hidden bg-card border border-border hover:border-border transition-all"
                        >
                            {/* Poster */}
                            <div className="relative aspect-[2/3] w-full bg-secondary">
                                {item.posterUrl ? (
                                    <img
                                        src={item.posterUrl}
                                        alt={item.mediaTitle}
                                        className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity"
                                    />
                                ) : (
                                    <div className="w-full h-full flex items-center justify-center">
                                        <Film size={24} className="text-muted-foreground/40" />
                                    </div>
                                )}
                                <div className="absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-transparent" />

                                {/* Vote button */}
                                <button
                                    onClick={() => onVote?.(watchlist.id, item.id)}
                                    className={`absolute top-2 right-2 flex items-center gap-1 px-2 py-1 rounded-full text-xs font-bold transition-all ${item.viewerHasVoted
                                            ? 'bg-violet-500 text-foreground shadow-lg shadow-violet-500/25'
                                            : 'bg-card/50 text-muted-foreground hover:bg-violet-500/20 hover:text-violet-400 border border-border'
                                        }`}
                                >
                                    <ThumbsUp size={11} className={item.viewerHasVoted ? 'fill-current' : ''} />
                                    {item.voteCount > 0 && <span>{item.voteCount}</span>}
                                </button>
                            </div>

                            {/* Info */}
                            <div className="absolute bottom-0 left-0 right-0 p-2.5 pt-6">
                                <p className="text-xs font-semibold text-foreground leading-tight truncate">
                                    {item.mediaTitle}
                                </p>
                                <p className="text-[10px] text-muted-foreground mt-0.5">
                                    Added by {item.addedByUsername}
                                </p>
                            </div>
                        </div>
                    ))}
                </div>
            )}
        </div>
    );
};
