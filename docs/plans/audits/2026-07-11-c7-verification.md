# C7 verification probes — server-side achievement granting (B2/B3)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL
editor (superuser/`postgres` session, which may `SET LOCAL ROLE authenticated`),
AFTER applying:

1. `supabase/migrations/20260711_achievements_server_grant.sql` (drops the
   `WITH CHECK (true)` INSERT policy on `user_achievements`; adds the
   `grant_achievements()` SECURITY DEFINER RPC; verifies the `badge_unlock`
   notification type).

Every write probe is wrapped in `begin; … rollback;` — nothing persists,
including the RPC grants and notification inserts.

> **PROBE-HARNESS RULE (C3-A lesson, learned 2026-07-09):** the jwt claims MUST
> include `"role":"authenticated"`, i.e.
> `set local request.jwt.claims to '{"sub":"<UUID>","role":"authenticated"}';`
> — `auth.role()` and any policy that joins `friend_follows` read the JWT `role`
> claim (NOT the Postgres role). A sub-only claim silently mis-evaluates
> `auth.uid()`/`auth.role()` inside the SECURITY DEFINER body's reads and can
> false-negative a probe. Real app tokens always carry the role claim. See
> `docs/plans/audits/2026-07-09-c3-ios-verification.md:21-28`.

`grant_achievements()` is `SECURITY DEFINER` — it runs as the function owner and
recomputes thresholds from `auth.uid()`'s OWN rows. `auth.uid()` inside the body
resolves from the `sub` claim set below, so the RPC grants to whoever the JWT
identifies, exactly as the app calls it (`supabase.rpc('grant_achievements')`).

---

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick real UUIDs and substitute them into the probes below.

```sql
-- FIXTURE_USER: a real user with ENOUGH rows to earn at least one badge.
-- The most reliable earner is `first_rank` (>= 1 combined ranking). This lists
-- users by combined rank count so you can pick one who will earn several badges.
select u.user_id,
       (select count(*) from user_rankings  where user_id = u.user_id) as movie_ranks,
       (select count(*) from tv_rankings    where user_id = u.user_id) as tv_ranks,
       (select count(*) from book_rankings  where user_id = u.user_id) as book_ranks,
       (select count(*) from journal_entries
          where user_id = u.user_id
            and review_text is not null and btrim(review_text) <> '') as reviews
from (select id as user_id from profiles) u
order by movie_ranks desc
limit 5;
-- Pick FIXTURE_USER := a user_id with movie_ranks >= 1 (guarantees first_rank).

-- SECOND_USER: any other real user, for the cross-user isolation probe (5).
select id as second_user
from profiles
where id <> '<FIXTURE_USER>'
limit 1;

-- Baseline: which badges FIXTURE_USER already holds (so we know which are NEW).
select badge_key from user_achievements where user_id = '<FIXTURE_USER>' order by badge_key;
```

Substitute `<FIXTURE_USER>` and `<SECOND_USER>` into the probes below.

---

## Probe 1 — direct client INSERT is RLS-denied (B2 closed)

The `WITH CHECK (true)` INSERT policy is dropped; there is NO insert path for
authenticated clients. A direct INSERT under an authenticated JWT must fail with
an RLS violation (no policy permits the write).

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FIXTURE_USER>","role":"authenticated"}';

  -- Attempt to self-grant a badge directly (the old abuse path). Even granting to
  -- SELF must be denied now — the only writer is the SECURITY DEFINER RPC.
  insert into user_achievements (user_id, badge_key)
  values ('<FIXTURE_USER>', 'rank_100');
  -- EXPECT: ERROR — new row violates row-level security policy for table
  --         "user_achievements"  (pre-fix this silently succeeded, B2)
rollback;
```

Cross-user variant (the headline B2 abuse) — also denied:

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FIXTURE_USER>","role":"authenticated"}';

  insert into user_achievements (user_id, badge_key)
  values ('<SECOND_USER>', 'rank_100');   -- grant to SOMEONE ELSE
  -- EXPECT: ERROR — RLS denial (pre-fix: minted rank_100 on any user)
rollback;
```

## Probe 2 — RPC grants the earned badges for the fixture user

