/**
 * Open Library API service for searching and retrieving book data.
 * API docs: https://openlibrary.org/dev/docs/api/search
 * Free, no key required. Rate limit: ~3 req/s with User-Agent header.
 */

import { ALL_BOOK_GENRES } from '../constants';

export interface OpenLibraryBook {
  id: string;           // "ol_OL27448W"
  title: string;
  author: string;
  year: string;
  posterUrl: string;
  genres: string[];
  pageCount?: number;
  isbn?: string;
  olWorkKey: string;    // "OL27448W"
  olRatingsAverage?: number;  // 0-5 scale
  globalScore?: number;       // 0-10 scale (olRatingsAverage * 2)
}

interface OLSearchResult {
  key: string;                    // "/works/OL27448W"
  title: string;
  author_name?: string[];
  first_publish_year?: number;
  number_of_pages_median?: number;
  cover_i?: number;
  ratings_average?: number;
  ratings_count?: number;
  subject?: string[];
  isbn?: string[];
}

interface OLSearchResponse {
  numFound: number;
  docs: OLSearchResult[];
}

const SEARCH_FIELDS = [
  'key', 'title', 'author_name', 'first_publish_year',
  'number_of_pages_median', 'cover_i', 'ratings_average',
  'ratings_count', 'subject', 'isbn',
].join(',');

/** Map messy Open Library subjects to canonical book genres */
const SUBJECT_TO_GENRE: Record<string, string> = {
  // Fiction genres
  'fiction': 'Fiction',
  'literary fiction': 'Literary Fiction',
  'fantasy': 'Fantasy',
  'fantasy fiction': 'Fantasy',
  'science fiction': 'Sci-Fi',
  'sci-fi': 'Sci-Fi',
  'mystery': 'Mystery',
  'mystery and detective stories': 'Mystery',
  'detective': 'Mystery',
  'thriller': 'Thriller',
  'thrillers': 'Thriller',
  'suspense': 'Thriller',
  'romance': 'Romance',
  'romance fiction': 'Romance',
  'love stories': 'Romance',
  'horror': 'Horror',
  'horror fiction': 'Horror',
  'humor': 'Humor',
  'humorous fiction': 'Humor',
  'comedy': 'Humor',
  'satire': 'Humor',
  'young adult': 'Young Adult',
  'young adult fiction': 'Young Adult',
  'juvenile fiction': 'Children',
  'children\'s fiction': 'Children',
  'children': 'Children',
  'graphic novels': 'Graphic Novel',
  'comics': 'Graphic Novel',
  'manga': 'Graphic Novel',
  'poetry': 'Poetry',
  'poems': 'Poetry',
  // Non-fiction genres
  'non-fiction': 'Non-fiction',
  'nonfiction': 'Non-fiction',
  'biography': 'Biography',
  'biographies': 'Biography',
  'autobiography': 'Biography',
  'memoirs': 'Biography',
  'memoir': 'Biography',
  'history': 'History',
  'historical': 'History',
  'philosophy': 'Philosophy',
  'self-help': 'Self-help',
  'self help': 'Self-help',
  'personal development': 'Self-help',
  'science': 'Science',
  'popular science': 'Science',
  'travel': 'Travel',
  'travel writing': 'Travel',
};

const VALID_GENRES = new Set(ALL_BOOK_GENRES);

export function normalizeBookGenres(subjects: string[]): string[] {
  const genres = new Set<string>();

  for (const subject of subjects) {
    const lower = subject.toLowerCase().trim();
    const mapped = SUBJECT_TO_GENRE[lower];
    if (mapped && VALID_GENRES.has(mapped)) {
      genres.add(mapped);
    }
  }

  // If no genres found, check for partial matches (longer keywords first to avoid misclassification)
  if (genres.size === 0) {
    const sortedEntries = Object.entries(SUBJECT_TO_GENRE).sort((a, b) => b[0].length - a[0].length);
    for (const subject of subjects) {
      const lower = subject.toLowerCase().trim();
      for (const [keyword, genre] of sortedEntries) {
        if (lower.includes(keyword) && VALID_GENRES.has(genre)) {
          genres.add(genre);
          break;
        }
      }
      if (genres.size >= 3) break;
    }
  }

  return Array.from(genres).slice(0, 5);
}

export function getBookCoverUrl(coverId: number | undefined, size: 'S' | 'M' | 'L' = 'M'): string {
  if (!coverId) return '';
  return `https://covers.openlibrary.org/b/id/${coverId}-${size}.jpg`;
}

function extractWorkKey(key: string): string {
  // "/works/OL27448W" → "OL27448W"
  return key.replace('/works/', '');
}

export async function searchBooks(
  query: string,
  timeoutMs: number = 8000,
): Promise<OpenLibraryBook[]> {
  if (!query.trim()) return [];

  const url = new URL('https://openlibrary.org/search.json');
  url.searchParams.set('q', query.trim());
  url.searchParams.set('limit', '10');
  url.searchParams.set('fields', SEARCH_FIELDS);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url.toString(), {
      signal: controller.signal,
    });

    if (!res.ok) {
      console.error('Open Library search failed:', res.status);
      return [];
    }

    const data: OLSearchResponse = await res.json();

    return data.docs
      .filter((doc) => doc.title && doc.key)
      .map((doc): OpenLibraryBook => {
        const workKey = extractWorkKey(doc.key);
        const olRatingsAverage = doc.ratings_average ?? undefined;
        return {
          id: `ol_${workKey}`,
          title: doc.title,
          author: doc.author_name?.[0] ?? 'Unknown',
          year: doc.first_publish_year?.toString() ?? '',
          posterUrl: getBookCoverUrl(doc.cover_i, 'M'),
          genres: normalizeBookGenres(doc.subject ?? []),
          pageCount: doc.number_of_pages_median ?? undefined,
          isbn: doc.isbn?.[0] ?? undefined,
          olWorkKey: workKey,
          olRatingsAverage,
          globalScore: olRatingsAverage != null ? olRatingsAverage * 2 : undefined,
        };
      });
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      console.error('Open Library search timed out');
    } else {
      console.error('Open Library search error:', err);
    }
    return [];
  } finally {
    clearTimeout(timer);
  }
}
