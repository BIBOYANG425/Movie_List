# SPOOL Gap Analysis

> Produced 2026-02-26 by reading the full codebase and mapping it against the three feature specs: Adaptive Ranking System, Social Feed, and Movie Review Journal (+ AI Agent).

---

## 1. Adaptive Ranking System

### What EXISTS (fully built)

| Feature | Location | Notes |
|---------|----------|-------|
| Five-tier ranking (S/A/B/C/D) | `types.ts`, `constants.ts`, `RankingAppPage.tsx` | Score ranges: S=9-10, A=7-8.9, B=5-6.9, C=3-4.9, D=0.1-2.9 |
| Tier score computation | `rankingAlgorithm.ts:computeTierScore` | Linear interpolation within tier range |
| Bracket classification | `rankingAlgorithm.ts:classifyBracket` | Commercial (default), Documentary, Animation auto-detected from genres |
| Bracket filtering UI | `RankingAppPage.tsx` | Filter tabs: All / Commercial / Artisan / Documentary / Animation |
| Adaptive binary search insertion | `AddMediaModal.tsx` | `computeSeedIndex` seeds from TMDB global score, `adaptiveNarrow` binary-searches |
| Drag & drop reorder (within tier) | `RankingAppPage.tsx:handleDropOnItem` | Batch upserts all shifted positions |
| Drag & drop tier migration | `RankingAppPage.tsx:handleDrop` | Opens comparison flow in target tier |
| Sticky tier logic | `RankingAppPage.tsx:computeStickyTiers` | Auto-reassigns items when score drifts beyond dynamic tolerance |
| Score visibility gating | `RankingAppPage.tsx` | Hidden until >= 10 ranked movies |
| Notes per movie | `user_rankings.notes` | Max 280 chars, optional |
| Watchlist / Save for Later | `watchlist_items` table, `Watchlist.tsx` | Separate from rankings |
| Comparison logging | `comparison_logs` table | Analytics for algorithm training |
| Smart 5-pool suggestions | `tmdbService.ts` | Similar, Taste, Trending, Variety, Friend pools |
| Taste profile computation | `tmdbService.ts:buildTasteProfile` | Tier-weighted genres, decade distribution, underexposed genres |
| DB taste profile foundation | `user_taste_profiles`, `movie_credits_cache` tables | Trigger-based recomputation on ranking changes |
| Backfill prefetch system | `tmdbService.ts:getSmartBackfill` | Two-pool architecture with seamless refill |
| Generic suggestions (< 3 movies) | `tmdbService.ts:getGenericSuggestions` | 50% trending + 50% classics |
| Friend suggestion picks | `tmdbService.ts:getFriendSuggestionPicks` | Random S/A-tier movies from followed users |
| Onboarding flow (10-movie gate) | `MovieOnboardingPage.tsx` | Simplified tier assignment for first 5, comparison for 6+ |
| Movie detail modal | `MediaDetailModal.tsx` | Backdrop, poster, genres, runtime, director, streaming providers |
| Group rankings | `GroupRankingView.tsx` | Multi-user consensus with divergence scoring |
| Ranking comparison view | `RankingComparisonView.tsx` | Side-by-side with agreement/disagreement filters |
| Stats view | `StatsView.tsx` | Genre radar chart, distribution stats |

### What's MISSING or INCOMPLETE

| Gap | Severity | Notes |
|-----|----------|-------|
| **Artisan bracket classification** | Medium | Always falls through to Commercial. Needs festival/distribution data not in TMDB. Deferred by design. |
| **Score persistence** | Low | Scores recomputed on every filter change; not stored in DB. Could cause confusion if numbers shift. |
| **Undo after ranking** | Low | No undo for comparison result after insertion completes. User must drag to fix. |
| **Batch import** | Low | No way to import rankings from Letterboxd, IMDb, etc. |

