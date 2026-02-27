import React from 'react';
import { WatchlistItem } from '../types';
import { Bookmark, Trash2, ArrowUpRight, Film, Clock } from 'lucide-react';
import { useTranslation } from '../contexts/LanguageContext';

interface WatchlistProps {
  items: WatchlistItem[];
  onRemove: (id: string) => void;
  onRank: (item: WatchlistItem) => void;
}

export const Watchlist: React.FC<WatchlistProps> = ({ items, onRemove, onRank }) => {
  const { t } = useTranslation();

  if (items.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-20 text-zinc-600">
        <Bookmark size={48} className="mb-4 opacity-30" />
        <p className="text-lg font-semibold text-zinc-500">{t('watchlist.empty')}</p>
        <p className="text-sm mt-1 opacity-60 max-w-xs text-center">
          {t('watchlist.emptyHint')}
        </p>
      </div>
    );
  }

  const formatDate = (iso: string) => {
    try {
      return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    } catch {
      return '';
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Bookmark size={18} className="text-emerald-400" />
          <h2 className="text-lg font-bold text-white">{t('watchlist.title')}</h2>
        </div>
        <span className="text-xs font-mono text-zinc-500 bg-zinc-900 px-2 py-1 rounded border border-zinc-800">
          {items.length} {t('watchlist.saved')}
        </span>
      </div>

      <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 gap-3">
        {items.map((item) => (
          <div
            key={item.id}
            className="group relative rounded-xl overflow-hidden bg-zinc-900 border border-zinc-800 hover:border-zinc-600 transition-all shadow-lg"
          >
            {/* Poster */}
            <div className="relative aspect-[2/3] w-full bg-zinc-800">
              <img
                src={item.posterUrl}
                alt={item.title}
                className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black/90 via-transparent to-transparent opacity-80" />

              {/* Hover actions */}
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 opacity-0 group-hover:opacity-100 transition-opacity bg-black/50 backdrop-blur-[2px]">
                <button
                  onClick={() => onRank(item)}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-white text-black text-xs font-semibold hover:bg-zinc-200 transition-colors shadow-lg"
                >
                  <ArrowUpRight size={13} />
                  {t('watchlist.rankIt')}
                </button>
                <button
                  onClick={() => onRemove(item.id)}
                  className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-zinc-800/80 text-red-400 text-xs font-medium hover:bg-red-500/20 border border-zinc-700 transition-colors"
                >
                  <Trash2 size={12} />
                  {t('watchlist.remove')}
                </button>
              </div>
            </div>

            {/* Info */}
            <div className="absolute bottom-0 left-0 right-0 p-2.5 pt-5">
              <p className="text-xs font-semibold text-white leading-tight truncate">{item.title}</p>
              <div className="flex items-center gap-1.5 mt-1 text-[10px] text-zinc-500">
                <Film size={10} />
                <span>{item.year}</span>
                <span className="text-zinc-700">·</span>
                <Clock size={9} />
                <span>{formatDate(item.addedAt)}</span>
              </div>
            </div>

            {/* Bookmark badge */}
            <div className="absolute top-1.5 right-1.5 p-1 rounded-full bg-emerald-500/20 border border-emerald-500/30 text-emerald-400">
              <Bookmark size={10} className="fill-current" />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};
