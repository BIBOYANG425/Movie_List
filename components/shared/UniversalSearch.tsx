import React, { useState, useRef, useEffect } from 'react';
import { Search, X, Film, Tv, BookOpen, Plus, Bookmark, Loader2, Users } from 'lucide-react';
import { searchMovies, searchTVShows, TMDBMovie, TMDBTVShow } from '../../services/tmdbService';
import { searchBooks, OpenLibraryBook } from '../../services/openLibraryService';
import { getFriendRankingCounts } from '../../services/tasteService';
import { useAuth } from '../../contexts/AuthContext';
import { useTranslation } from '../../contexts/LanguageContext';

type SearchTab = 'all' | 'movies' | 'tv' | 'books';

interface UniversalSearchResult {
  id: string;
  title: string;
  subtitle: string;
  year: string;
  posterUrl: string;
  type: 'movie' | 'tv' | 'book';
  genres: string[];
  raw: TMDBMovie | TMDBTVShow | OpenLibraryBook;
}

interface UniversalSearchProps {
  rankedIds: Set<string>;
  watchlistIds: Set<string>;
  onRankMovie: (movie: TMDBMovie) => void;
  onRankTV: (show: TMDBTVShow) => void;
  onRankBook: (book: OpenLibraryBook) => void;
  onSaveMovie: (movie: TMDBMovie) => void;
  onSaveTV: (show: TMDBTVShow) => void;
  onSaveBook: (book: OpenLibraryBook) => void;
}