**Verdict: Ranking System is ~95% complete.** Remaining gaps are deliberate scope cuts or low-priority polish.

---

## 2. Social Feed

### What EXISTS (fully built)

| Feature | Location | Notes |
|---------|----------|-------|
| Activity event logging | `feedService.ts`, `friendsService.ts` | Types: ranking_add, ranking_move, ranking_remove, review, list_create, milestone |
| Friends feed tab | `SocialFeedView.tsx`, `feedService.ts:getFeedCards` | Shows activity from followed users only |
| Explore feed tab | `SocialFeedView.tsx` | Shows public activity from all users |
| 5-reaction system | `ReactionPicker.tsx`, `feedService.ts:toggleReaction` | fire, agree, disagree, want_to_watch, love |
| Threaded comments (1-level) | `FeedCommentThread.tsx`, `feedService.ts` | Max 500 chars, reply-to nesting |
| Feed card types | `FeedRankingCard`, `FeedReviewCard`, `FeedMilestoneCard`, `FeedListCard` | Each event type has dedicated card component |
| Filter bar | `FeedFilterBar.tsx` | Card type, tier, time range (24h/7d/30d/all) |
| Bracket filtering | `feedService.ts` | Client-side from metadata |
| User muting | `feed_mutes` table, `FeedCardMenu.tsx` | Hide all activity from specific user |
| Movie muting | `feed_mutes` table, `FeedCardMenu.tsx` | Hide all activity about specific movie |
| Review boost sorting | `feedService.ts` | Reviews get 2-hour time boost |
| Milestone throttling | `feedService.ts` | Max 3 milestones per day in feed |
| Infinite scroll pagination | `SocialFeedView.tsx` | IntersectionObserver, 20 items/page |
| Follow/unfollow | `friendsService.ts` | One-directional follow graph |
| User search & discovery | `friendsService.ts:searchUsers` | Search by username/display_name |
| Profile summary | `friendsService.ts:getProfileSummary` | Follower/following counts, follow status |
| Taste compatibility | `TasteCompatibilityBadge.tsx`, `friendsService.ts` | Compatibility scoring between users |
| Notification bell | `NotificationBell.tsx` | Badge count, notification list |
| Notification types | `notifications` table | new_follower, review_like, party_invite, poll_vote, ranking_comment, journal_tag, etc. |

### What's MISSING or INCOMPLETE

| Gap | Severity | Notes |
|-----|----------|-------|
| **Real-time feed updates** | Medium | No Supabase Realtime subscriptions. Feed requires manual refresh or re-mount to see new activity. |
| **"Trending" or "Most Engaged" sort** | Low | Feed is chronological only. No option to sort by reaction count or engagement. |
| **DMs / Private messaging** | Low | No direct message system between users. |
| **Pinned posts** | Low | No ability to pin important activity to top of feed. |
| **Comment editing** | Low | Comments can only be deleted, not edited. |
| **User blocking** | Medium | Muting hides content in feed but doesn't prevent follows/comments/reactions from blocked user. |
| **Report/flag content** | Medium | No abuse reporting mechanism. |
| **Rich media in comments** | Low | Comments are plain text only, no images/links. |
| **Feed algorithm tuning** | Low | No ML-based relevance scoring. Pure reverse-chronological with review boost. |

**Verdict: Social Feed is ~90% complete.** Core feed, reactions, comments, muting, and filtering all work. Missing features are mostly social safety (blocking/reporting) and engagement optimizations.

---

## 3. Movie Review Journal

### What EXISTS (fully built)

