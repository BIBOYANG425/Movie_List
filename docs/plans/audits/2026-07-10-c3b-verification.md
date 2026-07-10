# C3 Part B — Controller Verification Probes

Post-deploy probes for the `suggestions` edge function (Task 1). The controller
deploys via MCP (`deploy_edge_function` name="suggestions") **before merge**, runs
these probes, then merges. Implementers never deploy. Secret dependency:
`TMDB_API_KEY` (set by the owner 2026-07-09 in the function store). A live 200 from
any TMDB-backed mode implicitly proves the secret is present.

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
| 4 | **Movie suggestions 200 shape** | `{ "mediaType":"movie","mode":"suggestions","page":1 }` (user with ≥3 movie rankings) | `200`; `items` array, `length ≤ 12`; each item has `id`, `tmdbId`, `title`, `year`, `posterUrl`, `mediaType:"movie"`, `genres`, `overview`, `seasonCount`, **`pool` ∈ {similar,taste,trending,variety,friend,generic,backfill}**; `totalRanked` = the user's ranking count |
| 5 | **TV suggestions 200 shape** | `{ "mediaType":"tv","mode":"suggestions","page":1 }` (user with ≥3 tv rankings) | `200`; `items` ≤ 12; each `id:"tv_{showId}"`, `mediaType:"tv"`, `seasonCount`, `pool` present |
| 6 | **Backfill cap ≤20** | `{ "mediaType":"movie","mode":"backfill","page":1 }` | `200`; `items.length ≤ 20`; items tagged `pool:"backfill"` (or `generic` when the user has no S/A top ids) |
| 7 | **new_releases shape + ascending dates** | `{ "mediaType":"movie","mode":"new_releases","limit":10 }` | `200`; `items.length ≤ 10`; every `pool:"new_release"`; **release dates ascending** — verify by pulling each `tmdbId`'s release_date via TMDB and confirming non-decreasing order; posters all non-null |
| 8 | **Threshold fallback (generic for <3)** | `{ "mediaType":"movie","mode":"suggestions","page":1 }` as a user with **<3** rankings | `200`; items tagged `pool:"generic"`; `totalRanked < 3` |
| 9 | **RLS isolation** | Same request as #4 but as **User B** who follows nobody and has different rankings | `200`; `totalRanked` reflects **User B's** count only; User B never sees User A's exclusions or friend picks (the forwarded-JWT client reads only rows User B's RLS permits). Confirm two distinct users get distinct `totalRanked`. |
| 10 | **Token-bucket 429** | Fire **31+ POSTs within 60 s** for the same user | at least one `429 { error: "Rate limit exceeded" }` (limit 30/min per isolate; note: bucket is per-isolate in-memory, so a cold isolate resets it — run the burst against a warm function) |
| 11 | **Upstream masking (502)** | (Best-effort) if TMDB is unreachable / key wrong, engine returns `502 { error: "TMDB upstream error" }` and **never echoes the upstream body** | on any TMDB failure path, body is exactly `{ "error": "TMDB upstream error" }` |

## Notes for the controller

- **RLS posture (probe 9 is the load-bearing one):** the function builds its Supabase
  client with the *forwarded* user JWT (`global.headers.Authorization`), so every table
  read (`user_rankings`, `watchlist_items`, `tv_rankings`, `tv_watchlist_items`,
  `friend_follows`) runs under the caller's own RLS. No service-role key is used. Two
  users must see disjoint exclusion/friend data.
- **No caching:** each call re-randomizes (page jitter, coin-flip decade, shuffle). Two
  back-to-back identical requests SHOULD generally differ in ordering/content — this is
  the product behavior, not a bug.
- **Secret probe is implicit:** a 200 from probe 4/6/7 means `TMDB_API_KEY` resolved. If
  those return 502 with `{ "error": "TMDB upstream error" }`, check the secret first.
- **B1 exclusion probe (optional):** as a user whose rankings include a bare-numeric
  `tmdb_id` (legacy format), confirm that movie never reappears in suggestions — the
  server normalizes both `tmdb_{n}` and `{n}` forms at the boundary.
- **Rollback:** delete the function (MCP `delete_edge_function` or
  `supabase functions delete suggestions`). Old clients don't call it, so deletion is
  safe until the client migration (Tasks 3-6) lands.
