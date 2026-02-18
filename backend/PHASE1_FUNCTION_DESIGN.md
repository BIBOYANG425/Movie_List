# Marquee Phase 1 Detailed Backend Design

This document is implementation-grade for Phase 1.

## Phase 1 Scope

- `auth`: signup, login, me
- `rankings`: list my rankings, create ranking, move ranking, delete ranking
- Guarded endpoints via JWT bearer auth
- Uses existing Postgres schema + functions from migration `0001_initial_schema.py`

Out of scope for Phase 1:
- Social feed/follows
- TMDB ingest/search fallback in backend
- Advanced analytics/leaderboard

---

## 1) Final API Contracts (Phase 1)

## 1.1 Auth

### `POST /auth/signup`
Creates user account.

Request:
```json
{
  "username": "cinephile_1",
  "email": "user@example.com",
  "password": "PlainTextPassword123"
}
```

Response `201`:
```json
{
  "id": "uuid",
  "username": "cinephile_1",
  "email": "user@example.com"
}
```

Errors:
- `409` username or email already exists
- `422` validation error

### `POST /auth/login`
OAuth2 password form.

Request form fields:
- `username` (Marquee username)
- `password`

Response `200`:
```json
{
  "access_token": "jwt",
  "token_type": "bearer"
}
```

Errors:
- `401` invalid credentials

### `GET /auth/me`
Returns current authenticated user.

Response `200`:
```json
{
  "id": "uuid",
  "username": "cinephile_1",
  "email": "user@example.com"
}
```

Errors:
- `401` missing/invalid/expired token

---

## 1.2 Rankings

All ranking endpoints require `Authorization: Bearer <token>`.

### `GET /rankings/me`
Query params:
- `tier` optional: `S|A|B|C|D`
- `genre` optional string (matches `attributes ->> 'genre'`)
- `media_type` optional (`MOVIE` now; future `PLAY`)
- `limit` default 100, max 500
- `offset` default 0

Response `200`:
```json
[
  {
    "id": "ranking_uuid",
    "media_item_id": "media_uuid",
    "tier": "A",
    "rank_position": 1500.0,
    "visual_score": 8.5,
    "media_title": "Dune: Part Two",
    "media_type": "MOVIE",
    "attributes": {"genre": "Science Fiction"},
    "created_at": "2026-02-18T00:00:00Z",
    "updated_at": "2026-02-18T00:00:00Z"
  }
]
```

### `POST /rankings`
Create first ranking for a media item for this user.

Request:
```json
{
  "media_id": "media_uuid",
  "tier": "A",
  "prev_ranking_id": "optional_uuid",
  "next_ranking_id": "optional_uuid",
  "notes": "optional"
}
```

Behavior:
- Calls DB function `insert_ranking_between(...)` for position + score
- If `notes` provided, update inserted row notes in same transaction

Response `201`: ranking object (same shape as list item)

Errors:
- `404` media not found
- `409` already ranked by this user
- `400` invalid neighbor pair
- `422` validation

### `PATCH /rankings/{ranking_id}/move`
Move existing ranking (within or across tier), preserving ranking row identity.

Request:
```json
{
  "tier": "A",
  "prev_ranking_id": "optional_uuid",
  "next_ranking_id": "optional_uuid"
}
```

Behavior:
- Locks target ranking row (`FOR UPDATE`)
- Validates neighbor ownership + tier
- Computes new `rank_position` + `visual_score` using `RankingMath`
- Rebalances target tier if gap too small, then recomputes
- Updates target row

Response `200`: ranking object

Errors:
- `404` ranking not found
- `400` invalid move request
- `409` unique position collision (rare race)

### `DELETE /rankings/{ranking_id}`
Delete own ranking.

Response: `204` no body

Errors:
- `404` ranking not found or not owned

---

## 2) Module Structure and Function Inventory

Recommended Phase 1 structure:

- `/Users/mac/Documents/Movie_List_MVP/backend/app/api/auth.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/api/rankings.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/deps/auth.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/schemas/auth.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/schemas/rankings.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/auth_service.py` (new)
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/ranking_service.py` (new)

## 2.1 Auth Functions

## File: `app/deps/auth.py`

1. `oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")`
- Shared bearer token extractor.

2. `def get_current_user(db: Session = Depends(get_db), token: str = Depends(oauth2_scheme)) -> User`
- Decodes JWT
- Validates `sub` is UUID
- Fetches user from DB
- Ensures `is_active = true`
- Raises `401` on any failure

## File: `app/services/auth_service.py`

3. `def create_user(db: Session, username: str, email: str, password: str) -> User`
- Normalizes username/email (`strip`, lowercase email)
- Hashes password via `hash_password`
- Inserts user
- Handles unique conflicts -> raises domain error `DuplicateUserError`