export const UniversalSearch: React.FC<UniversalSearchProps> = ({
  rankedIds, watchlistIds, onRankMovie, onRankTV, onRankBook, onSaveMovie, onSaveTV, onSaveBook,
}) => {
  const { t } = useTranslation();
  const { user } = useAuth();
  const [isOpen, setIsOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [tab, setTab] = useState<SearchTab>('all');
  const [results, setResults] = useState<UniversalSearchResult[]>([]);
  const [friendCounts, setFriendCounts] = useState<Map<string, number>>(new Map());
  const [loading, setLoading] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const requestIdRef = useRef(0);

  // Focus input when opened
  useEffect(() => {
    if (isOpen) {
      setTimeout(() => inputRef.current?.focus(), 50);
    } else {
      setQuery('');
      setResults([]);
      setFriendCounts(new Map());
      setTab('all');
    }
  }, [isOpen]);

  // Click outside to close
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [isOpen]);

  // Escape to close
  useEffect(() => {
    if (!isOpen) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setIsOpen(false);
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [isOpen]);

  // Debounced search
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    const trimmed = query.trim();
    if (!trimmed) {
      setResults([]);
      setLoading(false);
      return;
    }

    setLoading(true);
    const rid = ++requestIdRef.current;

    debounceRef.current = setTimeout(async () => {
      const [movies, tvShows, books] = await Promise.all([
        searchMovies(trimmed, 5000).catch(() => [] as TMDBMovie[]),
        searchTVShows(trimmed, 5000).catch(() => [] as TMDBTVShow[]),
        searchBooks(trimmed, 5000).catch(() => [] as OpenLibraryBook[]),
      ]);

      if (rid !== requestIdRef.current) return;

      const mapped: UniversalSearchResult[] = [
        ...movies.slice(0, 8).map((m): UniversalSearchResult => ({
          id: m.id,
          title: m.title,
          subtitle: m.genres?.slice(0, 2).join(', ') || '',
          year: m.year,
          posterUrl: m.posterUrl ?? '',
          type: 'movie',
          genres: m.genres ?? [],
          raw: m,
        })),
        ...tvShows.slice(0, 8).map((s): UniversalSearchResult => ({
          id: s.id,
          title: s.name,
          subtitle: s.seasonCount ? `${s.seasonCount} ${t('search.seasons')}` : '',
          year: s.year,
          posterUrl: s.posterUrl ?? '',
          type: 'tv',
          genres: s.genres ?? [],
          raw: s,
        })),
        ...books.slice(0, 8).map((b): UniversalSearchResult => ({
          id: b.id,
          title: b.title,
          subtitle: b.author,
          year: b.year,
          posterUrl: b.posterUrl,
          type: 'book',
          genres: b.genres,
          raw: b,
        })),
      ];

      setResults(mapped);
      setLoading(false);

      // Fetch friend ranking counts in background
      if (user) {
        const ids = mapped.map((r) => r.id);
        getFriendRankingCounts(user.id, ids)
          .then((counts) => { if (rid === requestIdRef.current) setFriendCounts(counts); })
          .catch(() => {});
      }
    }, 350);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [query]);

  const tabToType = (t: SearchTab): string => t === 'movies' ? 'movie' : t === 'books' ? 'book' : t;
  const filteredResults = tab === 'all'
    ? results
    : results.filter(r => r.type === tabToType(tab));

  const isOwned = (id: string) => rankedIds.has(id) || watchlistIds.has(id);

  const handleRank = (result: UniversalSearchResult) => {
    setIsOpen(false);
    if (result.type === 'movie') onRankMovie(result.raw as TMDBMovie);
    else if (result.type === 'tv') onRankTV(result.raw as TMDBTVShow);
    else onRankBook(result.raw as OpenLibraryBook);
  };

  const handleSave = (result: UniversalSearchResult) => {
    if (result.type === 'movie') onSaveMovie(result.raw as TMDBMovie);
    else if (result.type === 'tv') onSaveTV(result.raw as TMDBTVShow);
    else onSaveBook(result.raw as OpenLibraryBook);
  };

  const typeIcon = (type: string) => {
    if (type === 'movie') return <Film size={10} />;
    if (type === 'tv') return <Tv size={10} />;
    return <BookOpen size={10} />;
  };

  const typeBadgeClass = (type: string) => {
    if (type === 'movie') return 'bg-blue-500/15 text-blue-400';
    if (type === 'tv') return 'bg-purple-500/15 text-purple-400';
    return 'bg-emerald-500/15 text-emerald-400';
  };

  const typeLabel = (type: string) => {
    if (type === 'movie') return t('search.mediaMovie');
    if (type === 'tv') return t('search.mediaTV');
    return t('search.mediaBook');
  };

  const tabs: { key: SearchTab; label: string }[] = [
    { key: 'all', label: t('search.all') },
    { key: 'movies', label: t('search.movies') },
    { key: 'tv', label: t('search.tv') },
    { key: 'books', label: t('search.books') },
  ];

  return (
    <div ref={containerRef} className="relative z-50">
      {/* Search input — always expanded */}
      <div className="flex items-center gap-2 bg-card border border-border/30 rounded-xl px-4 py-2.5 w-full">
        <Search size={16} className="text-muted-foreground flex-shrink-0" />
        <input
          ref={inputRef}
          type="text"
          placeholder={t('search.placeholder')}
          value={query}
          onChange={(e) => { setQuery(e.target.value); setIsOpen(true); }}
          onFocus={() => setIsOpen(true)}
          aria-label="Search"
          className="flex-1 bg-transparent text-foreground placeholder-muted-foreground text-sm focus:outline-none"
        />
        {loading && <Loader2 size={16} className="text-muted-foreground animate-spin flex-shrink-0" />}
        {query && (
          <button onClick={() => { setQuery(''); setResults([]); }} className="text-muted-foreground hover:text-foreground transition-colors flex-shrink-0">
            <X size={16} />
          </button>
        )}
      </div>

      {/* Dropdown */}
      {isOpen && query.trim() && (
        <div className="absolute top-full left-0 right-0 mt-2 bg-background border border-border rounded-xl shadow-2xl overflow-hidden max-h-[70vh] flex flex-col">
          {/* Tabs */}
          <div className="flex border-b border-border/30 px-2 pt-2">
            {tabs.map(({ key, label }) => (
              <button
                key={key}
                onClick={() => setTab(key)}
                className={`px-3 py-1.5 text-xs font-semibold rounded-t-lg transition-colors ${
                  tab === key
                    ? 'bg-secondary text-foreground'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {label}
                {key !== 'all' && (
                  <span className="ml-1 text-[10px] opacity-50">
                    {results.filter(r => r.type === tabToType(key)).length}
                  </span>
                )}
              </button>
            ))}
          </div>

          {/* Results */}
          <div className="overflow-y-auto flex-1 p-2 space-y-1">
            {loading && (
              <div className="space-y-2 py-2">
                {[1, 2, 3].map(i => (
                  <div key={i} className="flex items-center gap-3 p-2 rounded-lg animate-pulse">
                    <div className="w-10 h-14 bg-secondary rounded flex-shrink-0" />
                    <div className="flex-1 space-y-2">
                      <div className="h-3 bg-secondary rounded w-3/4" />
                      <div className="h-2 bg-secondary rounded w-1/2" />
                    </div>
                  </div>
                ))}
              </div>
            )}

            {!loading && filteredResults.length === 0 && query.trim() && (
              <div className="text-center py-8 text-muted-foreground text-sm">
                <Search size={24} className="mx-auto mb-2 opacity-30" />
                <p>{t('search.noResults')}</p>
              </div>
            )}

            {!loading && filteredResults.map((result) => (
              <div
                key={`${result.type}-${result.id}`}
                className="flex items-center gap-3 p-2 rounded-xl hover:bg-secondary/50 transition-colors group"
              >
                {/* Poster */}
                <div className="w-10 h-14 rounded-lg overflow-hidden bg-secondary flex-shrink-0">
                  {result.posterUrl ? (
                    <img src={result.posterUrl} alt={result.title} className="w-full h-full object-cover" />
                  ) : (
                    <div className="w-full h-full flex items-center justify-center text-muted-foreground/40">
                      {typeIcon(result.type)}
                    </div>
                  )}
                </div>

                {/* Info */}
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-foreground truncate">{result.title}</p>
                  <div className="flex items-center gap-1.5 mt-0.5">
                    <span className={`inline-flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded-full font-medium ${typeBadgeClass(result.type)}`}>
                      {typeIcon(result.type)}
                      {typeLabel(result.type)}
                    </span>
                    {result.year && <span className="text-[11px] text-muted-foreground">{result.year}</span>}
                    {result.subtitle && <span className="text-[11px] text-muted-foreground truncate">· {result.subtitle}</span>}
                    {(friendCounts.get(result.id) ?? 0) > 0 && (
                      <span className="inline-flex items-center gap-0.5 text-[10px] px-1.5 py-0.5 rounded-full font-medium bg-gold/10 text-gold">
                        <Users size={9} />
                        {t('search.friendsRanked').replace('{n}', String(friendCounts.get(result.id)))}
                      </span>
                    )}
                  </div>
                </div>

                {/* Actions */}
                <div className="flex items-center gap-1 flex-shrink-0">
                  {!isOwned(result.id) && (
                    <>
                      <button
                        onClick={(e) => { e.stopPropagation(); handleSave(result); }}
                        className="p-1.5 rounded-lg text-muted-foreground/40 hover:text-emerald-400 hover:bg-emerald-500/10 transition-colors"
                        title={t('search.save')}
                      >
                        <Bookmark size={14} />
                      </button>
                      <button
                        onClick={(e) => { e.stopPropagation(); handleRank(result); }}
                        className="p-1.5 rounded-lg text-muted-foreground/40 hover:text-gold hover:bg-gold/10 transition-colors"
                        title={t('search.rank')}
                      >
                        <Plus size={16} />
                      </button>
                    </>
                  )}
                  {isOwned(result.id) && (
                    <span className="text-[10px] text-muted-foreground/50 px-2">{t('search.added')}</span>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};
