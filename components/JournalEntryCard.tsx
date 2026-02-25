import React, { useState } from 'react';
import { Heart, Edit3, Camera, Sparkles, ChevronDown, ChevronUp } from 'lucide-react';
import { JournalEntryCard as JournalEntryCardType } from '../types';
import { TIER_COLORS, MOOD_TAGS } from '../constants';
import { toggleJournalLike } from '../services/journalService';

interface JournalEntryCardProps {
  entry: JournalEntryCardType;
  currentUserId: string;
  isLiked?: boolean;
  onEdit?: (entry: JournalEntryCardType) => void;
  isOwnProfile?: boolean;
}

function timeAgo(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'now';
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h`;
  const days = Math.floor(hrs / 24);
  if (days < 30) return `${days}d`;
  return new Date(dateStr).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export const JournalEntryCard: React.FC<JournalEntryCardProps> = ({
  entry,
  currentUserId,
  isLiked: initialIsLiked = false,
  onEdit,
  isOwnProfile = false,
}) => {
  const [liked, setLiked] = useState(initialIsLiked);
  const [likeCount, setLikeCount] = useState(entry.likeCount);
  const [expanded, setExpanded] = useState(false);

  const handleLike = async () => {
    const newLiked = !liked;
    setLiked(newLiked);
    setLikeCount((c) => c + (newLiked ? 1 : -1));
    await toggleJournalLike(currentUserId, entry.id, newLiked);
  };

  const tierColorClass = entry.ratingTier ? TIER_COLORS[entry.ratingTier]?.split(' ')[0] : 'text-zinc-400';
  const reviewTruncated = entry.reviewText && entry.reviewText.length > 200;
  const displayText = expanded ? entry.reviewText : entry.reviewText?.slice(0, 200);

  const moodChips = entry.moodTags
    .map((id) => MOOD_TAGS.find((t) => t.id === id))
    .filter(Boolean);

  return (
    <div className="bg-zinc-900/50 border border-zinc-800 rounded-xl p-3.5">
      <div className="flex gap-3">
        {/* Poster */}
        {entry.posterUrl && (
          <img
            src={entry.posterUrl}
            alt={entry.title}
            className="w-12 h-[72px] rounded-lg object-cover shrink-0"
          />
        )}

        <div className="flex-1 min-w-0">
          {/* Title + tier + date */}
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0">
              <h4 className="text-sm font-semibold text-zinc-100 truncate">{entry.title}</h4>
              <div className="flex items-center gap-2 mt-0.5">
                {entry.ratingTier && (
                  <span className={`text-xs font-bold ${tierColorClass}`}>{entry.ratingTier}</span>
                )}
                <span className="text-[10px] text-zinc-600">{timeAgo(entry.createdAt)}</span>
                {entry.containsSpoilers && (
                  <span className="text-[10px] text-amber-500 font-medium">Spoiler</span>
                )}
              </div>
            </div>
            {isOwnProfile && onEdit && (
              <button
                onClick={() => onEdit(entry)}
                className="p-1.5 text-zinc-600 hover:text-zinc-300 transition-colors"
              >
                <Edit3 size={14} />
              </button>
            )}
          </div>

          {/* Review text */}
          {entry.reviewText && (
            <div className="mt-2">
              <p className="text-xs text-zinc-300 leading-relaxed whitespace-pre-line">
                {displayText}
                {reviewTruncated && !expanded && '...'}
              </p>
              {reviewTruncated && (
                <button
                  onClick={() => setExpanded(!expanded)}
                  className="flex items-center gap-0.5 text-[10px] text-indigo-400 hover:text-indigo-300 mt-1"
                >
                  {expanded ? <><ChevronUp size={10} /> less</> : <><ChevronDown size={10} /> read more</>}
                </button>
              )}
            </div>
          )}

          {/* Mood chips */}
          {moodChips.length > 0 && (
            <div className="flex gap-1 flex-wrap mt-2">
              {moodChips.map((tag) => (
                <span
                  key={tag!.id}
                  className="inline-flex items-center gap-0.5 rounded-full px-2 py-0.5 text-[10px] bg-zinc-800 text-zinc-400 border border-zinc-700/50"
                >
                  {tag!.emoji} {tag!.label}
                </span>
              ))}
            </div>
          )}

          {/* Meta indicators */}
          <div className="flex items-center gap-3 mt-2.5">
            {/* Like */}
            <button
              onClick={handleLike}
              className={`flex items-center gap-1 text-xs transition-colors ${
                liked ? 'text-pink-400' : 'text-zinc-600 hover:text-zinc-400'
              }`}
            >
              <Heart size={13} fill={liked ? 'currentColor' : 'none'} />
              {likeCount > 0 && <span>{likeCount}</span>}
            </button>

            {/* Photo count */}
            {entry.photoPaths.length > 0 && (
              <span className="flex items-center gap-1 text-[10px] text-zinc-600">
                <Camera size={11} /> {entry.photoPaths.length}
              </span>
            )}

            {/* Moments count */}
            {entry.favoriteMoments.filter(Boolean).length > 0 && (
              <span className="flex items-center gap-1 text-[10px] text-zinc-600">
                <Sparkles size={11} /> {entry.favoriteMoments.filter(Boolean).length}
              </span>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
