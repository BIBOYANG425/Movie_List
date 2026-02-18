# Marquee Backend Plan (Repository-Aligned)

## 1) Current State (What Exists)

- Backend framework is in place: FastAPI + SQLAlchemy + Alembic in `/Users/mac/Documents/Movie_List_MVP/backend`.
- Database migration is strong and already contains core ranking functions (`insert_ranking_between`, `rebalance_tier_positions`).
- API routes are mostly stubs returning `501` in:
  - `/Users/mac/Documents/Movie_List_MVP/backend/app/api/auth.py`
  - `/Users/mac/Documents/Movie_List_MVP/backend/app/api/media.py`
  - `/Users/mac/Documents/Movie_List_MVP/backend/app/api/rankings.py`
  - `/Users/mac/Documents/Movie_List_MVP/backend/app/api/social.py`
- Frontend currently runs local-first and stores rankings in browser localStorage (`/Users/mac/Documents/Movie_List_MVP/App.tsx`).

## 2) Gaps To Close For a Real Backend

### Gap A: Auth is non-functional
- Signup/login/me are all TODO.
- Security helpers exist (`hash_password`, `verify_password`, JWT helpers) but are unused.

### Gap B: Ranking system exists at DB layer but not exposed
- Fractional index + score interpolation are implemented in Postgres functions.
- API endpoints don’t call those functions yet.

### Gap C: Media search path is split
- Frontend calls TMDB directly from browser (`/Users/mac/Documents/Movie_List_MVP/services/tmdbService.ts`).
- Backend media search endpoint is stubbed.
- Needed outcome: backend-owned search + caching into `media_items`.

### Gap D: Data model mismatch for Plays
- Migration currently uses `media_type` enum with only `MOVIE`.
- Product goal includes `PLAY`, so migration/model need to be aligned before launch.

### Gap E: Two app trees in repo
- There is a duplicate frontend tree under `/Users/mac/Documents/Movie_List_MVP/Movie_List`.
- This creates deployment confusion unless we standardize a single source of truth.

## 3) Target Backend Architecture (V1)

## API Surface

### Auth
- `POST /auth/signup`
- `POST /auth/login`
- `GET /auth/me`

### Media
- `GET /media/search?q=&limit=&offset=`
  - Query local DB first (`pg_trgm` similarity + `ILIKE` fallback)
  - If low result count, call TMDB and upsert cache
- `GET /media/{media_id}`
- `POST /media/create_stub` (manual entry, primarily for plays)

### Rankings
- `GET /rankings/me?tier=&genre=&media_type=&limit=&offset=`
- `POST /rankings`
  - Calls DB function `insert_ranking_between`
- `PATCH /rankings/{ranking_id}/move`
  - Reposition within tier or move across tiers with same function
- `DELETE /rankings/{ranking_id}`

### Social (Phase 2)
- `POST /social/follow/{user_id}`
- `DELETE /social/follow/{user_id}`
- `GET /social/feed`
- `GET /social/leaderboard`

## Data & Query Rules

- Keep ranking math in DB (single source of truth).
- Treat `user_rankings` as write-heavy and lock neighbor rows with `FOR UPDATE` when moving/reinserting.
- Use existing indexes:
  - `idx_user_rankings_user_tier_rank`
  - `idx_media_items_attributes_gin`
  - `idx_media_items_genre_btree`
- Add `tier_sort` expression in query layer (`S,A,B,C,D`) for deterministic UI order.

## 4) Implementation Phases

## Phase 1 (Must Have, 2-3 days)
- Implement real auth routes with DB + JWT.
- Implement `GET /rankings/me`, `POST /rankings`, `PATCH /rankings/{id}/move`, `DELETE /rankings/{id}`.
- Add dependency `get_current_user` to all protected ranking endpoints.
- Add minimal request validation and consistent error responses.

## Phase 2 (Media + Plays, 2 days)
- Implement `GET /media/search` with local DB query + TMDB fallback + cache upsert.
- Implement `GET /media/{id}` and `POST /media/create_stub`.
- Add migration to support `PLAY` in `media_type` enum and allow manual play metadata in `attributes`.

## Phase 3 (Social + quality, 2-3 days)
- Implement follow/unfollow/feed/leaderboard.
- Add tests for auth, ranking insert/move, filtering by JSON attributes.
- Add rate limiting, pagination defaults, and API response envelopes.

## 5) Frontend Integration Plan

- Keep current local mode as fallback while backend is being wired.
- Introduce a small `apiClient` and switch these flows first:
  - Add item -> `POST /rankings`
  - Move item -> `PATCH /rankings/{id}/move`
  - Load list on app start -> `GET /rankings/me`
- After backend write paths are stable, disable localStorage persistence in production mode.

## 6) Immediate Decisions Needed

- Decide primary app root: keep root app, or `/Movie_List` duplicate.
- Confirm if `PLAY` is required in V1 launch.
- Confirm auth scope for V1:
  - email/password only
  - no OAuth for now

## 7) Recommended Next Build Step

Start Phase 1 now:
1. Implement auth routes in `/Users/mac/Documents/Movie_List_MVP/backend/app/api/auth.py`.
2. Implement current-user dependency shared by rankings/social routes.
3. Implement ranking CRUD around `insert_ranking_between` in `/Users/mac/Documents/Movie_List_MVP/backend/app/api/rankings.py`.
