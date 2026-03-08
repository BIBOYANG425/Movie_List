# Spool Visual Rebrand Design

## Goal
Integrate the Spool app design UI into the Movie List MVP — full visual rebrand with typography changes and webapp-compatible component restyling.

## 1. Color System

Replace zinc-based palette with Spool warm dark palette:

| Token | Current | New | CSS Variable |
|-------|---------|-----|-------------|
| Background | `#08080B` | `#0F1419` | `--background` |
| Surface/Card | `#111116`/`#16161D` | `#1C2128` | `--card` |
| Elevated | `#1C1C25` | `#252C35` | `--secondary` |
| Text Primary | `#F0EBE3` | `#F5F3EF` | `--foreground` |
| Text Secondary | `#C8C3BC` | `#9BA3AB` | `--muted-foreground` |
| Primary/CTA | `#ffc107` | `#D4C5B0` (warm beige) | `--primary`, `--gold` |
| Accent | — | `#8BA8BA` (muted blue-grey) | `--accent` |
| Destructive | — | `#D4183D` | `--destructive` |
| Border | zinc-800 | `#252C35` | `--border` |
| Input BG | — | `#1C2128` | `--input-background` |

**Tier colors stay vibrant** (unchanged):
- S: `#A855F7` (Purple)
- A: `#3B82F6` (Blue)
- B: `#10B981` (Green)
- C: `#F59E0B` (Orange)
- D: `#EF4444` (Red)

## 2. Typography

| Role | Current | New |
|------|---------|-----|
| Display/Headings | Instrument Serif | Cormorant Garamond (serif) |
| Body/UI | DM Sans | Source Sans 3 (sans-serif) |
| Mono | Space Mono | Space Mono (unchanged) |

- Base font size: 16px
- h1: 2.5rem, serif, weight 600, letter-spacing -0.01em
- h2: 2rem, serif, weight 600
- h3: 1.5rem, serif, weight 500
- h4: 1.25rem, serif, weight 500
- Body: sans-serif, weight 400
- Labels: 0.875rem, weight 500
- Buttons: 1rem, weight 500

## 3. Build System Migration

- Remove CDN Tailwind `<script>` from `index.html`
- Install: `tailwindcss@4`, `@tailwindcss/vite`, `postcss`, `autoprefixer`
- Create `src/styles/theme.css` with CSS custom properties
- Update `vite.config.ts` with `@tailwindcss/vite` plugin
- Create `src/styles/tailwind.css` with `@import "tailwindcss"` and `@theme` block
- Update `index.tsx` to import new stylesheets

## 4. Navigation — Responsive Hybrid

### Desktop (>=1024px): Collapsible Left Sidebar
- Logo (Spool wordmark) at top
- Nav items with icons + labels: Board, Feed, Watchlist, Discover, Stats, Groups, Polls, Journal, Achievements
- Profile/Settings at bottom
- Collapse to icon-only on toggle
- Width: 240px expanded, 64px collapsed

### Mobile (<1024px): Bottom Tab Bar
- 5 primary tabs: Board, Feed, Watchlist, Stats, Profile
- Secondary features from profile menu or sub-nav
- Safe area inset handling
- Active tab: gold color, inactive: muted-foreground

## 5. Component Restyling

### Cards
- Background: `bg-card/50` with `border border-border/30`
- Border radius: `rounded-2xl`
- Subtle backdrop blur on elevated cards

### Buttons
- Primary: `bg-gold text-background`, `rounded-xl`, `active:scale-95`
- Secondary/Outline: `border-border/30 text-muted-foreground`
- Destructive: `bg-destructive text-destructive-foreground`

### Tier Rows
- Keep horizontal scroll layout
- Restyle headers: serif tier letter (3xl) + descriptive label (uppercase, xs)
- Labels: S=Transcendent, A=Exceptional, B=Good, C=Mediocre, D=Disappointing
- Background: `bg-card/40 backdrop-blur-sm rounded-2xl border-border/30`

### Media Cards
- Width: ~104px, 2:3 aspect ratio poster area
- Rounded-xl poster with gradient overlay
- Title + year below, mood badge at bottom
- Season badge for TV (top-right corner)

### Mood Badges
- Small pills: `px-2 py-0.5 rounded-full text-[10px]`
- Style: `bg-gold/8 text-gold border border-gold/20`

### Modals
- Desktop: centered modal with backdrop blur
- Mobile: bottom sheet with spring animation (existing modals restyled)
- Handle bar, rounded-t-3xl, card background

## 6. Landing Page

- Film grain texture overlay (SVG noise at 3% opacity)
- Gradient glow: `bg-accent-primary/5` blurred circle
- Serif headlines (Cormorant Garamond)
- Warm beige CTA buttons with shadow
- Philosophy bullets with dot separators
- Footer with border-t

## 7. Unchanged

- All existing features, routes, and business logic
- Supabase integration
- Lucide React icons
- Recharts for stats
- Drag-and-drop ranking system
- Auth flow (Supabase Auth + OAuth)
- All services and data layer
