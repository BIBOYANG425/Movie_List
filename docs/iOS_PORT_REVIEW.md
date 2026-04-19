# Spool iOS SwiftUI Port — Codebase Review

Source: `/Users/mac/Documents/Movie_List_MVP-rebrand` (branch `feature/acquisition-retention-features`).
Purpose: reference for rebuilding the React/TypeScript app as a native iOS SwiftUI client against the **same Supabase backend**.
Generated: 2026-04-18.

---

## 1. Big picture

React + Vite SPA. Direct Supabase client from browser — no backend proxy, no REST gateway. Postgres with heavy RLS. Three media verticals (movie, tv_season, book) share one tier model. Social layer: follow graph, activity feed, reactions, comments, journal likes. AI layer: journal-enrichment agent via edge function, with explicit user-data consent and correction logging for training.

**Tech the iOS port keeps:** Supabase backend, TMDB, Open Library, tier/bracket ranking algorithm.
**Tech the iOS port replaces:** Vite bundler, Tailwind, lucide-react, recharts, react-router, drag-and-drop, color-thief, html2canvas, jszip, focus-trap, express/server.js, Vercel deploy.

**Recommended iOS stack:**
- `supabase-swift` (Postgrest, Auth, Realtime, Storage) — mirrors the JS client 1:1
- `NavigationStack` (iOS 16+) — replaces react-router
- `URLSession` for TMDB and Open Library (no SDK needed)
- `Kingfisher` or `NukeUI` for poster caching
- `Charts` (Swift Charts, iOS 16+) — replaces recharts radar/bar
- `GoogleSignIn` or `ASWebAuthenticationSession` for OAuth
- Keychain via Supabase iOS SDK for session
- `Localizable.xcstrings` (or SwiftGen) — 306 keys, en + zh

---

## 2. Domain model — Swift structs to write first

All models below are defined in `types.ts`. Dates are ISO 8601 strings; map to `Date` via `JSONDecoder.dateDecodingStrategy = .iso8601`. Supabase returns `snake_case`; use `convertFromSnakeCase` or explicit `CodingKeys`.

### 2.1 Enums (write these first — everything depends on them)

```swift
enum Tier: String, Codable, CaseIterable { case S, A, B, C, D }
enum Bracket: String, Codable { case commercial = "Commercial", artisan = "Artisan", documentary = "Documentary", animation = "Animation" }
enum MediaType: String, Codable { case movie, tvSeason = "tv_season", book }
enum Visibility: String, Codable { case `public`, friends, `private` }
enum ReactionType: String, Codable { case fire, agree, disagree, wantToWatch = "want_to_watch", love }
enum FeedCardType: String, Codable { case ranking, review, milestone, list }
enum NotificationType: String, Codable { case newFollower = "new_follower", reviewLike = "review_like", listLike = "list_like", badgeUnlock = "badge_unlock", rankingComment = "ranking_comment", journalTag = "journal_tag" }
enum EnginePhase: String, Codable { case prediction, probe, escalation, crossGenre = "cross_genre", settlement, complete, binarySearch = "binary_search" }
```

### 2.2 Foundation structs (MVP scope)

| Struct | Source type | Notes |
|---|---|---|
| `MediaItem` | `MediaItem` | Base; all optional fields union across movie/tv/book |
| `RankedItem` | `RankedItem` | `MediaItem` + tier, rankPosition, notes, watchedWithUserIds |
| `WatchlistItem` | `WatchlistItem` | `MediaItem` + addedAt |
| `AppProfile` | `AppProfile` | Own profile |
| `FriendProfile` / `UserSearchResult` / `UserProfileSummary` | same names | Progressive enrichment |
| `JournalEntry` | `JournalEntry` | 20+ fields incl. moodTags, vibeTags, favoriteMoments, standoutPerformances (JSONB) |
| `FeedCard` | `FeedCard` | Discriminated by `cardType` — use Swift enum with associated values |
| `AppNotification` | `AppNotification` | |
| `MovieReview`, `ActivityComment`, `FeedComment` | same | FeedComment nests replies one level |

### 2.3 Second-tier (add when feature comes online)