Calling `grant_achievements()` under FIXTURE_USER's JWT recomputes thresholds
from their own rows and inserts the newly-earned badges, returning their keys.
A user with `movie_ranks >= 1` must at minimum get `first_rank` (if not already
held). The return array = badges granted on THIS call.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FIXTURE_USER>","role":"authenticated"}';

  select grant_achievements() as newly_granted;
  -- EXPECT: a text[] of the badges the user just earned but didn't previously
  --         hold. For a user with >= 1 ranking and no prior badges, this
  --         INCLUDES 'first_rank' (plus rank_10/25/... and taste/social badges
  --         per their actual counts). Compare against the fixture-0 baseline:
  --         every returned key must satisfy its threshold and must NOT have been
  --         in the baseline list.

  -- Rows now exist for the returned keys inside this txn:
  select badge_key from user_achievements
  where user_id = '<FIXTURE_USER>'
  order by badge_key;
  -- EXPECT: baseline set ∪ newly_granted (no other changes)

  -- One badge_unlock notification per NEW grant (D4 first writer):
  select count(*) as new_badge_notifs
  from notifications
  where user_id = '<FIXTURE_USER>'
    and type = 'badge_unlock'
    and created_at >= now() - interval '1 minute';
  -- EXPECT: equals array_length(newly_granted, 1)  (one notif per new badge)
rollback;
```

## Probe 3 — idempotent re-call grants nothing, no dup rows, no dup notifications

Because the whole probe rolls back, call the RPC TWICE inside ONE transaction:
the first call grants, the second must return an EMPTY array and write no rows or
notifications (ON CONFLICT DO NOTHING + return-only-inserted).

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FIXTURE_USER>","role":"authenticated"}';

  select grant_achievements() as first_call;   -- grants the earned set
  select grant_achievements() as second_call;  -- EXPECT: {}  (empty array)

  -- No duplicate rows (PK/unique on (user_id, badge_key) held):
  select badge_key, count(*)
  from user_achievements
  where user_id = '<FIXTURE_USER>'
  group by badge_key
  having count(*) > 1;
  -- EXPECT: 0 rows (no badge appears twice)

  -- No duplicate notifications from the second call: total badge_unlock notifs in
  -- this txn equals the count of NEWLY granted badges (first call only).
  select count(*) as total_badge_notifs
  from notifications
  where user_id = '<FIXTURE_USER>'
    and type = 'badge_unlock'
    and created_at >= now() - interval '1 minute';
  -- EXPECT: equals array_length(first_call, 1)  (second call wrote zero notifs)
rollback;
```

## Probe 4 — cross-user isolation (A's call cannot grant to B)

`grant_achievements()` takes no args and only ever writes for `auth.uid()`. When
FIXTURE_USER calls it, SECOND_USER's badge set is untouched — there is no way for
one user's call to mint a badge on another user.

```sql
begin;
  -- BEFORE: SECOND_USER's badge count
  select count(*) as before_b from user_achievements where user_id = '<SECOND_USER>';

  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<FIXTURE_USER>","role":"authenticated"}';
  perform grant_achievements();  -- FIXTURE_USER grants for THEMSELF

  reset role;  -- back to superuser to read B's count without RLS interference
  select count(*) as after_b from user_achievements where user_id = '<SECOND_USER>';
  -- EXPECT: after_b = before_b  (B unchanged — A's call touched only A's rows)
rollback;
```

## Probe 5 — unauthenticated call RAISEs

With no `sub` claim, `auth.uid()` is NULL and the RPC must raise rather than grant.

```sql
begin;
  set local role authenticated;
  set local request.jwt.claims to '{"role":"authenticated"}';  -- no sub → auth.uid() NULL

  select grant_achievements();
  -- EXPECT: ERROR — grant_achievements: not authenticated
rollback;
```

Also confirm EXECUTE is not public (anon cannot call it):

```sql
select has_function_privilege('anon', 'public.grant_achievements()', 'EXECUTE')       as anon_can,
       has_function_privilege('authenticated', 'public.grant_achievements()', 'EXECUTE') as auth_can;
-- EXPECT: anon_can = false, auth_can = true
```

---

## Pass criteria

| Probe | Expect |
|---|---|
| 1 | direct client INSERT (self AND cross-user) → RLS denial (B2 closed) |
| 2 | RPC returns the earned-but-unheld badge keys; rows appear; one `badge_unlock` notif per new badge |
| 3 | second call in same txn returns `{}`; no duplicate rows; no extra notifications |
| 4 | FIXTURE_USER's call leaves SECOND_USER's badge count unchanged (isolation) |
| 5 | no-sub JWT → RPC RAISEs `not authenticated`; `anon` has no EXECUTE, `authenticated` does |