4. `def authenticate_user(db: Session, username: str, password: str) -> User | None`
- Lookup by username (citext makes case-insensitive)
- Verifies password via `verify_password`
- Returns user or `None`

5. `def issue_access_token(user: User) -> str`
- Wrapper around `create_access_token(subject=user.id)`

6. `def get_user_by_id(db: Session, user_id: UUID) -> User | None`
- Simple accessor for deps and future services

## File: `app/api/auth.py`

7. `def signup(payload: SignupRequest, db: Session = Depends(get_db)) -> UserResponse`
- Calls `create_user`
- Maps domain exceptions to HTTP

8. `def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)) -> TokenResponse`
- Calls `authenticate_user`
- Returns bearer token

9. `def get_me(current_user: User = Depends(get_current_user)) -> UserResponse`
- Returns identity payload

---

## 2.2 Ranking Functions

## File: `app/schemas/rankings.py`

10. `class RankingListItem(BaseModel)`
- Response item with ranking + media metadata

11. `class CreateRankingRequest(BaseModel)`
- Fields: `media_id: UUID`, `tier: TierEnum`, `prev_ranking_id: UUID | None`, `next_ranking_id: UUID | None`, `notes: str | None`
- Validator: `prev_ranking_id != next_ranking_id`

12. `class MoveRankingRequest(BaseModel)`
- Fields: `tier: TierEnum`, `prev_ranking_id: UUID | None`, `next_ranking_id: UUID | None`
- Validator: `prev_ranking_id != next_ranking_id`

## File: `app/services/ranking_service.py`

13. `def tier_sort_case()`
- Returns SQLAlchemy `case` expression mapping `S->1, A->2, B->3, C->4, D->5`

14. `def list_rankings(db: Session, user_id: UUID, tier: TierEnum | None, genre: str | None, media_type: str | None, limit: int, offset: int) -> list[dict]`
- Query `user_rankings` joined `media_items`
- Applies optional filters
- Orders by tier case + rank position
- Returns rows for API mapping

15. `def _validate_neighbors(db: Session, user_id: UUID, target_tier: TierEnum, prev_id: UUID | None, next_id: UUID | None, exclude_ranking_id: UUID | None = None, lock: bool = False) -> tuple[UserRanking | None, UserRanking | None]`
- Ensures neighbor rows exist and belong to user + tier
- Excludes moving row when needed
- Optional row lock
- Validates ordering `prev.rank_position < next.rank_position`

16. `def _compute_position_and_score(db: Session, user_id: UUID, target_tier: TierEnum, prev_row: UserRanking | None, next_row: UserRanking | None) -> tuple[float, float]`
- Uses `RankingMath.calculate_position` + `RankingMath.interpolate_score`
- If gap too small: calls SQL `rebalance_tier_positions`, refetches neighbors, recalculates

17. `def create_ranking(db: Session, user_id: UUID, payload: CreateRankingRequest) -> UserRanking`
- Validates media exists
- Calls SQL function:
  ```sql
  SELECT * FROM insert_ranking_between(:user_id, :media_item_id, :tier, :prev_id, :next_id)
  ```
- Applies optional notes update
- Handles integrity exceptions (`uq_user_media`)
- Commits and returns row

18. `def move_ranking(db: Session, user_id: UUID, ranking_id: UUID, payload: MoveRankingRequest) -> UserRanking`
- Locks target ranking row for update
- Validates neighbors (`exclude_ranking_id=ranking_id`, `lock=True`)
- Computes new position+score
- Updates row fields: `tier`, `rank_position`, `visual_score`, `updated_at`
- Commits and returns

19. `def delete_ranking(db: Session, user_id: UUID, ranking_id: UUID) -> bool`
- Deletes by `(id, user_id)`
- Returns True if deleted else False

20. `def get_ranking_with_media(db: Session, ranking_id: UUID, user_id: UUID) -> dict | None`
- Returns fully hydrated response object after create/move

## File: `app/api/rankings.py`

21. `def get_my_rankings(...) -> list[RankingListItem]`
- Authenticated user scope only

22. `def create_ranking_route(payload: CreateRankingRequest, ...) -> RankingListItem`
- Delegates to service

23. `def move_ranking_route(ranking_id: UUID, payload: MoveRankingRequest, ...) -> RankingListItem`
- Delegates to service

24. `def delete_ranking_route(ranking_id: UUID, ...) -> Response`
- `204` on success, `404` otherwise

---

## 3) Transaction and Concurrency Design

## 3.1 Create ranking

Transaction boundary: service function `create_ranking`.

Flow:
1. Validate `media_id` exists.
2. Execute `insert_ranking_between(...)` inside transaction.
3. Optionally set notes.
4. Commit.