`MovieStub`, `MovieList` + `MovieListItem`, `SharedWatchlist*`, `TasteCompatibility`, `RankingComparison`, `GenreProfile*`, `TasteProfile`, `FriendRecommendation`, `TrendingMovie`, `MovieSocialStats`, `AgentSession`, `AgentMessage`, `AgentGeneration`, `UserCorrection`, `UserDataConsent`, `UserAchievement`.

**Discriminated-union watch:** `EngineResult` (`comparison | done`), `FeedCard.cardType`, `activity_events.event_type`. In Swift model each as `enum` with associated values — don't flatten into optionals.

**JSONB columns:** `journal_entries.standout_performances`, `agent_sessions.context_snapshot`, `user_taste_profiles.*`. Decode to concrete structs where shape is known, fall back to `AnyCodable` / `[String: JSONValue]` for `context_snapshot`.

---

## 3. Database schema — canonical reference

Full state after all migrations. See `supabase/migrations/` for the history.

### 3.1 Tables grouped by domain

**Core identity**
- `profiles` — PK `id` = `auth.users.id`; `username` citext UNIQUE matching `^[a-zA-Z0-9_]{3,32}$`; `profile_visibility` ∈ {public, friends, private}; `onboarding_completed`. Auto-created via `on_auth_user_created` trigger → `handle_new_user()` → `generate_unique_username()`.

**Rankings** (three tables, same shape with media-specific fields)
- `user_rankings` — movies. Unique `(user_id, tmdb_id)`. Has `watched_with_user_ids uuid[]` GIN index. Trigger `trg_recompute_taste` fires `recompute_taste_profile()` on every change.
- `tv_rankings` — seasons. `tmdb_id` format `tv_{showId}_s{seasonNum}`. No taste-recompute trigger.
- `book_rankings` — books. `tmdb_id` format `ol_{workKey}`. No taste-recompute trigger.

**Watchlists:** `watchlist_items`, `tv_watchlist_items`, `book_watchlist_items` — same shape, mirror of rankings.

**Social graph**
- `friend_follows` — directed `(follower_id, following_id)`, UNIQUE + CHECK `follower ≠ following`. Public SELECT, owner-only INSERT/DELETE.
- `feed_mutes` — user mutes user or movie from feed.

**Activity**
- `activity_events` — event_type ∈ {ranking_add, ranking_move, ranking_remove, review, list_create, milestone}. `metadata jsonb`. Indexed by (actor, created DESC), (created DESC), (type, created DESC).
- `activity_reactions` — composite PK (event, user, reaction). Visibility subquery: see reactions on events visible via RLS.
- `activity_comments` — parent_comment_id allows 1 level of replies. Body 1–500 chars.

**Journal**
- `journal_entries` — canonical entry table (replaces legacy `movie_reviews`). `standout_performances jsonb`, `photo_paths text[]`, `visibility_override` overrides profile default. `search_vector tsvector` GIN indexed. GIN indexes on mood_tags, vibe_tags. RLS checks visibility override + follow graph.
- `journal_likes` — PK (entry, user). Denormalized `like_count` on parent updated via RPC.

**Lists**
- `movie_lists` + `movie_list_items` + `movie_list_likes` — curated collections.
- `shared_watchlists` + `*_members` + `*_items` + `*_votes` — collaborative watchlists (partially deprecated but live).

**Notifications:** `notifications` — types listed in enum above. Indexed `(user, created DESC)` and partial `(user) WHERE NOT is_read`.

**Taste / suggestions**
- `movie_credits_cache` — shared TMDB cache keyed by numeric tmdb_id (no prefix).
- `user_taste_profiles` — computed: weighted_genres, top_directors, top_actors, decade_distribution, avg_runtime, underexposed_genres, top_movie_ids, total_ranked.

**AI / training**
- `user_data_consent` — three consent flags + version. No DELETE (audit).
- `agent_sessions` / `agent_messages` / `agent_generations` / `user_corrections` — conversation + output + correction log.
- `emotional_patterns` / `training_examples` — service_role only; iOS client ignores.

**Other:** `movie_stubs` (ticket-stub calendar), `user_achievements`, `comparison_logs`, `prediction_logs`.

### 3.2 RLS rules that matter on iOS

