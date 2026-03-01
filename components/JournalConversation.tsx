import React, { useEffect, useState, useCallback, useRef } from 'react';
import { X, ChevronDown, ChevronUp, Eye, EyeOff, Users, AlertTriangle, Calendar, MapPin, Tv, Send, Sparkles, ArrowLeft, MessageSquare } from 'lucide-react';
import { RankedItem, JournalEntry, StandoutPerformance, JournalVisibility } from '../types';
import { TIER_COLORS, JOURNAL_REVIEW_PROMPTS, JOURNAL_TAKEAWAY_PROMPTS, JOURNAL_MAX_PHOTOS, JOURNAL_MAX_MOMENTS, PLATFORM_OPTIONS } from '../constants';
import { upsertJournalEntry, getJournalEntry, uploadJournalPhoto, deleteJournalPhoto, UpsertJournalData } from '../services/journalService';
import { createSession, sendAgentMessage, requestReviewGeneration, endSession, AgentContext } from '../services/agentService';
import { recordAllCorrections } from '../services/correctionService';
import { MoodTagSelector } from './journal/MoodTagSelector';
import { VibeTagSelector } from './journal/VibeTagSelector';
import { CastSelector } from './journal/CastSelector';
import { FriendTagInput } from './journal/FriendTagInput';
import { JournalPhotoGrid } from './journal/JournalPhotoGrid';

interface JournalConversationProps {
  isOpen: boolean;
  item: RankedItem;
  userId: string;
  existingEntry?: JournalEntry | null;
  onDismiss: () => void;
  onSaved?: (entry: JournalEntry) => void;
}

