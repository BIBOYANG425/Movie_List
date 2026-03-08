# Spool Visual Rebrand Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebrand the Movie List MVP with Spool's color system, typography (Cormorant Garamond + Source Sans 3), and webapp-compatible responsive navigation (sidebar on desktop, bottom tabs on mobile).

**Architecture:** Migrate from CDN Tailwind to build-time Tailwind v4 with CSS variable theme. Replace all hardcoded color references across components. Add a responsive AppLayout wrapper with sidebar/bottom-tab navigation.

**Tech Stack:** Tailwind CSS v4, @tailwindcss/vite, Cormorant Garamond, Source Sans 3, React, TypeScript

---

### Task 1: Install Tailwind v4 and configure build system

**Files:**
- Modify: `package.json`
- Modify: `vite.config.ts`
- Create: `styles/theme.css`
- Create: `styles/tailwind.css`
- Modify: `index.html` (remove CDN script + inline config)
- Modify: `index.tsx` (import new stylesheets)

**Step 1: Install Tailwind v4 dependencies**

Run:
```bash
npm install tailwindcss@4 @tailwindcss/vite
npm uninstall autoprefixer postcss tailwindcss
```

Note: Tailwind v4 bundles its own PostCSS. Remove old v3 deps.

**Step 2: Update vite.config.ts**

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
});
```

**Step 3: Create `styles/theme.css`**

Copy the full theme from the Spool design at `/tmp/spool-design/src/styles/theme.css`, but keep the vibrant tier colors from the current app:

```css
@custom-variant dark (&:is(.dark *));

