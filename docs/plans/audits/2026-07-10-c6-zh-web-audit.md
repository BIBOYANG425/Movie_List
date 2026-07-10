# C6 Web Audit — Chinese localization (reference semantics for the iOS zh port)

**Cycle:** C6 (zh localization: UI copy tables, `t()` plumbing, locale storage/toggle, TMDB content localization, localized-title display layer)
**Audited at commit:** `20d59bb` on `feat/ios-parity-c5-tv-books` (post-C5: re-rank raw-item lookups live on all three verticals)
**Scope:** `i18n/en.ts` + `i18n/zh.ts` + `i18n/index.ts`, `contexts/LanguageContext.tsx`, `components/shared/LanguageToggle.tsx`, `components/layout/AppLayout.tsx`, `hooks/useLocalizedItems.ts`, `services/tmdbService.ts` (locale seams), `services/openLibraryService.ts`, `services/discoverChips.ts`, `supabase/functions/suggestions/index.ts` (locale param), `supabase/functions/tmdb-proxy/rules.ts`, `supabase/functions/journal-agent/index.ts`, `styles/theme.css` + `index.html` (typography), sampled untranslated components (`AuthPage`, `TierPicker`, `NotesStep`, `AddMediaModal`, `JournalEntrySheet`, `ErrorBoundary`, `NotificationBell`, `Watchlist`), iOS `TMDBService.swift` / `SuggestionsClient.swift` / `SpoolFonts.swift` / `SettingsScreen.swift` / `BottomNav.swift` / `OnboardingQueue.swift`. Audit only — no code changed.

**Premise notes (read first):**
1. **Web zh is two independent layers.** Layer 1: UI copy via hand-rolled key tables + `t()` (`contexts/LanguageContext.tsx:36-41`). Layer 2: content locale via `getTmdbLocale()` reading the SAME `spool_locale` storage directly (`services/tmdbService.ts:31-34`) — TMDB requests carry `language=zh-CN`, so search results, detail modals, and suggestions come back in Chinese. On web the two layers share one switch. On iOS today only layer 2 exists, and it keys off the DEVICE language, not an app preference (`TMDBService.swift:471-475`).
2. **The persisted-title pin is already contract law** (`docs/contracts/shared-payloads.md:429-433`): DB `title` columns, `activity_events.media_title`, and stub titles are default-locale; zh display is a read-time swap (`useLocalizedItems`). C4/C5 closed every re-rank hole (raw-item lookups at `RankingAppPage.tsx:1820,1825,1991,1998,2009`). One accepted exception: a fresh rank from a zh-locale `suggestions` response persists the zh title on both platforms (pin text, `shared-payloads.md:433`).
3. **The en table is the type source; zh is untyped.** `TranslationKey = keyof typeof en` (`i18n/en.ts:392`); `zh` is a bare `Record<string, string>` (`i18n/zh.ts:1`). Parity today is exact (322/322 keys, verified mechanically), but nothing enforces it — see B3.
4. **Coverage is much thinner than the table implies.** 322 keys defined, but only ~250 are live (229 literal `t('…')` + 21 dynamic); 72 keys (22%) are dead, and 39 of 71 page/component files have no `useTranslation` at all — including the main nav and the entire ranking ceremony steps. iOS must port the RECONCILED table, not the current one — see B2.

---

## 1. Reference semantics

### 1.0 The tables

| | `i18n/en.ts` | `i18n/zh.ts` |
|---|---|---|
| keys | 322 (`as const`, lines 1-390) | 322 (`Record<string, string>`, lines 1-390) |
| typing | source of `TranslationKey` (`:392`) | untyped — no compile check against en (`:1`) |
| missing / extra vs en | — | 0 / 0 (verified via keyset diff at HEAD) |
| intentionally identical values | — | 4: `auth.emailPlaceholder`, `auth.usernamePlaceholder`, `auth.passwordPlaceholder`, `landing.copyright` |