export const JournalConversation: React.FC<JournalConversationProps> = ({
  isOpen,
  item,
  userId,
  existingEntry,
  onDismiss,
  onSaved,
}) => {
  // Conversation phase
  const [phase, setPhase] = useState<'chat' | 'draft'>('chat');
  const [messages, setMessages] = useState<{ role: 'agent' | 'user'; content: string }[]>([]);
  const [inputText, setInputText] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [sessionId, setSessionId] = useState<string | null>(null);

  // Draft phase (generated values + user edits)
  const [generationId, setGenerationId] = useState<string | null>(null);
  const [generatedFields, setGeneratedFields] = useState<Record<string, string> | null>(null);
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

  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const userMessageCount = messages.filter((m) => m.role === 'user').length;

  const buildContext = useCallback((): AgentContext => ({
    movie: {
      title: item.title,
      year: item.year,
      genres: item.genres,
      director: item.director,
    },
    ranking: {
      tier: item.tier,
      score: item.rank,
      primaryGenre: item.genres?.[0],
    },
    userProfile: {
      moodHistory: [],
      topGenres: {},
      recentJournalCount: 0,
    },
  }), [item]);

  // Populate from existing entry
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

  // On open: create session or go to draft for existing entry
  useEffect(() => {
    if (!isOpen) return;

    if (existingEntry) {
      populateFromEntry(existingEntry);
      setPhase('draft');
      return;
    }

    // Try loading any saved entry
    getJournalEntry(userId, item.id).then((entry) => {
      if (entry) {
        populateFromEntry(entry);
      }
    });

    // Create agent session and send initial message
    const initSession = async () => {
      const context = buildContext();
      const session = await createSession(
        userId,
        item.id,
        undefined,
        context as unknown as Record<string, unknown>,
        'v1',
      );

      if (session) {
        setSessionId(session.id);
        // Send initial context to get first agent message
        setIsLoading(true);
        const result = await sendAgentMessage(session.id, `I just ranked ${item.title} (${item.year}) as ${item.tier} Tier.`, context);
        setIsLoading(false);
        if (result?.reply) {
          setMessages([
            { role: 'user', content: `I just ranked ${item.title} (${item.year}) as ${item.tier} Tier.` },
            { role: 'agent', content: result.reply },
          ]);
        } else {
          // Fallback if session creation or first message fails
          setMessages([
            { role: 'agent', content: `I see you rated ${item.title} as ${item.tier} Tier. What stood out to you about this one?` },
          ]);
        }
      } else {
        // Consent denied or error: show a fallback message
        setMessages([
          { role: 'agent', content: `I see you rated ${item.title} as ${item.tier} Tier. What stood out to you about this one?` },
        ]);
      }
    };

    initSession();
  }, [isOpen, item.id, userId, existingEntry, buildContext, item.title, item.year, item.tier]);

  // Slide-up animation
  useEffect(() => {
    if (isOpen) {
      requestAnimationFrame(() => setVisible(true));
    } else {
      setVisible(false);
    }
  }, [isOpen]);

  // Auto-scroll messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, isLoading]);

  const handleDismiss = useCallback(() => {
    if (sessionId) {
      endSession(sessionId, 'abandoned');
    }
    setVisible(false);
    setTimeout(onDismiss, 300);
  }, [sessionId, onDismiss]);

  // Chat: send message
  const handleSendMessage = useCallback(async () => {
    const text = inputText.trim();
    if (!text || isLoading) return;

    setMessages((prev) => [...prev, { role: 'user', content: text }]);
    setInputText('');
    setIsLoading(true);

    if (sessionId) {
      const result = await sendAgentMessage(sessionId, text, buildContext());
      if (result?.reply) {
        setMessages((prev) => [...prev, { role: 'agent', content: result.reply }]);
      }
    }

    setIsLoading(false);
    inputRef.current?.focus();
  }, [inputText, isLoading, sessionId, buildContext]);

  // Chat: generate review
  const handleGenerate = useCallback(async () => {
    if (!sessionId || isLoading) return;
    setIsLoading(true);

    const generation = await requestReviewGeneration(sessionId, buildContext());

    if (generation) {
      setGenerationId(generation.id);
      setReviewText(generation.generatedReviewText ?? '');
      setMoodTags(generation.generatedMoodTags ?? []);
      setFavoriteMoments(generation.generatedFavoriteMoments ?? []);
      setPersonalTakeaway(generation.generatedPersonalTakeaway ?? '');
      // Map standout performances strings to the expected format
      if (generation.generatedStandoutPerformances?.length) {
        setStandoutPerformances(
          generation.generatedStandoutPerformances.map((perf, i) => ({
            personId: i,
            name: perf,
          })),
        );
      }

      setGeneratedFields({
        reviewText: generation.generatedReviewText ?? '',
        moodTags: JSON.stringify(generation.generatedMoodTags),
        favoriteMoments: JSON.stringify(generation.generatedFavoriteMoments),
        personalTakeaway: generation.generatedPersonalTakeaway ?? '',
        standoutPerformances: JSON.stringify(generation.generatedStandoutPerformances),
      });

      setPhase('draft');
    }

    setIsLoading(false);
  }, [sessionId, isLoading, buildContext]);

  // Skip to form
  const handleSkipToForm = useCallback(() => {
    setPhase('draft');
  }, []);

  // Back to chat
  const handleBackToChat = useCallback(() => {
    setPhase('chat');
  }, []);

  // Save journal entry
  const handleSave = async () => {
    setSaving(true);
    try {
      // Record corrections if we have generated fields
      if (generatedFields && generationId) {
        const finalFields: Record<string, string> = {
          reviewText: reviewText,
          moodTags: JSON.stringify(moodTags),
          favoriteMoments: JSON.stringify(favoriteMoments.filter(Boolean)),
          personalTakeaway: personalTakeaway,
          standoutPerformances: JSON.stringify(standoutPerformances.map((p) => p.name)),
        };
        await recordAllCorrections(generationId, userId, generatedFields, finalFields);
      }

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
        if (sessionId) {
          endSession(sessionId, 'completed');
        }
        onSaved?.(result);
      }
    } catch (err) {
      console.error('Failed to save journal entry:', err);
    } finally {
      setSaving(false);
      setVisible(false);
      setTimeout(onDismiss, 300);
    }
  };

  // Photo handlers
  const handlePhotoAdd = async (file: File) => {
    if (!loadedEntryId) {
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
        {phase === 'chat' ? (
          <>
            {/* Chat Header */}
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
                onClick={handleSkipToForm}
                className="flex items-center gap-1 px-3 py-1.5 text-xs text-zinc-400 hover:text-zinc-200 border border-zinc-700 rounded-full transition-colors"
              >
                <MessageSquare size={12} />
                Skip to form
              </button>
            </div>

            {/* Messages */}
            <div className="flex-1 overflow-y-auto p-4 space-y-3">
              {messages.map((msg, i) => (
                <div
                  key={i}
                  className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
                >
                  <div
                    className={`max-w-[85%] rounded-2xl px-3.5 py-2.5 text-sm leading-relaxed ${
                      msg.role === 'agent'
                        ? 'bg-zinc-800 text-zinc-200'
                        : 'bg-indigo-500/20 text-zinc-200'
                    }`}
                  >
                    {msg.content}
                  </div>
                </div>
              ))}
              {isLoading && (
                <div className="flex justify-start">
                  <div className="bg-zinc-800 rounded-2xl px-3.5 py-2.5 text-sm text-zinc-400">
                    <span className="inline-flex gap-1">
                      <span className="animate-bounce" style={{ animationDelay: '0ms' }}>.</span>
                      <span className="animate-bounce" style={{ animationDelay: '150ms' }}>.</span>
                      <span className="animate-bounce" style={{ animationDelay: '300ms' }}>.</span>
                    </span>
                  </div>
                </div>
              )}
              <div ref={messagesEndRef} />
            </div>

            {/* Input area */}
            <div className="p-4 border-t border-zinc-800 shrink-0 space-y-2">
              <div className="flex gap-2">
                <input
                  ref={inputRef}
                  type="text"
                  value={inputText}
                  onChange={(e) => setInputText(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSendMessage(); } }}
                  placeholder="Share your thoughts..."
                  disabled={isLoading}
                  className="flex-1 bg-zinc-900 border border-zinc-800 rounded-xl px-3.5 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600 disabled:opacity-50"
                />
                <button
                  onClick={handleSendMessage}
                  disabled={!inputText.trim() || isLoading}
                  className="p-2.5 bg-indigo-500 hover:bg-indigo-400 text-white rounded-xl transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <Send size={16} />
                </button>
              </div>
              {userMessageCount >= 2 && (
                <button
                  onClick={handleGenerate}
                  disabled={isLoading}
                  className="w-full flex items-center justify-center gap-2 py-2.5 bg-indigo-500/20 hover:bg-indigo-500/30 text-indigo-300 text-sm font-medium rounded-xl border border-indigo-500/30 transition-colors disabled:opacity-50"
                >
                  <Sparkles size={14} />
                  Generate my review
                </button>
              )}
            </div>
          </>
        ) : (
          <>
            {/* Draft Header */}
            <div className="flex items-center gap-3 p-4 border-b border-zinc-800 shrink-0">
              {messages.length > 0 && (
                <button
                  onClick={handleBackToChat}
                  className="p-1.5 text-zinc-400 hover:text-zinc-200 transition-colors"
                >
                  <ArrowLeft size={18} />
                </button>
              )}
              <h3 className="flex-1 text-sm font-semibold text-zinc-100">Your Review Draft</h3>
              <button
                onClick={handleSave}
                disabled={saving}
                className="px-4 py-1.5 bg-indigo-500 hover:bg-indigo-400 text-white text-sm font-semibold rounded-full transition-colors disabled:opacity-50"
              >
                {saving ? 'Saving...' : 'Save'}
              </button>
            </div>

            {/* Draft Scrollable Content */}
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
                      <div className="flex items-center gap-2">
                        <Calendar size={14} className="text-zinc-500 shrink-0" />
                        <input
                          type="date"
                          value={watchedDate}
                          onChange={(e) => setWatchedDate(e.target.value)}
                          className="flex-1 bg-zinc-900 border border-zinc-800 rounded-lg px-3 py-1.5 text-sm text-zinc-200 focus:outline-none focus:border-zinc-600"
                        />
                      </div>
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
          </>
        )}
      </div>
    </div>
  );
};
