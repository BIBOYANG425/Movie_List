# C3-iOS Part A — Task 2 report: WatchlistRepository + contract layer

**Branch:** `feat/ios-parity-c3-watchlist` · **Base HEAD:** `815c0c3`
**Files added:**
- `ios/Spool/Sources/Spool/Services/WatchlistModels.swift` — model + row DTOs + pure `WatchlistContract`
- `ios/Spool/Sources/Spool/Services/WatchlistRepository.swift` — the actor
- `ios/Spool/Tests/SpoolTests/WatchlistContractTests.swift` — 24 pure tests

Tests: **381 baseline → 405** (24 new), all green. `swift build` clean, no warnings.

---

## Interfaces as built (exact signatures for Tasks 3-5)

### Model — `WatchlistItem` (`Identifiable, Sendable, Hashable`)
```swift
public struct WatchlistItem {
    public let id: String            // tmdb_id verbatim: tmdb_{n} | tv_{n}_s{m} | tv_{n} | ol_{key}
    public let title: String
    public let year: String          // "" when null (web year ?? '')
    public let posterUrl: String     // "" when null
    public let mediaType: WatchlistMediaType   // .movie | .tv | .book
    public let genres: [String]
    public let addedAt: Date
    public let director: String?     // movie/TV
    public let creator: String?      // TV
    public let showTmdbId: Int?      // TV
    public let seasonNumber: Int?    // TV (nil OR 0 = whole show)
    public let seasonTitle: String?  // TV
    public let author: String?       // book
    public let pageCount: Int?       // book
    public let isbn: String?         // book
    public let olWorkKey: String?    // book
    public let olRatingsAverage: Double? // book
    public var isWholeShow: Bool     // true iff .tv && (seasonNumber == nil || 0)
    public init(id:title:year:posterUrl:mediaType:genres:addedAt:
                director:creator:showTmdbId:seasonNumber:seasonTitle:
                author:pageCount:isbn:olWorkKey:olRatingsAverage:)  // per-media args default nil
}
```

### `WatchlistMediaType: String, CaseIterable` — `.movie | .tv | .book`
```swift
var dbType: String                 // "movie" | "tv_season" | "book"  (the `type` column)
init?(dbType: String)              // "tv_season"|"tv" → .tv
```

### `actor WatchlistRepository` (`.shared`)
```swift
enum RepoError: Error { case notConfigured, notAuthenticated }

func list(media: WatchlistMediaType) async throws -> [WatchlistItem]
    // own rows, added_at desc; B2 rows dropped; THROWS on failure (feed convention → empty state)

func listForUser(userId: UUID, media: WatchlistMediaType) async throws -> [WatchlistItem]
    // cross-user; userId is a FILTER, RLS decides visibility; added_at desc; THROWS on failure
    // (Task 5 Discover Twin read)

@discardableResult
func add(item: WatchlistItem) async -> Bool
    // UPSERT on (user_id, tmdb_id); never sends added_at; returns false on failure (no throw)

func remove(tmdbId: String, media: WatchlistMediaType) async throws
    // DELETE by (user_id, tmdb_id); owner-only + belt-and-suspenders eq(user_id); THROWS on failure

func allBookmarkedIds(media: WatchlistMediaType) async throws -> Set<String>
    // exclusion set; for .tv, season ids EXPAND to also include show id (tv_{n}_s{m} → + tv_{n});
    // returns [] on read failure (it's a filter, not a UI list) — Task 5 exclusions
```

### Pure contract (`enum WatchlistContract`) — usable by any task, network-free
```swift
// id helpers
static func movieId(_ tmdbID: Int) -> String            // "tmdb_{n}"
static func showId(_ showTmdbID: Int) -> String         // "tv_{n}"
static func tvSeasonId(showId: Int, season: Int) -> String  // "tv_{n}_s{m}"
static func bookId(_ workKey: String) -> String         // "ol_{key}"
static func tableName(for: WatchlistMediaType) -> String

// semantics
static func isWholeShow(seasonNumber: Int?) -> Bool     // nil || 0
static func expandExclusionIds(for id: String) -> [String]     // season → [self, showId]; else [self]
static func expandedBookmarkedIds(_ ids: some Sequence<String>) -> Set<String>

// row → model (nil = drop the row)
static func mapMovieRow(_:) -> WatchlistItem?
static func mapTVRow(_:) -> WatchlistItem?     // nil when show_tmdb_id == 0 (B2), logs loudly
static func mapBookRow(_:) -> WatchlistItem?

// add payloads (snake_case, explicit-null optionals, NO added_at)
static func movieAddPayload(_:userID:) -> MovieAddPayload
static func tvAddPayload(_:userID:) -> TVAddPayload
static func bookAddPayload(_:userID:) -> BookAddPayload
```
Row DTOs (`Codable`): `WatchlistRow`, `TVWatchlistRow` (`show_tmdb_id: Int`, `season_number: Int?`), `BookWatchlistRow`.

---

## Column mapping table (every column, no silent drops)

