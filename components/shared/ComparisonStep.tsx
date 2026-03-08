import React from 'react';
import { ComparisonRequest, Tier } from '../../types';
import { TIER_COLORS } from '../../constants';
import { ArrowLeft } from 'lucide-react';

interface ComparisonStepProps {
  comparison: ComparisonRequest;
  selectedTier: Tier | null;
  onChoice: (choice: 'new' | 'existing' | 'too_tough' | 'skip') => void;
  onUndo: () => void;
}

export const ComparisonStep: React.FC<ComparisonStepProps> = ({
  comparison,
  selectedTier,
  onChoice,
  onUndo,
}) => (
  <div className="flex flex-col gap-5 animate-fade-in">
    <h3 className="text-center text-lg font-bold text-white">
      {comparison.question}
    </h3>

    {/* Head-to-head */}
    <div className="flex items-stretch gap-3">
      {/* New item */}
      <button
        onClick={() => onChoice('new')}
        className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-border hover:border-indigo-500 hover:bg-indigo-500/5 transition-all group active:scale-[0.97]"
      >
        <img
          src={comparison.movieA.posterUrl}
          alt={comparison.movieA.title}
          className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
        />
        <div className="text-center">
          <p className="font-serif text-white text-sm leading-tight">{comparison.movieA.title}</p>
          <p className="text-xs text-dim mt-0.5">{comparison.movieA.year}</p>
          <span className="inline-block mt-2 text-xs text-indigo-400 font-semibold border border-indigo-500/30 bg-indigo-500/10 px-2 py-0.5 rounded-full">
            NEW
          </span>
        </div>
      </button>

      {/* OR divider */}
      <div className="flex items-center justify-center flex-shrink-0">
        <div className="w-9 h-9 rounded-full bg-card border border-border flex items-center justify-center text-xs font-black text-muted">
          OR
        </div>
      </div>

      {/* Comparison target */}
      <button
        onClick={() => onChoice('existing')}
        className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-border hover:border-zinc-400 hover:bg-zinc-400/5 transition-all group active:scale-[0.97]"
      >
        <img
          src={comparison.movieB.posterUrl}
          alt={comparison.movieB.title}
          className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
        />
        <div className="text-center">
          <p className="font-bold text-white text-sm leading-tight">{comparison.movieB.title}</p>
          <p className="text-xs text-dim mt-0.5">{comparison.movieB.year}</p>
          {selectedTier && (
            <span className={`inline-block mt-2 text-xs font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier]}`}>
              {selectedTier}
            </span>
          )}
        </div>
      </button>
    </div>

    {/* Actions */}
    <div className="flex items-center justify-between mt-1">
      <button
        onClick={onUndo}
        className="flex items-center gap-1.5 text-sm font-medium text-muted hover:text-white transition-colors"
      >
        <ArrowLeft size={15} />
        Undo
      </button>
      <button
        onClick={() => onChoice('too_tough')}
        className="px-4 py-2 rounded-full border border-zinc-700 text-sm font-semibold text-zinc-300 hover:bg-zinc-800 hover:border-zinc-500 transition-all"
      >
        Too tough
      </button>
      <button
        onClick={() => onChoice('skip')}
        className="flex items-center gap-1.5 text-sm font-medium text-zinc-400 hover:text-white transition-colors"
      >
        Skip
        <ArrowLeft size={15} className="rotate-180" />
      </button>
    </div>
  </div>
);
