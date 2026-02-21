# Marquee Phase 2 Detailed Backend Design

This is an implementation-grade design for Phase 2.

## Phase 2 Scope

- Media service completion (`/media/search`, `/media/{media_id}`, `/media/create_stub`)
- TMDB fallback + cache-upsert pipeline
- Play support in schema/model/API (`media_type = PLAY`)
- Manual-entry flow for unstructured play metadata via `attributes` JSONB

Out of scope for Phase 2:
- Social feed/follows/leaderboards
- Ranking algorithm changes
- Recommendation engine

---

## 1) API Contracts (Phase 2)

## 1.1 `GET /media/search`

Search local catalog first; fallback to TMDB if local recall is low.

Query params:
- `q` (required, min length 1)
- `media_type` optional: `MOVIE | PLAY`
- `limit` default `20`, max `50`
- `offset` default `0`

Response `200`:
```json
{
  "items": [
    {
      "id": "uuid",
      "title": "Dune: Part Two",
      "release_year": 2024,
      "media_type": "MOVIE",
      "tmdb_id": 693134,
      "attributes": {
        "genre": "Science Fiction",
        "genres": ["Science Fiction", "Adventure"],
        "director": "Denis Villeneuve",
        "cast": ["Timothee Chalamet", "Zendaya"],
        "runtime_minutes": 166,
        "poster_url": "https://image.tmdb.org/t/p/w500/...",
        "source": "tmdb"
      },
      "is_verified": true,
      "is_user_generated": false,
      "created_at": "2026-02-21T00:00:00Z",
      "updated_at": "2026-02-21T00:00:00Z"
    }
  ],
  "meta": {
    "count": 1,
    "source": "db_only"
  }
}
```

`meta.source` values:
- `db_only`: local results satisfied target
- `db_plus_tmdb`: TMDB called and cache merged
- `tmdb_only`: no local matches, TMDB provided candidates

Errors:
- `422` invalid query params

## 1.2 `GET /media/{media_id}`

Returns one media item by UUID.

Response `200`: `MediaItemDetail`

Errors:
- `404` media not found

## 1.3 `POST /media/create_stub`

Create user-generated media record, primarily for plays.

Auth: required (`Bearer`)

Request:
```json
{
  "title": "Hamilton",
  "media_type": "PLAY",
  "release_year": 2015,
  "attributes": {
    "creator": "Lin-Manuel Miranda",
    "cast": ["Leslie Odom Jr.", "Phillipa Soo"],
    "genre": "Musical",
    "genres": ["Musical", "Historical"],
    "venue": "Richard Rodgers Theatre",
    "runtime_minutes": 160,
    "source": "manual"
  }
}
```

Response `201`:
```json
{
  "id": "uuid",
  "title": "Hamilton",
  "release_year": 2015,
  "media_type": "PLAY",
  "tmdb_id": null,
  "attributes": {"genre": "Musical"},
  "is_verified": false,
  "is_user_generated": true,
  "created_by_user_id": "uuid"
}
```

Errors:
- `400` invalid media-type specific payload
- `409` duplicate manual stub for same owner + normalized title/year/type
- `422` schema validation

---

## 2) Data Model & Migration Design

Current issue: migration `0001` defines `media_type` enum as only `MOVIE`.

Phase 2 migration `0002_add_play_support.py` should do:

1. Add enum value:
```sql
ALTER TYPE media_type ADD VALUE IF NOT EXISTS 'PLAY';
```

2. Add media constraints:
- Plays cannot have `tmdb_id`:
```sql
ALTER TABLE media_items
ADD CONSTRAINT chk_play_tmdb_null
CHECK (media_type <> 'PLAY' OR tmdb_id IS NULL);
```

3. Add manual-dedup index (owner-scoped):
```sql
CREATE UNIQUE INDEX IF NOT EXISTS uq_media_items_manual_owner_title_year
ON media_items (created_by_user_id, media_type, lower(title), COALESCE(release_year, 0))
WHERE is_user_generated = true;
```

4. Keep existing indexes (already in `0001`):
- `idx_media_items_title_trgm` (GiST trigram)
- `idx_media_items_attributes_gin` (JSONB GIN)
- `idx_media_items_genre_btree`
- `uq_media_items_movie_tmdb_id` partial unique

Downgrade note:
- PostgreSQL enum value removal is non-trivial; downgrade should be documented as no-op for enum contraction unless rows converted first.

---

## 3) JSONB Attribute Contracts

## 3.1 Movie attributes (TMDB or manual)

Required keys in Phase 2 write path:
- `genre`: string or null
- `genres`: array of strings
- `source`: `"tmdb" | "manual"`