1. **Ranking visibility** (movies/tv/books) — caller can SELECT if: own row OR follows owner OR owner's profile is public. Cross-user fetches silently return empty without this; not an auth error.
2. **Journal visibility** — checks `visibility_override` (public / friends / private / NULL→friends) plus follow graph. NULL default = friends-only.
3. **Activity events** — owner or follower can see all events; non-followers on authenticated Explore can only see public types (ranking_add, review, list_create, milestone).
4. **Profiles** — public SELECT. All profiles readable; visibility lives on the referenced content tables.
5. **Notifications INSERT** — target user must exist in `profiles`. RLS enforces.
6. **Storage** — `avatars` and `journal-photos` buckets are public-read, write-restricted to `{user_id}/{filename}` prefix.

### 3.3 RPCs the client calls

- `increment_journal_likes(entry_id)` / `decrement_journal_likes(entry_id)` — SECURITY DEFINER
- `search_journal_entries(query, user_id)` — full-text, returns top 50
- `increment_review_likes` / `decrement_review_likes` — legacy, still present
- `recompute_taste_profile(user_id)` — fires automatically via trigger; client can call directly after bulk import

### 3.4 Edge functions

- `journal-agent` — multi-turn conversational agent. Input: user message + session context. Output: suggested mood tags, moments, takeaway, performances. Consent-gated on `consent_product_improvement`. iOS calls via `supabase.functions.invoke("journal-agent", body:)`.

### 3.5 Realtime

**No `.subscribe()` calls in the codebase today.** Web app polls `NotificationBell` every 15s. On iOS, subscribing to the following channels is the natural upgrade:
- `notifications` filtered by `user_id=eq.<uid>`
- `activity_events` — friend activity (filter client-side by follow set)
- `activity_reactions` / `activity_comments` — per event being viewed

---

## 4. Service layer — API surface

Each service below maps to a Swift repository. All functions take `userId` as an arg; no service calls `auth.getUser()` internally (except `agentService.recordGeneration`).

