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

---

# `tmdb-proxy` — Controller Verification Probes (Task 2)

Post-deploy probes for the `tmdb-proxy` edge function. Same deploy/merge flow:
the controller deploys via MCP (`deploy_edge_function` name="tmdb-proxy") **before
merge**, runs these probes, then merges. Implementers never deploy. Secret
dependency: `TMDB_API_KEY` (shared with the `suggestions` function; already set
in the function store). The proxy covers everything the client still hits TMDB
for directly (search / details / person / season / discover / trending /
now_playing / upcoming, audit §2.4); after this branch the key lives only in the
function secret store.

Endpoint: `GET {SUPABASE_URL}/functions/v1/tmdb-proxy?path=<tmdb path + query>`
Auth: `Authorization: Bearer <user JWT>` + `apikey: <anon>` (mirrors `suggestions`).
The `path` value is the bare TMDB path plus its query string, URL-encoded as one
`path=` parameter (the function splits path from query, allowlist-checks the path
without decoding, and strips the query to a safelist before injecting `api_key`).

## Probe checklist

| # | Probe | Request | Expect |
|---|---|---|---|
| P1 | **Allowlisted 200 w/ real JSON (key works)** | `GET ?path=search/movie?query=matrix` (auth) | `200`; body is TMDB JSON with a **non-empty `results` array** (proves `TMDB_API_KEY` is injected and resolving — the client never sends a key) |
| P1b | **Details + restricted append_to_response 200** | `GET ?path=movie/603?append_to_response=watch/providers,credits` | `200`; body includes `credits` and `watch/providers` sub-objects |
| P1c | **Trending / discover 200** | `GET ?path=trending/movie/week` and `GET ?path=discover/movie?sort_by=popularity.desc&vote_count.gte=100` | `200`; non-empty `results` |
| P2 | **Non-allowlisted 403 (generic, no echo)** | `GET ?path=configuration` and `GET ?path=account` | `403 { error: "Path not allowed" }`; body **never contains the attempted path** |
| P2b | **Non-allowlisted sub-resource 403** | `GET ?path=movie/603/account_states`, `GET ?path=tv/1399/credits`, `GET ?path=person/287/tv_credits` | `403 { error: "Path not allowed" }` |
| P3 | **Traversal rejected** | `?path=../3/account`, `?path=movie/603/../../account`, `?path=movie/603%2F..%2F..`, `?path=movie/603%2Faccount` (encoded slash), `?path=https://api.themoviedb.org/3/account` (absolute URL), `?path=//evil.com/movie/603` | each `403 { error: "Path not allowed" }`; no upstream call is made with the smuggled path |
| P4 | **api_key strip (client sends `api_key=evil`)** | `GET ?path=search/movie?query=matrix&api_key=evil-key-123` | `200` with real results — proves the client-supplied `api_key` is dropped and the **secret** is injected instead (an `evil` key would 401 at TMDB → 502). Non-empty `results` = strip worked |
| P4b | **Unknown param strip** | `GET ?path=search/movie?query=matrix&session_id=x&callback=y` | `200`; unknown params silently dropped (no JSONP, no session leakage) |
| P5 | **401 no JWT** | `GET ?path=search/movie?query=matrix` with no `Authorization` header | `401` (assert status only — the platform gateway may 401 before function code when `verify_jwt` is on) |
| P5b | **401 bad JWT** | `Authorization: Bearer garbage` | `401 { error: "Invalid or expired token" }` |
| P6 | **405 POST** | `POST /functions/v1/tmdb-proxy?path=search/movie?query=matrix` (auth) | `405 { error: "Method not allowed" }` |
| P7 | **Missing path 400** | `GET /functions/v1/tmdb-proxy` (auth, no `path`) | `400 { error: "Missing path parameter" }` |
| P8 | **Token-bucket 429** | Fire **31+ GETs within 60 s** for the same user against a warm isolate | at least one `429 { error: "Rate limit exceeded" }` (limit 30/min per isolate; per-isolate in-memory, so a cold isolate resets it) |
| P9 | **Upstream 502 (masking / timeout)** | Best-effort: any TMDB non-2xx (e.g. force a bad upstream) or a request that exceeds the 5s timeout | `502 { error: "upstream error" }`; the TMDB response body is **never echoed**. A missing `TMDB_API_KEY` env var 500s (caught by the outer try/catch) |

## Notes for the controller

- **Secret probe requires non-empty `results`:** P1 / P1c with `results.length > 0`
  confirms `TMDB_API_KEY` is present and valid. P4 is the load-bearing strip check —
  it sends a bogus `api_key`; a 200 with real results proves the function replaced it
  with the secret (had the bogus key leaked through, TMDB would 401 → the proxy would
  return 502).
- **403 never echoes the path:** the body is exactly `{ "error": "Path not allowed" }`
  for every non-allowlisted / traversal case. Confirm the attempted path string does
  not appear anywhere in the response.
- **No decoding before allowlist:** the path segment is matched against anchored regexes
  with no prior percent-decoding, so `%2f` / `%2e%2e` / `%5c` can never resolve into a
  real slash or `..`. `allowPath` also rejects any `%`, `\`, `://`, leading `//`, `?`,
  `#`, or whitespace outright.
- **5s upstream timeout:** the fetch aborts at 5000 ms; an abort or network error yields
  `502 { error: "upstream error" }`, never a stack trace or TMDB body.
- **Rollback:** delete the function (MCP `delete_edge_function` name="tmdb-proxy" or
  `supabase functions delete tmdb-proxy`). Old clients don't call it, so deletion is
  safe until the client migration (Tasks 3+5) lands.