| Table / column | DB type | → `WatchlistItem` | Notes |
|---|---|---|---|
| `tmdb_id` | text | `id` | verbatim (tmdb_/tv_/ol_) |
| `title` | text | `title` | |
| `year` | text? | `year` | null → `""` |
| `poster_url` | text? | `posterUrl` | null → `""` |
| `type` | text | `mediaType` | via `init?(dbType:)`; movie table unknown → `.movie` |
| `genres` | text[]? | `genres` | null → `[]` |
| `added_at` | timestamptz | `addedAt` | ISO8601 (fractional-or-plain); unparseable → `.distantPast` |
| `director` (movie) | text? | `director` | |
| **TV** `show_tmdb_id` | int | `showTmdbId` | **`0` → row REJECTED (B2)** |
| **TV** `season_number` | int? | `seasonNumber` | `nil` OR `0` → whole show (D6) |
| **TV** `season_title` | text? | `seasonTitle` | |
| **TV** `creator` | text? | `creator` | |
| **book** `author` | text? | `author` | |
| **book** `page_count` | int? | `pageCount` | |
| **book** `isbn` | text? | `isbn` | |
| **book** `ol_work_key` | text? | `olWorkKey` | |
| **book** `ol_ratings_average` | real? | `olRatingsAverage` | |

Deliberately **not mapped:** `id` (row PK UUID — kept on the DTO, not the model), `user_id`. The web reads `row.episode_count` in `rowToTVWatchlistItem`, but that column **does not exist** in the `tv_watchlist_items` DDL (web always got undefined), and the brief's interface list omits it — so `episodeCount` is intentionally absent here. No `globalScore` on the watchlist model (web derives it only on the *ranked* book item, not the watchlist item).

### Add-payload columns (client → upsert, matches web `addTo*Watchlist`)
- **movie** (8): user_id, tmdb_id, title, year, poster_url, type=`movie`, genres, director
- **TV** (11): + show_tmdb_id (nil→0), season_number (nil→0), season_title, creator, type=`tv_season`
- **book** (12): + author, page_count, isbn, ol_work_key, ol_ratings_average, type=`book`
- All optionals encode **explicit null** (custom `encode(to:)`) for web-parity on the UPSERT-UPDATE path; **`added_at` never sent** (DB `default now()`); `user_id` lowercased UUID.

---

## Test evidence (24 tests, `WatchlistContractTests`)
- Movie/TV/book row → item: every column asserted, plus null-coalescing (year/poster→"", genres→[]).
- Whole-show detection: `season_number = 0` ✓ whole show, `= NULL` ✓ whole show, `= 3` ✓ not.
- **B2 rejection:** `show_tmdb_id = 0` rows → `mapTVRow` returns nil (for season, null-season, and 0-season); non-zero accepted.
- Id helpers: `tmdb_603`, `tv_1399`, `tv_1399_s1`, `ol_OL45804W`.
- **TV exclusion expansion:** `tv_1399_s1` → `[tv_1399_s1, tv_1399]`; `tv_1399`/`tmdb_603`/`ol_…` unchanged; set-fold dedups overlapping show ids.
- Media-type ↔ db `type` round-trip (`tv_season` ↔ `.tv`).
- Add-payload wire shapes: exact key sets per table, `type` sentinel, `?? 0` coalescing, **no `added_at`**, dispatch-by-type.

---

## Concerns / notes for downstream tasks
1. **`add` returns `Bool`, does not throw** — matches the brief signature and the web's optimistic-prepend-then-revert-on-error UI pattern. Task 3's tab model owns the revert/toast; the repo just reports success. `remove`/`list`/`listForUser` DO throw (feed convention).
2. **`allBookmarkedIds` swallows read errors → `[]`.** Rationale: it feeds an *exclusion* filter (Task 5 Discover), where "exclude nothing" degrades gracefully but a throw would kill the suggestion fetch. If Task 5 needs to distinguish "empty" from "failed", it must add its own signal — flagging so it's a conscious choice, not a silent swallow.
3. **`listForUser` on the movie table returns `[]` for other users** — `watchlist_items` RLS is owner-only (no follower SELECT). Only TV/book add follower SELECT. So a cross-user *movie* watchlist read is empty by DB design; Task 5's Twin surface should not expect other users' movie bookmarks.

## Correction (fix round 1)

Concern #3 above is **superseded** by sibling commit 815c0c3 on this branch
(`supabase/migrations/20260709_c3_movie_watchlist_follower_select.sql`).  That
migration adds follower SELECT to `watchlist_items`, making the movie table
follower-visible alongside TV and book.  Task 5's Twin CAN expect cross-user
movie bookmarks once the Task-1 migration applies; the prior "empty by DB design"
statement no longer holds.
4. **`episode_count` intentionally dropped** (see mapping table) — not a real column; web read always undefined; brief omits it. If a later slice adds the column + writer, extend `TVWatchlistRow` + `mapTVRow` + the payload together.
5. **Corrupt-row skip is silent to the caller** but `NSLog`-loud in device logs (`[WatchlistRepository] rejecting corrupt TV row (show_tmdb_id=0)…`), per B2's "skip the row, log loudly."
6. **No cross-user write path** — `add`/`remove` are always `currentUserID()`-scoped; there is no way to write another user's watchlist through this repo (RLS would reject anyway).