:root {
  --font-size: 16px;

  --background: #0F1419;
  --foreground: #F5F3EF;

  --accent-primary: #8BA8BA;
  --accent-subtle: #D4C5B0;

  --gold: #D4C5B0;
  --gold-muted: #B8A998;

  --card: #1C2128;
  --card-foreground: #F5F3EF;
  --popover: #1C2128;
  --popover-foreground: #F5F3EF;

  --primary: #D4C5B0;
  --primary-foreground: #0F1419;

  --secondary: #252C35;
  --secondary-foreground: #F5F3EF;

  --muted: #252C35;
  --muted-foreground: #9BA3AB;

  --accent: #8BA8BA;
  --accent-foreground: #0F1419;

  --destructive: #D4183D;
  --destructive-foreground: #F5F3EF;

  --border: #252C35;
  --input: #252C35;
  --input-background: #1C2128;

  --ring: #8BA8BA;

  --font-serif: 'Cormorant Garamond', serif;
  --font-sans: 'Source Sans 3', sans-serif;

  --radius: 0.5rem;

  /* Keep vibrant tier colors from current app */
  --tier-s: #A855F7;
  --tier-a: #3B82F6;
  --tier-b: #10B981;
  --tier-c: #F59E0B;
  --tier-d: #EF4444;
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-card: var(--card);
  --color-card-foreground: var(--card-foreground);
  --color-popover: var(--popover);
  --color-popover-foreground: var(--popover-foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-secondary: var(--secondary);
  --color-secondary-foreground: var(--secondary-foreground);
  --color-muted: var(--muted);
  --color-muted-foreground: var(--muted-foreground);
  --color-accent: var(--accent);
  --color-accent-foreground: var(--accent-foreground);
  --color-destructive: var(--destructive);
  --color-destructive-foreground: var(--destructive-foreground);
  --color-border: var(--border);
  --color-input: var(--input);
  --color-input-background: var(--input-background);
  --color-ring: var(--ring);
  --color-gold: var(--gold);
  --color-gold-muted: var(--gold-muted);
  --color-accent-primary: var(--accent-primary);
  --color-accent-subtle: var(--accent-subtle);
  --color-tier-s: var(--tier-s);
  --color-tier-a: var(--tier-a);
  --color-tier-b: var(--tier-b);
  --color-tier-c: var(--tier-c);
  --color-tier-d: var(--tier-d);
  --radius-sm: calc(var(--radius) - 4px);
  --radius-md: calc(var(--radius) - 2px);
  --radius-lg: var(--radius);
  --radius-xl: calc(var(--radius) + 4px);
  --font-family-serif: var(--font-serif);
  --font-family-sans: var(--font-sans);
}

@layer base {
  * {
    @apply border-border;
  }

  body {
    @apply bg-background text-foreground;
    font-family: var(--font-sans);
  }

  html {
    font-size: var(--font-size);
  }

  h1 {
    font-family: var(--font-serif);
    font-size: 2.5rem;
    font-weight: 600;
    line-height: 1.2;
    letter-spacing: -0.01em;
  }

  h2 {
    font-family: var(--font-serif);
    font-size: 2rem;
    font-weight: 600;
    line-height: 1.3;
    letter-spacing: -0.01em;
  }

  h3 {
    font-family: var(--font-serif);
    font-size: 1.5rem;
    font-weight: 500;
    line-height: 1.4;
  }

  h4 {
    font-family: var(--font-serif);
    font-size: 1.25rem;
    font-weight: 500;
    line-height: 1.4;
  }

  label {
    font-size: 0.875rem;
    font-weight: 500;
    line-height: 1.5;
  }

  button {
    font-size: 1rem;
    font-weight: 500;
    line-height: 1.5;
  }

  input {
    font-size: 1rem;
    font-weight: 400;
    line-height: 1.5;
  }
}
```

**Step 4: Create `styles/tailwind.css`**

```css
@import "tailwindcss";
@import "./theme.css";
```

**Step 5: Update `index.html`**

Remove the CDN `<script src="https://cdn.tailwindcss.com"></script>`, the inline `<script>tailwind.config = {...}</script>`, and update the Google Fonts link to load Cormorant Garamond + Source Sans 3 instead of DM Sans + Instrument Serif:

```html
<!DOCTYPE html>
<html lang="en" class="dark">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Spool | Your Movie Archive</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,400;0,500;0,600;0,700;1,400;1,500&family=Source+Sans+3:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
      body {
        background-color: #0F1419;
        color: #9BA3AB;
      }
      .hide-scrollbar::-webkit-scrollbar { display: none; }
      .hide-scrollbar { -ms-overflow-style: none; scrollbar-width: none; }
    </style>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/index.tsx"></script>
  </body>
</html>
```

**Step 6: Update `index.tsx`**

Add import for the new Tailwind entry:
```ts
import './styles/tailwind.css';
import './styles/landing.css';
```

**Step 7: Verify the dev server starts**

Run: `npm run dev`
Expected: Vite starts with no errors. Page loads with new background color `#0F1419`.

**Step 8: Commit**

```bash
git add -A && git commit -m "build: migrate from CDN Tailwind to Tailwind v4 with Spool theme"
```

---

### Task 2: Update `landing.css` with Spool color variables

**Files:**
- Modify: `styles/landing.css`

**Step 1: Replace CSS custom properties in `:root`**

Replace the landing CSS variables to use the new Spool palette:

```css
:root {
  --bg-primary: #0F1419;
  --bg-secondary: #1C2128;
  --accent-pop: #D4C5B0;
  --text-primary: #F5F3EF;
  --text-muted: #9BA3AB;
  --font-display: 'Cormorant Garamond', serif;
  --font-body: 'Source Sans 3', sans-serif;
  --font-mono: 'Space Mono', monospace;
}
```

**Step 2: Update gradient colors in `.landing-root`**

Replace the gold/pink gradient references with Spool's warm beige/blue-grey:

```css
.landing-root {
  background:
    radial-gradient(circle at 12% 18%, rgba(212, 197, 176, 0.12), transparent 34%),
    radial-gradient(circle at 88% 6%, rgba(139, 168, 186, 0.08), transparent 28%),
    linear-gradient(180deg, #0F1419 0%, #0F1419 42%, #0c1015 100%);
}
```

**Step 3: Update any hardcoded `#ffc107` or gold references** in the rest of `landing.css` to `#D4C5B0`.

**Step 4: Verify landing page renders with new colors**

Run: `npm run dev`, navigate to `/`
Expected: Landing page shows warm beige accents instead of bright yellow gold.

**Step 5: Commit**

```bash
git add styles/landing.css && git commit -m "style: update landing.css with Spool color palette"
```

---

### Task 3: Update `constants.ts` tier labels

**Files:**
- Modify: `constants.ts`

**Step 1: Update TIER_LABELS to match Spool design vocabulary**

```ts
export const TIER_LABELS = {
  [Tier.S]: 'Transcendent',
  [Tier.A]: 'Exceptional',
  [Tier.B]: 'Good',
  [Tier.C]: 'Mediocre',
  [Tier.D]: 'Disappointing',
};
```

**Step 2: Commit**

```bash
git add constants.ts && git commit -m "style: update tier labels to Spool vocabulary"
```

---

### Task 4: Restyle `App.tsx` loading state

**Files:**
- Modify: `App.tsx`

**Step 1: Replace zinc/indigo classes with new theme tokens**

Change:
```tsx
<div className="min-h-screen bg-zinc-950 flex items-center justify-center">
  <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
</div>
```

To:
```tsx
<div className="min-h-screen bg-background flex items-center justify-center">
  <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
</div>
```

**Step 2: Commit**

```bash
git add App.tsx && git commit -m "style: restyle App loading spinner with Spool theme"
```

---

### Task 5: Create responsive AppLayout with sidebar + bottom tabs

**Files:**
- Create: `components/AppLayout.tsx`
- Create: `components/SpoolLogo.tsx`
- Modify: `App.tsx` (wrap `/app` route in layout)

**Step 1: Create `components/SpoolLogo.tsx`**

Copy from `/tmp/spool-design/src/app/components/SpoolLogo.tsx` — the double-loop infinity logo mark with "Spool" wordmark in serif font.

**Step 2: Create `components/AppLayout.tsx`**

Build a responsive layout component:

```tsx
import React, { useState } from 'react';
import { useLocation } from 'react-router-dom';
import SpoolLogo from './SpoolLogo';
import {
  Film, MessageSquare, Bookmark, BarChart3, User,
  Users, Vote, BookOpen, Award, Tv, ChevronLeft,
  ChevronRight, Settings, Compass
} from 'lucide-react';

interface NavItem {
  path: string;
  label: string;
  icon: React.ElementType;
  mobileTab?: boolean; // show in bottom tab bar
}

const NAV_ITEMS: NavItem[] = [
  { path: 'rankings', label: 'Board', icon: Film, mobileTab: true },
  { path: 'social', label: 'Feed', icon: MessageSquare, mobileTab: true },
  { path: 'watchlist', label: 'Watchlist', icon: Bookmark, mobileTab: true },
  { path: 'discover', label: 'Discover', icon: Compass },
  { path: 'stats', label: 'Insights', icon: BarChart3, mobileTab: true },
  { path: 'groups', label: 'Groups', icon: Users },
  { path: 'polls', label: 'Polls', icon: Vote },
  { path: 'journal', label: 'Journal', icon: BookOpen },
  { path: 'achievements', label: 'Achievements', icon: Award },
];

interface AppLayoutProps {
  activeView: string;
  onViewChange: (view: string) => void;
  children: React.ReactNode;
}

export default function AppLayout({ activeView, onViewChange, children }: AppLayoutProps) {
  const [collapsed, setCollapsed] = useState(false);
  const mobileTabs = NAV_ITEMS.filter(n => n.mobileTab);

  return (
    <div className="h-screen flex bg-background">
      {/* Desktop Sidebar (>=1024px) */}
      <aside className={`hidden lg:flex flex-col border-r border-border/30 transition-all duration-200 ${
        collapsed ? 'w-16' : 'w-60'
      }`}>
        {/* Logo */}
        <div className="p-4 flex items-center justify-between border-b border-border/20">
          <SpoolLogo size={collapsed ? 'sm' : 'md'} showWordmark={!collapsed} />
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-7 h-7 rounded-lg bg-secondary/40 flex items-center justify-center text-muted-foreground hover:text-foreground transition-colors"
          >
            {collapsed ? <ChevronRight className="w-4 h-4" /> : <ChevronLeft className="w-4 h-4" />}
          </button>
        </div>

        {/* Nav Items */}
        <nav className="flex-1 py-2 overflow-y-auto">
          {NAV_ITEMS.map((item) => {
            const active = activeView === item.path;
            return (
              <button
                key={item.path}
                onClick={() => onViewChange(item.path)}
                className={`w-full flex items-center gap-3 px-4 py-2.5 transition-all ${
                  active
                    ? 'text-gold bg-gold/8 border-r-2 border-gold'
                    : 'text-muted-foreground hover:text-foreground hover:bg-secondary/30'
                } ${collapsed ? 'justify-center px-0' : ''}`}
              >
                <item.icon className="w-5 h-5 flex-shrink-0" />
                {!collapsed && <span className="text-sm">{item.label}</span>}
              </button>
            );
          })}
        </nav>

        {/* Bottom: Profile + Settings */}
        <div className="border-t border-border/20 p-2">
          <button
            onClick={() => onViewChange('profile')}
            className={`w-full flex items-center gap-3 px-4 py-2.5 rounded-lg transition-colors ${
              activeView === 'profile' ? 'text-gold' : 'text-muted-foreground hover:text-foreground'
            } ${collapsed ? 'justify-center px-0' : ''}`}
          >
            <User className="w-5 h-5" />
            {!collapsed && <span className="text-sm">Profile</span>}
          </button>
        </div>
      </aside>

      {/* Main Content */}
      <div className="flex-1 flex flex-col min-w-0">
        <main className="flex-1 overflow-y-auto">
          {children}
        </main>

        {/* Mobile Bottom Tab Bar (<1024px) */}
        <nav className="lg:hidden flex-shrink-0 bg-background/95 backdrop-blur-xl border-t border-border/20 pb-[max(0.5rem,env(safe-area-inset-bottom))]">
          <div className="flex items-end justify-around px-2 pt-2">
            {[...mobileTabs, { path: 'profile', label: 'Profile', icon: User, mobileTab: true }].map((item) => {
              const active = activeView === item.path;
              return (
                <button
                  key={item.path}
                  onClick={() => onViewChange(item.path)}
                  className={`flex flex-col items-center gap-1 px-3 py-2 transition-all active:scale-90 min-w-[56px] ${
                    active ? 'text-gold' : 'text-muted-foreground'
                  }`}
                >
                  <item.icon className="w-6 h-6" strokeWidth={active ? 2.2 : 1.8} />
                  <span className="text-[10px]">{item.label}</span>
                </button>
              );
            })}
          </div>
        </nav>
      </div>
    </div>
  );
}
```

**Step 3: Integrate AppLayout into RankingAppPage**

The current `RankingAppPage` already manages `activeView` state and renders sub-views. Wrap its content with `AppLayout`, passing `activeView` and `onViewChange` as props. Remove any existing tab/navigation UI from `RankingAppPage` and let `AppLayout` handle it.

Key changes in `RankingAppPage.tsx`:
- Import `AppLayout`
- Wrap the return JSX with `<AppLayout activeView={activeView} onViewChange={setActiveView}>{...content}</AppLayout>`
- Remove the existing mobile tab bar and sidebar code (if any)

**Step 4: Verify navigation works on both desktop and mobile**

Run: `npm run dev`
Expected: Desktop shows left sidebar with all nav items. Mobile (<1024px) shows bottom tab bar with 5 primary tabs + Profile.

**Step 5: Commit**

```bash
git add components/AppLayout.tsx components/SpoolLogo.tsx App.tsx pages/RankingAppPage.tsx
git commit -m "feat: add responsive AppLayout with sidebar and bottom tabs"
```

---

### Task 6: Restyle `TierRow.tsx` with Spool card treatment

**Files:**
- Modify: `components/TierRow.tsx`

**Step 1: Read current TierRow.tsx**

Read the file to understand current class names and structure.

**Step 2: Apply Spool card styling**

Update the tier row container classes:
- Outer wrapper: `bg-card/40 backdrop-blur-sm rounded-2xl border border-border/30 overflow-hidden`
- Tier header: Use serif font for tier letter (`font-serif text-3xl`), add descriptive label from `TIER_LABELS` in uppercase xs
- Header background: Use tier-specific subtle background tint (keep current `TIER_COLORS` for the tier letter color)
- Items area: `px-4 py-3`
- Empty state: `text-muted-foreground/40 italic`

**Step 3: Verify tier board renders correctly**

Run: `npm run dev`, navigate to `/app`
Expected: Tier rows have rounded-2xl cards with serif tier letters and descriptive labels.

**Step 4: Commit**

```bash
git add components/TierRow.tsx && git commit -m "style: restyle TierRow with Spool card treatment"
```

---

### Task 7: Restyle `MediaCard.tsx` with Spool treatment

**Files:**
- Modify: `components/MediaCard.tsx`

**Step 1: Read current MediaCard.tsx**

Read the file to understand current structure.

**Step 2: Apply Spool styling**

Key class changes:
- Card button: `active:scale-95 transition-transform duration-200`
- Poster container: `rounded-xl overflow-hidden bg-secondary/40 border border-border/30 shadow-md`
- Poster aspect ratio: Keep 2:3 (`aspect-[2/3]`)
- Gradient overlay on poster: `bg-gradient-to-t from-black/30 via-transparent to-transparent`
- Title: `text-xs text-foreground line-clamp-2`
- Year: `text-[11px] text-muted-foreground`
- Season badge (TV): `bg-accent text-background px-1.5 py-0.5 rounded-md text-[10px] font-semibold`

**Step 3: Verify media cards render**

Expected: Cards show new border/shadow treatment with rounded-xl posters.

**Step 4: Commit**

```bash
git add components/MediaCard.tsx && git commit -m "style: restyle MediaCard with Spool design"
```

---

### Task 8: Restyle `AddMediaModal.tsx` with Spool treatment

**Files:**
- Modify: `components/AddMediaModal.tsx`

**Step 1: Read current AddMediaModal.tsx**

**Step 2: Apply Spool styling**

Key changes:
- Modal overlay: `bg-black/50 backdrop-blur-sm`
- Modal container: `bg-card rounded-2xl border border-border/30 shadow-2xl`
- Search input: `bg-input-background border-border/40 rounded-xl`
- Search results: `border border-border/30 bg-secondary/15 rounded-xl` per result
- Tier selection buttons: `border-border/30 bg-secondary/15 rounded-xl`, active: `border-gold/40 bg-gold/8`
- Tier letter in selection: `font-serif text-2xl` with tier color
- Primary CTA button: `bg-gold hover:bg-gold-muted text-background rounded-xl`
- All `bg-zinc-*` → use theme tokens (`bg-card`, `bg-secondary`, `bg-background`)
- All `text-zinc-*` → use theme tokens (`text-foreground`, `text-muted-foreground`)
- All `border-zinc-*` → `border-border`

**Step 3: Commit**

```bash
git add components/AddMediaModal.tsx && git commit -m "style: restyle AddMediaModal with Spool theme"
```

---

### Task 9: Restyle `AuthPage.tsx` with Spool treatment

**Files:**
- Modify: `pages/AuthPage.tsx`

**Step 1: Read current AuthPage**

**Step 2: Apply Spool styling**

- Page background: `bg-background`
- Film grain overlay (from Spool): Add SVG noise div at 3% opacity
- Add SpoolLogo component above form
- Heading: `font-serif text-2xl text-foreground`
- Subtext: `text-sm text-muted-foreground`
- Input fields: `bg-input-background border-border text-foreground rounded-xl h-12`
- Primary button: `bg-gold hover:bg-gold-muted text-background h-12 rounded-xl active:scale-95`
- Google OAuth button: `border-border hover:bg-secondary/50 text-foreground h-12 rounded-xl`
- Divider: `border-border/40` with "Or" text
- Toggle link: `text-muted-foreground`
- Replace all `zinc-*` references with theme tokens

**Step 3: Commit**

```bash
git add pages/AuthPage.tsx && git commit -m "style: restyle AuthPage with Spool design"
```

---

### Task 10: Restyle `LandingPage.tsx` components with Spool aesthetics

**Files:**
- Modify: `pages/LandingPage.tsx`
- Modify: Any landing sub-components in `components/landing/`

**Step 1: Read current LandingPage and its sub-components**

**Step 2: Apply Spool styling**

- Replace `Marquee` branding with `Spool` / SpoolLogo
- Hero headline: Use `font-serif` (Cormorant Garamond), warm beige italic accent
- CTA buttons: `bg-gold hover:bg-gold-muted text-background rounded-2xl`
- Feature cards: `bg-card/50 border border-border/30 rounded-2xl`
- Replace all `text-yellow-*`, `text-amber-*`, `#ffc107` with `text-gold` / `#D4C5B0`
- Replace `bg-zinc-*` with `bg-background`, `bg-card`, `bg-secondary`
- Replace `text-zinc-*` with `text-foreground`, `text-muted-foreground`
- Update gradient glow to use `accent-primary/5`

**Step 3: Commit**

```bash
git add pages/LandingPage.tsx components/landing/
git commit -m "style: restyle LandingPage with Spool branding and design"
```

---

### Task 11: Bulk restyle remaining components — color token swap

**Files:**
- All files in `components/` and `pages/` with `zinc-`, `bg-`, `cream`, `dim`, `muted`, `surface`, `elevated`, `indigo-` class references

**Step 1: Identify all files needing color updates**

Run: `grep -rl 'zinc-\|bg-surface\|bg-card\b\|bg-elevated\|text-cream\|text-dim\|text-muted\b\|border-zinc\|indigo-' --include='*.tsx' components/ pages/`

**Step 2: Apply systematic replacements across all files**

Color mapping (old Tailwind class → new theme token class):

| Old | New |
|-----|-----|
| `bg-zinc-950`, `bg-zinc-900`, `bg-bg` | `bg-background` |
| `bg-zinc-800`, `bg-surface` | `bg-card` |
| `bg-zinc-700`, `bg-elevated` | `bg-secondary` |
| `text-white`, `text-cream` | `text-foreground` |
| `text-zinc-200`, `text-zinc-300` | `text-foreground` |
| `text-zinc-400`, `text-text` | `text-muted-foreground` |
| `text-zinc-500`, `text-dim` | `text-muted-foreground` |
| `text-zinc-600` | `text-muted-foreground/60` |
| `border-zinc-700`, `border-zinc-800` | `border-border` |
| `border-white/10`, `border-white/5` | `border-border/30` |
| `bg-indigo-*`, `text-indigo-*` | `bg-accent`/`text-accent` |
| `bg-yellow-*`, `text-yellow-*` | `bg-gold`/`text-gold` |
| `font-serif` | `font-serif` (now maps to Cormorant Garamond) |
| `font-sans` | `font-sans` (now maps to Source Sans 3) |

Do this for every `.tsx` file in `components/` and `pages/`.

**Step 3: Verify no zinc/old color references remain**

Run: `grep -rn 'zinc-\|bg-surface\|text-cream\|text-dim\|indigo-' --include='*.tsx' components/ pages/`
Expected: No results.

**Step 4: Commit**

```bash
git add components/ pages/
git commit -m "style: bulk restyle all components with Spool color tokens"
```

---

### Task 12: Update `Grain.tsx` to match Spool film grain

**Files:**
- Modify: `components/Grain.tsx`

**Step 1: Read current Grain.tsx**

**Step 2: Update grain opacity and blend mode**

The Spool design uses 3% opacity (`opacity-[0.03]`) with a simple overlay. Update accordingly.

**Step 3: Commit**

```bash
git add components/Grain.tsx && git commit -m "style: update Grain overlay to Spool film grain treatment"
```

---

### Task 13: Restyle `ProfilePage.tsx` and `ProfileOnboardingPage.tsx`

**Files:**
- Modify: `pages/ProfilePage.tsx`
- Modify: `pages/ProfileOnboardingPage.tsx`

**Step 1: Read both files**

**Step 2: Apply Spool styling**

Profile page:
- Profile card: `bg-card/50 border border-border/30 rounded-2xl`
- Avatar: Gradient `from-gold/80 to-accent-primary/60`
- Stats grid: `bg-secondary/20 rounded-xl`, numbers in `font-serif text-gold`
- Emotional signature badges: `bg-gold/8 text-gold border border-gold/20 rounded-full`
- Activity items: `bg-card/50 border border-border/30 rounded-xl`

Onboarding:
- Same card/button treatment as AuthPage
- Use SpoolLogo
- CTA: `bg-gold text-background rounded-xl`

**Step 3: Commit**

```bash
git add pages/ProfilePage.tsx pages/ProfileOnboardingPage.tsx
git commit -m "style: restyle Profile and Onboarding pages with Spool theme"
```

---

### Task 14: Restyle `StatsView.tsx` charts with Spool palette

**Files:**
- Modify: `components/StatsView.tsx`

**Step 1: Read current StatsView**

**Step 2: Update Recharts colors**

- Chart container cards: `bg-card/50 border border-border/30 rounded-2xl`
- Chart axis text: `fill: '#9BA3AB'` (muted-foreground)
- Chart axis lines: `stroke: '#252C35'` (border)
- Bar/pie chart colors: Use `#D4C5B0` (gold), `#8BA8BA` (accent)
- Keep tier colors for tier distribution chart
- Stat numbers: `font-serif text-gold`
- Section headers: `font-serif text-foreground`

**Step 3: Commit**

```bash
git add components/StatsView.tsx && git commit -m "style: restyle StatsView charts with Spool palette"
```

---

### Task 15: Restyle remaining views (SocialFeedView, Watchlist, etc.)

**Files:**
- Modify: `components/SocialFeedView.tsx`
- Modify: `components/Watchlist.tsx`
- Modify: `components/DiscoverView.tsx`
- Modify: `components/FriendsView.tsx`
- Modify: `components/JournalHomeView.tsx`
- Modify: `components/WatchPartyView.tsx`
- Modify: `components/MoviePollView.tsx`
- Modify: `components/GroupRankingView.tsx`
- Modify: `components/AchievementsView.tsx`
- Modify: `components/MovieListView.tsx`

**Step 1: For each file, apply the same color token swap from Task 11**

Additional Spool-specific styling:
- Feed cards: `bg-card/50 border border-border/30 rounded-xl`, quoted text with `border-l-2 border-accent-primary/20 pl-3 italic`
- User avatars: gradient `from-gold/70 to-accent-primary/50`
- Action buttons (like/comment): `text-muted-foreground active:text-gold`
- Watchlist "I watched this" CTA: `bg-gold hover:bg-gold-muted text-background rounded-lg`
- Empty states: `text-muted-foreground/20` for icons, `font-serif` for headings

**Step 2: Verify each view renders**

Navigate through all tabs in the app, check styling is consistent.

**Step 3: Commit**

```bash
git add components/
git commit -m "style: restyle all remaining views with Spool theme"
```

---

### Task 16: Final verification and cleanup

**Files:**
- All modified files

**Step 1: Full visual audit**

Run: `npm run dev`
Walk through every page and view:
- [ ] Landing page
- [ ] Auth page
- [ ] Onboarding
- [ ] Tier Board (desktop sidebar + mobile tabs)
- [ ] Social Feed
- [ ] Watchlist
- [ ] Discover
- [ ] Stats
- [ ] Journal
- [ ] Groups / Polls / Achievements
- [ ] Profile page
- [ ] Media detail modal
- [ ] Add media modal

**Step 2: Check for any remaining old color references**

Run: `grep -rn 'zinc-\|#08080B\|#111116\|#16161D\|#1C1C25\|#C8C3BC\|#F0EBE3\|#ffc107\|indigo-' --include='*.tsx' --include='*.css' --include='*.html' .`
Expected: No results (except possibly in docs/ or test files).

**Step 3: Run build to check for errors**

Run: `npm run build`
Expected: Build succeeds with no errors.

**Step 4: Final commit**

```bash
git add -A && git commit -m "style: final cleanup and verification of Spool visual rebrand"
```