Optional keys:
- `director`, `cast`, `runtime_minutes`, `language`, `poster_url`, `overview`, `release_date`

## 3.2 Play attributes (manual)

Required keys:
- `genre`: string or null
- `genres`: array of strings
- `source`: `"manual"`

Optional keys:
- `creator`, `cast`, `venue`, `runtime_minutes`, `premiere_date`, `production_company`

Normalization rules:
- Always coerce `genres` to unique title-cased strings
- If `genre` missing and `genres` non-empty, set `genre = genres[0]`
- Ensure `attributes` is always JSON object

---

## 4) Module Layout & Function Inventory

Add/expand these files:

- `/Users/mac/Documents/Movie_List_MVP/backend/app/schemas/media.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/media_service.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/tmdb_sync.py` (complete existing)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/api/media.py` (replace stubs)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/db/models.py` (enum + constraints alignment)
- `/Users/mac/Documents/Movie_List_MVP/backend/alembic/versions/0002_add_play_support.py` (new)

## 4.1 Schema functions (`app/schemas/media.py`)

1. `class MediaTypeEnum(str, Enum)`
- Values: `MOVIE`, `PLAY`

2. `class MediaItemBaseResponse(BaseModel)`
- Base output for list/detail responses

3. `class MediaSearchResponse(BaseModel)`
- `{items: list[MediaItemBaseResponse], meta: SearchMeta}`

4. `class SearchMeta(BaseModel)`
- Fields: `count`, `source`

5. `class CreateMediaStubRequest(BaseModel)`
- Fields: `title`, `media_type`, `release_year`, `attributes`
- Validator: title non-empty; `attributes` object
- Validator: PLAY must not include `tmdb_id`

6. `class MediaItemDetailResponse(MediaItemBaseResponse)`
- Includes creator flags and timestamps

## 4.2 TMDB functions (`app/services/tmdb_sync.py`)

7. `class TMDBService.__init__(api_key: str | None = None)`
- Validate API key availability

8. `async def search_movies(query: str, page: int = 1) -> list[TMDBSearchItem]`
- Calls `/search/movie`
- Returns mapped candidates

9. `async def get_movie_details(tmdb_id: int) -> TMDBMovieDetails | None`
- Calls `/movie/{id}?append_to_response=credits`
- Pulls director from crew + runtime + genres

10. `def _format_poster_url(path: str | None) -> str | None`
- Prefix with image base URL

11. `def _map_search_item(raw: dict) -> dict | None`
- Minimal mapper for search results

12. `def _map_details(raw: dict) -> dict`
- Canonical attributes mapper for DB persistence

13. `def _pick_primary_genre(genres: list[str]) -> str | None`
- Returns first genre or None

## 4.3 Media service functions (`app/services/media_service.py`)

14. `def normalize_title(title: str) -> str`
- Strip + collapse spaces

15. `def normalize_attributes(attributes: dict, media_type: MediaTypeEnum) -> dict`
- Enforce JSON contract from section 3

16. `def build_local_search_query(db: Session, q: str, media_type: MediaTypeEnum | None)`
- SQLAlchemy query with trigram `similarity` + `ILIKE`

17. `def search_local_media(db: Session, q: str, media_type: MediaTypeEnum | None, limit: int, offset: int) -> list[MediaItem]`
- Executes local query and returns ordered rows

18. `async def fetch_tmdb_candidates(query: str, page: int = 1) -> list[dict]`
- Wrapper around `TMDBService.search_movies`

19. `async def enrich_tmdb_candidates(candidates: list[dict]) -> list[dict]`
- Optional details hydration (`get_movie_details`) for top N candidates

20. `def upsert_tmdb_media(db: Session, candidates: list[dict]) -> list[MediaItem]`
- Upsert by `tmdb_id` using raw SQL `INSERT ... ON CONFLICT ... DO UPDATE`
- Returns persisted rows

21. `def merge_dedup_results(local_rows: list[MediaItem], cached_rows: list[MediaItem]) -> list[MediaItem]`
- De-dupe by media UUID, fallback tmdb_id

22. `async def search_media_hybrid(db: Session, q: str, media_type: MediaTypeEnum | None, limit: int, offset: int) -> tuple[list[MediaItem], str]`
- Orchestrates local + TMDB fallback + merge
- Returns `(rows, source_tag)`

23. `def get_media_by_id(db: Session, media_id: UUID) -> MediaItem | None`
- Detail fetch

24. `def create_manual_stub(db: Session, user_id: UUID, payload: CreateMediaStubRequest) -> MediaItem`
- Validates payload by media type
- Normalizes `attributes`
- Inserts row with `is_user_generated = true`, `is_verified = false`
- Handles duplicate unique violation -> `DuplicateManualMediaError`

