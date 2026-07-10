# C3 Part B — Controller Verification Probes

Post-deploy probes for the `suggestions` edge function (Task 1). The controller
deploys via MCP (`deploy_edge_function` name="suggestions") **before merge**, runs
these probes, then merges. Implementers never deploy. Secret dependency:
`TMDB_API_KEY` (set by the owner 2026-07-09 in the function store). A 200 with a
**non-empty `items` array** from any TMDB-backed mode proves the secret is present
and resolving correctly. A 200 with `items: []` may indicate a bad or missing key
(TMDB returns error JSON that `fetchJson` treats as null, so all pools degrade to []).

Endpoint: `POST {SUPABASE_URL}/functions/v1/suggestions`
Auth: `Authorization: Bearer <user JWT>` + `apikey: <anon>` (mirrors journal-agent).

## Probe checklist

| # | Probe | Request | Expect |
|---|---|---|---|
| 1 | **Auth 401 (no JWT)** | POST with no `Authorization` header | `401 { error: "Missing Authorization header" }` |
| 1b | **Auth 401 (bad JWT)** | POST with `Authorization: Bearer garbage` | `401 { error: "Invalid or expired token" }` |
| 2 | **405 GET** | `GET /functions/v1/suggestions` (with auth) | `405 { error: "Method not allowed" }` |
| 3 | **400 bad mediaType** | `{ "mediaType": "book", "mode": "suggestions" }` | `400 { error: 'mediaType must be "movie" or "tv"' }` |
| 3b | **400 bad mode** | `{ "mediaType": "movie", "mode": "explore" }` | `400 { error: 'mode must be "suggestions", "backfill", or "new_releases"' }` |
| 3c | **400 new_releases + tv** | `{ "mediaType": "tv", "mode": "new_releases" }` | `400 { error: 'new_releases mode supports mediaType "movie" only' }` |
| 3d | **400 invalid JSON** | body = `not json` | `400 { error: "Invalid JSON in request body" }` |
| 4 | **Movie suggestions 200 shape** | `{ "mediaType":"movie","mode":"suggestions","page":1 }` (user with ≥3 movie rankings) | `200`; **`items.length > 0`** (non-empty — a seeded user must get results; 200-with-empty = bad-key signal); `length ≤ 12`; each item has `id`, `tmdbId`, `title`, `year`, `posterUrl`, `mediaType:"movie"`, `genres`, `overview`, `seasonCount`, **`pool` ∈ {similar,taste,trending,variety,friend,generic,backfill}**; `totalRanked` = the user's ranking count |
| 5 | **TV suggestions 200 shape** | `{ "mediaType":"tv","mode":"suggestions","page":1 }` (user with ≥3 tv rankings) | `200`; **`items.length > 0`** (non-empty for a seeded user; 200-with-empty = bad-key signal); `items.length ≤ 12`; each `id:"tv_{showId}"`, `mediaType:"tv"`, `seasonCount`, `pool` present |
| 6 | **Backfill cap ≤20** | `{ "mediaType":"movie","mode":"backfill","page":1 }` | `200`; `items.length ≤ 20`; items tagged `pool:"backfill"` (or `generic` when the user has no S/A top ids) |
| 7 | **new_releases shape + ascending dates** | `{ "mediaType":"movie","mode":"new_releases","limit":10 }` (user with ≥3 movie rankings) | `200`; **`items.length > 0`** (non-empty for a seeded user; 200-with-empty = bad-key signal); `items.length ≤ 10`; every `pool:"new_release"`; **release dates ascending** — verify by pulling each `tmdbId`'s release_date via TMDB and confirming non-decreasing order; posters all non-null |
| 8 | **Threshold fallback (generic for <3)** | `{ "mediaType":"movie","mode":"suggestions","page":1 }` as a user with **<3** rankings | `200`; items tagged `pool:"generic"`; `totalRanked < 3` |
| 9 | **RLS isolation** | Same request as #4 but as **User B** who follows nobody and has different rankings | `200`; `totalRanked` reflects **User B's** count only; User B never sees User A's exclusions or friend picks (the forwarded-JWT client reads only rows User B's RLS permits). Confirm two distinct users get distinct `totalRanked`. |
| 10 | **Token-bucket 429** | Fire **31+ POSTs within 60 s** for the same user | at least one `429 { error: "Rate limit exceeded" }` (limit 30/min per isolate; note: bucket is per-isolate in-memory, so a cold isolate resets it — run the burst against a warm function) |
| 11 | **Upstream masking (502)** | (Best-effort) if Supabase DB is transiently unreachable during a data read (`user_rankings` / `watchlist_items` / `tv_rankings` / `tv_watchlist_items`), the function returns `502 { error: "upstream error" }` and **never echoes the upstream body**. A bad/missing TMDB key does NOT produce 502 — `fetchJson` returns null on non-ok responses, so all pools degrade to [] and the response is `200 { items: [] }`. A missing `TMDB_API_KEY` env var 500s (caught by the outer try/catch). | on any DB-read failure path, status is 502 and body is exactly `{ "error": "upstream error" }` |

## Notes for the controller

- **Probe 1 (no JWT) — assert status only:** when `verify_jwt` is enabled on the
  function, the Supabase platform gateway may return the 401 before the function code
  runs, so the body may differ from `{ "error": "Missing Authorization header" }`.
  Assert `status === 401`; do not assert the exact body for this probe.
- **RLS posture (probe 9 is the load-bearing one):** the function builds its Supabase
  client with the *forwarded* user JWT (`global.headers.Authorization`), so every table
  read (`user_rankings`, `watchlist_items`, `tv_rankings`, `tv_watchlist_items`,
  `friend_follows`) runs under the caller's own RLS. No service-role key is used. Two
  users must see disjoint exclusion/friend data.
- **No caching:** each call re-randomizes (page jitter, coin-flip decade, shuffle). Two
  back-to-back identical requests SHOULD generally differ in ordering/content — this is
  the product behavior, not a bug.
- **Secret probe requires non-empty items:** a 200 from probe 4/5/7 with `items.length > 0`
  confirms `TMDB_API_KEY` is present and valid. A 200 with `items: []` for a seeded user
  (≥3 rankings) is the bad-key signal — `fetchJson` returns null on any non-ok TMDB
  response, degrading all pools to []. A 502 from those probes indicates a DB read
  failure (see probe 11). A missing `TMDB_API_KEY` env var yields 500, not 502.
- **B1 exclusion probe (optional):** as a user whose rankings include a bare-numeric
  `tmdb_id` (legacy format), confirm that movie never reappears in suggestions — the
  server normalizes both `tmdb_{n}` and `{n}` forms at the boundary.
- **Rollback:** delete the function (MCP `delete_edge_function` or
  `supabase functions delete suggestions`). Old clients don't call it, so deletion is
  safe until the client migration (Tasks 3-6) lands.
