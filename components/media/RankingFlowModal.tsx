import React, { useState, useEffect, useRef } from 'react';
import FocusTrap from 'focus-trap-react';
import { X, ArrowLeft } from 'lucide-react';
import { RankedItem, Tier, Bracket, ComparisonLogEntry } from '../../types';
import { useRankingCeremony } from '../../hooks/useRankingCeremony';
import { useAuth } from '../../contexts/AuthContext';
import { useTranslation } from '../../contexts/LanguageContext';
import { TierPicker } from '../shared/TierPicker';
import { NotesStep } from '../shared/NotesStep';
import { ComparisonStep } from '../shared/ComparisonStep';

interface RankingFlowModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  selectedItem: RankedItem;
  currentItems: RankedItem[];
  preselectedTier?: Tier;
  onCompare?: (log: ComparisonLogEntry) => void;
}

type Step = 'tier' | 'notes' | 'compare';

export const RankingFlowModal: React.FC<RankingFlowModalProps> = ({
  isOpen, onClose, onAdd, selectedItem: initialItem, currentItems, preselectedTier, onCompare,
}) => {
  const { user } = useAuth();
  const { t } = useTranslation();
  const [step, setStep] = useState<Step>('tier');
  const [selectedItem, setSelectedItem] = useState<RankedItem>(initialItem);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(preselectedTier ?? null);
  const [notes, setNotes] = useState('');
  const [watchedWithUserIds, setWatchedWithUserIds] = useState<string[]>([]);

  // Shared head-to-head ceremony DRIVER — the same RankingSession lifecycle the
  // main app's AddMediaModal uses (no forked comparison loop). onCompare logs
  // are emitted against the current (selectedItem, selectedTier) pair.
  const selectionRef = useRef<{ item: RankedItem | null; tier: Tier | null }>({ item: initialItem, tier: preselectedTier ?? null });
  selectionRef.current = { item: selectedItem, tier: selectedTier };
  const ceremony = useRankingCeremony({
    onCompare,
    getLogContext: () => selectionRef.current,
  });
  const currentComparison = ceremony.currentComparison;

  // Reset on open
  useEffect(() => {
    if (isOpen) {
      setSelectedItem(initialItem);
      setSelectedTier(preselectedTier ?? null);
      setNotes(initialItem.notes ?? '');
      setWatchedWithUserIds(initialItem.watchedWithUserIds ?? []);
      ceremony.reset();

      if (preselectedTier) {
        // Direct tier migration — start comparison immediately
        const stepResult = ceremony.begin(initialItem, preselectedTier, currentItems);
        if (stepResult.kind === 'placed') {
          onAdd({ ...initialItem, tier: preselectedTier, rank: stepResult.rank });
          onClose();
        } else {
          setStep('compare');
        }
      } else {
        setStep('tier');
      }
    }
    // ceremony methods are stable; excluding keeps this effect's deps identical
    // to the pre-extraction version so open/reset behavior is unchanged.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, initialItem, preselectedTier, currentItems, onAdd, onClose]);

  if (!isOpen) return null;

  const getTierItems = (tier: Tier) =>
    currentItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    setStep('notes');
  };

  const handleInsertAt = (rankIndex: number) => {
    if (selectedItem && selectedTier) {
      onAdd({
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        notes: notes.trim() || undefined,
        watchedWithUserIds: watchedWithUserIds.length > 0 ? watchedWithUserIds : undefined,
      });
      onClose();
    }
  };

  const proceedFromNotes = (overrideSkip?: boolean) => {
    const tierItems = getTierItems(selectedTier!);
    const item = selectedItem;
    const finalNotes = overrideSkip ? undefined : (notes.trim() || undefined);
    const finalWatchedWith = overrideSkip ? undefined : (watchedWithUserIds.length > 0 ? watchedWithUserIds : undefined);

    if (tierItems.length === 0) {
      onAdd({ ...item, tier: selectedTier!, rank: 0, notes: finalNotes, watchedWithUserIds: finalWatchedWith });
      onClose();
      return;
    }

    const stepResult = ceremony.begin(item, selectedTier!, currentItems);
    if (stepResult.kind === 'placed') {
      handleInsertAt(stepResult.rank);
    } else if (stepResult.kind === 'compare') {
      setStep('compare');
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    const stepResult = ceremony.choose(choice);
    if (stepResult.kind === 'placed') {
      handleInsertAt(stepResult.rank);
    }
  };

  const handleUndo = () => {
    ceremony.undo();
  };

  const getStepTitle = () => {
    switch (step) {
      case 'tier': return t('book.assignTier');
      case 'notes': return t('book.addNote');
      case 'compare': return t('book.headToHead');
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('notes');
    else if (step === 'notes') setStep('tier');
  };

  return (
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm">
      <div role="dialog" aria-modal="true" aria-label="Ranking flow" className="bg-background border border-border w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        <div className="flex items-center justify-between p-5 border-b border-border bg-card/30 flex-shrink-0">
          <div className="flex items-center gap-3">
            {step !== 'tier' && (
              <button onClick={handleBack} className="text-muted-foreground hover:text-foreground transition-colors">
                <ArrowLeft size={20} />
              </button>
            )}
            <h2 className="text-xl font-bold text-foreground">{getStepTitle()}</h2>
          </div>
          <button onClick={onClose} className="text-muted-foreground hover:text-foreground transition-colors">
            <X size={24} />
          </button>
        </div>

        <div className="p-5 overflow-y-auto flex-1">
          {step === 'tier' && (
            <TierPicker
              selectedItem={selectedItem}
              currentItems={currentItems}
              onSelectTier={handleSelectTier}
              onBracketChange={(b) => setSelectedItem(prev => ({ ...prev, bracket: b }))}
            />
          )}
          {step === 'notes' && (
            <NotesStep
              selectedItem={selectedItem}
              selectedTier={selectedTier}
              notes={notes}
              onNotesChange={setNotes}
              onContinue={proceedFromNotes}
              onSkip={() => { setNotes(''); setWatchedWithUserIds([]); proceedFromNotes(true); }}
              currentUserId={user?.id}
              watchedWithUserIds={watchedWithUserIds}
              onWatchedWithChange={setWatchedWithUserIds}
            />
          )}
          {step === 'compare' && currentComparison && (
            <ComparisonStep
              comparison={currentComparison}
              selectedTier={selectedTier}
              onChoice={handleCompareChoice}
              onUndo={handleUndo}
            />
          )}
        </div>
      </div>
    </div>
    </FocusTrap>
  );
};