| Service | Purpose | Key functions (Swift naming) | Tables touched |
|---|---|---|---|
| `profileService` | Profile CRUD, search, avatars | `getProfile`, `getProfileSummary`, `getProfileByUsername`, `searchUsers`, `updateMyProfile`, `uploadAvatar`, `getFollowing`, `getFollowers` | profiles, friend_follows, storage:avatars |
| `followService` | Follow graph | `follow(target)`, `unfollow(target)`, `mutualCount(a,b)` | friend_follows, notifications |
| `consentService` | AI consent | `getConsent`, `upsertConsent`, `hasConsent`, `ensureConsentRecord`, `needsPrompt` | user_data_consent |
| `publicProfileService` | Read-only public rankings | `getPublicRankings(userId)` | user/tv/book_rankings |
| `socialService` | Lists + shared watchlists | `createList`, `addListItem`, `toggleListLike`, `createSharedWL`, `addSharedWLItem`, `toggleSharedWLVote` | movie_lists*, shared_watchlist* |
| `stubService` | Ticket-stub calendar | `createStub`, `getStubsForMonth`, `backfillStubs`, `extractPalette` | movie_stubs |
| `tasteService` | Compatibility + recs | `getCompatibility`, `getRankingComparison`, `getFriendRecs`, `getTrendingAmongFriends`, `getGenreProfile`, `getMovieSocialStats`, `getTVSocialStats`, `getBookSocialStats` | many; read-heavy |
| `feedService` | Social feed | `getFeedCards(filters, offset, limit)`, `toggleReaction`, `getReactionsForEvents`, `listFeedComments`, `addFeedComment`, `getMutes`, `addMute`, `logReviewEvent`, `logListCreatedEvent`, `logMilestoneEvent` | activity_events, activity_reactions, activity_comments, feed_mutes |
| `activityService` | Profile activity | `logRankingEvent`, `getFriendFeed`, `getRecentProfileActivity`, `getActivityEngagement`, `toggleLike`, `listComments`, `addComment`, `saveToWatchlist`, `rankActivityMovie` | activity_events, activity_reactions, activity_comments, watchlist_items, user_rankings |
| `journalService` | Journal CRUD | `upsertEntry`, `getEntry(userId, tmdbId)`, `getEntryById`, `deleteEntry`, `listEntries(filters)`, `searchEntries(query)`, `getStats`, `uploadPhoto`, `deletePhoto`, `toggleLike` | journal_entries, journal_likes, storage:journal-photos |
| `reviewService` | Legacy — delegates to journal | kept for backward compat | journal_entries |
| `notificationService` | Notifications | `create`, `list(userId)`, `markRead(ids)`, `getUnreadCount` | notifications |
| `achievementService` | Badges | `getUserAchievements`, `checkAndGrantBadges` | user_achievements + many reads |
| `tmdbService` | TMDB API | `searchMovies`, `searchTV`, `searchPeople`, `getPersonFilmography`, `getMovieGlobalScore`, genre discovery, streaming providers | TMDB v3 |
| `openLibraryService` | Books | `searchBooks(query)`, `getBookCoverUrl(coverId, size)`, `normalizeBookGenres(subjects)` | Open Library |
| `rankingAlgorithm` | Pure functions | `classifyBracket`, `computeSeedIndex`, `computeTierScore` | — |
| `spoolPrediction` | Signal-based score prediction | `computePredictionSignals`, `predictScore` | — |
| `spoolRankingEngine` | State machine for comparisons | 5-phase engine: Prediction → Probe → Escalation → Cross-genre → Settlement | — |
| `spoolPrompts` | Tier/genre emotional prompts | `getComparisonPrompt(tier, genreA, genreB, phase)` | — |
| `agentService` | AI journal agent | `createSession`, `appendMessage`, `sendAgentMessage`, `requestReviewGeneration`, `recordGeneration` | agent_sessions, agent_messages, agent_generations + edge function |
| `correctionService` | User corrections to AI | `recordCorrection`, `recordAllCorrections`, `computeEditDistance`, `detectCorrectionType` | user_corrections |
| `letterboxdImportService` | CSV import | `extractZip`, `mergeEntries`, `buildPreview`, `resolveAllWithTMDB`, `assignPositions`, `persistImport` | user_rankings, watchlist_items, journal_entries |
| `csvParser` | RFC 4180 parser | `parseCSV` | — |
| `fuzzySearch` | Local fuzzy match | `fuzzyFilterLocal`, `getBestCorrectedQuery`, `mergeAndDedupSearchResults` | — |

### Cross-cutting patterns

- **Error handling:** `console.error` + return `null | false | []`. In Swift, use `throws` with typed errors — the current pattern loses information.
- **Auth:** always passed as `userId` arg; keep this on iOS for testability.
- **Caching:** none in service layer. Add on iOS: `NSCache` for TMDB search responses, SQLite or SwiftData for rankings/journals, with background sync.
- **Pagination:** offset/limit, default 20–30. Consider cursor on iOS for infinite scroll.
- **Optimistic updates:** none. Add on iOS in the UI layer with rollback on error.
- **Side effects:** `followUser`→notification, `upsertJournalEntry`→activity+tag notifications, `createMovieList`→activity, `checkAndGrantBadges`→milestone activity. Mirror these in the Swift repo methods; a thin coordinator can orchestrate.

---

## 5. Feature inventory — screens to build

### 5.1 Routes → SwiftUI navigation

| Web route | iOS scene | Auth | Core function |
|---|---|---|---|
| `/` | `LandingView` | — | Marketing, trending, live feed preview |
| `/auth` | `AuthView` | — | Email + Google OAuth |
| `/auth/callback` | deep-link handler | — | OAuth redirect + session poll |
| `/onboarding/profile` | `ProfileOnboardingView` | ✓ | Avatar + display name + bio |
| `/onboarding/movies` | `MovieOnboardingView` | ✓ | Search + comparison-driven ranking, 5+ required |
| `/app` | `MainTabView` | ✓ | Tier grid + feed + discover + watchlist + journal + notifications |
| `/profile/:id` | `MyProfileView` | ✓ | Own profile, tabs: journal, memories, lists, achievements |
| `/u/:username` | `PublicProfileView` | optional | Read-only public tier list |

Web uses modals for everything. On iOS, lift to `.sheet` / `.fullScreenCover` per navigation rule: destination = push; composition = sheet; critical decision = alert/confirmationDialog.

