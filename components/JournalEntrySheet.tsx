import React, { useEffect, useState, useCallback } from 'react';
import { X, ChevronDown, ChevronUp, Eye, EyeOff, Users, AlertTriangle, Calendar, MapPin, Tv } from 'lucide-react';
import { RankedItem, JournalEntry, StandoutPerformance, JournalVisibility } from '../types';
import { TIER_COLORS, JOURNAL_REVIEW_PROMPTS, JOURNAL_TAKEAWAY_PROMPTS, JOURNAL_MAX_PHOTOS, JOURNAL_MAX_MOMENTS, PLATFORM_OPTIONS } from '../constants';
import { upsertJournalEntry, getJournalEntry, uploadJournalPhoto, deleteJournalPhoto, UpsertJournalData } from '../services/journalService';
import { MoodTagSelector } from './journal/MoodTagSelector';
import { VibeTagSelector } from './journal/VibeTagSelector';
import { CastSelector } from './journal/CastSelector';
import { FriendTagInput } from './journal/FriendTagInput';
import { JournalPhotoGrid } from './journal/JournalPhotoGrid';

interface JournalEntrySheetProps {
  isOpen: boolean;
  item: RankedItem;
  userId: string;
  onDismiss: () => void;
  onSaved?: (entry: JournalEntry) => void;
  existingEntry?: JournalEntry | null;
}

