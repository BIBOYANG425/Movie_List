-- 20260712_agent_showtimes_cards.sql
--
-- Backing table for the /agent-showtimes web card (S2b). The agent (spool-agent)
-- fetches listings, INSERTs one row of the card payload as the authenticated
-- user, and texts the user a link `https://rankspool.com/agent-showtimes#c=<id>`.
-- The web route reads the row with the ANON client — showtimes are public data,
-- so anon SELECT of UNEXPIRED rows is an accepted design decision, not an
-- oversight. Rows self-expire after 24h; expired rows are unreadable by anyone
-- (RLS `using (expires_at > now())`), which drives the friendly "expired" state.

create table public.agent_showtimes_cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);

alter table public.agent_showtimes_cards enable row level security;

create policy "agent_showtimes_cards_insert_own"
  on public.agent_showtimes_cards for insert to authenticated
  with check (auth.uid() = user_id);

create policy "agent_showtimes_cards_select_unexpired"
  on public.agent_showtimes_cards for select to anon, authenticated
  using (expires_at > now());
