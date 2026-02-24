import React, { useEffect, useState } from 'react';
import { BookOpen, Heart, Lock, Globe, Plus, Trash2, X } from 'lucide-react';
import { MovieList, MovieListItem } from '../types';
import {
    createMovieList,
    getMyMovieLists,
    getMovieListItems,
    addMovieListItem,
    removeMovieListItem,
    toggleListLike,
    deleteMovieList,
} from '../services/friendsService';

interface MovieListViewProps {
    userId: string;
}

export const MovieListView: React.FC<MovieListViewProps> = ({ userId }) => {
    const [lists, setLists] = useState<MovieList[]>([]);
    const [loading, setLoading] = useState(true);
    const [showCreate, setShowCreate] = useState(false);
    const [selectedList, setSelectedList] = useState<MovieList | null>(null);
    const [items, setItems] = useState<MovieListItem[]>([]);

    // Create form
    const [newTitle, setNewTitle] = useState('');
    const [newDesc, setNewDesc] = useState('');
    const [newPublic, setNewPublic] = useState(true);

    const loadLists = async () => {
        setLoading(true);
        const data = await getMyMovieLists(userId);
        setLists(data);
        setLoading(false);
    };

    useEffect(() => {
        if (userId) loadLists();
    }, [userId]);

    const handleCreate = async () => {
        if (!newTitle.trim()) return;
        const list = await createMovieList(userId, newTitle.trim(), newDesc.trim() || undefined, newPublic);
        if (list) {
            setLists((l) => [list, ...l]);
            setShowCreate(false);
            setNewTitle('');
            setNewDesc('');
            setNewPublic(true);
        }
    };

    const handleSelectList = async (list: MovieList) => {
        setSelectedList(list);
        const listItems = await getMovieListItems(list.id);
        setItems(listItems);
    };

    const handleLike = async (listId: string) => {
        const result = await toggleListLike(listId, userId);
        setLists((prev) =>
            prev.map((l) =>
                l.id === listId
                    ? {
                        ...l,
                        isLikedByViewer: result,
                        likeCount: l.likeCount + (result ? 1 : -1),
                    }
                    : l,
            ),
        );
    };

    const handleDelete = async (listId: string) => {
        await deleteMovieList(listId);
        setLists((prev) => prev.filter((l) => l.id !== listId));
        if (selectedList?.id === listId) {
            setSelectedList(null);
            setItems([]);
        }
    };

    const handleRemoveItem = async (itemId: string) => {
        await removeMovieListItem(itemId);
        setItems((prev) => prev.filter((i) => i.id !== itemId));
    };

    if (loading) {
        return (
            <div className="flex items-center justify-center py-12">
                <div className="w-6 h-6 border-2 border-teal-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    // Detail view
    if (selectedList) {
        return (
            <div className="space-y-4">
                <button
                    onClick={() => { setSelectedList(null); setItems([]); }}
                    className="text-xs text-zinc-500 hover:text-zinc-300 flex items-center gap-1"
                >
                    ← Back to lists
                </button>

                <div className="bg-zinc-900/60 rounded-2xl border border-zinc-800/30 p-5 space-y-4">
                    <div className="flex items-start justify-between">
                        <div>
                            <h3 className="text-lg font-bold flex items-center gap-2">
                                {selectedList.title}
                                {selectedList.isPublic ? (
                                    <Globe size={14} className="text-emerald-400" />
                                ) : (
                                    <Lock size={14} className="text-zinc-500" />
                                )}
                            </h3>
                            {selectedList.description && (
                                <p className="text-xs text-zinc-500 mt-1">{selectedList.description}</p>
                            )}
                        </div>
                        <div className="flex items-center gap-2">
                            <button
                                onClick={() => handleLike(selectedList.id)}
                                className={`flex items-center gap-1 px-2 py-1 rounded-lg text-xs transition-colors ${selectedList.isLikedByViewer
                                        ? 'bg-pink-500/15 text-pink-400'
                                        : 'bg-zinc-800 text-zinc-500 hover:text-zinc-300'
                                    }`}
                            >
                                <Heart size={12} fill={selectedList.isLikedByViewer ? 'currentColor' : 'none'} />
                                {selectedList.likeCount}
                            </button>
                        </div>
                    </div>

                    {items.length === 0 ? (
                        <div className="text-center py-8 text-zinc-500">
                            <BookOpen size={24} className="mx-auto mb-2 opacity-40" />
                            <p className="text-xs">No movies in this list yet.</p>
                        </div>
                    ) : (
                        <div className="space-y-1.5">
                            {items.map((item, idx) => (
                                <div
                                    key={item.id}
                                    className="flex items-center gap-3 p-2 rounded-lg bg-zinc-800/30 hover:bg-zinc-800/50 transition-colors"
                                >
                                    <span className="text-sm font-bold text-zinc-700 w-6 text-center">{idx + 1}</span>
                                    {item.posterUrl ? (
                                        <img src={item.posterUrl} alt="" className="w-8 h-12 rounded object-cover flex-shrink-0" />
                                    ) : (
                                        <div className="w-8 h-12 rounded bg-zinc-700 flex-shrink-0" />
                                    )}
                                    <div className="flex-1 min-w-0">
                                        <h4 className="text-xs font-semibold text-zinc-200 truncate">{item.title}</h4>
                                        <p className="text-[10px] text-zinc-500">{item.year}</p>
                                        {item.note && (
                                            <p className="text-[10px] text-zinc-400 italic mt-0.5 truncate">"{item.note}"</p>
                                        )}
                                    </div>
                                    {selectedList.createdBy === userId && (
                                        <button
                                            onClick={() => handleRemoveItem(item.id)}
                                            className="text-zinc-600 hover:text-red-400 transition-colors p-1"
                                        >
                                            <Trash2 size={12} />
                                        </button>
                                    )}
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </div>
        );
    }

    return (
        <div className="space-y-4">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <BookOpen size={18} className="text-teal-500" />
                    <h2 className="text-lg font-bold">Movie Lists</h2>
                </div>
                <button
                    onClick={() => setShowCreate(!showCreate)}
                    className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-teal-500/15 text-teal-400 text-xs font-semibold hover:bg-teal-500/25 transition-colors"
                >
                    <Plus size={14} /> New List
                </button>
            </div>

            {showCreate && (
                <div className="bg-zinc-900/60 rounded-xl border border-zinc-800/30 p-4 space-y-3">
                    <input
                        type="text"
                        placeholder="List title (e.g. Best Horror of the 2010s)..."
                        value={newTitle}
                        onChange={(e) => setNewTitle(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-teal-500 focus:outline-none"
                    />
                    <input
                        type="text"
                        placeholder="Description (optional)"
                        value={newDesc}
                        onChange={(e) => setNewDesc(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-teal-500 focus:outline-none"
                    />
                    <label className="flex items-center gap-2 text-xs text-zinc-400">
                        <input
                            type="checkbox"
                            checked={newPublic}
                            onChange={(e) => setNewPublic(e.target.checked)}
                            className="rounded border-zinc-600 bg-zinc-800 text-teal-500 focus:ring-teal-500"
                        />
                        Make this list public
                    </label>
                    <div className="flex gap-2 justify-end">
                        <button onClick={() => setShowCreate(false)} className="px-3 py-1.5 rounded-lg text-xs text-zinc-500 hover:text-zinc-300">
                            Cancel
                        </button>
                        <button
                            onClick={handleCreate}
                            disabled={!newTitle.trim()}
                            className="px-4 py-1.5 rounded-lg bg-teal-600 text-white text-xs font-semibold hover:bg-teal-500 disabled:opacity-40 transition-colors"
                        >
                            Create List
                        </button>
                    </div>
                </div>
            )}

            {lists.length === 0 ? (
                <div className="text-center py-16 text-zinc-500">
                    <BookOpen size={40} className="mx-auto mb-3 opacity-40" />
                    <p className="text-sm">No movie lists yet. Create your first curated collection!</p>
                </div>
            ) : (
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    {lists.map((list) => (
                        <button
                            key={list.id}
                            onClick={() => handleSelectList(list)}
                            className="text-left p-4 rounded-xl bg-zinc-900/60 border border-zinc-800/30 hover:border-zinc-700 transition-all group"
                        >
                            <div className="flex items-start justify-between">
                                <h3 className="text-sm font-semibold text-zinc-100 group-hover:text-white transition-colors">
                                    {list.title}
                                </h3>
                                {list.isPublic ? (
                                    <Globe size={12} className="text-emerald-400 mt-0.5" />
                                ) : (
                                    <Lock size={12} className="text-zinc-500 mt-0.5" />
                                )}
                            </div>
                            {list.description && (
                                <p className="text-[11px] text-zinc-500 mt-1 line-clamp-2">{list.description}</p>
                            )}
                            <div className="flex items-center gap-3 mt-2 text-[10px] text-zinc-500">
                                <span>{list.itemCount ?? 0} movies</span>
                                <span className="flex items-center gap-0.5">
                                    <Heart size={9} /> {list.likeCount}
                                </span>
                            </div>
                        </button>
                    ))}
                </div>
            )}
        </div>
    );
};

export default MovieListView;
