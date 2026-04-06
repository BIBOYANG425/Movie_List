import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import FocusTrap from 'focus-trap-react';
import { X, BookOpen, MapPin, Monitor, Star, Quote, RotateCcw } from 'lucide-react';
import { MovieStub, JournalEntry } from '../../types';
import { updateStubWatchedDate } from '../../services/stubService';
import { getJournalEntry } from '../../services/journalService';
import { useTranslation } from '../../contexts/LanguageContext';
import { StubCard } from './StubCard';
import { TIER_LABELS } from '../../constants';

interface StubDetailModalProps {
  stub: MovieStub;
  isOwnProfile: boolean;
  onClose: () => void;
  onDateChanged?: (stubId: string, newDate: string) => void;
}

export const StubDetailModal: React.FC<StubDetailModalProps> = ({
  stub,
  isOwnProfile,
  onClose,
  onDateChanged,
}) => {
  const { t } = useTranslation();
  const [watchedDate, setWatchedDate] = useState(stub.watchedDate);
  const [saving, setSaving] = useState(false);
  const [journal, setJournal] = useState<JournalEntry | null>(null);
  const [loadingJournal, setLoadingJournal] = useState(true);

  useEffect(() => {
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose]);

  // Fetch journal entry for this stub's media (only for own profile to respect privacy)
  useEffect(() => {
    if (!isOwnProfile) {
      setLoadingJournal(false);
      return;
    }
    let cancelled = false;
    setLoadingJournal(true);
    getJournalEntry(stub.userId, stub.tmdbId)
      .then((entry) => {
        if (!cancelled) {
          setJournal(entry);
          setLoadingJournal(false);
        }
      })
      .catch((err) => {
        console.error('Failed to load journal entry:', err);
        if (!cancelled) setLoadingJournal(false);
      });
    return () => { cancelled = true; };
  }, [stub.userId, stub.tmdbId, isOwnProfile]);

  const handleDateChange = async (newDate: string) => {
    if (newDate === watchedDate || !newDate) return;
    setSaving(true);
    const ok = await updateStubWatchedDate(stub.id, newDate);
    if (ok) {
      setWatchedDate(newDate);
      onDateChanged?.(stub.id, newDate);
    }
    setSaving(false);
  };

  return createPortal(
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
    <div
      className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/70 backdrop-blur-sm p-4 overflow-y-auto"
      onClick={onClose}
    >
      <div
        className="relative w-full max-w-md space-y-4 my-auto"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Close button */}
        <button
          onClick={onClose}
          aria-label="Close"
          className="absolute -top-2 -right-2 z-10 w-8 h-8 rounded-full bg-card border border-border flex items-center justify-center text-muted-foreground hover:text-foreground transition-colors"
        >
          <X size={16} aria-hidden="true" />
        </button>

        {/* Full stub card */}
        <div className="flex justify-center">
          <StubCard stub={{ ...stub, watchedDate }} size="full" />
        </div>

        {/* Journal / Review section */}
        {loadingJournal ? (
          <div className="rounded-xl bg-card/60 border border-border/30 p-4 space-y-3 animate-pulse">
            <div className="h-4 bg-secondary/40 rounded w-1/3" />
            <div className="h-3 bg-secondary/40 rounded w-full" />
            <div className="h-3 bg-secondary/40 rounded w-2/3" />
          </div>
        ) : journal ? (
          <div className="rounded-xl bg-card/60 border border-border/30 p-4 space-y-3">
            {/* Review header */}
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <BookOpen size={14} className="text-gold" />
              <span className="font-semibold text-foreground">{t('stubs.yourReview')}</span>
              {journal.ratingTier && (
                <span className="ml-auto text-xs px-2 py-0.5 rounded-full bg-gold/10 text-gold font-medium">
                  {TIER_LABELS[journal.ratingTier]}
                </span>
              )}
            </div>

            {/* Review text */}
            {journal.reviewText && (
              <p className="text-sm text-foreground/90 leading-relaxed whitespace-pre-wrap">
                {journal.reviewText}
              </p>
            )}

            {/* Personal takeaway */}
            {journal.personalTakeaway && (
              <div className="flex gap-2 text-sm text-muted-foreground italic">
                <Quote size={14} className="flex-shrink-0 mt-0.5 text-accent" />
                <span>{journal.personalTakeaway}</span>
              </div>
            )}

            {/* Mood & vibe tags */}
            {(journal.moodTags.length > 0 || journal.vibeTags.length > 0) && (
              <div className="flex flex-wrap gap-1.5">
                {journal.moodTags.map((tag) => (
                  <span key={`mood-${tag}`} className="text-xs px-2 py-0.5 rounded-full bg-accent/10 text-accent">
                    {tag}
                  </span>
                ))}
                {journal.vibeTags.map((tag) => (
                  <span key={`vibe-${tag}`} className="text-xs px-2 py-0.5 rounded-full bg-gold/10 text-gold">
                    {tag}
                  </span>
                ))}
              </div>
            )}

            {/* Favorite moments */}
            {journal.favoriteMoments.length > 0 && (
              <div className="space-y-1">
                <p className="text-xs font-semibold text-muted-foreground flex items-center gap-1.5">
                  <Star size={12} className="text-gold" /> {t('stubs.favoriteMoments')}
                </p>
                <ul className="text-sm text-foreground/80 space-y-0.5 pl-4">
                  {journal.favoriteMoments.map((m, i) => (
                    <li key={i} className="list-disc">{m}</li>
                  ))}
                </ul>
              </div>
            )}

            {/* Standout performances */}
            {journal.standoutPerformances.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {journal.standoutPerformances.map((p) => (
                  <span key={p.personId} className="text-xs px-2 py-0.5 rounded-full bg-secondary/40 text-foreground">
                    {p.name}{p.character ? ` ${t('stubs.asCharacter')} ${p.character}` : ''}
                  </span>
                ))}
              </div>
            )}

            {/* Meta: location, platform, rewatch */}
            <div className="flex flex-wrap gap-3 text-xs text-muted-foreground pt-1 border-t border-border/20">
              {journal.watchedLocation && (
                <span className="flex items-center gap-1">
                  <MapPin size={11} /> {journal.watchedLocation}
                </span>
              )}
              {journal.watchedPlatform && (
                <span className="flex items-center gap-1">
                  <Monitor size={11} /> {journal.watchedPlatform}
                </span>
              )}
              {journal.isRewatch && (
                <span className="flex items-center gap-1">
                  <RotateCcw size={11} /> {t('stubs.rewatch')}
                  {journal.rewatchNote && ` — ${journal.rewatchNote}`}
                </span>
              )}
            </div>
          </div>
        ) : (
          <div className="rounded-xl bg-card/60 border border-border/30 p-4 text-center text-sm text-muted-foreground">
            {t('stubs.noReview')}
          </div>
        )}

        {/* Palette swatches */}
        {stub.palette.length > 0 && (
          <div className="flex items-center justify-center gap-2">
            {stub.palette.map((color, i) => (
              <div
                key={i}
                className="w-6 h-6 rounded-full border border-white/10"
                style={{ backgroundColor: color }}
                title={color}
              />
            ))}
          </div>
        )}

        {/* Date picker (own profile only) */}
        {isOwnProfile && (
          <div className="flex items-center justify-center gap-2 text-sm">
            <label className="text-muted-foreground">{t('stubs.watchedOn')}:</label>
            <input
              type="date"
              value={watchedDate}
              onChange={(e) => handleDateChange(e.target.value)}
              disabled={saving}
              className="rounded-lg border border-border bg-background px-3 py-1.5 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-accent/40"
            />
          </div>
        )}
      </div>
    </div>
    </FocusTrap>,
    document.body,
  );
};