- Namespaces: `nav, tab, stubs, firstRun, ranking, tier, watchlist, stats, feed, filter, discover(+chip), tierLabel, notifications, journal, profile(+tab), auth, onboarding, error, toast, landing, book, search, tv, public, share, streak, recap, detail, lang` — flat dot-keys, one file per locale, barrel export `i18n/index.ts:1-3`.
- Interpolation is ad-hoc: values carry `{n}`/`{tier}`/`{count}`/`{label}`/`{rank}`/`{score}` placeholders; each call site does `.replace('{n}', String(...))` manually (`UniversalSearch.tsx:319`, `StreakBadge.tsx:38`, `MediaDetailModal.tsx:383,454,485,536`, `RankingAppPage.tsx:368`). No plural engine — en uses separate keys (`stubs.moment`/`stubs.moments`), zh duplicates identical values where Chinese needs no plural (`discover.friend`/`discover.friends`, `zh.ts:117-118`).

### 1.1 `t()` plumbing + locale store

- `LanguageProvider` (`contexts/LanguageContext.tsx:22-48`) mounts at the app root (`index.tsx:19`). State init: `localStorage.getItem('spool_locale') === 'zh' ? 'zh' : 'en'` (`:23-26`) — **default is `en` regardless of browser language; web NEVER auto-selects zh**. Every change is persisted back (`:28-30`).
- `t(key: TranslationKey)` = `TRANSLATIONS[locale][key] ?? en[key] ?? key` (`:36-41`) — zh-miss falls back to en, then to the raw key. Call sites are typed, with three `as any` escapes for dynamically-built keys (`ProfilePage.tsx:552`, `FeedFilterBar.tsx:43`, `LandingPage.tsx:417`).
- **Content locale reads storage directly, not context**: `getTmdbLocale()` re-reads `localStorage['spool_locale']` per request (`tmdbService.ts:31-34`), so a toggle applies to the very next fetch with no reload and no React dependency. This storage-as-seam decoupling is the pattern the iOS `LocaleStore` should copy.
- Usage census: 71 `.tsx` files under `components/` + `pages/`; **32 import `useTranslation`**, 39 do not; **279 literal `t('…')` call sites** plus 6 dynamic sites (`ProfilePage.tsx:552`, `FeedFilterBar.tsx:43`, `DiscoverView.tsx:65,103,517`, `LandingPage.tsx:417`).
- Key census: 229 unique keys referenced literally + 21 dynamically (7 `discover.chip.*` via `discoverChips.ts:27-35`; `filter.allTime` via `FeedFilterBar.tsx:15,43`; 8 `landing.step{1-4}{Title,Desc}` via `LandingPage.tsx:393-396,417`; 5 `profile.tab*` via `ProfilePage.tsx:552`) = **250 live, 72 dead** (§2 B2 lists them). Zero keys are used-but-undefined.

### 1.2 Toggle surface

- `LanguageToggle` (`components/shared/LanguageToggle.tsx:5-22`): Globe icon + `中文`/`EN` flip button; `title` tooltip is itself bilingual-hardcoded (`:15`).
- Rendered in exactly ONE place: `RankingAppPage` `headerActions` (`pages/RankingAppPage.tsx:1657`), next to NotificationBell and Sign out.
- `AppLayout` renders `headerActions` inside `hidden md:flex` (`components/layout/AppLayout.tsx:67`) — **on <768px viewports the toggle does not exist anywhere in the app** (the mobile bottom tab bar `:76-98` carries no header actions). Landing, Auth, Profile, and Public-profile pages never render the toggle at all (grep: only `RankingAppPage.tsx:21,1657`), though Landing/Profile ARE translated and react to the stored locale.

### 1.3 What is NOT translated (hardcoded EN surfaces)

39 of 71 tsx files have no `useTranslation`. Excluding purely visual ones (SpoolLogo, Grain, SkeletonCard, GenreRadarChart, PosterMosaic…), the user-facing hardcoded-EN surfaces are:

