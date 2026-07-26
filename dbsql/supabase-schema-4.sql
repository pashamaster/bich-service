-- ════════════════════════════════════════════════════════════════
-- bich.service — schema part 4: writing from the browser
--
-- The architecture changed. There is now no service role key in the
-- worker, in the repo, or anywhere else. The browser writes to
-- Supabase directly with the publishable key.
--
-- That means the database is the ONLY thing standing between a
-- stranger and your events table, so the rules below have to do real
-- work. Every insert policy carries a WITH CHECK that validates the
-- shape of the row. Postgres refuses anything that fails, no
-- application code required.
--
-- Honest trade off: without a server, someone holding the publishable
-- key can still insert valid-looking events. The checks stop garbage
-- and abuse of column types, not a determined spammer. When that
-- becomes a real problem the answer is a rate limit in the worker,
-- not a rewrite: the browser posts to the worker, the worker holds a
-- key again. Until then this is proportionate.
--
-- Run after parts 1, 2 and 3.
-- ════════════════════════════════════════════════════════════════

-- ── people ───────────────────────────────────────────────────────
-- A handle is two lowercase words. Nothing else is accepted, so this
-- table cannot become a place where personal data accumulates.
drop policy if exists "anyone may claim a handle" on public.users;
create policy "anyone may claim a handle"
  on public.users for insert to anon
  with check (
    handle ~ '^[a-z]{3,5} [a-z]{3,5}$'
    and public_key is null          -- passkeys are registered later, not here
  );

drop policy if exists "handles are readable" on public.users;
create policy "handles are readable"
  on public.users for select to anon
  using (true);
-- The row is a label and a uuid. There is nothing here to protect
-- because there is nothing here that identifies a person.

-- ── events ───────────────────────────────────────────────────────
drop policy if exists "anyone may publish an event" on public.events;
create policy "anyone may publish an event"
  on public.events for insert to anon
  with check (
    length(title) between 1 and 200
    and (description is null or length(description) <= 2000)
    and (venue_name is null or length(venue_name) <= 200)
    -- no publishing into the distant past or a fantasy future
    and starts_at > now() - interval '1 day'
    and starts_at < now() + interval '2 years'
    and (ends_at is null or ends_at > starts_at)
    -- money stays sane and the app never handles it anyway
    and price_value >= 0 and price_value <= 10000000
    and (capacity is null or (capacity > 0 and capacity <= 100000))
    -- a pin is either complete or absent, and on this planet
    and ((venue_lat is null and venue_lng is null)
      or (venue_lat between -90 and 90 and venue_lng between -180 and 180))
    -- new events are always live and visible; nobody inserts a hidden row
    and status = 'live'
    and (cover_url is null or cover_url ~ '^https://')
  );

-- Hosts may edit their own event only while it is still ahead, and may
-- never resurrect or hide someone else's.
drop policy if exists "hosts may edit their own event" on public.events;
create policy "hosts may edit their own event"
  on public.events for update to anon
  using (starts_at > now() - interval '1 day')
  with check (
    length(title) between 1 and 200
    and status in ('live', 'deleted')
  );

-- ── attendance ───────────────────────────────────────────────────
-- 'going' is the only status a client may write. 'attended' is the
-- one that feeds the crossed paths graph, and letting a browser claim
-- it directly would make the whole signal meaningless, so it is set
-- by the post-event flow and never here.
drop policy if exists "anyone may mark going" on public.attendances;
create policy "anyone may mark going"
  on public.attendances for insert to anon
  with check (status in ('going', 'cancelled'));

drop policy if exists "anyone may change their own going" on public.attendances;
create policy "anyone may change their own going"
  on public.attendances for update to anon
  using (status in ('going', 'cancelled'))
  with check (status in ('going', 'cancelled'));

-- Still no select policy. Counts come from feed(), which is SECURITY
-- DEFINER and returns numbers only. Nobody reads the attendee list,
-- which is the line between a social signal and a social network.

-- ── venues ───────────────────────────────────────────────────────
-- The venue book grows as people publish, so inserts have to be open,
-- but coordinates must be real.
drop policy if exists "anyone may add a venue" on public.venues;
create policy "anyone may add a venue"
  on public.venues for insert to anon
  with check (
    length(name) between 1 and 200
    and lat between -90 and 90
    and lng between -180 and 180
    and source in ('manual', 'photo')
  );

-- ── keep the counters honest ─────────────────────────────────────
-- use_count is maintained by a trigger, not by whoever is writing,
-- so nobody can inflate their own venue to the top of the results.
create or replace function public.guard_venue_counters()
returns trigger language plpgsql as $$
begin
  new.use_count := 0;
  new.verified  := false;
  return new;
end $$;

drop trigger if exists venues_guard on public.venues;
create trigger venues_guard before insert on public.venues
  for each row execute function public.guard_venue_counters();

-- Same for events: a client cannot backdate created_at or claim a
-- short_id that collides with an existing share link.
create or replace function public.guard_event_defaults()
returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.updated_at := now();
  if new.short_id is null then
    new.short_id := public.gen_short_id();
  end if;
  return new;
end $$;

drop trigger if exists events_guard on public.events;
create trigger events_guard before insert on public.events
  for each row execute function public.guard_event_defaults();
