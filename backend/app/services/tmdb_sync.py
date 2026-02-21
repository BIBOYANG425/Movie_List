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
TMDB_TIMEOUT_SECONDS = 10.0

TMDB_GENRE_MAP: dict[int, str] = {
    28: "Action",
    12: "Adventure",
    16: "Animation",
    35: "Comedy",
    80: "Crime",
    99: "Documentary",
    18: "Drama",
    10751: "Family",
    14: "Fantasy",
    36: "History",
    27: "Horror",
    10402: "Music",
    9648: "Mystery",
    10749: "Romance",
    878: "Science Fiction",
    10770: "TV Movie",
    53: "Thriller",
    10752: "War",
    37: "Western",
}


class TMDBConfigError(Exception):
    """Raised when TMDB client is used without an API key."""


class TMDBUpstreamError(Exception):
    """Raised for non-recoverable TMDB request/response errors."""


class TMDBService:
    """
    Thin async wrapper around TMDB v3 API.
    Uses httpx for HTTP — non-blocking in async FastAPI context.
    """

    def __init__(self, api_key: str | None = None) -> None:
        self.api_key = api_key or settings.TMDB_API_KEY
        if not self.api_key:
            raise TMDBConfigError(
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
        cleaned_query = query.strip()
        if not cleaned_query:
            return []

        params = {
            "api_key": self.api_key,
            "query": cleaned_query,
            "page": page,
            "language": "en-US",
            "include_adult": "false",
        }

        try:
            async with httpx.AsyncClient(timeout=TMDB_TIMEOUT_SECONDS) as client:
                response = await client.get(f"{TMDB_BASE_URL}/search/movie", params=params)
                response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise TMDBUpstreamError(
                f"TMDB search failed with status {exc.response.status_code}"
            ) from exc
        except httpx.RequestError as exc:
            raise TMDBUpstreamError("TMDB search request failed") from exc

        payload = response.json()
        results = payload.get("results", [])
        mapped: list[dict] = []
        for raw in results:
            movie = self._map_search_item(raw)
            if movie is not None:
                mapped.append(movie)
        return mapped

    async def get_movie_details(self, tmdb_id: int) -> dict | None:
        """
        Fetch full details for a single movie including credits (director).

        Returns None if the movie is not found.
        """
        params = {
            "api_key": self.api_key,
            "language": "en-US",
            "append_to_response": "credits",
        }

        try:
            async with httpx.AsyncClient(timeout=TMDB_TIMEOUT_SECONDS) as client:
                response = await client.get(
                    f"{TMDB_BASE_URL}/movie/{tmdb_id}",
                    params=params,
                )
                if response.status_code == 404:
                    return None
                response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise TMDBUpstreamError(
                f"TMDB details failed with status {exc.response.status_code}"
            ) from exc
        except httpx.RequestError as exc:
            raise TMDBUpstreamError("TMDB details request failed") from exc

        return self._map_details(response.json())

    def _format_poster_url(self, path: str | None) -> str | None:
        """Prefix the TMDB image base URL onto a poster path."""
        if not path:
            return None
        return f"{TMDB_IMAGE_BASE}{path}"

    def _pick_primary_genre(self, genres: list[str]) -> str | None:
        """Return the primary genre name for a movie."""
        return genres[0] if genres else None

    def _map_search_item(self, raw: dict) -> dict | None:
        """Normalize a TMDB /search/movie result row."""
        tmdb_id = raw.get("id")
        title = raw.get("title")
        if not tmdb_id or not title:
            return None

        genre_names = [
            TMDB_GENRE_MAP[gid]
            for gid in raw.get("genre_ids", [])
            if gid in TMDB_GENRE_MAP
        ]

        release_date = raw.get("release_date")
        release_year = int(release_date[:4]) if isinstance(release_date, str) and len(release_date) >= 4 else None
        poster_url = self._format_poster_url(raw.get("poster_path"))

        attributes = {
            "genres": genre_names,
            "genre": self._pick_primary_genre(genre_names),
            "director": None,
            "runtime_minutes": None,
            "language": raw.get("original_language"),
            "release_date": release_date,
            "overview": raw.get("overview"),
            "poster_url": poster_url,
            "source": "tmdb",
        }

        return {
            "tmdb_id": int(tmdb_id),
            "title": title,
            "release_year": release_year,
            "poster_url": poster_url,
            "attributes": attributes,
        }

    def _map_details(self, raw: dict) -> dict:
        """Normalize a TMDB /movie/{id} details payload."""
        genres = [g.get("name") for g in raw.get("genres", []) if g.get("name")]

        crew = raw.get("credits", {}).get("crew", [])
        director = next((p.get("name") for p in crew if p.get("job") == "Director"), None)

        cast = raw.get("credits", {}).get("cast", [])
        cast_names = [p.get("name") for p in cast[:8] if p.get("name")]

        release_date = raw.get("release_date")
        release_year = int(release_date[:4]) if isinstance(release_date, str) and len(release_date) >= 4 else None
        poster_url = self._format_poster_url(raw.get("poster_path"))

        attributes = {
            "genres": genres,
            "genre": self._pick_primary_genre(genres),
            "director": director,
            "cast": cast_names,
            "runtime_minutes": raw.get("runtime"),
            "language": raw.get("original_language"),
            "release_date": release_date,
            "overview": raw.get("overview"),
            "poster_url": poster_url,
            "source": "tmdb",
        }

        return {
            "tmdb_id": int(raw["id"]),
            "title": raw.get("title"),
            "release_year": release_year,
            "poster_url": poster_url,
            "attributes": attributes,
        }