| Feature | Location | Notes |
|---------|----------|-------|
| `journal_entries` table | `supabase_journal_entries.sql` | Full schema with all fields, indexes, RLS, full-text search vector |
| `journal_likes` table | `supabase_journal_entries.sql` | Like tracking with atomic increment/decrement RPCs |
| Journal entry CRUD | `journalService.ts` | upsert, get, getById, list, delete, search, stats |
| Photo upload/delete | `journalService.ts` | Supabase Storage bucket `journal-photos`, max 6 photos, 5MB each |
| Full-text search | `journalService.ts:searchJournalEntries` | RPC-based with weighted tsvector (title A, review B, moments C, takeaway D) |
| Journal stats | `journalService.ts:getJournalStats` | Total entries, most common mood, streaks, friend tags |
| Slide-up entry sheet | `JournalEntrySheet.tsx` | Progressive disclosure, auto-save on dismiss |
| Tier-aware prompts | `constants.ts:JOURNAL_REVIEW_PROMPTS` | S: "What makes this an all-time great?", etc. |
| 24 mood tags (4 categories) | `constants.ts:MOOD_TAGS`, `MoodTagSelector.tsx` | Positive, Reflective, Intense, Light |
| 11 vibe tags | `constants.ts:VIBE_TAGS`, `VibeTagSelector.tsx` | Solo watch, Date night, Theater, etc. |
| Cast selector | `CastSelector.tsx` | TMDB credits API, searchable, 30 top cast with photos |
| Friend tagging | `FriendTagInput.tsx` | Searchable friends, sends `journal_tag` notifications |
| Photo grid | `JournalPhotoGrid.tsx` | 3x2 grid, upload/remove, accepts JPEG/PNG/WebP |
| 13 platform options | `constants.ts:PLATFORM_OPTIONS` | Theater, Netflix, Apple TV+, etc. |
| Favorite moments | `JournalEntrySheet.tsx` | Up to 5 free-text inputs |
| Rewatch toggle + note | `JournalEntrySheet.tsx` | Boolean toggle with conditional text field |
| Personal takeaway (private) | `JournalEntrySheet.tsx` | Always-private field with tier-aware prompts |
| Spoiler toggle | `JournalEntrySheet.tsx` | Marks entry as containing spoilers |
| Visibility controls | `JournalEntrySheet.tsx` | Default / Public / Friends / Private buttons |
| Journal home view | `JournalHomeView.tsx` | Stats bar, search, filters, infinite scroll |
| Journal filter bar | `JournalFilterBar.tsx` | Mood, vibe (own only), tier, platform (own only), date range |
| Journal entry card | `JournalEntryCard.tsx` | Truncated review, mood chips, like/photo/moment counts |
| Post-ranking integration | `RankingAppPage.tsx` | JournalEntrySheet opens automatically after ranking a movie |
| Movie detail integration | `MediaDetailModal.tsx` | "Leave a Review" button opens JournalEntrySheet |
| Profile tab integration | `ProfilePage.tsx` | Activity / Journal tab switcher |
| Privacy-aware display | `JournalHomeView.tsx` | Hides vibe/context/takeaway when viewing others |
| Activity feed integration | `journalService.ts` | Calls `logReviewActivityEvent()` for public/friends reviews |

### What's MISSING (entirely unbuilt)

| Gap | Severity | Notes |
|-----|----------|-------|
| **Journal Agent (Conversational AI)** | **CRITICAL** | No AI integration exists anywhere in the codebase. The spec calls for a conversational agent that interviews users about their movie experience, uses voice input, and generates structured journal entries. Zero implementation: no LLM API calls, no voice/speech recognition, no chat interface, no prompt engineering, no agent state machine. |
| **Voice input** | **CRITICAL** | No Web Speech API, no Whisper integration, no microphone access. The agent spec requires voice-first input for the journal interview flow. |
| **AI-generated insights** | High | No analysis of journal entries for patterns, trends, or personalized observations. |
| **Year-in-review stats** | Medium | Deferred to V2 by design. |
| **Journal export** | Low | No PDF/markdown export. Deferred by design. |
| **Rich text formatting** | Low | Plain text only. Deferred by design. |
| **Custom mood/vibe tags** | Low | Fixed sets only. Deferred by design. |
| **Timeline/calendar view** | Low | List view only. Deferred by design. |
| **Edit history tracking** | Low | Last save wins. Deferred by design. |

