# Spool iMessage Companion Agent — Design (owner-approved 2026-07-09)

A standalone iMessage companion for Spool, built by copying the HANA structure
(`/Users/mac/Downloads/HANA-new` — Photon's MIT-licensed, Mastra-based companion
framework). **Build starts after the iOS parity cycles (C5–C7) finish**; this
spec freezes the decisions so the plan can be written then.

## Owner decisions (brainstorm 2026-07-09)

1. **Standalone agent** — own repo, own Photon Spectrum cloud line (new number),
   own persona. george (`~/Code/george`) stays uncoupled; its only conceptual
   contribution is the account-linking handshake.
2. **Framework = HANA structure** — copy the MIT packages (`types`, `core`,
   plugins: `spectrum`, `spontaneous`, `life-sim`, `self-tasks`, `web-search`,
   `url-reader`, `observability`). The Marin/Xia character packages are
   All-Rights-Reserved and are NOT copied; we author our own character package.
3. **Linking: agent-line handshake first, phone login later** — v1 links via a
   6-char code texted to the agent; Supabase phone-OTP login on iOS is deferred
   to the final phase (it is an auth project, not an agent dependency).
4. **Persona depth: full HANA human-sim** — life-sim activity buckets, variable
   response delays, typos, occasional left-on-read, moods. The companion has a
   life; utility latency is an accepted trade.
5. **Data plane: unified into Spool's Supabase** (owner chose over separate
   Postgres) — with the guardrails in §3.
6. **Write scope: FULL** — journal + watchlist + rankings, via the contracts in
   `docs/contracts/shared-payloads.md`. The agent is a third write client.

## §1 Architecture

New repo `spool-agent` (pnpm workspace, turbo, Node 22+, Mastra), bootstrapped
from HANA's MIT framework. Authored surface is exactly three units:

