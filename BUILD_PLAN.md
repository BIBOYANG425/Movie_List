# SPOOL Build Plan

> Sequenced implementation plan based on the gap analysis in `GAPS.md`.
> Produced 2026-02-26.

---

## Phase 1: Foundation & Safety (1-2 days)

Quick wins that harden the existing product before building new features.

### 1.1 Error Boundaries

Add React error boundaries around major feature areas so a crash in one component doesn't take down the entire page.

**Files:**
- Create: `components/ErrorBoundary.tsx`
- Modify: `pages/RankingAppPage.tsx` — wrap tier rows, modals
- Modify: `pages/ProfilePage.tsx` — wrap activity/journal tabs
- Modify: `components/SocialFeedView.tsx` — wrap feed cards

### 1.2 Loading Skeletons

Replace text-based loading states ("Loading...") with skeleton placeholders in high-traffic areas.

**Files:**
- Create: `components/SkeletonCard.tsx` — reusable skeleton for cards
- Modify: `components/SocialFeedView.tsx` — skeleton cards during feed load
- Modify: `components/JournalHomeView.tsx` — skeleton cards during journal load
- Modify: `components/AddMediaModal.tsx` — skeleton during suggestion load

### 1.3 User Blocking

Extend the muting system to a full blocking system that prevents interactions (not just feed hiding).

**Files:**
- Modify: `supabase_phase5_social_feed.sql` — add `block_type` column or new `user_blocks` table
- Modify: `services/feedService.ts` — filter blocked users from comments/reactions
- Modify: `services/friendsService.ts` — prevent follow from blocked users
- Modify: `components/FeedCardMenu.tsx` — add "Block @username" option

### 1.4 Old Review System Cleanup

Remove the deprecated `movie_reviews` table and clean up legacy functions.

**Files:**
- Migration SQL: DROP `movie_reviews` and `review_likes` tables (after verifying all data migrated to `journal_entries`)
- Modify: `services/friendsService.ts` — remove deprecated review functions or redirect fully to journalService

---

## Phase 2: Journal Agent (3-5 days) — THE BIG BUILD

The single largest gap. A conversational AI that interviews users about their movie experience and generates structured journal entries.

### 2.1 LLM Service Layer

**Create:** `services/agentService.ts`

**Responsibilities:**
- Manage API calls to Claude API (Anthropic)
- System prompt engineering for movie interview agent
- Conversation state machine (greeting → questions → extraction → review)
- Structured output extraction (mood tags, moments, performances → JournalEntry fields)
- Streaming response handling

**Key Functions:**
- `startJournalConversation(movie, tier, userId)` — Initialize agent with movie context
- `sendMessage(conversationId, userMessage)` — Send user message, get agent response
- `extractJournalEntry(conversationId)` — Parse conversation into structured JournalEntry fields
- `getConversationHistory(conversationId)` — Retrieve full conversation

**Agent Behavior:**
1. **Open**: "Hey! You just ranked [Movie] as [Tier]. What did you think?"
2. **Probe mood**: "How did it make you feel?" → extract mood tags
3. **Probe moments**: "Any scenes that stuck with you?" → extract favorite moments
4. **Probe performances**: "Any standout performances?" → extract cast references
5. **Probe context**: "Where'd you watch it? With anyone?" → extract watch context
6. **Summarize**: Generate review text + personal takeaway from conversation
7. **Confirm**: Show generated entry preview, let user edit before saving

**API Key:** `VITE_ANTHROPIC_API_KEY` (or proxy through edge function for key security)

### 2.2 Voice Input Service

**Create:** `services/voiceService.ts`

**Approach:** Web Speech API (browser-native, zero cost) with Whisper fallback for unsupported browsers.

**Key Functions:**
- `startListening(onTranscript, onError)` — Begin speech recognition
- `stopListening()` — End recognition
- `isSupported()` — Check browser support for Web Speech API

**Considerations:**
- Web Speech API is free but requires internet connection and has browser support limitations
- Whisper API fallback costs money but works everywhere
- Start with Web Speech API only; add Whisper later if needed

### 2.3 Agent Chat UI

**Create:** `components/JournalAgentChat.tsx`

