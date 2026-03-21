<p align="center">
  <img src="https://img.shields.io/badge/React_18-61DAFB?style=flat-square&logo=react&logoColor=black" />
  <img src="https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white" />
  <img src="https://img.shields.io/badge/Vite-646CFF?style=flat-square&logo=vite&logoColor=white" />
  <img src="https://img.shields.io/badge/Tailwind_v4-06B6D4?style=flat-square&logo=tailwindcss&logoColor=white" />
  <img src="https://img.shields.io/badge/Supabase-3FCF8E?style=flat-square&logo=supabase&logoColor=white" />
</p>

<h1 align="center">Spool</h1>

<p align="center">
  <strong>Your personal movie, TV & book canon — ranked, journaled, and shared.</strong>
</p>

<p align="center">
  Search any title. Rank it S through D with head-to-head comparisons.<br/>
  Write journal entries. Follow friends. See who agrees with you (and who doesn't).
</p>

---

## 🌟 Highlights

- **Tier-based ranking** — S/A/B/C/D tiers with drag-and-drop. An adaptive comparison engine places new items via head-to-head matchups, not guesswork.
- **Movies, TV & Books** — Search TMDB for movies and TV seasons, Open Library for books. One unified search bar, three media types.
- **Journal** — Write entries about anything you've watched or read. Mood/vibe tags, cast mentions, friend tags, photo grids.
- **Social feed** — Follow friends, see their ranking activity, react, comment, and discover what your circle is watching.
- **Taste DNA** — Genre radar charts, tier distribution stats, and taste compatibility scores with friends.
- **Groups & polls** — Group rankings, watch parties, collaborative watchlists with voting, and movie polls.
- **Smart suggestions** — 5-pool system: similar titles, taste-based, trending, variety picks, and friend-influenced recommendations.
- **Letterboxd import** — Bring your existing rankings over from CSV.
- **i18n** — English and Chinese.

## 🚀 Quick Start

```bash
git clone https://github.com/BIBOYANG425/Movie_List.git
cd Movie_List
npm install
npm run dev
```

Create a `.env.local` in the root:

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
VITE_TMDB_API_KEY=your-tmdb-key
```

Open [localhost:5173](http://localhost:5173) and start ranking.

## 🏗️ Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | React 18, TypeScript, Vite |
| **Styling** | Tailwind CSS v4 with CSS custom properties |
| **Database** | Supabase (PostgreSQL + Row Level Security) |
| **Auth** | Supabase Auth (Google OAuth) |
| **APIs** | TMDB (movies & TV), Open Library (books) |
| **Charts** | Recharts |
| **Icons** | Lucide React |
| **Fonts** | Cormorant Garamond + Source Sans 3 |
| **Testing** | Vitest |
| **Deployment** | Vercel + Supabase Edge Functions |

## 📂 Project Structure

```
pages/                          # Route-level components
  RankingAppPage.tsx             # Main ranking board + all views
  ProfilePage.tsx                # User profile, journal, activity
  LandingPage.tsx                # Marketing landing page

components/
  feed/                          # Social feed cards, reactions, comments
  journal/                       # Journal editor, entries, mood selectors
  layout/                        # AppLayout, SpoolLogo
  media/                         # Add/detail modals, watchlist, ranking flow
  ranking/                       # TierRow, stats, genre radar
  shared/                        # Universal search, tier picker, toast, skeleton
  social/                        # Friends, discover, groups, polls, notifications

services/
  tmdbService.ts                 # TMDB search & metadata
  openLibraryService.ts          # Open Library book search
  spoolRankingEngine.ts          # Adaptive head-to-head comparison engine
  rankingAlgorithm.ts            # Score computation, bracket classification
  feedService.ts                 # Activity feed with engagement data
  tasteService.ts                # Taste compatibility, recommendations
  journalService.ts              # Journal CRUD
  fuzzySearch.ts                 # Typo-tolerant search ("Incpetion" → "Inception")

supabase/migrations/             # SQL schema files (run in order)
i18n/                            # en.ts, zh.ts
styles/                          # Theme CSS variables
```

## 🗄️ Database Setup

Run the migrations in `supabase/migrations/` in order against your Supabase project:

1. `supabase_schema.sql` — Core tables (profiles, rankings, watchlist, follows)
2. `supabase_phase1_profile_patch.sql` — Profile fields & avatar storage
3. `supabase_phase2_activity_patch.sql` — Activity events
4. `supabase_phase3_groups.sql` — Group rankings, watch parties
5. `supabase_phase4_engagement.sql` — Notifications, lists, achievements
6. `supabase_phase5_social_feed.sql` — Feed mutes
7. `supabase_journal_entries.sql` — Journal entries with FTS
8. `supabase_fix_missing_tables.sql` — review_likes, shared_watchlist_votes
9. `supabase_fix_critical_rls.sql` — RLS policy tightening
10. `supabase_smart_suggestions.sql` — Taste profiles, credits cache
11. `supabase_emotional_data.sql` — Agent sessions
12. `supabase_spool_ranking.sql` — Comparison logs
13. `supabase_spool_genre_ranking.sql` — Genre ranking helpers
14. `supabase_tv_rankings.sql` — TV show/season support
15. `supabase_watched_with.sql` — "Watched with" friend tagging
16. `supabase_book_rankings.sql` — Book rankings & watchlist

## 🔑 Google OAuth

1. Create an OAuth client in [Google Cloud Console](https://console.cloud.google.com/) (Web application type)
2. Set redirect URI: `https://<your-supabase-ref>.supabase.co/auth/v1/callback`
3. In Supabase Dashboard → Auth → Providers, enable Google with your client ID & secret
4. Add allowed redirect URLs: `http://localhost:5173/auth/callback` and your production domain

## 🧪 Testing

```bash
npm test              # run all tests
npm run test:watch    # watch mode
```

## 📦 Production Build

```bash
npm run build         # outputs to dist/
npm run start         # serves dist/ via Express on port 8080
```

## 🎨 Design System

Spool uses a dark-first design with CSS custom properties:

- **Background**: `#0F1419` — deep charcoal
- **Gold accent**: `#D4C5B0` — warm muted gold
- **Cool accent**: `#8BA8BA` — steel blue
- **Tier colors**: Vibrant yellow (S), green (A), blue (B), zinc (C), red (D)
- **Typography**: Cormorant Garamond for headings, Source Sans 3 for body

## 💭 Contributing

Found a bug or have a feature idea? [Open an issue](https://github.com/BIBOYANG425/Movie_List/issues) or submit a PR.

---

<p align="center">
  <sub>Built with care by <a href="https://github.com/BIBOYANG425">@BIBOYANG425</a></sub>
</p>
