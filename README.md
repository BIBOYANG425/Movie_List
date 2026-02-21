# Marquee - Movie Ranking App

Marquee is a React + Vite web app for building a personal movie canon.
Users can search movies, rank them in S/A/B/C/D tiers, save titles for later, and view simple ranking stats.

## What This Repo Contains

- Root app (active): React frontend with Supabase auth/data + TMDB movie discovery.
- Optional static server: Express server for serving the built `dist/` folder.
- Separate backend folder: `backend/` contains a FastAPI project (partially implemented, not the primary runtime path for the root frontend).
- Legacy duplicate frontend tree: `Movie_List/`.

## Core Features

- Email/password sign-up and sign-in.
- Route-protected app area (`/app`).
- Tier-based ranking board with drag-and-drop movement.
- Add flow with TMDB search + suggestion system.
- Watch Later list with quick promote-to-rank flow.
- Stats view for tier distribution and media split.

## Tech Stack

- Frontend: React 18, TypeScript, Vite, React Router
- Data/Auth: Supabase (`@supabase/supabase-js`)
- Charts: Recharts
- Icons/UI: Lucide React, Tailwind utility classes
- Production static serving: Express

## Prerequisites

- Node.js 18+ (recommended)
- npm
- A Supabase project
- A TMDB API key

## Environment Variables

Create `.env.local` in the repo root:

```env
VITE_SUPABASE_URL=https://your-project-id.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
VITE_TMDB_API_KEY=your-tmdb-api-key
```

## Install and Run

1. Install dependencies:

```bash
npm install
```

2. Start development server:

```bash
npm run dev
```

3. Open the Vite URL shown in terminal (typically `http://localhost:5173`).

## Build and Serve

Build:

```bash
npm run build
```

Serve built app with Express:

```bash
npm run start
```

Default server port is `8080` (or `PORT` env var if provided).

## Database Notes

- Supabase schema and RLS policies for the root app are in:
  - `supabase_schema.sql`
- Additional schema artifacts also exist:
  - `marquee_schema.sql` (separate/alternate schema work)

## Project Structure (Root App)

- `index.tsx` - app bootstrap + router + auth provider
- `App.tsx` - route definitions (`/`, `/auth`, `/app`)
- `pages/` - landing, auth, ranking app pages
- `components/` - ranking, modal, stats, watchlist UI
- `contexts/AuthContext.tsx` - Supabase auth/session state
- `lib/supabase.ts` - Supabase client initialization
- `services/tmdbService.ts` - TMDB search/suggestion calls
- `server.js` - static production server for `dist/`

## Backend Folder (`backend/`)

`backend/` includes a FastAPI + SQLAlchemy + Alembic service with Docker setup and API modules.
Some endpoints are still placeholders/stubs, so treat it as in-progress unless you are actively developing that backend.

## Scripts

- `npm run dev` - start Vite dev server
- `npm run build` - production build to `dist/`
- `npm run start` - serve `dist/` with Express
