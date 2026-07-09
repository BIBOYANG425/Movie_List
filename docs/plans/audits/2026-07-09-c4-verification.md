# C4 verification probes — `set_tier_order` RPC (Task 1)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL editor
(superuser/`postgres` session, which may `SET ROLE authenticated`), AFTER applying:

1. `supabase/migrations/20260709_set_tier_order_rpc.sql` (the positions-only,
   delete-aware tier-order RPC — Q4 adjudication).

Every write probe is wrapped in `begin; … rollback;` — nothing persists (the RPC's
UPDATE, and the fixture INSERTs that seed a clean tier, all roll back). Each probe
sets `local role authenticated` + a `request.jwt.claims` sub so the RPC runs under
`security invoker` with the caller's RLS, exactly as the app calls it.

The probes call the RPC as `select set_tier_order('movie', 'B', array[...]);` — the
`p_media` branch is switchable to `'tv'`/`'book'` to exercise the other two tables
(identical shape).

---

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick real UUIDs and substitute them into the probes below.

```sql
-- OWNER: a real user with several user_rankings rows (so we can carve a test tier).
select user_id, count(*) as ranking_rows
from user_rankings
group by user_id
order by ranking_rows desc
limit 5;

-- OTHER: any DIFFERENT real user id, for the cross-user no-op probe (4).
select user_id
from user_rankings
where user_id <> '<OWNER>'
group by user_id
limit 1;
```

The write probes below SEED their own tier rows inside the transaction (using
tmdb_ids `probe_a`..`probe_d` unlikely to collide) so they are self-contained and
do not depend on the shape of the owner's real data. All of it rolls back.

---

## Probe 1 — reorder happy path (contiguity after)

Seed three rows in tier B in a scrambled order, then set the intended order.
Positions must come back contiguous `0..2` matching the array order.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title) values
    ('<OWNER>', 'probe_a', 'B', 5, 'A'),
    ('<OWNER>', 'probe_b', 'B', 9, 'B'),
    ('<OWNER>', 'probe_c', 'B', 2, 'C');

  -- Intended order: c, a, b
  select set_tier_order('movie', 'B', array['probe_c','probe_a','probe_b']);
  -- EXPECT: 3  (three rows updated)

  select tmdb_id, rank_position
  from user_rankings
  where user_id = '<OWNER>' and tmdb_id in ('probe_a','probe_b','probe_c')
  order by rank_position;
  -- EXPECT exactly:
  --   probe_c | 0
  --   probe_a | 1
  --   probe_b | 2
  -- (contiguous 0..2, no gap, no dup — matches array order)
rollback;
```

## Probe 2 — delete-aware compaction (missing id skipped, survivors compact)

Pass a membership array that names an id with NO matching row. The surviving ids
must still compact to a contiguous `0..k-1` (no gap where the phantom sat).

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title) values
    ('<OWNER>', 'probe_a', 'B', 0, 'A'),
    ('<OWNER>', 'probe_c', 'B', 1, 'C');
  -- NOTE: no probe_b row exists.

  -- Stale membership snapshot still names probe_b (since deleted on another device).
  select set_tier_order('movie', 'B', array['probe_a','probe_b','probe_c']);
  -- EXPECT: 2  (only the two existing rows updated; probe_b skipped, not resurrected)

  select tmdb_id, rank_position
  from user_rankings
  where user_id = '<OWNER>' and tmdb_id in ('probe_a','probe_b','probe_c')
  order by rank_position;
  -- EXPECT exactly:
  --   probe_a | 0
  --   probe_c | 1
  -- (probe_b absent; probe_c compacted to 1, NOT left at 2 — no gap)
rollback;
```

## Probe 3 — cannot resurrect (deleted row stays deleted after stale call)

