import { useEffect, useState } from 'react';
import { RankedItem } from '../types';
import {
  getExtendedMovieDetails,
  getTVSeasonDetails,
  getTVShowDetails,
} from '../services/tmdbService';

export interface InspectDetails {
  /** Director-as-artist (or TV creator / book author). */
  director: string | null;
  runtimeMinutes: number | null;
  episodeCount: number | null;
  genres: string[];
  /** null until resolved; drives engine.setBackdrop (stage-2 async). */
  backdropUrl: string | null;
  loading: boolean;
}

const EMPTY: InspectDetails = {
  director: null,
  runtimeMinutes: null,
  episodeCount: null,
  genres: [],
  backdropUrl: null,
  loading: false,
};

// Same derivation MediaDetailModal uses for tv_season ids ("tv_123_s2").
function parseTVSeasonId(
  id: string,
): { showTmdbId: number; seasonNumber: number } | null {
  const match = id.match(/^tv_(\d+)_s(\d+)$/);
  if (!match) return null;
  return { showTmdbId: Number(match[1]), seasonNumber: Number(match[2]) };
}

/**
 * Placard/backdrop data for the gallery inspect state. Reuses the exact
 * fetch functions MediaDetailModal's data effect uses, without the modal's
 * Supabase ranking re-query or social stats (tier/rank/notes come from the
 * item the gallery already holds).
 */
export function useInspectDetails(item: RankedItem | null): InspectDetails {
  const [details, setDetails] = useState<InspectDetails>(EMPTY);

  useEffect(() => {
    if (!item) {
      setDetails(EMPTY);
      return;
    }

    // Books need no fetch: author/pageCount are on the RankedItem.
    if (item.type === 'book') {
      setDetails({
        director: item.author ?? null,
        runtimeMinutes: null,
        episodeCount: null,
        genres: item.genres,
        backdropUrl: null,
        loading: false,
      });
      return;
    }

    let didCancel = false;
    setDetails({
      director: item.director ?? item.creator ?? null,
      runtimeMinutes: null,
      episodeCount: item.episodeCount ?? null,
      genres: item.genres,
      backdropUrl: null,
      loading: true,
    });

    const fetchData = async () => {
      if (item.type === 'tv_season') {
        const target = {
          showTmdbId:
            item.showTmdbId ?? parseTVSeasonId(item.id)?.showTmdbId ?? 0,
          seasonNumber:
            item.seasonNumber ?? parseTVSeasonId(item.id)?.seasonNumber ?? 0,
        };
        if (!target.showTmdbId || !target.seasonNumber) {
          if (!didCancel) setDetails((d) => ({ ...d, loading: false }));
          return;
        }
        const [show, season] = await Promise.all([
          getTVShowDetails(target.showTmdbId),
          getTVSeasonDetails(
            target.showTmdbId,
            target.seasonNumber,
            item.title,
          ),
        ]);
        if (didCancel) return;
        setDetails({
          director: show?.creators[0] ?? item.creator ?? null,
          runtimeMinutes: null,
          episodeCount:
            season?.episodeCount ?? item.episodeCount ?? null,
          genres: show?.genres ?? item.genres,
          backdropUrl: show?.backdropUrl ?? null,
          loading: false,
        });
        return;
      }

      const numericId = parseInt(item.id.replace('tmdb_', ''), 10);
      if (isNaN(numericId)) {
        if (!didCancel) setDetails((d) => ({ ...d, loading: false }));
        return;
      }
      const extended = await getExtendedMovieDetails(numericId);
      if (didCancel) return;
      setDetails({
        director: extended?.director ?? item.director ?? null,
        runtimeMinutes: extended?.movie.runtime ?? null,
        episodeCount: null,
        genres: extended?.movie.genres ?? item.genres,
        backdropUrl: extended?.movie.backdropUrl ?? null,
        loading: false,
      });
    };

    fetchData();
    return () => {
      didCancel = true;
    };
  }, [item?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  return details;
}