**Props:** `isOpen`, `movie: RankedItem`, `userId`, `onDismiss`, `onEntryGenerated(entry)`

**Layout:**
- Full-height slide-up sheet (replaces JournalEntrySheet when agent mode active)
- Movie poster + title header
- Scrollable message area (agent messages left, user messages right)
- Text input with send button + microphone button
- "Switch to manual" link → falls back to JournalEntrySheet
- "Generate entry" button appears after sufficient conversation

**Sub-components:**
- `components/journal/AgentMessage.tsx` — Agent bubble with typing indicator
- `components/journal/UserMessage.tsx` — User bubble (text or voice transcript badge)
- `components/journal/VoiceInput.tsx` — Microphone button with pulse animation during recording
- `components/journal/AgentReview.tsx` — Generated entry preview with edit/accept actions

### 2.4 Agent Integration

**Modify:** `pages/RankingAppPage.tsx`
- After ranking, offer choice: "Write it yourself" (JournalEntrySheet) or "Tell me about it" (JournalAgentChat)
- Default to agent if user has used it before (localStorage preference)

**Modify:** `components/MediaDetailModal.tsx`
- "Leave a Review" button offers same choice

**Modify:** `pages/ProfilePage.tsx`
- Journal tab "New Entry" could open agent or manual sheet

### 2.5 Edge Function for API Key Security

**Create:** Supabase Edge Function `journal-agent`

Since this is a client-side app with no backend, the Anthropic API key can't be exposed in the browser. Options:
1. **Supabase Edge Function** — Proxy LLM calls through a serverless function that holds the API key
2. **Direct client-side** — Expose key in env var (acceptable for MVP/personal use)

**Recommended:** Start with direct client-side (`VITE_ANTHROPIC_API_KEY`) for MVP speed, migrate to edge function before public launch.

---

## Phase 3: AI-Powered Insights (1-2 days)

After the agent is built, leverage the same LLM integration for journal analysis.

### 3.1 Journal Insights

**Modify:** `services/agentService.ts` — add insight generation functions
**Modify:** `components/JournalHomeView.tsx` — add insights section

**Features:**
- "Your taste profile" — AI-generated summary of viewing patterns
- "Mood trends" — Analysis of mood tag distribution over time
- "Watch streak insights" — Commentary on streaks and viewing habits
- Cached per user, regenerated weekly or on-demand

---

## Phase 4: Polish (ongoing)

### 4.1 Content Reporting
- Add "Report" option to FeedCardMenu
- Create `content_reports` table
- Admin review flow (deferred — just store reports for now)

### 4.2 Score Persistence
- Store computed scores in `user_rankings.score` column
- Recompute on rank changes only (not on every filter change)

### 4.3 Push Notifications
- Service worker registration
- Browser push notification API
- Notification preferences in profile settings

---

## Execution Order

```
Phase 1.1  Error Boundaries ──────────┐
Phase 1.2  Loading Skeletons ─────────┤  ✅ DONE
Phase 1.3  User Blocking ────────────├── Can be parallelized
Phase 1.4  Review System Cleanup ─────┘
                │
Phase 2.1  LLM Service Layer ────────┐
Phase 2.2  Voice Input Service ───────┤── Can be parallelized
Phase 2.3  Agent Chat UI ────────────┘
                │
Phase 2.4  Agent Integration ─────────── Sequential (depends on 2.1-2.3)
Phase 2.5  Edge Function (optional) ──── Can be done anytime
                │
Phase 3.1  Journal Insights ──────────── Sequential (depends on Phase 2)
                │
Phase 4.x  Polish ────────────────────── Ongoing
```

### Deferred (revisit after Phase 3)

- **Real-Time Feed** — Supabase Realtime subscriptions for live feed updates and notification badges. Not critical for MVP; feed works fine with refresh-based loading.

---

## Highest Priority: Journal Agent (Phase 3)

The Journal Agent is the single largest missing feature and the most differentiating. The ranking system and social feed are both >90% complete. The journal data layer and UI are built — what's missing is the AI interview experience that makes journaling feel effortless.

**Recommended starting point:** Phase 3.1 (LLM Service Layer) — get a working agent conversation flowing before building voice input or chat UI. Test with a simple text interface first, then layer on voice and polish.
