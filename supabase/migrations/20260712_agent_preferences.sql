-- Agent preferences — Chris's "daily reel" cadence (P1 M2b follow-on).
--
-- Chris (Spool's iMessage movie friend) can send a short morning newsletter of
-- movie-industry news in his voice. This table holds each user's control over
-- that reel: cadence (daily / weekly / off), the local delivery hour, and the
-- timezone the hour is interpreted in. Users set it from the app AND the website.
--
-- Direct table under RLS (own-row), no RPC: the app upserts on user_id with the
-- authenticated client, exactly like profiles. The agent (Chris's side) reads it
-- with the service role from its own scheduler; that access is NOT granted here
-- (service role bypasses RLS). No anon access — a signed-out caller has no row.
--
-- This file is the repo RECORD of the DDL already applied + RLS-probed in prod.
--
-- Header last reviewed: 2026-07-12

create table if not exists public.agent_preferences (
  user_id             uuid primary key references auth.users(id) on delete cascade,
  trade_digest_cadence text not null default 'daily'
                        check (trade_digest_cadence in ('daily', 'weekly', 'off')),
  digest_hour         int not null default 9
                        check (digest_hour >= 0 and digest_hour <= 23),
  timezone            text not null default 'America/Los_Angeles',
  updated_at          timestamptz not null default now()
);

alter table public.agent_preferences enable row level security;

-- Own-row select/insert/update for authenticated users. No delete policy: a row
-- is upserted and edited in place, never removed by the client (the cascade from
-- auth.users handles account deletion).
create policy "agent_preferences own row select"
  on public.agent_preferences for select
  to authenticated
  using (auth.uid() = user_id);

create policy "agent_preferences own row insert"
  on public.agent_preferences for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "agent_preferences own row update"
  on public.agent_preferences for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select, insert, update on public.agent_preferences to authenticated;

-- ROLLBACK (verbatim):
--   drop table if exists public.agent_preferences;
