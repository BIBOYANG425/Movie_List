# C6-iOS zh Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Bring Chinese to Spool iOS: a locale store + string-table mechanism (the audit-recommended Swift twin of web's hand-rolled tables), a Settings toggle, TMDB/suggestions locale re-sourced from the store, and the app's user-visible copy wired through the seam.

**Architecture (controller-adjudicated, owner-reviewable — recorded in the parity ledger C6 notes):** pure Swift dictionary tables + a UserDefaults-backed `LocaleStore` (NOT Apple String Catalogs — matches the repo's pure-seam style and web's mechanism); `LocaleStore` defaults to the DEVICE language (zh-device users keep today's zh content behavior and gain zh UI; web defaults en — deviation noted); toggle = a `SettingsScreen` row. Web zh values are ported VERBATIM where the en string matches; iOS-only strings get new zh following the web register + the owner's voice rules (no 不是…而是, no em dashes, no negation-contrast).

**Tech Stack:** Swift + XCTest. Baselines: iOS 741, web 545 (untouched).

## Global Constraints

- Binding: `docs/plans/audits/2026-07-10-c6-zh-web-audit.md` §1 (mechanism reference) + the C6 ledger adjudications. The B4 lesson binds: any future title-localization twin must use the `tmdb_`/`tv_` ALLOWLIST guard (not an `ol_` denylist).
- Scope: UI-chrome localization + locale plumbing. The **localized-title display twin** (web's `useLocalizedItems` re-titling of DB rows) is EXPLICITLY DEFERRED — content titles already arrive localized from live TMDB fetches; shelf/feed re-titling is its own feature (ledgered, owner question).
- The persisted-title contract pin is untouched (display-only localization; persisted titles stay default-locale on re-rank paths).
- String extraction ONLY in the sweep task — zero logic/flow changes; the em-dash/voice rules enforced by a parity test like web's.
- Tests `swift test --package-path ios/Spool` green each task; conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; dated headers bumped.

---

### Task 1: LocaleStore + L10n table mechanism + parity test

**Files:** Create `ios/Spool/Sources/Spool/Services/LocaleStore.swift` (UserDefaults key e.g. `spool_locale`; `current: SpoolLocale` [.en/.zh]; DEFAULT = device preferred language zh→.zh else .en, persisted on first read so the default is stable; change notification for SwiftUI [ObservableObject singleton or a @AppStorage-friendly raw string — pick the repo-idiomatic shape]), `ios/Spool/Sources/Spool/L10n/L10n.swift` (the `t(_ key:)` seam reading LocaleStore; zh→en→key fallback exactly like web), `ios/Spool/Sources/Spool/L10n/EN.swift` + `ZH.swift` (tables — START EMPTY-ish: Task 3 populates; seed with ~10 keys to prove the mechanism); Test `L10nParityTests.swift` (bidirectional keys, non-empty, no em-dash in zh, placeholder-set parity — port web's i18nParity semantics).
- Commit `feat(ios): LocaleStore + L10n string tables with parity test`.

### Task 2: Locale plumbing + Settings toggle

**Files:** Modify `ios/Spool/Sources/Spool/Services/TMDBService.swift` (`locale()` re-sources from LocaleStore — the ledgered Part-B note), `SuggestionsClient.swift` (same — kill the duplicated device-read), `SettingsScreen.swift` (a language row: EN/中文 segmented or menu, writing LocaleStore; the screen's existing row idiom); Tests: locale mapping (store .zh → "zh-CN" both clients), toggle persistence.
- Content behavior note (test-pinned): device-zh users' TMDB locale is UNCHANGED by default (store defaults to device); an en-device user toggling zh switches content locale live.
- Commit `feat(ios): locale re-sourced from LocaleStore; Settings language toggle`.

### Task 3: The sweep — wire iOS copy through t()

**Files:** The screens (FeedScreen, StubsScreen + journal views, WatchlistScreen, DiscoverScreen, FullListScreen, RankEntryScreen + ceremony screens, SettingsScreen, ProfileScreen, SignInSheet, onboarding screens, toasts/menus) + `EN.swift`/`ZH.swift` population.
- USER-VISIBLE copy only (debug/NSLog strings stay EN); string extraction ONLY — the reviewer diffs for drift.
- zh values: reuse web's zh VERBATIM where the en matches a web key (cite the web key in a comment when reused); new zh for iOS-only strings follows the register + voice rules. The full new-zh table is owner-reviewable (PR body).
- The lowercase hand-voice aesthetic: zh has no case — match web's zh register (which already answers this).
- Sub-stage the sweep by screen group; run the parity test + `swift build` continuously.
- Commit `feat(ios): app copy wired through L10n — zh ships (owner-reviewable table)`.

### Task 4: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C6 COMPLETE both halves; deferred: localized-title display twin [owner question], Landing/Auth web toggle tail, zh font/typography check result [SpoolFonts are Latin-only — record what zh renders with and whether it's acceptable or a design-cycle item]); `docs/contracts/shared-payloads.md` only if a locale-related contract line is stale.
- Commit `docs: C6 complete — zh on both platforms`.

## Self-Review Notes
- Task 3 is the bulk; its reviewer must sample for behavior drift exactly like C6-web's T2 (where the sweep hid a real regression).
- zh typography: SpoolFonts' Latin-only faces mean zh falls back to system fonts — Task 4 RECORDS the rendering verdict; fixing typography is design-cycle scope.
- Device smoke owed: toggle zh in Settings → chrome flips live, TMDB content follows, relaunch persists.
