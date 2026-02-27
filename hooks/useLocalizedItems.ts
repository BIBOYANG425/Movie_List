import { useEffect, useRef, useState } from 'react';
import { useTranslation } from '../contexts/LanguageContext';
import { RankedItem, WatchlistItem } from '../types';

const TMDB_BASE = 'https://api.themoviedb.org/3';
const CACHE_KEY = 'spool_title_zh';
const BATCH_SIZE = 10;

interface TitleEntry {
  title: string;
  overview?: string;
}

function readCache(): Record<string, TitleEntry> {
  try {
    return JSON.parse(localStorage.getItem(CACHE_KEY) || '{}');
  } catch {
    return {};
  }
}

function writeCache(cache: Record<string, TitleEntry>) {
  localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
}

async function fetchChineseTitles(tmdbIds: string[]): Promise<Record<string, TitleEntry>> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey || tmdbIds.length === 0) return {};

  const cache = readCache();
  const missing = tmdbIds.filter((id) => !cache[id]);
  if (missing.length === 0) return cache;

  // Fetch in batches to avoid rate limits
  for (let i = 0; i < missing.length; i += BATCH_SIZE) {
    const batch = missing.slice(i, i + BATCH_SIZE);
    const results = await Promise.allSettled(
      batch.map(async (id) => {
        const numericId = id.replace('tmdb_', '');
        const res = await fetch(
          `${TMDB_BASE}/movie/${numericId}?api_key=${apiKey}&language=zh-CN`,
        );
        if (!res.ok) return null;
        const data = await res.json();
        return { id, title: data.title as string, overview: data.overview as string | undefined };
      }),
    );

    for (const r of results) {
      if (r.status === 'fulfilled' && r.value) {
        cache[r.value.id] = { title: r.value.title, overview: r.value.overview };
      }
    }
  }

  writeCache(cache);
  return cache;
}

/**
 * Returns ranked items with localized titles when the app is in Chinese mode.
 * Fetches Chinese titles from TMDB and caches them in localStorage.
 */
export function useLocalizedItems(items: RankedItem[]): RankedItem[] {
  const { locale } = useTranslation();
  const [titleMap, setTitleMap] = useState<Record<string, TitleEntry>>(() =>
    locale === 'zh' ? readCache() : {},
  );
  const idsKey = items.map((i) => i.id).join(',');
  const prevIdsKey = useRef(idsKey);
  const prevLocale = useRef(locale);

  useEffect(() => {
    if (locale !== 'zh') {
      setTitleMap({});
      prevLocale.current = locale;
      return;
    }

    const ids = items.map((i) => i.id);
    const cache = readCache();
    const needsFetch = ids.some((id) => !cache[id]);

    // Only fetch if locale changed or new items appeared
    if (!needsFetch && prevLocale.current === locale && prevIdsKey.current === idsKey) {
      if (Object.keys(titleMap).length === 0) setTitleMap(cache);
      return;
    }

    prevLocale.current = locale;
    prevIdsKey.current = idsKey;

    fetchChineseTitles(ids).then(setTitleMap);
  }, [locale, idsKey]);

  if (locale !== 'zh' || Object.keys(titleMap).length === 0) return items;

  return items.map((item) => {
    const entry = titleMap[item.id];
    return entry ? { ...item, title: entry.title } : item;
  });
}

/**
 * Same as useLocalizedItems but for watchlist items.
 */
export function useLocalizedWatchlist(items: WatchlistItem[]): WatchlistItem[] {
  const { locale } = useTranslation();
  const [titleMap, setTitleMap] = useState<Record<string, TitleEntry>>(() =>
    locale === 'zh' ? readCache() : {},
  );
  const idsKey = items.map((i) => i.id).join(',');

  useEffect(() => {
    if (locale !== 'zh') {
      setTitleMap({});
      return;
    }
    fetchChineseTitles(items.map((i) => i.id)).then(setTitleMap);
  }, [locale, idsKey]);

  if (locale !== 'zh' || Object.keys(titleMap).length === 0) return items;

  return items.map((item) => {
    const entry = titleMap[item.id];
    return entry ? { ...item, title: entry.title } : item;
  });
}
