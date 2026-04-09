import React, { useEffect, useState } from 'react';
import { Heart, Edit3, Camera, Sparkles, ChevronDown, ChevronUp, Users } from 'lucide-react';
import { JournalEntryCard as JournalEntryCardType } from '../../types';
import { TIER_COLORS, MOOD_TAGS } from '../../constants';
import { toggleJournalLike } from '../../services/journalService';
import { getProfilesByIds } from '../../services/friendsService';

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
  const [watchedWithNames, setWatchedWithNames] = useState<string[]>([]);

  // Resolve watched-with UUIDs to usernames
  useEffect(() => {
    if (!entry.watchedWithUserIds?.length) {
      setWatchedWithNames([]);
      return;
    }
    let cancelled = false;
    getProfilesByIds(entry.watchedWithUserIds).then((profileMap) => {
      if (cancelled) return;
      setWatchedWithNames(
        entry.watchedWithUserIds
          .map((id) => profileMap.get(id)?.username)
          .filter((u): u is string => Boolean(u)),
      );
    });
    return () => { cancelled = true; };
  }, [entry.watchedWithUserIds?.join(',')]);

  const handleLike = async () => {
    const newLiked = !liked;
    setLiked(newLiked);
    setLikeCount((c) => c + (newLiked ? 1 : -1));
    await toggleJournalLike(currentUserId, entry.id, newLiked);
  };

  const tierColorClass = entry.ratingTier ? TIER_COLORS[entry.ratingTier]?.split(' ')[0] : 'text-muted-foreground';
  const reviewTruncated = entry.reviewText && entry.reviewText.length > 200;
  const displayText = expanded ? entry.reviewText : entry.reviewText?.slice(0, 200);

  const moodChips = entry.moodTags
    .map((id) => MOOD_TAGS.find((t) => t.id === id))
    .filter(Boolean);

  return (
    <div className="group relative rounded-2xl overflow-hidden bg-card/30">
      {/* Poster — hero of the card */}
      <div className="relative aspect-[2/3]">
        {entry.posterUrl ? (
          <img
            src={entry.posterUrl}
            alt={entry.title}
            className="absolute inset-0 w-full h-full object-cover"
          />
        ) : (
          <div className="absolute inset-0 bg-secondary" />
        )}

        {/* Bottom gradient for text */}
        <div className="absolute inset-x-0 bottom-0 h-2/3 bg-gradient-to-t from-black/80 via-black/40 to-transparent" />

        {/* Tier badge — top-left */}
        {entry.ratingTier && (
          <span
            className={`absolute top-2 left-2 text-xs font-bold px-1.5 py-0.5 rounded ${tierColorClass} bg-black/50 backdrop-blur-sm`}
          >
            {entry.ratingTier}
          </span>
        )}

        {/* Mood emoji — top-right */}
        {moodChips.length > 0 && (
          <div className="absolute top-2 right-2 flex gap-0.5">
            {moodChips.slice(0, 2).map((tag) => (
              <span key={tag!.id} className="text-sm drop-shadow-md" title={tag!.label}>
                {tag!.emoji}
              </span>
            ))}
          </div>
        )}

        {/* Edit button — top-right, on hover */}
        {isOwnProfile && onEdit && (
          <button
            onClick={() => onEdit(entry)}
            className="absolute top-2 right-2 p-1.5 rounded-full bg-black/40 backdrop-blur-sm text-white/70 hover:text-white opacity-0 group-hover:opacity-100 transition-opacity"
            style={moodChips.length > 0 ? { top: '2.25rem' } : undefined}
          >
            <Edit3 size={12} />
          </button>
        )}

        {/* Bottom content — title + actions */}
        <div className="absolute inset-x-0 bottom-0 p-3 space-y-1.5">
          <h4 className="text-sm font-semibold text-white leading-snug line-clamp-2 drop-shadow-sm">
            {entry.title}
          </h4>

          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <button
                onClick={handleLike}
                className={`flex items-center gap-1 text-xs transition-colors ${
                  liked ? 'text-pink-400' : 'text-white/50 hover:text-white/80'
                }`}
              >
                <Heart size={13} fill={liked ? 'currentColor' : 'none'} />
                {likeCount > 0 && <span>{likeCount}</span>}
              </button>
              {entry.photoPaths.length > 0 && (
                <span className="text-white/40"><Camera size={12} /></span>
              )}
              {entry.favoriteMoments.filter(Boolean).length > 0 && (
                <span className="text-white/40"><Sparkles size={12} /></span>
              )}
            </div>
            <span className="text-[11px] text-white/40">{timeAgo(entry.createdAt)}</span>
          </div>
        </div>

        {/* Spoiler overlay */}
        {entry.containsSpoilers && (
          <div className="absolute top-2 left-1/2 -translate-x-1/2 text-[10px] font-semibold text-gold bg-black/50 backdrop-blur-sm rounded-full px-2 py-0.5">
            Spoiler
          </div>
        )}
      </div>

      {/* Review text — below poster if present */}
      {entry.reviewText && (
        <div className="px-3 py-2.5">
          <p className="text-xs text-muted-foreground leading-relaxed whitespace-pre-line line-clamp-3">
            {displayText}
            {reviewTruncated && !expanded && '...'}
          </p>
          {reviewTruncated && (
            <button
              onClick={() => setExpanded(!expanded)}
              className="flex items-center gap-0.5 text-[11px] text-accent hover:text-accent mt-1"
            >
              {expanded ? <><ChevronUp size={10} /> less</> : <><ChevronDown size={10} /> more</>}
            </button>
          )}
        </div>
      )}

      {/* Watched with — below poster if present */}
      {watchedWithNames.length > 0 && (
        <div className={`flex items-center gap-1.5 px-3 pb-2.5 text-[11px] text-muted-foreground ${!entry.reviewText ? 'pt-2' : ''}`}>
          <Users size={10} className="text-accent" />
          <span>with {watchedWithNames.map(u => `@${u}`).join(', ')}</span>
        </div>
      )}
    </div>
  );
};