The classic B6 race: a row is deleted, then a stale-membership reorder arrives that
still lists it. The RPC is UPDATE-only, so it must NOT re-insert the deleted row.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title) values
    ('<OWNER>', 'probe_a', 'B', 0, 'A'),
    ('<OWNER>', 'probe_b', 'B', 1, 'B');

  -- Device A deletes probe_b.
  delete from user_rankings where user_id = '<OWNER>' and tmdb_id = 'probe_b';

  -- Device B (stale snapshot) reorders the tier, still listing probe_b.
  select set_tier_order('movie', 'B', array['probe_b','probe_a']);
  -- EXPECT: 1  (only probe_a exists to update)

  select count(*) as resurrected
  from user_rankings
  where user_id = '<OWNER>' and tmdb_id = 'probe_b';
  -- EXPECT: 0  (probe_b was NOT re-inserted — UPDATE-only cannot resurrect)

  select tmdb_id, rank_position
  from user_rankings
  where user_id = '<OWNER>' and tmdb_id in ('probe_a','probe_b');
  -- EXPECT exactly: probe_a | 0  (contiguous; no phantom probe_b)
rollback;
```

## Probe 4 — cross-user no-op (invoker + RLS: another user's ids untouched)

Under `security invoker`, the RPC runs as OWNER but is handed OTHER's ids. RLS +
the `user_id = auth.uid()` join predicate mean none of OTHER's rows match, so the
update count is 0 and OTHER's positions are unchanged.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  -- OTHER's real rows are NOT visible/writable to OWNER. Feed the RPC some of
  -- OTHER's tmdb_ids (discover a few first, as superuser, before the begin block):
  --   select tmdb_id from user_rankings where user_id = '<OTHER>' limit 3;
  select set_tier_order('movie', 'B', array['<OTHER_ID_1>','<OTHER_ID_2>']);
  -- EXPECT: 0  (OWNER owns none of these ids; the join/RLS match nothing)
rollback;

-- Confirm OTHER's rows are untouched (superuser, no role switch — after the
-- rolled-back probe above; positions must be exactly what they were):
select tmdb_id, rank_position
from user_rankings
where user_id = '<OTHER>'
order by rank_position;
-- EXPECT: OTHER's ordering identical to before (the probe wrote nothing anyway).
```

## Probe 5 — tier-move updates the `tier` column

Rows currently in tier A, listed in a `set_tier_order(..., 'B', ...)` call, must be
re-tiered to B (and repositioned). This is the target-tier half of a cross-tier move.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title) values
    ('<OWNER>', 'probe_a', 'A', 0, 'A'),
    ('<OWNER>', 'probe_b', 'A', 1, 'B');

  -- Move both into tier B (target-tier membership call).
  select set_tier_order('movie', 'B', array['probe_b','probe_a']);
  -- EXPECT: 2

  select tmdb_id, tier, rank_position
  from user_rankings
  where user_id = '<OWNER>' and tmdb_id in ('probe_a','probe_b')
  order by rank_position;
  -- EXPECT exactly:
  --   probe_b | B | 0
  --   probe_a | B | 1
  -- (tier column flipped A -> B; positions recomputed from array order)
rollback;
```

## Probe 6 — unknown `p_media` raises

```sql
select set_tier_order('podcast', 'B', array['x']);
-- EXPECT: ERROR — SQLSTATE 22023, message
--   'set_tier_order: unknown p_media podcast, expected one of movie|tv|book'
-- (no table touched; the branch falls through to RAISE)
```

Empty / NULL membership no-op (bonus assertion — returns 0, writes nothing):

```sql
select set_tier_order('movie', 'B', array[]::text[]);  -- EXPECT: 0
select set_tier_order('movie', 'B', null);             -- EXPECT: 0
```

## Probe 6b — invalid tier fails the table CHECK naturally (no extra guard)

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<OWNER>"}';

  insert into user_rankings (user_id, tmdb_id, tier, rank_position, title)
    values ('<OWNER>', 'probe_a', 'B', 0, 'A');

  select set_tier_order('movie', 'Z', array['probe_a']);
  -- EXPECT: ERROR — new row for relation "user_rankings" violates check
  --         constraint (tier IN ('S','A','B','C','D')). SQLSTATE 23514.
  -- The RPC adds NO tier validation; the table CHECK is the guard.
rollback;
```

---

## Corruption-detection probe (B5 baseline — REPORT counts, do NOT auto-run repair)