| Surface | Evidence | Twist |
|---|---|---|
| **Main nav** (Board/Feed/Watchlist/Discover/Profile, both desktop + mobile bars) | `AppLayout.tsx:14-20` | The dead `tab.*`/`nav.all` keys are leftovers of a pre-AppLayout nav; labels have since diverged ("Board" has no key at all) |
| **Ceremony steps** — TierPicker, NotesStep, ComparisonStep | `TierPicker.tsx:38,44`; `NotesStep.tsx:73` | The core loop of the product is EN-only in zh mode |
| **AddMediaModal** (movie search + suggestions) | `AddMediaModal.tsx:431,451,479,584,641,652,717` | AddTVSeasonModal/RankingFlowModal/UniversalSearch ARE translated — movies, the flagship vertical, are not |
| **AuthPage** | `AuthPage.tsx:83,94,123,146` | All 14 `auth.*` keys exist in BOTH tables and are dead — the page was built/rebuilt without them |
| **Onboarding pages** (Movie + Profile) | `pages/MovieOnboardingPage.tsx`, `ProfileOnboardingPage.tsx` (no hook) | All 8 `onboarding.*` keys dead; zh `onboarding.welcome` says "欢迎来到 Marquee" — stale brand (`zh.ts:208`) |
| **ErrorBoundary** | `ErrorBoundary.tsx:46-47` "Something hit a snag" | Diverged from dead `error.somethingWrong` = "Something went wrong" |
| **Journal suite** — EntrySheet, Conversation, FilterBar, EntryCard, Mood/VibeTagSelector, CastSelector | `JournalEntrySheet.tsx:226,250,284,294,314,327,338,351,377,410` | Plus mood/vibe labels are EN data constants (`constants.ts:185-231`) rendered verbatim |
| **NotificationBell time-ago** | `NotificationBell.tsx:16-25` hardcodes `now/m/h/d` | `feed.justNow/minsAgo/hrsAgo/daysAgo` keys dead; `JournalEntryCard.tsx:16-25` same |
| **Landing subcomponents** | `LandingHero.tsx:40` "SOCIAL RANKING REIMAGINED" | Parent `LandingPage` is translated; hero/CTA/panels are not |
| **LetterboxdImportModal, AchievementsView, MovieListView, SharedWatchlistView, MonthlyRecapCard, FeedCardMenu, MediaCard** | (no hook in any) | |
| **Data-level EN**: genres persisted EN and rendered raw; notification titles baked EN at write (`shared-payloads.md:121-122`, C1 D12 — its web fix ledgered "C6 adjacent", `audits/2026-07-07-c1-feed-web-audit.md:172`); journal-agent LLM prompt EN-only (`journal-agent/index.ts:90`, no locale param) | | |

Mixed-language bugs on screens that ARE translated: reset confirm interpolates the EN media label into the zh sentence — `label = 'book'|'TV'|'movie'` (`RankingAppPage.tsx:367-368`) renders "重置你的book列表？"; the shared Watchlist empty state says 电影/"movies" in TV/books modes (single key `watchlist.empty`, `Watchlist.tsx:19`); zh `tier.items` = `部` (movie/film measure word) is wrong for books (本) (`zh.ts:60`).

### 1.4 Dates, numbers, typography

- **Dates are inconsistent across three patterns**: locale-aware — `toLocaleDateString(locale …)` passing the raw `'zh'|'en'` context value (valid BCP-47) at `StubCard.tsx:160`, `CalendarView.tsx:42,45`, `MediaDetailModal.tsx:201,526`; browser-default (`undefined`) at `JournalEntryCard.tsx:25`, `StubCollectionView.tsx:68`, `AchievementsView.tsx:127`; hardcoded `'en-US'` at `Watchlist.tsx:29` (a file that imports `useTranslation` two lines up).
- Numbers: `toLocaleString()` browser-locale (`LandingPage.tsx:370`); everything else plain string interpolation.
- **No zh typography handling anywhere**: fonts are `'Cormorant Garamond'` serif + `'Source Sans 3'` sans (`styles/theme.css:41-42`; loaded `index.html:9`) — Latin-only; CJK glyphs fall back per-glyph to the platform default (PingFang SC on macOS). No `:lang(zh)` CSS (grep: zero hits in `styles/`), and `<html lang="en">` is static (`index.html:2`) — never updated on toggle, so CJK line-breaking/screen-reader hints are wrong in zh mode.
- Test coverage: exactly one i18n test — `discoverChips.test.ts:53-54` asserts en+zh entries exist for the 7 chip keys. No full-table parity test.