Why safe:
- DB function locks neighbor rows (`FOR UPDATE`) and handles tiny-gap rebalance.

## 3.2 Move ranking

Transaction boundary: service function `move_ranking`.

Flow:
1. `SELECT ... FOR UPDATE` target ranking.
2. Validate neighbors in target tier and lock them.
3. Compute new rank/score (rebalance if needed).
4. `UPDATE user_rankings` target row.
5. Commit.

Why this strategy:
- Preserves ranking row `id` and `created_at`.
- Avoids `uq_user_media` conflict that would occur if move was implemented as delete+insert via `insert_ranking_between`.

---

## 4) SQL/ORM Query Specs

## 4.1 List rankings query

Pseudo-ORM:
```python
q = (
  db.query(
    UserRanking.id,
    UserRanking.media_item_id,
    UserRanking.tier,
    UserRanking.rank_position,
    UserRanking.visual_score,
    UserRanking.created_at,
    UserRanking.updated_at,
    MediaItem.title.label("media_title"),
    MediaItem.media_type,
    MediaItem.attributes,
  )
  .join(MediaItem, MediaItem.id == UserRanking.media_item_id)
  .filter(UserRanking.user_id == user_id)
)
```

Filters:
- tier: `q = q.filter(UserRanking.tier == tier)`
- genre: `q = q.filter(MediaItem.attributes["genre"].astext == genre)`
- media_type: `q = q.filter(MediaItem.media_type == media_type)`

Ordering:
- `ORDER BY CASE tier WHEN 'S' THEN 1 ... END, rank_position ASC`

## 4.2 Create ranking SQL call

```sql
SELECT *
FROM insert_ranking_between(
  :p_user_id,
  :p_media_item_id,
  :p_tier,
  :p_prev_ranking_id,
  :p_next_ranking_id
)
```

## 4.3 Rebalance call used by move flow

```sql
SELECT rebalance_tier_positions(:p_user_id, :p_tier)
```

---

## 5) Validation Rules

1. `tier` must be enum value `S|A|B|C|D`.
2. `prev_ranking_id` and `next_ranking_id` cannot be equal.
3. If both neighbors provided, both must belong to same user + target tier.
4. If both neighbors provided, `prev.rank_position < next.rank_position`.
5. Neighbor IDs cannot reference the moving ranking itself.
6. Create endpoint refuses duplicate media per user (`uq_user_media`).
7. `notes` max length 2000 (recommended app-level cap).

---

## 6) Error Mapping

- `DuplicateUserError` -> `409 USER_EXISTS`
- Invalid login -> `401 INVALID_CREDENTIALS`
- Invalid token -> `401 INVALID_TOKEN`
- Not found ownership-scoped ranking -> `404 RANKING_NOT_FOUND`
- Invalid neighbor ordering -> `400 INVALID_NEIGHBOR_ORDER`
- Duplicate ranking create -> `409 MEDIA_ALREADY_RANKED`
- Generic DB integrity error -> `409 CONFLICT`

Response format recommendation:
```json
{
  "error": {
    "code": "MEDIA_ALREADY_RANKED",
    "message": "This media item is already ranked by the user"
  }
}
```

---

## 7) Exact Implementation Checklist

1. Add `app/deps/auth.py` with `get_current_user`.
2. Extract request/response models into `app/schemas/auth.py` and `app/schemas/rankings.py`.
3. Add `app/services/auth_service.py`.
4. Add `app/services/ranking_service.py`.
5. Replace stubs in `app/api/auth.py` and `app/api/rankings.py` with service calls.
6. Keep `/social` and `/media` as stubs for now.
7. Add tests:
   - signup success + duplicate
   - login success + wrong password
   - me with/without token
   - create ranking top/middle/bottom
   - move ranking intra-tier + cross-tier
   - delete ranking ownership guard
   - list with genre filter

---

## 8) Open Decisions Before Coding

1. Keep endpoint path as `/rankings/me` only, or also support existing `/rankings/user/{user_id}`?
   - Recommendation: `/rankings/me` only in Phase 1 to enforce auth model.
2. Should login accept email in addition to username?
   - Recommendation: username only for now (keep OAuth2 form simple).
3. Do we hard-fail if user is inactive (`is_active = false`)?
   - Recommendation: yes, return `401`.

---

## 9) Implementation Order (Fastest Path)

1. Auth dependency + auth service + auth API.
2. Rankings list endpoint (read path first).
3. Rankings create endpoint via DB function.
4. Rankings move endpoint with row locking + rebalance fallback.
5. Rankings delete endpoint.
6. Add tests and wire frontend to `/rankings/me` + create/move/delete.