Find existing tiers that already violate the position-integrity invariant
(duplicate or gapped `rank_position`) per user, per table. Given B5 (iOS ceremony
inserts mint duplicate positions in prod today), `user_rankings` is EXPECTED to
report `> 0` here. Run once per table (swap the table name); report the counts.

```sql
-- Per (user_id, tier): does the position set match a clean 0..n-1?
-- Reports every corrupt tier. Swap user_rankings -> tv_rankings / book_rankings.
with per_tier as (
  select user_id, tier,
         count(*)                          as n,
         count(distinct rank_position)     as distinct_pos,
         min(rank_position)                as min_pos,
         max(rank_position)                as max_pos
  from user_rankings
  group by user_id, tier
)
select user_id, tier, n, distinct_pos, min_pos, max_pos,
       (distinct_pos <> n)                 as has_duplicate,
       (min_pos <> 0 or max_pos <> n - 1)  as has_gap
from per_tier
where distinct_pos <> n            -- duplicate positions in the tier
   or min_pos <> 0                 -- doesn't start at 0
   or max_pos <> n - 1            -- not contiguous to n-1 (gap)
order by user_id, tier;
-- EXPECT (per B5): user_rankings returns > 0 rows. Record the count and the
--   worst offenders. tv_rankings/book_rankings: report whatever they show.

-- Summary count (one number per table for the ledger):
with per_tier as (
  select user_id, tier,
         count(*) as n,
         count(distinct rank_position) as distinct_pos,
         min(rank_position) as min_pos, max(rank_position) as max_pos
  from user_rankings
  group by user_id, tier
)
select count(*) as corrupt_tiers
from per_tier
where distinct_pos <> n or min_pos <> 0 or max_pos <> n - 1;
```

### Compaction-repair UPDATE (QUOTED — do NOT auto-run; owner/controller decides)

This repairs every corrupt tier in one table by rewriting `rank_position` from a
stable `row_number()` (ties broken by existing position, then `id` for
determinism). It is the server-side equivalent of what `set_tier_order` does per
call. **Do not run it as part of verification** — it is a one-shot data fix the
owner must green-light (it touches every user's rows and bumps `updated_at`, which
`getTrendingAmongFriends` keys on — audit D1). Wrap in `begin; … commit;` only on
explicit owner approval; dry-run under `rollback;` first.

```sql
-- REPAIR (owner-approved only). Swap the table name for tv_rankings/book_rankings.
-- begin;
  with ranked as (
    select id,
           (row_number() over (
              partition by user_id, tier
              order by rank_position, id      -- keep current order; id as tiebreak
            ) - 1) as new_pos
    from user_rankings
  )
  update user_rankings r
     set rank_position = k.new_pos,
         updated_at = now()
    from ranked k
   where r.id = k.id
     and r.rank_position <> k.new_pos;        -- only rewrite rows that actually move
-- rollback;   -- <- dry run
-- commit;     -- <- ONLY on explicit owner approval
```

Note: after this branch merges, corrupt tiers ALSO self-heal on the next
`set_tier_order` write to that tier (any reorder/move/delete/add through the
corrected client paths), so the bulk repair is optional — it just fixes tiers no
one happens to touch. The self-heal is why B5 rides this branch even before the
management UI ships.

---

## Pass criteria

| Probe | Expect |
|---|---|
| 1 reorder happy path | returns `3`; positions `0,1,2` in array order |
| 2 delete-aware compaction | returns `2`; survivors compact `0,1` (no gap for the phantom) |
| 3 cannot resurrect | returns `1`; deleted id count stays `0` (not re-inserted) |
| 4 cross-user no-op | returns `0`; other user's rows unchanged |
| 5 tier-move | returns `2`; `tier` flipped to target; positions recomputed |
| 6 unknown p_media | ERROR SQLSTATE `22023` |
| 6 (bonus) empty/NULL array | returns `0`; nothing written |
| 6b invalid tier | ERROR SQLSTATE `23514` (table CHECK, no RPC guard) |
| corruption-detection | `user_rankings` corrupt_tiers `> 0` per B5 — report the number |
