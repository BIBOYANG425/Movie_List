# C1 RLS verification probes (B2 + B3)

Run by the controller against prod (project `emulyralduiitxuigboj`) in the SQL editor
(superuser/`postgres` session, which may `SET ROLE authenticated`), AFTER applying:

1. `supabase/migrations/20260707_explore_visibility_rls.sql`
2. `supabase/migrations/20260707_reactions_comments_explore_rls.sql`

Every probe is wrapped in `begin; … rollback;` — nothing persists, including the
insert probes. Probe 4 is the pre-fix baseline; capture it BEFORE applying the
migrations if possible (if the migrations are already applied, its stated pre-fix
expectations serve as the comparison record).

## 0. Fixture discovery (run as-is, no role switch — RLS bypassed)

Pick real UUIDs and substitute them into the probes below.

```sql
-- VIEWER: any real user (use your own account's auth.users id).
select id as viewer_id, username from profiles limit 10;

-- FRIENDS_ACTOR: a 'friends'-visibility profile with explore-type events,
-- NOT followed by VIEWER and not VIEWER themself.
select p.id as friends_actor_id, p.username, count(e.id) as events
from profiles p
join activity_events e on e.actor_id = p.id
where p.profile_visibility = 'friends'
  and e.event_type in ('ranking_add','review','list_create','milestone')
  and p.id <> '<VIEWER>'
  and not exists (select 1 from friend_follows f
                  where f.follower_id = '<VIEWER>' and f.following_id = p.id)
group by p.id, p.username
order by events desc limit 5;

-- PUBLIC_ACTOR: same shape but profile_visibility = 'public' (also not followed
-- by VIEWER, so the public branch — not the follower branch — is what grants).
select p.id as public_actor_id, p.username, count(e.id) as events
from profiles p
join activity_events e on e.actor_id = p.id
where p.profile_visibility = 'public'
  and e.event_type in ('ranking_add','review','list_create','milestone')
  and p.id <> '<VIEWER>'
  and not exists (select 1 from friend_follows f
                  where f.follower_id = '<VIEWER>' and f.following_id = p.id)
group by p.id, p.username
order by events desc limit 5;

-- PUBLIC_EVENT_ID: one explore-type event by PUBLIC_ACTOR (for insert probes).
select id as public_event_id, event_type from activity_events
where actor_id = '<PUBLIC_ACTOR>'
  and event_type in ('ranking_add','review','list_create','milestone')
limit 1;

-- FOLLOWED_ACTOR: someone VIEWER follows whose visibility is NOT 'public'
-- (proves the follower branch works independently of visibility).
select p.id as followed_actor_id, p.username, p.profile_visibility,
       count(e.id) as events
from friend_follows f
join profiles p on p.id = f.following_id
join activity_events e on e.actor_id = p.id
where f.follower_id = '<VIEWER>'
  and p.profile_visibility <> 'public'
group by p.id, p.username, p.profile_visibility
order by events desc limit 5;
```

If prod has no user matching a slot (e.g. no non-followed public actor with
events), temporarily flip a test account's `profile_visibility` for the probe
run and flip it back afterwards; note it in the run log.

## 1. Leak probe (B2) — non-follower reads a 'friends'-visibility user's events

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select id, event_type, media_title
from activity_events
where actor_id = '<FRIENDS_ACTOR>';
rollback;
```

**Expected (post-fix): 0 rows.** Pre-fix this returned all of FRIENDS_ACTOR's
`ranking_add`/`review`/`list_create`/`milestone` rows — the B2 leak.

## 2. Public probe — non-follower reads a 'public'-visibility user's events

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select id, event_type, media_title
from activity_events
where actor_id = '<PUBLIC_ACTOR>';
rollback;
```

**Expected: ≥1 row(s)**, and every returned `event_type` is one of
`ranking_add`/`review`/`list_create`/`milestone`. A stranger must NOT see
`ranking_move`/`ranking_remove` rows even from a public actor (the event-type
scope of the original explore policy is deliberately retained):

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select id, event_type
from activity_events
where actor_id = '<PUBLIC_ACTOR>'
  and event_type in ('ranking_move','ranking_remove');
rollback;
```

**Expected: 0 rows.**

## 3. Reaction insert on a public actor's event (B3) — succeeds

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
insert into activity_reactions (event_id, user_id, reaction)
values ('<PUBLIC_EVENT_ID>', '<VIEWER>', 'love');
rollback;
```

**Expected: `INSERT 0 1` (success), then rolled back.** Pre-fix this failed
with `42501 new row violates row-level security policy`.

Comment insert on the same event (same B3 policy shape):

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
insert into activity_comments (event_id, user_id, body)
values ('<PUBLIC_EVENT_ID>', '<VIEWER>', 'rls verification probe');
rollback;
```

**Expected: `INSERT 0 1` (success), then rolled back.**

## 4. Pre-fix failing case (baseline for comparison)

Run BEFORE applying the migrations if possible. This is the user-visible B3
symptom: engagement counts read as 0 on explore cards from non-followed actors.

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select count(*) as visible_reactions
from activity_reactions
where event_id = '<PUBLIC_EVENT_ID>';
select count(*) as visible_comments
from activity_comments
where event_id = '<PUBLIC_EVENT_ID>';
rollback;
```

**Pre-fix expected: both counts are 0 regardless of actual rows** (the phase-2
policies only admitted own/followed events).
**Post-fix expected: counts equal the true row counts** — verify against the
RLS-bypassed truth:

```sql
select
  (select count(*) from activity_reactions where event_id = '<PUBLIC_EVENT_ID>') as true_reactions,
  (select count(*) from activity_comments  where event_id = '<PUBLIC_EVENT_ID>') as true_comments;
```

## 5. Friends-tab regression probe — follower still sees followed user's events

Visibility must NOT gate the follower relationship: a follower sees a followed
user's events (all types, including `ranking_move`) even when that user's
`profile_visibility` is `'friends'` or `'private'`.

```sql
begin;
set local role authenticated;
set local request.jwt.claims to '{"sub":"<VIEWER>"}';
select id, event_type, media_title
from activity_events
where actor_id = '<FOLLOWED_ACTOR>';
rollback;
```

**Expected: all of FOLLOWED_ACTOR's event rows** (row count matches the
RLS-bypassed `select count(*) from activity_events where actor_id =
'<FOLLOWED_ACTOR>'`), identical pre- and post-fix.

## 6. Policy inventory check

```sql
select tablename, policyname, cmd
from pg_policies
where tablename in ('activity_events','activity_reactions','activity_comments')
order by tablename, policyname;
```

**Expected:**
- `activity_events`: `Users can read own, followed, and public-profile activity events` (SELECT) present; `Authenticated users can read public activity events` GONE; phase-2 `Users can view own and followed activity events` (SELECT) and `Users can insert own activity events` (INSERT) unchanged.
- `activity_reactions`: `Users can view reactions on visible events` (SELECT), `Users can insert own reactions on visible events` (INSERT), `Users can delete own reactions` (DELETE) — no UPDATE policy.
- `activity_comments`: `Users can view comments on visible events` (SELECT), `Users can insert own comments on visible events` (INSERT), `Users can delete own comments` (DELETE) — no UPDATE policy.
