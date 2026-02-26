import React, { useEffect, useState, useMemo, useRef } from 'react';
import { Search, X } from 'lucide-react';
import { StandoutPerformance } from '../../types';
import { getExtendedMovieDetails } from '../../services/tmdbService';

interface CastSelectorProps {
  tmdbId: number;
  selected: StandoutPerformance[];
  onChange: (performances: StandoutPerformance[]) => void;
}

interface CastMember {
  id: number;
  name: string;
  character: string;
  profile_path: string | null;
}

export const CastSelector: React.FC<CastSelectorProps> = ({ tmdbId, selected, onChange }) => {
  const [cast, setCast] = useState<CastMember[]>([]);
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [loading, setLoading] = useState(false);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Clear debounce timeout on unmount
  useEffect(() => {
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    // Fetch credits via the TMDB API directly since getExtendedMovieDetails doesn't expose cast
    const apiKey = import.meta.env.VITE_TMDB_API_KEY;
    if (!apiKey) {
      setLoading(false);
      return;
    }

    fetch(`https://api.themoviedb.org/3/movie/${tmdbId}/credits?api_key=${apiKey}`)
      .then((res) => res.json())
      .then((data) => {
        if (!cancelled && data.cast) {
          setCast(data.cast.slice(0, 30));
        }
      })
      .catch(console.error)
      .finally(() => { if (!cancelled) setLoading(false); });

    return () => { cancelled = true; };
  }, [tmdbId]);

  const filtered = useMemo(() => {
    if (!debouncedSearch.trim()) return cast;
    const q = debouncedSearch.toLowerCase();
    return cast.filter(
      (c) => c.name.toLowerCase().includes(q) || c.character.toLowerCase().includes(q),
    );
  }, [cast, debouncedSearch]);

  const selectedIds = new Set(selected.map((s) => s.personId));

  const toggle = (member: CastMember) => {
    if (selectedIds.has(member.id)) {
      onChange(selected.filter((s) => s.personId !== member.id));
    } else {
      onChange([...selected, {
        personId: member.id,
        name: member.name,
        character: member.character,
        profilePath: member.profile_path ?? undefined,
      }]);
    }
  };

  return (
    <div className="space-y-2">
      {/* Selected chips */}
      {selected.length > 0 && (
        <div className="flex gap-1.5 flex-wrap">
          {selected.map((perf) => (
            <span
              key={perf.personId}
              className="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs bg-indigo-500/20 text-indigo-300 border border-indigo-500/30"
            >
              {perf.name}
              <button type="button" onClick={() => onChange(selected.filter((s) => s.personId !== perf.personId))}>
                <X size={12} />
              </button>
            </span>
          ))}
        </div>
      )}

      {/* Search */}
      <div className="relative">
        <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-zinc-500" />
        <input
          type="text"
          placeholder="Search cast..."
          value={search}
          onChange={(e) => {
            const val = e.target.value;
            setSearch(val);
            if (debounceRef.current) clearTimeout(debounceRef.current);
            debounceRef.current = setTimeout(() => {
              setDebouncedSearch(val);
            }, 300);
          }}
          className="w-full bg-zinc-900 border border-zinc-800 rounded-lg pl-8 pr-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
        />
      </div>

      {/* Cast list */}
      {loading ? (
        <p className="text-xs text-zinc-600 py-2">Loading cast...</p>
      ) : (
        <div className="max-h-48 overflow-y-auto space-y-0.5">
          {filtered.map((member) => (
            <button
              key={member.id}
              type="button"
              className={`w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left transition-colors ${
                selectedIds.has(member.id)
                  ? 'bg-indigo-500/10 text-indigo-300'
                  : 'text-zinc-300 hover:bg-zinc-800/50'
              }`}
              onClick={() => toggle(member)}
            >
              {member.profile_path ? (
                <img
                  src={`https://image.tmdb.org/t/p/w92${member.profile_path}`}
                  alt={member.name}
                  className="w-7 h-7 rounded-full object-cover"
                />
              ) : (
                <div className="w-7 h-7 rounded-full bg-zinc-800 flex items-center justify-center text-[10px] text-zinc-500">
                  {member.name[0]}
                </div>
              )}
              <div className="min-w-0">
                <p className="text-xs font-medium truncate">{member.name}</p>
                <p className="text-[10px] text-zinc-500 truncate">{member.character}</p>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};