25. `def validate_media_type_payload(payload: CreateMediaStubRequest) -> None`
- Guard rules:
  - PLAY: no `tmdb_id`, `source=manual`
  - MOVIE manual: allow `tmdb_id=null`

26. `def map_media_response(row: MediaItem) -> MediaItemBaseResponse`
- Shared serializer

## 4.4 API route functions (`app/api/media.py`)

27. `async def search_media(...) -> MediaSearchResponse`
- Calls `search_media_hybrid`
- Returns response envelope

28. `def get_media_item(media_id: UUID, ...) -> MediaItemDetailResponse`
- 404 if missing

29. `def create_stub(payload: CreateMediaStubRequest, current_user: User = Depends(get_current_user), ...) -> MediaItemDetailResponse`
- Auth protected
- Calls `create_manual_stub`

---

## 5) Search/Ranking Performance Strategy

## 5.1 Local search SQL strategy

Use weighted sort:
- `similarity(title, :q)` DESC
- exact-prefix boost
- fallback alphabetical tie-break

Predicate:
```sql
WHERE title ILIKE :q_prefix OR similarity(title, :q) > 0.20
```

Index use:
- `idx_media_items_title_trgm` accelerates similarity and ILIKE fuzzy matches.

## 5.2 JSON filters compatibility

Phase 2 search should remain compatible with ranking filter strategy from Phase 1:
- genre filter uses `attributes ->> 'genre'`
- richer filters can use JSON containment with `@>` and GIN index

---

## 6) Transaction & Concurrency Design

## 6.1 `search_media_hybrid`

- Read local rows first (no write lock).
- If local count < threshold (e.g., 8), fetch TMDB candidates.
- Upsert TMDB rows in single transaction.
- Requery merged set and return.

Idempotency:
- Repeated same search does not duplicate due partial unique index on movie `tmdb_id`.

## 6.2 `create_manual_stub`

- Single write transaction.
- Owner-scoped dedupe index prevents accidental duplicate play rows.
- Return existing conflict as `409`.

---

## 7) Validation & Error Mapping

Domain errors and HTTP mapping:

- `TMDBConfigError` -> `503 TMDB_NOT_CONFIGURED`
- `TMDBUpstreamError` -> `502 TMDB_UPSTREAM_ERROR`
- `MediaNotFoundError` -> `404 MEDIA_NOT_FOUND`
- `DuplicateManualMediaError` -> `409 MEDIA_ALREADY_EXISTS`
- `InvalidMediaPayloadError` -> `400 INVALID_MEDIA_PAYLOAD`

Standard error shape:
```json
{
  "error": {
    "code": "MEDIA_ALREADY_EXISTS",
    "message": "A similar media item already exists for this user"
  }
}
```

---

## 8) Security Rules

- `POST /media/create_stub` requires valid bearer token.
- `GET /media/search` and `GET /media/{media_id}` can be public in Phase 2.
- If you want private beta behavior, gate all `/media` endpoints behind auth without changing service design.

---

## 9) Test Plan (Phase 2)

1. Migration applies cleanly from `0001` to `0002`.
2. Manual play insert succeeds with valid attributes.
3. Manual play with `tmdb_id` fails (`400`).
4. Duplicate manual stub (same owner/title/year/type) returns `409`.
5. Local media search returns trigram matches in expected order.
6. Hybrid search falls back to TMDB when local results are insufficient.
7. TMDB upsert updates existing movie metadata (same `tmdb_id`) instead of duplicating.
8. `GET /media/{id}` returns `404` on unknown UUID.
9. JSON structure normalization ensures `genre`/`genres` consistency.

---

## 10) Implementation Sequence (Fast Path)

1. Add migration `0002_add_play_support.py`.
2. Align `app/db/models.py` (`media_type` enum support for `PLAY`).
3. Create `app/schemas/media.py`.
4. Complete `app/services/tmdb_sync.py`.
5. Implement `app/services/media_service.py`.
6. Replace stubs in `app/api/media.py`.
7. Add tests for migration + media APIs.
8. Integrate frontend search to backend endpoint (`/media/search`) after API pass.

---

## 11) Open Decisions

1. Search auth model for launch:
- Option A: public search/detail (recommended for easier adoption)
- Option B: auth-required for all media endpoints

2. TMDB detail hydration depth:
- Option A: hydrate top 5 fallback results (recommended)
- Option B: hydrate all fallback results (higher latency/cost)

3. Manual movie stubs:
- Option A: allow (recommended for flexibility)
- Option B: restrict manual stubs to PLAY only