**Verdict: Journal data layer and UI are ~95% complete. The Journal Agent (conversational AI with voice) is 0% complete and represents the single largest gap in the entire product.**

---

## 4. Cross-Cutting Gaps

| Gap | Severity | Affects | Notes |
|-----|----------|---------|-------|
| **No AI/LLM integration** | Critical | Journal Agent | No API keys, no service layer, no UI for AI. Foundation must be built from scratch. |
| **No voice/speech input** | Critical | Journal Agent | No Web Speech API or Whisper integration. |
| **No real-time updates** | Medium | Social Feed | No Supabase Realtime subscriptions. Feed is poll-based (re-mount to refresh). |
| **No user blocking** | Medium | Social Feed | Muting hides feed content but doesn't prevent interactions. |
| **No content reporting** | Medium | Social Feed, Journal | No abuse/spam reporting mechanism. |
| **No offline support** | Low | All | No service worker, no local caching strategy. |
| **No push notifications** | Low | Social Feed | Notifications visible in-app only, no browser push. |
| **Old review system not fully deprecated** | Low | Journal | `movie_reviews` table still exists in schema alongside `journal_entries`. `friendsService.ts` review functions partially migrated. |
| **Error boundaries missing** | Medium | All | No React error boundaries wrapping major features. Crash in one component takes down the page. |
| **Loading skeletons missing** | Low | All | Most loading states show text ("Loading...") rather than skeleton placeholders. |

---

## Priority Matrix

```
                    HIGH IMPACT
                        |
    [Journal Agent]     |     [Real-time Feed]
    [Voice Input]       |     [User Blocking]
                        |     [Content Reporting]
   ─────────────────────┼─────────────────────
                        |     [Error Boundaries]
    [AI Insights]       |     [Loading Skeletons]
                        |     [Score Persistence]
                        |
                    LOW IMPACT

        HIGH EFFORT ←───┼───→ LOW EFFORT
```

### Build Priority (recommended order):

1. **Journal Agent + Voice** — The single largest unbuilt feature. Requires: LLM API integration, agent state machine, chat UI, voice input (Web Speech API or Whisper), prompt engineering for structured extraction, and entry generation from conversation.

2. **Real-time feed updates** — Medium effort via Supabase Realtime channels. High user-facing impact (feed feels "alive").

3. **User blocking + content reporting** — Social safety features needed before scaling user base.

4. **Error boundaries + loading skeletons** — Low effort, improves perceived quality.

5. **Old review system cleanup** — Low effort housekeeping. Drop `movie_reviews` table, clean up legacy functions in `friendsService.ts`.

---

## File Inventory

### Existing Service Files (5)
- `services/tmdbService.ts` (1,116 lines) — TMDB API + suggestions
- `services/friendsService.ts` (2,837 lines) — Social graph + legacy reviews
- `services/feedService.ts` (592 lines) — Feed, reactions, comments, mutes
- `services/journalService.ts` (446 lines) — Journal CRUD, photos, likes, stats
- `services/rankingAlgorithm.ts` (191 lines) — Scoring, brackets, binary search

### Existing Component Files (42)
- 7 pages, 28 components, 7 journal sub-components

### Files That Would Need To Be Created (for Journal Agent)
- `services/agentService.ts` — LLM API integration, prompt management, conversation state
- `services/voiceService.ts` — Web Speech API / Whisper integration
- `components/JournalAgentChat.tsx` — Chat interface for agent conversation
- `components/journal/VoiceInput.tsx` — Microphone button + voice visualization
- `components/journal/AgentMessage.tsx` — Agent message bubble with typing indicator
- `components/journal/UserMessage.tsx` — User message bubble (text or voice transcript)
- `components/journal/AgentReview.tsx` — Generated journal entry preview from agent conversation