### 1.5 TMDB / content localization

- `getTmdbLocale()` (`tmdbService.ts:31-34`): `'zh' → 'zh-CN'`, else `'en-US'`. Applied at every TMDB read: movie search `:189`, person search `:268`, person details `:327-330`, movie details ×3 (`:401,433,468`), TV search `:837`, TV show details `:897`, season details `:947`, TV global score `:978` — so in zh mode, search results, detail modals (title + overview + providers), and people all render Chinese from TMDB directly.
- **Suggestions**: client sends `locale: getTmdbLocale()` in the edge-function body (`tmdbService.ts:672`); server normalizes `zh*` → `zh-CN` (`suggestions/index.ts:154-156`, applied `:829`); contract pin `shared-payloads.md:768,783-784` ("mirrors `getTmdbLocale` / `TMDBService.locale()` on both clients"). A zh suggestions response carries zh titles into the rank flow — and per the accepted pin, a fresh rank persists that zh title (premise 2).
- **`useLocalizedItems` / `useLocalizedWatchlist`** (`hooks/useLocalizedItems.ts:61-125`) — the display-swap layer for DB-read (EN-persisted) titles:
  - zh-only: returns items untouched unless `locale === 'zh'` (`:93,119`).
  - Fetches per-id via `fetchLocalizedTitle(id, 'zh-CN')` (`tmdbService.ts:797-818`): `tv_{n}` / `tv_{n}_s{k}` → `tv/{n}` (SHOW-level title, season ignored); anything else strips `tmdb_` → `movie/{id}`. Batches of 10 (`:7,36-38`), only successes cached (`:46-53`).
  - Cache: `localStorage['spool_title_zh']` (`:6`) — unbounded, never invalidated; a TMDB zh-miss returns the default-locale title, which gets cached under zh (acceptable fallback, invisible).
  - Swap is title-only and display-only (`{ ...item, title: entry.title }`, `:95-98`). The `overview` is fetched and cached (`:42-48`) but **never rendered from this cache** — detail modals refetch live with `getTmdbLocale`, so the cached overview is dead weight.
  - Consumed exactly once each: `RankingAppPage.tsx:1568-1569` (ranked grid + watchlist). Feed cards, stubs, and journal render persisted EN titles even in zh mode — deliberate (baked-string pins, `shared-payloads.md:121,431`).
  - The watchlist variant lacks the items-identity guard the ranked variant has (`:109-117` vs `:70-91`) — refires `fetchChineseTitles` on every ids change (cache absorbs most of it).
- **Books have no zh path at all**: OpenLibrary search takes no language param (`openLibraryService.ts` — zero `language`/`lang` hits) and `fetchLocalizedTitle` has **no `ol_` branch** — an `ol_…` id becomes `movie/ol_OL27448W`, fails the proxy's `/^movie\/\d+$/` rule (`tmdb-proxy/rules.ts:40`), 403s, is never cached (successes only), and refires — burning the 30 req/min proxy bucket in zh mode. This is C5-D5, **still unfixed at HEAD** — promoted to Blocking here (B4) because C6 is the cycle that multiplies zh usage.

### 1.6 iOS current state (what C6 builds on)