### 5.2 Signature UX patterns

- **Tier ranking (S–D)** with sticky-tier migration. Core algorithm lives in `rankingAlgorithm.ts` + `spoolRankingEngine.ts` — pure logic, port directly to Swift.
- **Comparison engine** — head-to-head "this vs X" during placement. 5 phases, bounded at ~5–7 questions. State machine in `spoolRankingEngine.ts`.
- **Three media types in one tier list** — movies / TV seasons / books. User flips mediaMode; same tier UI.
- **Journal entry composition** — mood tags (20 across 4 categories), vibe tags (11), favorite moments, standout performances (cast), photo grid (max 6 @ 5MB), visibility override, friend tagging creates notifications.
- **Social feed** — `FeedCard` discriminated union. Reactions (5 emoji), threaded comments (1 level), mutes. Currently polled; upgrade to Realtime on iOS.
- **Genre radar chart** — swap recharts for Swift Charts.
- **Universal search** — TMDB movies/TV/people + Open Library books + user profiles, merged + deduped + fuzzy-corrected. Debounce 300ms.
- **Letterboxd import** — zip → CSV parse → TMDB resolve → tier assignment → batch upsert. Rate-limited 8-concurrent. On iOS, use `UIDocumentPickerViewController` for zip selection.
- **Ticket stubs** — color palette extracted from poster. Web uses `color-thief-browser`; on iOS use `UIImage` + `CIAreaAverage` or a Swift package like `DominantColors`.

### 5.3 Auth flow

- Email + password via `supabase.auth.signUp` / `signIn`. Signup triggers profile auto-creation via Postgres trigger; client polls `getProfile` up to 10× 250ms until profile row exists.
- Google OAuth via redirect to `auth.supabase.co/authorize?provider=google&redirect_to=<callback>`. On iOS: `ASWebAuthenticationSession` with custom URL scheme, or `GoogleSignIn` SDK + `supabase.auth.signInWithIdToken`.
- Session persistence: Supabase iOS SDK writes to Keychain automatically.
- Redirect logic: `needsOnboarding = !profile || !profile.onboardingCompleted` — route to `/onboarding/profile` then `/onboarding/movies` then `/app`.

### 5.4 i18n

- 306 keys × 2 locales (`en`, `zh`). Flat key-value files under `i18n/`.
- 20 logical namespaces: nav, tab, stubs, firstRun, ranking, tier, watchlist, stats, feed, filter, social, profile, friend, discover, journal, badges, search, settings, errors, misc.
- TMDB titles localized per-user via `useLocalizedItems` hook (fetches `language=zh-CN` on demand, caches in localStorage).
- **On iOS:** migrate keys to `.xcstrings` catalog. Titles: call TMDB with `language` param matching `Locale.current.language.languageCode`.

---

## 6. Port risks & gotchas

### 6.1 Won't translate directly

| Area | Why | iOS approach |
|---|---|---|
| Drag-and-drop tier reorder | HTML5 DnD API | `.onDrag` / `.onDrop` on iPad, long-press + drag on iPhone, or explicit "move" buttons |
| `color-thief-browser` palette extraction | Canvas API | `CIAreaAverage` or `DominantColors` package; extract on device and upload to `movie_stubs.palette` |
| `html2canvas` share-card rendering | DOM screenshot | `ImageRenderer` (iOS 16+) to rasterize a SwiftUI view |
| `jszip` Letterboxd import | Browser blob/ZIP | `ZIPFoundation` package + `FileManager` |
| `focus-trap-react` in modals | Web accessibility | SwiftUI accessibility focus (`@AccessibilityFocusState`) is built-in |
| Recharts radar/bar | SVG | Swift Charts `Chart { BarMark / AreaMark }` |
| Tailwind utility classes | Build-time CSS | Design tokens to `Color`/`Font` in a `Theme.swift` derived from `styles/theme.css` |

### 6.2 API-key exposure

`tmdbService.ts` reads `import.meta.env.VITE_TMDB_API_KEY` — shipped in the client bundle. On iOS you will ship it in the app binary too, which is equivalent exposure. If you want a real lockdown, move TMDB proxying behind a Supabase edge function with a secret-held key. Not currently done.