export const JournalEntrySheet: React.FC<JournalEntrySheetProps> = ({
  isOpen,
  item,
  userId,
  onDismiss,
  onSaved,
  existingEntry,
}) => {
  const [reviewText, setReviewText] = useState('');
  const [containsSpoilers, setContainsSpoilers] = useState(false);
  const [moodTags, setMoodTags] = useState<string[]>([]);
  const [vibeTags, setVibeTags] = useState<string[]>([]);
  const [favoriteMoments, setFavoriteMoments] = useState<string[]>([]);
  const [standoutPerformances, setStandoutPerformances] = useState<StandoutPerformance[]>([]);
  const [watchedDate, setWatchedDate] = useState(new Date().toISOString().split('T')[0]);
  const [watchedLocation, setWatchedLocation] = useState('');
  const [watchedWithUserIds, setWatchedWithUserIds] = useState<string[]>([]);
  const [watchedPlatform, setWatchedPlatform] = useState('');
  const [isRewatch, setIsRewatch] = useState(false);
  const [rewatchNote, setRewatchNote] = useState('');
  const [personalTakeaway, setPersonalTakeaway] = useState('');
  const [photoPaths, setPhotoPaths] = useState<string[]>([]);
  const [visibilityOverride, setVisibilityOverride] = useState<JournalVisibility | undefined>(undefined);
  const [showDetails, setShowDetails] = useState(false);
  const [saving, setSaving] = useState(false);
  const [visible, setVisible] = useState(false);
  const [loadedEntryId, setLoadedEntryId] = useState<string | null>(null);

  // Load existing entry
  useEffect(() => {
    if (!isOpen) return;

    if (existingEntry) {
      populateFromEntry(existingEntry);
      return;
    }

    getJournalEntry(userId, item.id).then((entry) => {
      if (entry) populateFromEntry(entry);
    });
  }, [isOpen, item.id, userId, existingEntry]);

  function populateFromEntry(entry: JournalEntry) {
    setLoadedEntryId(entry.id);
    setReviewText(entry.reviewText ?? '');
    setContainsSpoilers(entry.containsSpoilers);
    setMoodTags(entry.moodTags);
    setVibeTags(entry.vibeTags);
    setFavoriteMoments(entry.favoriteMoments);
    setStandoutPerformances(entry.standoutPerformances);
    setWatchedDate(entry.watchedDate ?? new Date().toISOString().split('T')[0]);
    setWatchedLocation(entry.watchedLocation ?? '');
    setWatchedWithUserIds(entry.watchedWithUserIds);
    setWatchedPlatform(entry.watchedPlatform ?? '');
    setIsRewatch(entry.isRewatch);
    setRewatchNote(entry.rewatchNote ?? '');
    setPersonalTakeaway(entry.personalTakeaway ?? '');
    setPhotoPaths(entry.photoPaths);
    setVisibilityOverride(entry.visibilityOverride);
    if (entry.vibeTags.length || entry.favoriteMoments.length || entry.standoutPerformances.length || entry.watchedLocation || entry.personalTakeaway || entry.photoPaths.length) {
      setShowDetails(true);
    }
  }

  // Slide-up animation
  useEffect(() => {
    if (isOpen) {
      requestAnimationFrame(() => setVisible(true));
    } else {
      setVisible(false);
    }
  }, [isOpen]);

  const handleDismiss = useCallback(async () => {
    // Auto-save on dismiss
    await handleSave();
    setVisible(false);
    setTimeout(onDismiss, 300);
  }, [reviewText, moodTags, vibeTags, favoriteMoments, standoutPerformances, watchedDate, watchedLocation, watchedWithUserIds, watchedPlatform, isRewatch, rewatchNote, personalTakeaway, photoPaths, visibilityOverride, containsSpoilers]);

  const handleSave = async () => {
    setSaving(true);
    try {
      const data: UpsertJournalData = {
        title: item.title,
        posterUrl: item.posterUrl,
        reviewText: reviewText || undefined,
        containsSpoilers,
        moodTags,
        vibeTags,
        favoriteMoments: favoriteMoments.filter(Boolean),
        standoutPerformances,
        watchedDate,
        watchedLocation: watchedLocation || undefined,
        watchedWithUserIds,
        watchedPlatform: watchedPlatform || undefined,
        isRewatch,
        rewatchNote: rewatchNote || undefined,
        personalTakeaway: personalTakeaway || undefined,
        photoPaths,
        visibilityOverride,
      };

      const result = await upsertJournalEntry(userId, item.id, data);
      if (result) {
        setLoadedEntryId(result.id);
        onSaved?.(result);
      }
    } catch (err) {
      console.error('Failed to save journal entry:', err);
    } finally {
      setSaving(false);
    }
  };

  const handlePhotoAdd = async (file: File) => {
    if (!loadedEntryId) {
      // Save first to get an entry ID
      const data: UpsertJournalData = { title: item.title, posterUrl: item.posterUrl };
      const result = await upsertJournalEntry(userId, item.id, data);
      if (!result) return;
      setLoadedEntryId(result.id);
      const path = await uploadJournalPhoto(userId, result.id, file, photoPaths.length);
      if (path) setPhotoPaths((prev) => [...prev, path]);
    } else {
      const path = await uploadJournalPhoto(userId, loadedEntryId, file, photoPaths.length);
      if (path) setPhotoPaths((prev) => [...prev, path]);
    }
  };

  const handlePhotoRemove = async (path: string) => {
    if (!loadedEntryId) return;
    const ok = await deleteJournalPhoto(userId, loadedEntryId, path);
    if (ok) setPhotoPaths((prev) => prev.filter((p) => p !== path));
  };

  const updateMoment = (index: number, value: string) => {
    const updated = [...favoriteMoments];
    updated[index] = value;
    setFavoriteMoments(updated);
  };

  const addMoment = () => {
    if (favoriteMoments.length < JOURNAL_MAX_MOMENTS) {
      setFavoriteMoments([...favoriteMoments, '']);
    }
  };

  const removeMoment = (index: number) => {
    setFavoriteMoments(favoriteMoments.filter((_, i) => i !== index));
  };

  const tmdbNumericId = parseInt(item.id.replace('tmdb_', ''), 10);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center">
      {/* Backdrop */}
      <div
        className={`absolute inset-0 bg-black/60 backdrop-blur-sm transition-opacity duration-300 ${visible ? 'opacity-100' : 'opacity-0'}`}
        onClick={handleDismiss}
      />

      {/* Sheet */}
      <div
        className={`relative w-full max-w-md bg-surface rounded-t-2xl shadow-2xl flex flex-col transition-transform duration-300 ease-out ${
          visible ? 'translate-y-0' : 'translate-y-full'
        }`}
        style={{ maxHeight: '80vh' }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center gap-3 p-4 border-b border-zinc-800 shrink-0">
          {item.posterUrl && (
            <img src={item.posterUrl} alt={item.title} className="w-10 h-14 rounded object-cover" />
          )}
          <div className="flex-1 min-w-0">
            <h3 className="text-sm font-semibold text-zinc-100 truncate">{item.title}</h3>
            <span className={`text-xs font-bold ${TIER_COLORS[item.tier]?.split(' ')[0] ?? 'text-zinc-400'}`}>
              {item.tier} Tier
            </span>
          </div>
          <button
            onClick={handleDismiss}
            disabled={saving}
            className="px-4 py-1.5 bg-indigo-500 hover:bg-indigo-400 text-white text-sm font-semibold rounded-full transition-colors disabled:opacity-50"
          >
            {saving ? 'Saving...' : 'Done'}
          </button>
        </div>

        {/* Scrollable content */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Review text */}
          <textarea
            value={reviewText}
            onChange={(e) => setReviewText(e.target.value)}
            placeholder={JOURNAL_REVIEW_PROMPTS[item.tier] ?? 'Write your thoughts...'}
            rows={3}
            className="w-full bg-zinc-900 border border-zinc-800 rounded-xl px-3.5 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 resize-none focus:outline-none focus:border-zinc-600"
          />

          {/* Mood tags */}
          <div>
            <p className="text-xs font-medium text-zinc-400 mb-2">How did this make you feel?</p>
            <MoodTagSelector selected={moodTags} onChange={setMoodTags} />
          </div>

          {/* Expandable details */}
          <button
            type="button"
            onClick={() => setShowDetails(!showDetails)}
            className="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-zinc-300 transition-colors"
          >
            {showDetails ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
            {showDetails ? 'Less details' : 'Add more details'}
          </button>

          {showDetails && (
            <div className="space-y-4">
              {/* Vibe tags */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Vibe</p>
                <VibeTagSelector selected={vibeTags} onChange={setVibeTags} />
              </div>

              {/* Favorite moments */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Favorite moments</p>
                <div className="space-y-1.5">
                  {favoriteMoments.map((moment, i) => (
                    <div key={i} className="flex gap-1.5">
                      <input
                        type="text"
                        value={moment}
                        onChange={(e) => updateMoment(i, e.target.value)}
                        placeholder={`Moment ${i + 1}...`}
                        className="flex-1 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
                      />
                      <button
                        type="button"
                        onClick={() => removeMoment(i)}
                        className="p-1.5 text-zinc-600 hover:text-red-400"
                      >
                        <X size={14} />
                      </button>
                    </div>
                  ))}
                  {favoriteMoments.length < JOURNAL_MAX_MOMENTS && (
                    <button
                      type="button"
                      onClick={addMoment}
                      className="text-xs text-indigo-400 hover:text-indigo-300"
                    >
                      + Add moment
                    </button>
                  )}
                </div>
              </div>

              {/* Standout performances */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Standout performances</p>
                <CastSelector
                  tmdbId={tmdbNumericId}
                  selected={standoutPerformances}
                  onChange={setStandoutPerformances}
                />
              </div>

              {/* Watch context */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Watch context</p>
                <div className="space-y-2">
                  {/* Date */}
                  <div className="flex items-center gap-2">
                    <Calendar size={14} className="text-zinc-500 shrink-0" />
                    <input
                      type="date"
                      value={watchedDate}
                      onChange={(e) => setWatchedDate(e.target.value)}
                      className="flex-1 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 focus:outline-none focus:border-zinc-600"
                    />
                  </div>

                  {/* Location */}
                  <div className="flex items-center gap-2">
                    <MapPin size={14} className="text-zinc-500 shrink-0" />
                    <input
                      type="text"
                      value={watchedLocation}
                      onChange={(e) => setWatchedLocation(e.target.value)}
                      placeholder="Where did you watch?"
                      className="flex-1 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
                    />
                  </div>

                  {/* Platform */}
                  <div className="flex items-center gap-2">
                    <Tv size={14} className="text-zinc-500 shrink-0" />
                    <select
                      value={watchedPlatform}
                      onChange={(e) => setWatchedPlatform(e.target.value)}
                      className="flex-1 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 focus:outline-none focus:border-zinc-600"
                    >
                      <option value="">Select platform...</option>
                      {PLATFORM_OPTIONS.map((opt) => (
                        <option key={opt.id} value={opt.id}>{opt.label}</option>
                      ))}
                    </select>
                  </div>

                  {/* Watched with */}
                  <div>
                    <div className="flex items-center gap-2 mb-1.5">
                      <Users size={14} className="text-zinc-500 shrink-0" />
                      <span className="text-xs text-zinc-500">Watched with</span>
                    </div>
                    <FriendTagInput
                      currentUserId={userId}
                      selectedUserIds={watchedWithUserIds}
                      onChange={setWatchedWithUserIds}
                    />
                  </div>
                </div>
              </div>

              {/* Photos */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Photos</p>
                <JournalPhotoGrid
                  photoPaths={photoPaths}
                  onAdd={handlePhotoAdd}
                  onRemove={handlePhotoRemove}
                  maxPhotos={JOURNAL_MAX_PHOTOS}
                />
              </div>

              {/* Rewatch */}
              <div className="flex items-center gap-3">
                <label className="flex items-center gap-2 text-sm text-zinc-300 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={isRewatch}
                    onChange={(e) => setIsRewatch(e.target.checked)}
                    className="rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-indigo-500/20"
                  />
                  Rewatch
                </label>
              </div>
              {isRewatch && (
                <input
                  type="text"
                  value={rewatchNote}
                  onChange={(e) => setRewatchNote(e.target.value)}
                  placeholder="What was different this time?"
                  className="w-full bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
                />
              )}

              {/* Personal takeaway */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Personal takeaway (private)</p>
                <textarea
                  value={personalTakeaway}
                  onChange={(e) => setPersonalTakeaway(e.target.value)}
                  placeholder={JOURNAL_TAKEAWAY_PROMPTS[item.tier] ?? 'Your personal reflection...'}
                  rows={2}
                  className="w-full bg-zinc-900 border border-zinc-800 rounded-xl px-3.5 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 resize-none focus:outline-none focus:border-zinc-600"
                />
              </div>

              {/* Spoiler toggle */}
              <div className="flex items-center gap-3">
                <label className="flex items-center gap-2 text-sm text-zinc-300 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={containsSpoilers}
                    onChange={(e) => setContainsSpoilers(e.target.checked)}
                    className="rounded border-zinc-700 bg-zinc-900 text-amber-500 focus:ring-amber-500/20"
                  />
                  <AlertTriangle size={14} className="text-amber-400" />
                  Contains spoilers
                </label>
              </div>

              {/* Visibility */}
              <div>
                <p className="text-xs font-medium text-zinc-400 mb-2">Visibility</p>
                <div className="flex gap-2">
                  {([undefined, 'public', 'friends', 'private'] as const).map((vis) => {
                    const label = vis === undefined ? 'Default' : vis === 'public' ? 'Public' : vis === 'friends' ? 'Friends' : 'Private';
                    const icon = vis === 'private' ? <EyeOff size={12} /> : vis === 'friends' ? <Users size={12} /> : <Eye size={12} />;
                    const active = visibilityOverride === vis;
                    return (
                      <button
                        key={vis ?? 'default'}
                        type="button"
                        onClick={() => setVisibilityOverride(vis as JournalVisibility | undefined)}
                        className={`flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium border transition-colors ${
                          active
                            ? 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30'
                            : 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600'
                        }`}
                      >
                        {icon} {label}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
