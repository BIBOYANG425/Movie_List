# Spool - Movie & TV Ranking App

Spool is a React + Vite web app for building a personal movie and TV canon. Users search titles via TMDB, rank them in S/A/B/C/D tiers with a head-to-head comparison flow, keep a watchlist, write journal entries, and follow friends to see their activity.

## Core Features

- **Tier-based ranking** — S/A/B/C/D tiers with drag-and-drop reordering and an adaptive head-to-head comparison engine for placement.
- **Movie & TV support** — Search and rank movies or individual TV seasons.
- **Smart suggestions** — 5-pool suggestion system (similar, taste-based, trending, variety, friend-influenced) powered by TMDB + taste profiles.
- **Fuzzy search** — Typo-tolerant search with Levenshtein-based correction ("Incpetion" finds "Inception").
- **Watch Later list** — Bookmark titles and promote to ranked with one tap.
- **Journal** — Write entries about movies with mood/vibe tags, cast mentions, friend tags, and photo grids.
- **Social feed** — Follow friends, see ranking activity, reviews, milestones; react and comment.
- **Groups & polls** — Create group rankings, watch parties, and movie polls.
- **Shared watchlists** — Collaborative watchlists with voting.
- **Stats** — Genre radar chart, tier distribution, and media split analytics.
- **Letterboxd import** — Import existing rankings from CSV export.
- **i18n** — English and Chinese language support.

## Tech Stack

- **Frontend**: React 18, TypeScript, Vite
- **Styling**: Tailwind CSS v4 (`@tailwindcss/vite`), CSS custom properties
- **Data/Auth**: Supabase (PostgreSQL + RLS + OAuth)
- **API**: TMDB for movie/TV metadata and search
- **Charts**: Recharts
- **Icons**: Lucide React
- **Testing**: Vitest
- **Deployment**: Vercel (frontend), Supabase Edge Functions (journal agent)

## Prerequisites

- Node.js 18+
- npm
- A Supabase project
- A TMDB API key

## Environment Variables

Create `.env.local` in the repo root (see `.env.example`):

```env
VITE_SUPABASE_URL=https://your-project-id.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
VITE_TMDB_API_KEY=your-tmdb-api-key
```

## Install and Run

```bash
npm install
npm run dev
```

Open the Vite URL shown in terminal (typically `http://localhost:5173`).

## Build

```bash
npm run build     # production build to dist/
npm run start     # serve dist/ with Express (port 8080 or PORT env var)
```

## Tests

```bash
npm test          # run vitest
```

## Project Structure

```
├── App.tsx                     # Route definitions (/, /auth, /app)
├── index.tsx                   # Bootstrap, router, auth provider
├── types.ts                    # Shared TypeScript types
├── constants.ts                # Tier score ranges, config
│
├── pages/                      # Route-level page components
│   ├── RankingAppPage.tsx      # Main app (ranking board + views)
│   ├── ProfilePage.tsx         # User profile, journal, activity
│   ├── LandingPage.tsx         # Marketing landing
│   ├── AuthPage.tsx            # Sign in / sign up
│   ├── AuthCallbackPage.tsx    # OAuth callback handler
│   ├── MovieOnboardingPage.tsx # First-run 10-movie ranking
│   └── ProfileOnboardingPage.tsx
│
├── components/
│   ├── feed/                   # Social feed cards, filters, reactions
│   ├── journal/                # Journal views, entry editor, tag selectors
│   ├── landing/                # Landing page hero, CTA, panels
│   ├── layout/                 # AppLayout (sidebar + tabs), SpoolLogo
│   ├── media/                  # Add modals, media card/detail, watchlist
│   ├── ranking/                # TierRow, stats, genre radar, comparisons
│   ├── shared/                 # Error boundary, skeleton, toast, tier picker
│   └── social/                 # Friends, discover, groups, polls, notifications
│
├── services/                   # Business logic & API calls
│   ├── tmdbService.ts          # TMDB search, suggestions, taste profiles
│   ├── friendsService.ts       # Social graph, reviews, groups, polls
│   ├── feedService.ts          # Activity feed, reactions, comments
│   ├── journalService.ts       # Journal CRUD, photos, likes
│   ├── agentService.ts         # Journal agent (LLM integration)
│   ├── fuzzySearch.ts          # Fuzzy/typo-tolerant search utilities
│   ├── spoolRankingEngine.ts   # Adaptive head-to-head ranking engine
│   ├── rankingAlgorithm.ts     # Score computation, bracket classification
│   ├── spoolPrediction.ts      # Prediction signals for ranking placement
│   ├── correctionService.ts    # Edit distance, correction detection
│   ├── letterboxdImportService.ts
│   ├── consentService.ts
│   ├── csvParser.ts
│   ├── spoolPrompts.ts
│   └── __tests__/              # Unit tests (vitest)
│
├── contexts/                   # React contexts (Auth, Language)
├── hooks/                      # Custom hooks (useLocalizedItems)
├── i18n/                       # Translations (en, zh)
├── lib/supabase.ts             # Supabase client initialization
├── styles/                     # Tailwind config, CSS theme variables
│
├── supabase/
│   ├── migrations/             # SQL schema & migration files
│   └── functions/              # Supabase Edge Functions
│
├── docs/plans/                 # Design & implementation plan docs
├── server.js                   # Express static server for dist/
├── vite.config.ts
├── vitest.config.ts
├── vercel.json
└── tsconfig.json
```

## Database Setup

Run the SQL migration files in `supabase/migrations/` in order:

1. `supabase_schema.sql` — Base schema (profiles, rankings, watchlist, follows, activity, reviews)
2. `supabase_phase1_profile_patch.sql` — Profile fields, avatar storage
3. `supabase_phase2_activity_patch.sql` — Activity event types
4. `supabase_phase3_groups.sql` — Group rankings, watch parties
5. `supabase_phase4_engagement.sql` — Notifications, lists, achievements
6. `supabase_phase5_social_feed.sql` — Feed mutes
7. `supabase_journal_entries.sql` — Journal entries, moods, FTS
8. `supabase_fix_missing_tables.sql` — review_likes, shared_watchlist_votes
9. `supabase_fix_critical_rls.sql` — RLS tightening
10. `supabase_smart_suggestions.sql` — Taste profiles, credits cache
11. `supabase_emotional_data.sql` — Agent sessions, consent
12. `supabase_spool_ranking.sql` — Comparison logs
13. `supabase_spool_genre_ranking.sql` — Genre ranking helpers
14. `supabase_tv_rankings.sql` — TV show/season support

## Google OAuth Setup

1. In Google Cloud Console, create an OAuth client (Web application) with redirect URI: `https://<your-supabase-ref>.supabase.co/auth/v1/callback`
2. In Supabase Dashboard, enable Google provider with your client ID and secret.
3. Add allowed redirect URLs: `http://localhost:5173/auth/callback` and your production domain.
