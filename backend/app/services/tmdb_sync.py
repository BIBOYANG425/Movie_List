"""
TMDB Sync Service
─────────────────
Wraps the TMDB v3 REST API.

Day 1: Skeleton with correct method signatures and response shapes.
Day 2: Full implementation used by /media/search as a fallback.

Flow:
  1. User searches for a movie.
  2. /media/search queries local DB with pg_trgm.
  3. If results < 3, this service calls TMDB and caches new items.
"""
import httpx

from app.core.config import settings

TMDB_BASE_URL = "https://api.themoviedb.org/3"
TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p/w500"


class TMDBService:
    """
    Thin async wrapper around TMDB v3 API.
    Uses httpx for HTTP — non-blocking in async FastAPI context.
    """

    def __init__(self, api_key: str | None = None) -> None:
        self.api_key = api_key or settings.TMDB_API_KEY
        if not self.api_key:
            raise ValueError(
                "TMDB_API_KEY is not set. "
                "Add it to your .env file or pass it explicitly."
            )

    async def search_movies(self, query: str, page: int = 1) -> list[dict]:
        """
        Search TMDB for movies matching *query*.

        Returns a list of dicts shaped like:
        [
          {
            "tmdb_id": 693134,
            "title": "Dune: Part Two",
            "release_year": 2024,
            "poster_url": "https://image.tmdb.org/t/p/w500/...",
            "attributes": {
              "genres": ["Science Fiction", "Adventure"],
              "genre": "Science Fiction",
              "director": None,       ← filled by get_movie_details()
              "runtime_minutes": None,
              "language": "en",
              "source": "tmdb"
            }
          },
          ...
        ]
        """
        # TODO (Day 2): implement
        return []

    async def get_movie_details(self, tmdb_id: int) -> dict | None:
        """
        Fetch full details for a single movie including credits (director).

        Returns None if the movie is not found.
        TODO (Day 2): implement with /movie/{id}?append_to_response=credits
        """
        return None

    def _format_poster_url(self, path: str | None) -> str | None:
        """Prefix the TMDB image base URL onto a poster path."""
        if not path:
            return None
        return f"{TMDB_IMAGE_BASE}{path}"