- **`packages/characters/<persona>`** — character card, movie/streaming/theater
  world-info, spontaneous scenario set (`recommendation`, `new_release`,
  `post_watch_checkin`, `hot_take_debate`, `journal_nudge`), observer/reflector/
  re-reach/relationship evaluator prompts tuned to the movie domain. Voice:
  bilingual EN/zh code-switch (HANA's per-user language lock), movie-obsessed
  friend energy. Name decided during character authoring (candidates: Reel,
  Marquee, Spool). Standing voice rules apply (no 不是…而是, no em dashes, no
  negation-contrast).
- **`packages/plugins/spool`** — the domain plugin (§4): TMDB tools + all
  Spool account reads/writes under the shared-payloads contract.
- **`apps/spool-agent`** — `defineConfig` app: character + plugins + Spectrum
  transport + models.

Models (via OpenRouter, swappable in config): agent = Claude Sonnet 4.6,
observer/reflector/re-reach/relationship/life-sim evaluators = Claude Opus 4.6.
No Haiku anywhere (standing owner rule). The in-app Kimi `journal-agent` edge
function is unrelated and untouched.

Everything else — pg-boss pipeline (batch/debounce/read-receipt/generate/send,
cancellation + ghost rollback), three-layer memory + pgvector semantic recall,
response-timing engine, typing simulation, tapbacks, spontaneous scheduler with
3-layer re-reach gating, self-tasks with sweep re-evaluation, blocklist,
injection hardening, debug CLI, dry-run mode — comes from the framework copy
unmodified.

Transport: **Spectrum cloud** (Photon project + dedicated Spool line; env
`SPECTRUM_PROJECT_ID`/`SPECTRUM_PROJECT_SECRET`). Deploy: Railway (george
precedent) + Valkey addon. Observability: Braintrust plugin (optional key).

## §2 Identity & linking

- HANA keys users by phone. **Guest mode** until linked: full personality,
  recs from stated taste, zero account access, organic nudges to link.
- **Handshake**: app Settings → "Text Spool" → 6-char code + prefilled `sms:`
  deep link → user texts code → plugin verifies against `link_codes`
  (single-use, 15-min TTL) → binds phone → `user_id` in `agent_links`.
  Unlink from app settings or by texting the agent. `link_codes` and
  `agent_links` live in the agent-owned `hana` schema (not `public`), created
  by the plugin's migrations.
- **Auth posture (binding):** NO service-role key in the hot path. The plugin
  mints short-lived per-user JWTs (HS256, Supabase JWT secret, `sub` = linked
  user, `role: authenticated`); every Supabase read/write runs under RLS as
  that user, matching the SECURITY INVOKER posture of the whole backend.
  Service role is permitted only for the handshake tables themselves.
- Phone-OTP login (Twilio + iOS/web login UI + existing-account phone linking)
  is **P4** — it upgrades the linking story, it does not gate the agent.

## §3 Data plane (unified Supabase, fenced)

- `DATABASE_URL` = Spool Supabase Postgres, **Supavisor session mode**, hard
  pool cap (agent must never starve the app).
- Mastra/memory tables in dedicated schema `hana`; pg-boss in `hana_boss`;
  pgvector (Supabase-native) for semantic recall. The app never reads agent
  schemas; the agent's PostgREST access goes through RLS like any client.
- `HANA_DRY_RUN` shadow mode + `HANA_BOSS_TIME_ACCEL` stay wired for safe
  testing against prod.
- **Escape hatch (documented, not built):** if agent load ever degrades the
  app, the `hana*` schemas move to a dedicated Postgres via `DATABASE_URL`
  swap — zero code change.

## §4 Feature behaviors

**Journal intake (core loop).** Movie talk → agent converses in character →
saves a journal quick-entry (moods + one-liner) with
`visibility_override = 'private'` by default. Deep conversations get an offered
full write-up (review_text / favorite_moments / personal_takeaway composed from
the actual chat). Contract rules are binding: full-replace 20-column upsert,
probe-before-edit (never wipe an existing row), owner-only takeaway, photo
paths untouched.

**Rankings over text.** Reaction → proposed tier ("instant classic or solid
watch?") → **max two** H2H comparisons against real neighbors from the user's
tier list → write exactly like iOS post-C4: upsert row → `set_tier_order`
splice → stub + `ranking_add`/`ranking_move` event per contract. The
two-comparison cap is a product rule, not a tuning knob.

**Movie timers (no showtimes vendor in v1).**
- Stated plans ("seeing Dune Friday 7pm") → self-task ~3h after → "how was
  it??" → journal intake. This is the "agent reaches out first" behavior.
- **Release radar**: scheduled job checks TMDB release dates against watchlist
  + fresh taste; drops become spontaneous texts. Literal theater showtimes
  (Fandango/SerpAPI-class vendor) is a designed P5 slot-in, out of v1.

**Proactive engine.** Framework spontaneous system + our scenario weights
(evening recs, drop-day alerts, post-movie journal nudges). Re-reach gating
(24–36h, hard stop at 3), quiet hours, `/pause`, hard-block — all inherited.
Taste is computed **fresh from `user_rankings` + journal at generation time**;
the parked `user_taste_profiles` tables stay parked.

**Companion polish (iOS 26).** Tapbacks inherited; Spectrum mini-app cards in
P4 (rank-comparison card, watchlist picker); contact-card + multi-message
greeting onboarding.

## §5 Build phases (each = own plan → subagent execution → reviews)

| Phase | Deliverable | Proves |
|---|---|---|
| P0 | Framework copy, character skeleton, Spectrum line live, guest chat E2E | infra |
| P1 | Handshake linking + read-side plugin (taste/rankings context in chat) | identity |
| P2 | Journal intake + watchlist writes + post-watch self-task check-ins | **the product** |
| P3 | Rankings over text + release radar + proactive tuning | depth |
| P4 | Mini-app cards + iOS 26 polish + phone-OTP login | polish |
| P5 (optional) | Theater showtimes vendor | reach |

## §6 Errors & testing

- pg-boss durable retries + failure audit table (inherited). Rules on top:
  account writes are never silently dropped (failed write → self-task retry +
  in-character acknowledgment); all writes RLS-scoped per-user JWT (no
  cross-account blast radius).
- Tests: plugin contract-marshalling unit tests (repo fixture conventions);
  `HANA_DRY_RUN` shadow mode with a test account; time-accelerated queue tests
  for delay/self-task logic; owner device smoke per phase.
- E2E smoke after any schema change (standing DB rule).

## Deferred / explicitly not chosen

- Phone-OTP login before the agent ships (deferred to P4).
- Separate agent Postgres (owner chose unified; escape hatch documented).
- Theater showtimes vendor in v1 (P5).
- Reusing george's runtime or extracting a shared framework package.
- Copying Marin/Xia character content (license + wrong persona).
