-- 20260718_agent_seat_holds.sql
--
-- Backing table for the /agent-seats web card (seat-hunt). Unlike
-- agent_showtimes_cards (insert-only), a seat hold is MUTABLE: the agent
-- (spool-agent) INSERTs a `hunting` row, then PATCHes it as its headful browser
-- drives AMC checkout (hunting -> held -> awaiting_payment -> paid | expired |
-- failed). The web route reads the row with the ANON client and polls while the
-- status is non-terminal. The payload carries only what the human needs to pay
-- (seats, price, the /orders/{id}/purchase URL, the hold countdown) — never any
-- browser/session secret. Rows self-expire after 24h (anon SELECT is gated on
-- expires_at > now(), which drives the "expired" state).

create table public.agent_seat_holds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'hunting'
    check (status in ('hunting','held','awaiting_payment','paid','expired','failed')),
  payload jsonb not null,
  hold_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);

alter table public.agent_seat_holds enable row level security;

-- The agent writes as the authenticated (linked) user under its minted JWT.
create policy "agent_seat_holds_insert_own"
  on public.agent_seat_holds for insert to authenticated
  with check (auth.uid() = user_id);

create policy "agent_seat_holds_update_own"
  on public.agent_seat_holds for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- The web card reads with the anon client; seats/price/purchase-url are not
-- sensitive and the row id is an unguessable UUID in the URL fragment.
create policy "agent_seat_holds_select_unexpired"
  on public.agent_seat_holds for select to anon, authenticated
  using (expires_at > now());
