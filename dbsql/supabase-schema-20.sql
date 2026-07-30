-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 20
--
--   the policies that let a browser write anything
--
-- Run after 19. Idempotent and safe to re-run.
-- ═══════════════════════════════════════════════════════════════════


-- ── what this fixes ───────────────────────────────────────────────
--     42501: new row violates row-level security policy
--            for table "attendances"
--
-- Row level security is enabled on attendances, and NO insert policy
-- matches. When that happens Postgres refuses every write — the default
-- with RLS on is deny, so a table with no policies is a table nobody
-- can write to.
--
-- The policies were only ever created in schema 4. If that file was not
-- run on this project, or was run before the table was recreated, they
-- are simply absent. Nothing later ever recreated them.
--
-- This file is self-contained: it does not assume schema 4 ran, and it
-- can be run repeatedly.


-- ── attendances ───────────────────────────────────────────────────
alter table public.attendances enable row level security;

drop policy if exists "anyone may mark going" on public.attendances;
create policy "anyone may mark going"
  on public.attendances for insert to anon
  with check (status in ('going', 'cancelled'));

/* The upsert path needs this. INSERT ... ON CONFLICT DO UPDATE checks
   the UPDATE policy against the row already there, so without it a
   SECOND tap on the same event fails even when the first succeeded —
   which looks like the toggle working once and then breaking. */
drop policy if exists "anyone may change their own going" on public.attendances;
create policy "anyone may change their own going"
  on public.attendances for update to anon
  using (status in ('going', 'cancelled', 'attended'))
  with check (status in ('going', 'cancelled'));

/* Deliberately NO select policy. Counts come from SECURITY DEFINER
   functions that return integers, so nobody can list who is going —
   that is the line between a social signal and a social network. The
   SELECT grant from schema 19 is a different thing: it lets the upsert
   read the conflicting row, while this absent policy still hides every
   row from anyone asking directly. */


-- ── events ────────────────────────────────────────────────────────
-- Same treatment, same reason: if schema 4 never ran here, publishing
-- would be refused too.
alter table public.events enable row level security;

drop policy if exists "events are public" on public.events;
create policy "events are public"
  on public.events for select to anon
  using (status = 'live');

drop policy if exists "anyone may publish a well formed event" on public.events;
create policy "anyone may publish a well formed event"
  on public.events for insert to anon
  with check (
    length(title) between 1 and 200
    and (description is null or length(description) <= 2000)
    and (venue_name is null or length(venue_name) <= 200)
    and starts_at > now() - interval '90 days'      -- backfill, schema 13
    and starts_at < now() + interval '2 years'
    and (ends_at is null or ends_at > starts_at)
    and price_value >= 0 and price_value <= 10000000
    and (capacity is null or (capacity > 0 and capacity <= 100000))
    and ((venue_lat is null and venue_lng is null)
      or (venue_lat between -90 and 90 and venue_lng between -180 and 180))
    and status = 'live'
  );


-- ── users ─────────────────────────────────────────────────────────
alter table public.users enable row level security;

drop policy if exists "handles are readable" on public.users;
create policy "handles are readable"
  on public.users for select to anon using (true);

drop policy if exists "anyone may claim a handle" on public.users;
create policy "anyone may claim a handle"
  on public.users for insert to anon
  with check (
    handle ~ '^[a-z]{3,5} [a-z]{3,5}$'
    and public_key is null
  );


-- ── venues ────────────────────────────────────────────────────────
alter table public.venues enable row level security;

drop policy if exists "venues are public" on public.venues;
create policy "venues are public"
  on public.venues for select to anon using (true);

drop policy if exists "anyone may add a venue" on public.venues;
create policy "anyone may add a venue"
  on public.venues for insert to anon
  with check (
    length(name) between 1 and 200
    and lat between -90 and 90
    and lng between -180 and 180
    and source in ('manual', 'photo', 'osm')       -- schema 16
    and (source <> 'osm' or (source_id is not null and length(source_id) between 3 and 64))
  );


-- ── communities ───────────────────────────────────────────────────
alter table public.communities enable row level security;

drop policy if exists "communities are public" on public.communities;
create policy "communities are public"
  on public.communities for select to anon using (true);

-- No insert policy, on purpose: ensure_community() is SECURITY DEFINER
-- and is the only way a community is created.


-- ── did it work ───────────────────────────────────────────────────
-- Run this on its own afterwards. attendances must show BOTH an INSERT
-- and an UPDATE policy, and no SELECT policy.
--
--   select tablename, policyname, cmd
--     from pg_policies where schemaname = 'public'
--    order by tablename, cmd;
--
-- Prove the write as anon, with real ids from your own tables:
--
--   set local role anon;
--   insert into public.attendances (event_id, user_id, status)
--   values ('<event uuid>', '<user uuid>', 'going')
--   on conflict (event_id, user_id) do update set status = 'going';
--   reset role;
--
-- If that succeeds, the going button will work.