- **No display-copy i18n layer**: zero `NSLocalizedString` / `String(localized:)` / `.strings` / `.xcstrings` anywhere in `ios/` (grep-verified). **208 `Text("…")` literals** plus ~19 `Button("…")`/`TextField` prompts across 23 screens + 4 onboarding files + 19 components — all EN, all in the bespoke lowercase hand voice ("how did it feel?" `RankTierScreen.swift:34`; "public shows your activity in explore" `SettingsScreen.swift:196`; nav "feed/stubs/queue/friends/me" `BottomNav.swift:52-60`). Voice is pinned as spec: "Copy voice: lowercase mono, existing app conventions" (`2026-07-08-c1-ios-feed-ui-plan.md:16`).
- **Content locale follows the DEVICE, in two duplicated helpers**: `TMDBService.locale()` (`TMDBService.swift:471-475`) and `SuggestionsClient.locale()` (`SuggestionsClient.swift:122-125`) both do `Locale.preferredLanguages.first` → `zh*` → `zh-CN` else `en-US`. Applied to movie detail `:104`, TV `:238,293,329`, search `:357,372`, and the suggestions body (`SuggestionsClient.swift:85`). The ledgered note is explicit: "iOS in-app locale toggle would need `locale()` re-sourcing" (`2026-07-07-ios-parity-ledger.md:85`). Net today: a zh-device user gets zh TMDB CONTENT (search/detail/suggestions) under EN chrome — the inverse of web, where nothing is zh until the toggle and then everything is.
- **No `useLocalizedItems` equivalent**: DB-read surfaces (FullListScreen, feed, stubs) render persisted titles as-is; the only localized-title awareness is a comment (`TierOrder.swift:19` — ids-only helpers "cannot leak a localized title").
- **Chinese-aware code that exists**: `containsCJK` (`TMDBService.swift:454-462`) gates typo-retry variants (CJK queries skip chopping) — mirrors web `fuzzySearch`'s non-ASCII gate. That's all.
- **Typography**: `SpoolFonts` (`Theme/SpoolFonts.swift:24-56`) = Gloock / Kalam / Caveat / DM Mono with system fallbacks — all four are Latin-only; CJK falls back per-glyph to PingFang SC, so the hand/script aesthetic does not carry to Chinese text (same situation as web's Cormorant, but more load-bearing given the hand-voice design).
- **Infrastructure precedents to reuse**: `OnboardingQueue`'s UserDefaults seam — stable key + comment "do not rename without a migration" + test-overridable store (`OnboardingQueue.swift:40-43`); SettingsScreen's sectioned layout ACCOUNT/APPEARANCE/PRIVACY/ABOUT (`SettingsScreen.swift:131,161,176,226`) as the natural toggle home.
- The program design pre-sketched C6 as "`.xcstrings` catalog (~376 keys from web i18n)" (`2026-07-07-ios-parity-program-design.md:32`) — the key count is stale (322 actual, ~250 live) and the mechanism is contested below (§3 mechanism, Q4).
- zh-mode deferred item already ledgered: typo-retry "no results" label shows EN in zh locale (`ledger:496`).

---

## 2. Findings

### Blocking (web fixes required BEFORE iOS copies the mechanism)

**B1 — The language toggle is unreachable on mobile; iOS would copy a toggle placement that doesn't exist for its form factor.**
`LanguageToggle` renders only inside `RankingAppPage` `headerActions` (`RankingAppPage.tsx:1657`), and `AppLayout` hides `headerActions` below 768px (`AppLayout.tsx:67` — `hidden md:flex`). The mobile bottom bar (`:76-98`) has no equivalent. A phone user cannot switch language at all; since iOS is the phone form factor, there is no web-reference placement to port. Landing/Auth also lack the toggle, so a zh user's first-run funnel is EN with no visible escape.
*Fix shape:* add the toggle to a mobile-reachable surface (Profile view or a settings sheet — the same place iOS will put it), keep the desktop header instance.

**B2 — The key table misrepresents coverage: 72 dead keys (22%) while the highest-traffic surfaces have no keys at all.**
Dead (defined in both tables, referenced nowhere, dynamic uses accounted for): all 14 `auth.*`, all 8 `onboarding.*`, 7 of 8 `tab.*` (only `tab.resetRankings` lives, `RankingAppPage.tsx:1704`), 5 `tierLabel.*`, 4 `feed.{justNow,minsAgo,hrsAgo,daysAgo}`, both `error.*`, `nav.{all,addItem,myProfile}`, `stubs.changeDate`, `ranking.allGenres`, `discover.{friend,friends}`, 6 `profile.*` (find-friends cluster), 8 `landing.*` (`getStarted`, `createAccount`, `step`, `about`, `privacy`, `terms`, `contact` + `landing.step`), `book.{searchBooks,author,pages,addBook}`, `tv.{seasonCount,episodeCount,seasons,creator,status}`, `recap.{watched,topMood}`, `lang.toggle`. Meanwhile the components those keys were written for hardcode EN (AuthPage `:83-146`, onboarding pages, `ErrorBoundary.tsx:46-47` with diverged copy, `NotificationBell.tsx:16-25`), and the surfaces with the most zh-mode exposure — main nav (`AppLayout.tsx:14-20`), ceremony steps (`TierPicker.tsx:38,44`, `NotesStep.tsx:73`), `AddMediaModal` (`:431-717`) — have neither keys nor hooks. Porting the table as-is gives iOS 72 phantom keys and no copy for the screens that matter.
*Fix shape:* reconcile before the port — wire the resurrectable dead keys into their components (auth, onboarding, error, time-ago), delete the unrescuable ones (stale `tab.*`/`nav.*`), and add keys for nav + ceremony + AddMediaModal + journal sheet. The reconciled keyset is the iOS port artifact.

**B3 — Nothing enforces en/zh parity: zh is untyped and untested.**
`zh` is `Record<string, string>` (`zh.ts:1`) — a missing, extra, or typo'd zh key compiles clean and silently falls back to en at runtime (`LanguageContext.tsx:38`). The only test touches 7 chip keys (`discoverChips.test.ts:53-54`). Parity is exact today (322/322) by discipline, not by machine.
*Fix shape:* type zh as `Record<TranslationKey, string>` (compile-time exhaustiveness + no strays) and add one vitest asserting `Object.keys(en)` ≡ `Object.keys(zh)`. The same fixture doubles as the future web↔iOS key-parity check (engine-parity fixture convention).

**B4 — zh mode burns proxy quota on every book id, on every items change (C5-D5, now in-cycle).**
`fetchLocalizedTitle` has no `ol_` early-return (`tmdbService.ts:802-814`), so each book ranked/bookmarked in zh mode fires `movie/ol_…` → guaranteed 403 (`rules.ts:40`), never cached (`useLocalizedItems.ts:46-53` caches successes only), re-fired on ids-identity changes, counted against the shared 30 req/min bucket. A book-heavy zh user can starve their own movie/TV localization and search.
*Fix shape:* one line — `if (id.startsWith('ol_')) return null;` at the top of `fetchLocalizedTitle`. iOS must bake the same guard into any localized-title fetch from day one.

**B5 — Translated screens still emit mixed-language sentences.**
The reset confirm splices the EN media word into zh copy: `label = 'book'|'TV'|'movie'` (`RankingAppPage.tsx:367`) → "重置你的book列表？" (`zh.ts:51`). The shared watchlist empty-state/hint say "movies/电影" in TV and books modes (`Watchlist.tsx:19,21`, single `watchlist.empty` key). zh `tier.items` uses the film measure word `部` for all three verticals (`zh.ts:60`).
*Fix shape:* interpolate translated labels (reuse `nav.movies/nav.tv/nav.books`) and split the per-media strings (`watchlist.empty.{movie,tv,book}` or a `{media}` placeholder). Pin the rule: never interpolate an untranslated enum into a translated sentence.

### Deferred

**D1 — No zh typography or `lang` handling.** `<html lang="en">` static (`index.html:2`); Latin-only font stacks (`theme.css:41-42`); no `:lang(zh)` rules. CJK renders via per-glyph system fallback — legible but off-design. Web fix: set `document.documentElement.lang` on toggle + choose a zh stack (or accept system fallback and pin it). iOS mirrors the same decision in `SpoolFonts` (§3 #7).
**D2 — Date formatting is three-way inconsistent** (§1.4): locale-aware vs browser-default vs hardcoded `'en-US'` (`Watchlist.tsx:29`). Standardize on the context locale; the time-ago helpers (`NotificationBell.tsx:16-25`, `JournalEntryCard.tsx:16-25`) should consume the dead `feed.*Ago` keys or the keys should go (B2 overlap).
**D3 — Interpolation/plural convention is implicit.** `.replace('{x}', …)` per call site, plural via separate keys, zh duplicates. Fine for en/zh — but pin it in the contract so iOS `t()` implements the same (string replace, no ICU/plural engine).
**D4 — journal-agent is EN-only** (`journal-agent/index.ts:90`, no locale in the request contract). A zh user's journal conversation happens in English. Product decision; if fixed, the edge-function contract grows a `locale` param like `suggestions`.
**D5 — Notification titles baked EN at write** (C1 D12, `shared-payloads.md:121-122`; ledgered "i18n-by-type is a later web fix (C6 adjacent)", `c1-feed-web-audit.md:172`). Fixing means type+params rendering at read time on BOTH clients — decide whether it's in C6 scope (Q5).
**D6 — `useLocalizedWatchlist` lacks the refetch guard** its ranked twin has (`useLocalizedItems.ts:109-117` vs `:70-91`) — harmless with a warm cache, wasteful without.
**D7 — Localized overview is fetched+cached but never displayed from cache** (`useLocalizedItems.ts:42-48` vs `:95-98`) — dead localStorage weight; drop the field or use it.
**D8 — Stale copy in both tables**: `onboarding.welcome` = "Welcome to Marquee" / "欢迎来到 Marquee" (`en.ts:208`, `zh.ts:208`) — pre-rebrand app name (rebrand doc `2026-03-08-spool-visual-rebrand-plan.md`); dead anyway per B2 but must not be ported verbatim.
**D9 — `spool_title_zh` cache is unbounded and permanent** (`useLocalizedItems.ts:22-24`) — no TTL, no size cap, survives locale flips. Fine at current scale; note before iOS replicates the cache shape.

---

## 3. iOS gap list (what C6 must build, in dependency order)

Today: content-locale layer exists (device-keyed, duplicated); display-copy layer absent (~227 hardcoded literals); no locale store, no toggle, no localized-title display path.

1. **Web reconciliation first (B1-B5).** The port target is the post-B2 keyset and the post-B5 string shapes — porting the current table imports 72 dead keys and the mixed-language bugs.
2. **`LocaleStore` (the seam everything hangs on).** UserDefaults-backed, stable key (`spool.locale`), values `en`/`zh`/absent = follow-device policy per Q2, test-overridable store — copy the `OnboardingQueue` pattern exactly (`OnboardingQueue.swift:40-43`). Pure Swift, no UI dependency, readable from services — mirroring web's storage-as-seam (`tmdbService.ts:31-34` reads storage, not context).
3. **Re-source the two `locale()` helpers** (the ledgered note, `ledger:85`): `TMDBService.swift:471-475` and `SuggestionsClient.swift:122-125` both become `LocaleStore first, device fallback` — and dedupe into one shared helper while touching them (they are already drift-prone duplicates). This keeps the `shared-payloads.md:783-784` mirror-pin true after the toggle lands.
4. **Copy table + `t()`.** Port the reconciled tables as Swift dictionaries keyed by the SAME dot-key strings, `t(_ key:) -> String` with the same fallback chain (locale → en → key) and the same `{placeholder}` replace convention (D3). Locale exposed as observable app state so SwiftUI re-renders in place on toggle. **Mechanism recommendation: hand-rolled table, NOT `.xcstrings`** — despite the program-design sketch (`program-design.md:32`) and despite String Catalogs being platform-idiomatic — because (a) the binding requirement is an IN-APP toggle with instant in-session switching, which String Catalogs don't natively do (they follow the app's effective system locale; forcing requires per-app language Settings round-trips or `AppleLanguages` process restarts), (b) key-for-key parity with web must be machine-checkable — two dictionaries with identical key strings diff trivially against the web tables in a fixture test (the repo's engine-parity convention), an `.xcstrings` JSON adds an extraction/format layer between the platforms, and (c) the repo precedent is hand-rolled pure seams with unit tests, and none of the catalog ecosystem benefits (plural rules, export-for-translation, per-locale review in Xcode) are used by this product's two-locale, bespoke-voice copy. Costs accepted: no automatic plural/gender handling (web has none either), no Xcode localization tooling. Flag as Q4 since it deviates from the program sketch.
5. **Screen adoption.** Replace the ~227 literals (208 `Text` + buttons/prompts) across 23 screens + 19 components. Reuse web keys where the surface matches (tiers, watchlist, feed, detail); mint iOS-namespaced keys for iOS-only chrome (`BottomNav` "feed/stubs/queue/friends/me", settings sections, stub screens) — and get zh copy for them (Q3). The dead-key lesson from B2 applies in reverse: no key lands without a consuming call site.
6. **Toggle UI**: SettingsScreen row (own LANGUAGE section or under APPEARANCE, `SettingsScreen.swift:161`) — placement per Q1, matching wherever web's B1 fix puts the mobile toggle.
7. **Localized display titles (the `useLocalizedItems` twin)** — scope per Q6. If ported: swap-at-display for ranked/watchlist reads only (matching web's single consumption point, `RankingAppPage.tsx:1568-1569`), show-level `tv/{n}` fetch for `tv_…` ids, **`ol_` early-return** (B4's guard), success-only cache, title-only swap. The title-locale pin holds: persistence paths never see the swapped item (iOS's `CeremonyEmission`/`TierOrder` id-only design already guarantees most of this, `TierOrder.swift:19`); feed/stubs stay EN-baked on both platforms.
8. **zh typography decision** (with D1): `SpoolFonts` hand/script styles have no CJK equivalent — decide per-style CJK fallbacks (system serif/rounded) or a bundled zh font; pin so web (D1) and iOS agree on the zh look.
9. **Do NOT port**: the 72 dead keys (B2), the desktop-only toggle placement (B1), EN-enum interpolation (B5), the `ol_` quota burn (B4), untyped zh table (B3), the unused-overview cache field (D7), "Marquee" copy (D8).
10. **Contract doc additions** (`shared-payloads.md`): a `## locale` section — storage key + values + default policy (Q2's answer), the `t()` fallback chain, the `{placeholder}` convention, the `ol_`-never-localizes rule, and a pointer that `getTmdbLocale`/`locale()` must read the SAME store the UI toggle writes on each platform.

## 4. Open questions

1. **Q1 (toggle placement on iOS):** Settings row (recommended — SettingsScreen sections exist, matches "preferences" mental model) vs profile/header affordance mirroring web's desktop placement? Also decides web's B1 fix location so the two platforms tell one story.
2. **Q2 (device-locale auto-select):** web defaults to `en` unless the user toggles (`LanguageContext.tsx:25` — no `navigator.language` check); iOS CONTENT already follows the device (`TMDBService.swift:471-475`). Should iOS display-copy default to device (`zh` device → zh chrome, no toggle needed for the target user) or mirror web's explicit-opt-in `en`? Recommend: absent-key = follow device on iOS, and ALSO fix web to seed from `navigator.language` — pin whichever in the contract. Note the today-split this resolves: zh-device iOS users currently see zh content under EN chrome.
3. **Q3 (does the voice translate):** the lowercase hand voice has no Chinese equivalent (CJK has no case). Web's zh register is standard-neutral (你的/暂无/去排名). Adopt web's zh strings verbatim for shared keys; for iOS-only copy ("stubs", "queue", "me"), owner review of the zh register is required — machine translation of a bespoke voice is the highest-risk copy in the cycle.
4. **Q4 (mechanism sign-off):** confirm the hand-rolled-table recommendation over the program-design's `.xcstrings` sketch (`program-design.md:32`) — the sketch also cites "~376 keys", stale vs 322 defined / ~250 live.
5. **Q5 (adjacent EN-baked data):** are notification-title i18n-by-type (D5/C1-D12) and journal-agent zh (D4) in C6 scope, or ledgered to C7? Both are cross-platform contract changes, not client copy.
6. **Q6 (localized display titles on iOS):** port the `useLocalizedItems` twin in C6, or defer? Deferring is coherent (persisted EN titles are already contract), but a zh iOS user then sees zh search/detail against an EN board — the exact seam the web hook exists to smooth. Recommend: port, ranked+watchlist reads only, `ol_` guard included.
7. **Q7 (zh QA gate):** the parity fixture (B3) machine-checks keysets, not quality. Who eyeballs zh screens per cycle? A `zh` pass in the C6 verification doc (screenshot walk of nav/ceremony/feed/detail in zh) would catch the B5-class bugs no test sees.
