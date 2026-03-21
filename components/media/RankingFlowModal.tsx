import React, { useState, useEffect, useRef } from 'react';
import { X, ArrowLeft } from 'lucide-react';
import { RankedItem, Tier, Bracket, ComparisonLogEntry, ComparisonRequest } from '../../types';
import { TIER_SCORE_RANGES } from '../../constants';
import { classifyBracket, computeSeedIndex, computeTierScore } from '../../services/rankingAlgorithm';
import { SpoolRankingEngine } from '../../services/spoolRankingEngine';
import { computePredictionSignals } from '../../services/spoolPrediction';
import { useAuth } from '../../contexts/AuthContext';
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
  const [step, setStep] = useState<Step>('tier');
  const [selectedItem, setSelectedItem] = useState<RankedItem>(initialItem);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(preselectedTier ?? null);
  const [notes, setNotes] = useState('');
  const [watchedWithUserIds, setWatchedWithUserIds] = useState<string[]>([]);

  // Spool ranking engine state
  const engineRef = useRef<SpoolRankingEngine | null>(null);
  const isProcessingRef = useRef(false);
  const smallTierRef = useRef<{
    mode: 'compare_all' | 'seed' | 'quartile';
    tierItems: RankedItem[];
    low: number; high: number; mid: number;
    round: number; seedIdx: number;
  } | null>(null);
  const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
  const [sessionId, setSessionId] = useState(() => crypto.randomUUID());

  // Reset on open
  useEffect(() => {
    if (isOpen) {
      setSelectedItem(initialItem);
      setSelectedTier(preselectedTier ?? null);
      setNotes(initialItem.notes ?? '');
      setWatchedWithUserIds(initialItem.watchedWithUserIds ?? []);
      engineRef.current = null;
      smallTierRef.current = null;
      setCurrentComparison(null);
      setSessionId(crypto.randomUUID());

      if (preselectedTier) {
        // Direct tier migration — start comparison immediately
        const engine = new SpoolRankingEngine();
        const signals = computePredictionSignals(
          currentItems,
          initialItem.genres[0] ?? '',
          initialItem.bracket ?? classifyBracket(initialItem.genres),
          initialItem.globalScore,
          preselectedTier,
        );
        const result = engine.start(initialItem, preselectedTier, currentItems, signals);
        engineRef.current = engine;

        if (result.type === 'done') {
          onAdd({ ...initialItem, tier: preselectedTier, rank: result.finalRank! });
          onClose();
        } else {
          setCurrentComparison(result.comparison!);
          setStep('compare');
        }
      } else {
        setStep('tier');
      }
    }
  }, [isOpen, initialItem, preselectedTier]);

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
    } else if (tierItems.length <= 5) {
      smallTierRef.current = { mode: 'compare_all', tierItems, low: 0, high: tierItems.length, mid: 0, round: 1, seedIdx: 0 };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[0], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else if (tierItems.length <= 20) {
      const range = TIER_SCORE_RANGES[selectedTier!];
      const tierScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
      const seedIdx = computeSeedIndex(tierScores, range.min, range.max, item.globalScore);
      smallTierRef.current = { mode: 'seed', tierItems, low: 0, high: tierItems.length, mid: seedIdx, round: 1, seedIdx };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[seedIdx], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else {
      const engine = new SpoolRankingEngine();
      const signals = computePredictionSignals(
        currentItems,
        item.genres[0] ?? '',
        item.bracket ?? classifyBracket(item.genres),
        item.globalScore,
        selectedTier!,
      );
      const result = engine.start(item, selectedTier!, currentItems, signals);
      engineRef.current = engine;

      if (result.type === 'done') {
        handleInsertAt(result.finalRank!);
      } else {
        setCurrentComparison(result.comparison!);
        setStep('compare');
      }
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    if (!currentComparison) return;
    if (!engineRef.current && !smallTierRef.current) return;
    if (isProcessingRef.current) return;
    isProcessingRef.current = true;

    try {
      if (onCompare && selectedItem && selectedTier) {
        onCompare({
          sessionId,
          movieAId: currentComparison.movieA.id,
          movieBId: currentComparison.movieB.id,
          winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
          round: currentComparison.round,
          phase: currentComparison.phase,
          questionText: currentComparison.question,
        });
      }

      if (smallTierRef.current) {
        const st = smallTierRef.current;
        const movieA = currentComparison.movieA;

        if (choice === 'too_tough' || choice === 'skip') {
          smallTierRef.current = null;
          handleInsertAt(st.mid);
          return;
        }

        const pick = choice === 'new' ? 'new' as const : 'existing' as const;
        const nextRound = st.round + 1;
        const setNext = (mid: number, mode?: typeof st.mode, low?: number, high?: number) => {
          smallTierRef.current = { ...st, mode: mode ?? st.mode, low: low ?? st.low, high: high ?? st.high, mid, round: nextRound };
          setCurrentComparison({ movieA, movieB: st.tierItems[mid], question: 'Which do you prefer?', round: nextRound, phase: 'binary_search' });
        };
        const done = (rank: number) => { smallTierRef.current = null; handleInsertAt(rank); };

        if (st.mode === 'compare_all') {
          if (pick === 'new') { done(st.mid); }
          else if (st.mid + 1 >= st.tierItems.length) { done(st.tierItems.length); }
          else { setNext(st.mid + 1); }
        } else if (st.mode === 'seed') {
          if (pick === 'new') {
            if (st.mid === 0) { done(0); }
            else { setNext(0, 'quartile', 0, st.mid); }
          } else {
            const newLow = st.mid + 1;
            if (newLow >= st.tierItems.length) { done(st.tierItems.length); }
            else {
              const newHigh = st.tierItems.length;
              const nextMid = Math.min(newLow + Math.floor((newHigh - newLow) * 0.75), newHigh - 1);
              setNext(nextMid, 'quartile', newLow, newHigh);
            }
          }
        } else {
          const newLow = pick === 'new' ? st.low : st.mid + 1;
          const newHigh = pick === 'new' ? st.mid : st.high;
          if (newLow >= newHigh) { done(newLow); }
          else {
            const ratio = pick === 'new' ? 0.25 : 0.75;
            const nextMid = Math.max(newLow, Math.min(newLow + Math.floor((newHigh - newLow) * ratio), newHigh - 1));
            setNext(nextMid, 'quartile', newLow, newHigh);
          }
        }
        return;
      }

      if (!engineRef.current) return;

      if (choice === 'too_tough' || choice === 'skip') {
        const result = engineRef.current.skip();
        handleInsertAt(result.finalRank!);
        return;
      }

      const winnerId = choice === 'new' ? selectedItem.id : currentComparison.movieB.id;
      const result = engineRef.current.submitChoice(winnerId);

      if (result.type === 'done') {
        handleInsertAt(result.finalRank!);
      } else {
        setCurrentComparison(result.comparison!);
      }
    } finally {
      isProcessingRef.current = false;
    }
  };

  const handleUndo = () => {
    if (!engineRef.current) return;
    const result = engineRef.current.undo();
    if (result && result.comparison) {
      setCurrentComparison(result.comparison);
    }
  };

  const getStepTitle = () => {
    switch (step) {
      case 'tier': return 'Assign Tier';
      case 'notes': return 'Add a Note';
      case 'compare': return 'Head-to-Head';
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('notes');
    else if (step === 'notes') setStep('tier');
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm">
      <div className="bg-background border border-border w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
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
  );
};
