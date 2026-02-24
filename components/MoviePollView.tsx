import React, { useEffect, useState } from 'react';
import { BarChart, Check, Clock, Plus, Vote, X } from 'lucide-react';
import { MoviePoll, MoviePollOption } from '../types';
import {
    createMoviePoll,
    getMyPolls,
    votePoll,
    closePoll,
} from '../services/friendsService';

interface MoviePollViewProps {
    userId: string;
}

export const MoviePollView: React.FC<MoviePollViewProps> = ({ userId }) => {
    const [polls, setPolls] = useState<MoviePoll[]>([]);
    const [loading, setLoading] = useState(true);
    const [showCreate, setShowCreate] = useState(false);

    // Create form
    const [newQuestion, setNewQuestion] = useState('What should we watch?');
    const [newOptions, setNewOptions] = useState<{ title: string; tmdbId: string }[]>([
        { title: '', tmdbId: '' },
        { title: '', tmdbId: '' },
    ]);

    const loadPolls = async () => {
        setLoading(true);
        const data = await getMyPolls(userId);
        setPolls(data);
        setLoading(false);
    };

    useEffect(() => {
        if (userId) loadPolls();
    }, [userId]);

    const handleCreate = async () => {
        const validOptions = newOptions.filter((o) => o.title.trim());
        if (!newQuestion.trim() || validOptions.length < 2) return;

        const poll = await createMoviePoll(userId, newQuestion.trim(), validOptions);
        if (poll) {
            setPolls((p) => [poll, ...p]);
            setShowCreate(false);
            setNewQuestion('What should we watch?');
            setNewOptions([{ title: '', tmdbId: '' }, { title: '', tmdbId: '' }]);
        }
    };

    const handleVote = async (pollId: string, optionId: string) => {
        await votePoll(pollId, userId, optionId);
        // Reload polls to get updated counts
        await loadPolls();
    };

    const handleClose = async (pollId: string) => {
        await closePoll(pollId);
        setPolls((prev) =>
            prev.map((p) => (p.id === pollId ? { ...p, isClosed: true } : p)),
        );
    };

    const addOption = () => {
        if (newOptions.length < 8) {
            setNewOptions([...newOptions, { title: '', tmdbId: '' }]);
        }
    };

    const removeOption = (idx: number) => {
        if (newOptions.length > 2) {
            setNewOptions(newOptions.filter((_, i) => i !== idx));
        }
    };

    const updateOption = (idx: number, title: string) => {
        setNewOptions(newOptions.map((o, i) => (i === idx ? { ...o, title } : o)));
    };

    if (loading) {
        return (
            <div className="flex items-center justify-center py-12">
                <div className="w-6 h-6 border-2 border-pink-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    return (
        <div className="space-y-4">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                    <Vote size={18} className="text-pink-500" />
                    <h2 className="text-lg font-bold">Movie Polls</h2>
                </div>
                <button
                    onClick={() => setShowCreate(!showCreate)}
                    className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-pink-500/15 text-pink-400 text-xs font-semibold hover:bg-pink-500/25 transition-colors"
                >
                    <Plus size={14} /> New Poll
                </button>
            </div>

            {/* Create form */}
            {showCreate && (
                <div className="bg-zinc-900/60 rounded-xl border border-zinc-800/30 p-4 space-y-3">
                    <input
                        type="text"
                        placeholder="Your question..."
                        value={newQuestion}
                        onChange={(e) => setNewQuestion(e.target.value)}
                        className="w-full bg-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-pink-500 focus:outline-none"
                    />

                    <div className="space-y-2">
                        <p className="text-xs text-zinc-500">Options (2–8):</p>
                        {newOptions.map((opt, idx) => (
                            <div key={idx} className="flex items-center gap-2">
                                <span className="text-xs text-zinc-600 w-5 text-center">{idx + 1}.</span>
                                <input
                                    type="text"
                                    placeholder={`Movie ${idx + 1}...`}
                                    value={opt.title}
                                    onChange={(e) => updateOption(idx, e.target.value)}
                                    className="flex-1 bg-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-100 placeholder-zinc-500 border border-zinc-700 focus:border-pink-500 focus:outline-none"
                                />
                                {newOptions.length > 2 && (
                                    <button onClick={() => removeOption(idx)} className="text-zinc-600 hover:text-zinc-400">
                                        <X size={14} />
                                    </button>
                                )}
                            </div>
                        ))}
                        {newOptions.length < 8 && (
                            <button
                                onClick={addOption}
                                className="text-xs text-pink-400 hover:text-pink-300 flex items-center gap-1"
                            >
                                <Plus size={12} /> Add option
                            </button>
                        )}
                    </div>

                    <div className="flex gap-2 justify-end">
                        <button onClick={() => setShowCreate(false)} className="px-3 py-1.5 rounded-lg text-xs text-zinc-500 hover:text-zinc-300">
                            Cancel
                        </button>
                        <button
                            onClick={handleCreate}
                            disabled={!newQuestion.trim() || newOptions.filter((o) => o.title.trim()).length < 2}
                            className="px-4 py-1.5 rounded-lg bg-pink-600 text-white text-xs font-semibold hover:bg-pink-500 disabled:opacity-40 transition-colors"
                        >
                            Create Poll
                        </button>
                    </div>
                </div>
            )}

            {/* Poll list */}
            {polls.length === 0 ? (
                <div className="text-center py-16 text-zinc-500">
                    <Vote size={40} className="mx-auto mb-3 opacity-40" />
                    <p className="text-sm">No polls yet. Create one to vote with friends!</p>
                </div>
            ) : (
                <div className="space-y-3">
                    {polls.map((poll) => {
                        const maxVotes = Math.max(
                            ...(poll.options?.map((o) => o.voteCount ?? 0) ?? [1]),
                            1,
                        );
                        const isExpired = poll.expiresAt && new Date(poll.expiresAt) < new Date();
                        const closed = poll.isClosed || isExpired;

                        return (
                            <div
                                key={poll.id}
                                className="bg-zinc-900/60 rounded-xl border border-zinc-800/30 p-4 space-y-3"
                            >
                                <div className="flex items-start justify-between">
                                    <div>
                                        <h3 className="text-sm font-bold text-zinc-100">{poll.question}</h3>
                                        <p className="text-[10px] text-zinc-500 mt-0.5">
                                            by {poll.creatorUsername || 'you'} · {poll.totalVotes ?? 0} votes
                                            {closed && <span className="ml-1 text-red-400">· Closed</span>}
                                        </p>
                                    </div>
                                    {poll.createdBy === userId && !closed && (
                                        <button
                                            onClick={() => handleClose(poll.id)}
                                            className="text-[10px] text-zinc-500 hover:text-zinc-300 px-2 py-0.5 rounded border border-zinc-700"
                                        >
                                            Close
                                        </button>
                                    )}
                                </div>

                                {/* Options with vote bars */}
                                <div className="space-y-1.5">
                                    {(poll.options ?? []).map((opt) => {
                                        const votes = opt.voteCount ?? 0;
                                        const pct = maxVotes > 0 ? (votes / maxVotes) * 100 : 0;
                                        const isVoted = poll.viewerVoteOptionId === opt.id;
                                        const isWinner = closed && opt.isWinner;

                                        return (
                                            <button
                                                key={opt.id}
                                                onClick={() => !closed && handleVote(poll.id, opt.id)}
                                                disabled={closed}
                                                className={`w-full relative overflow-hidden rounded-lg p-2.5 text-left transition-all ${isVoted
                                                        ? 'ring-1 ring-pink-500 bg-pink-500/10'
                                                        : 'bg-zinc-800/50 hover:bg-zinc-800'
                                                    } ${closed ? 'cursor-default' : 'cursor-pointer'}`}
                                            >
                                                {/* Bar fill */}
                                                <div
                                                    className={`absolute inset-y-0 left-0 transition-all duration-500 ${isWinner ? 'bg-pink-500/20' : 'bg-zinc-700/30'
                                                        }`}
                                                    style={{ width: `${pct}%` }}
                                                />

                                                <div className="relative flex items-center justify-between">
                                                    <div className="flex items-center gap-2">
                                                        {opt.posterUrl && (
                                                            <img src={opt.posterUrl} alt="" className="w-6 h-9 rounded object-cover" />
                                                        )}
                                                        <span className="text-xs font-medium text-zinc-200 truncate">
                                                            {opt.title}
                                                        </span>
                                                        {isVoted && <Check size={12} className="text-pink-400" />}
                                                        {isWinner && <span className="text-[10px] text-pink-400 font-bold">🏆</span>}
                                                    </div>
                                                    <span className="text-[10px] text-zinc-400 font-semibold ml-2">
                                                        {votes}
                                                    </span>
                                                </div>
                                            </button>
                                        );
                                    })}
                                </div>
                            </div>
                        );
                    })}
                </div>
            )}
        </div>
    );
};

export default MoviePollView;