### 6.3 RLS surprises

- Empty result set ≠ error. Writing "no rankings found" on an iOS friend profile could mean "not following" rather than "they haven't ranked anything." Expose the distinction in the UI.
- Journal `visibility_override = NULL` defaults to **friends**, not public. Three-state logic everywhere.
- `notifications` INSERT requires target profile row to exist — don't pre-create notifications during signup races.

### 6.4 Realtime gap

Web polls. iOS can use Realtime immediately for `notifications` and viewed-event reactions. Also a good spot for `activity_events` with a client-side follow-set filter. But watch channel limits (2 default, up to 100 paid) — don't subscribe per card.

### 6.5 Legacy present in schema

- `movie_reviews` and `review_likes` still exist; `journal_entries` is canonical. `reviewService.ts` delegates. Port against `journal_entries` only.
- `shared_watchlists` family is partially deprecated but live. Safe to defer until Phase 2.

### 6.6 Known issues from project memory

- Pre-existing TS type mismatches in `profileService.ts` (optional vs required props). Clean slate on iOS — don't mirror the bug.
- No error boundaries; ~40 `console.error` sites with no user-facing message. Bake error presentation into the SwiftUI shell from day one.
- Missing indexes: `notifications(user_id, created_at)`, `activity_reactions(user_id)`. If iOS hits the scaling wall, add these migrations before blaming the client.

---

## 7. Suggested build order

**Phase 0 — foundation (1–2 weeks)**
1. Swift Package scaffolding, `supabase-swift` integration, Keychain session.
2. Enums + MVP structs (section 2).
3. Auth flow (email + Google) + profile onboarding + movie onboarding with 5-movie minimum.

**Phase 1 — core ranking (2–3 weeks)**
4. `RankingRepository` (movies only first).
5. Tier grid view + add-media flow + comparison engine port.
6. Watchlist.
7. Ticket stubs w/ palette extraction.

**Phase 2 — social (2–3 weeks)**
8. Follow graph, profile views (own + public).
9. Activity feed + reactions + comments. Add Realtime for notifications.
10. Journal entries (CRUD, photos, tags, friend mentions).
11. Notifications + bell badge.

**Phase 3 — discovery & polish (2 weeks)**
12. TV + book verticals.
13. Taste compatibility, friend recommendations, trending, social stats per media.
14. Genre radar, stats views.
15. Achievements.

**Phase 4 — AI + import (optional)**
16. Journal agent (edge function integration + consent flow).
17. Letterboxd import.
18. Correction logging.

---

## 8. Appendix — constants worth porting verbatim

- `TIERS`, `TIER_LABELS`, `TIER_USER_PROMPTS`, `TIER_SCORE_RANGES`, `TIER_WEIGHTS`
- `TIER_HEX` — hex colors for tier visualization (S–D)
- `BRACKETS`, `BRACKET_LABELS`
- `MOOD_TAGS` (20 across 4 categories), `VIBE_TAGS` (11), `MOOD_CATEGORIES` (4)
- `ALL_TMDB_GENRES` (19), `ALL_TV_GENRES` (13), `ALL_BOOK_GENRES` (19)
- `JOURNAL_REVIEW_PROMPTS`, `JOURNAL_TAKEAWAY_PROMPTS`, `TIER_COMPARISON_PROMPTS`, `GENRE_COMPARISON_PROMPTS`
- Thresholds: `MIN_MOVIES_FOR_SCORES=5`, `SMART_SUGGESTION_THRESHOLD=3`, `NEW_USER_THRESHOLD=15`, `MAX_TIER_TOLERANCE=2.0`
- `JOURNAL_PHOTO_BUCKET='journal-photos'`, `JOURNAL_PHOTO_MAX_BYTES=5242880`, `JOURNAL_MAX_PHOTOS=6`, `JOURNAL_MAX_MOMENTS=5`
- `DEFAULT_POOL_SLOTS = { similar:3, taste:4, trending:2, variety:2, friend:1 }`
- Platform options (13): theater, netflix, apple_tv, max, hulu, prime, disney, peacock, paramount, mubi, criterion, physical, other

These are text/hex/number lists — copy into a `Constants.swift` unchanged.
