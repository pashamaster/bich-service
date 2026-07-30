-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 14
--
--   who has visited an event, and what the host is allowed to know
--
-- Run after 13. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── visits ────────────────────────────────────────────────────────
-- "Going" and "visited" are different questions and the app could only
-- answer the first. A host publishing something had no idea whether
-- nobody was interested or nobody had seen it — the same zero either
-- way, with completely different meanings.
--
-- A visit is one person opening the event, deduped. Not a page-hit
-- counter: the same person coming back four times is one interested
-- person, and counting it as four would make the number a lie.

create table if not exists public.event_visits (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.users(id)  on delete cascade,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  seen_count integer not null default 1,
  primary key (event_id, user_id)
);

create index if not exists event_visits_event_idx on public.event_visits (event_id);

alter table public.event_visits enable row level security;

/* No select policy, on purpose, exactly like attendances. Nobody reads
   this table directly — not even the host. Everything comes back
   through SECURITY DEFINER functions that return integers.

   No insert policy either: record_visit() is the only way in, and it
   writes the caller's own row and nothing else. */

create or replace function public.record_visit(p_short_id text, p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_event uuid;
begin
  if p_user is null then return; end if;

  select id into v_event from public.events
   where short_id = p_short_id and status = 'live';
  if not found then return; end if;

  insert into public.event_visits (event_id, user_id)
  values (v_event, p_user)
  on conflict (event_id, user_id) do update
    set last_seen  = now(),
        seen_count = public.event_visits.seen_count + 1;
end $$;

grant execute on function public.record_visit(text, uuid) to anon;


-- ── what the host may know ────────────────────────────────────────
-- Counts, never names. The promise is that nobody reads the attendee
-- list, and "nobody" includes the person who created the event: a host
-- who can see exactly which handles are coming to a six-person dinner
-- knows who each of them is.
--
-- So this returns five integers and no identifiers of any kind.

create or replace function public.event_stats(
  p_short_id text, p_user uuid, p_secret text
)
returns table (
  visitors      integer,   -- distinct people who opened it
  going         integer,   -- currently marked going
  attended      integer,   -- promoted after the event ended
  cancelled     integer,   -- said going, then changed their mind
  repeat_visits integer    -- opened it more than once: real interest
)
language plpgsql stable security definer set search_path = public
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return; end if;

  -- host only. owns_event() checks host_id AND the device secret.
  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  return query
  select
    (select count(*)::integer from public.event_visits v where v.event_id = target.id),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'going'),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'attended'),
    (select count(*)::integer from public.attendances a
      where a.event_id = target.id and a.status = 'cancelled'),
    (select count(*)::integer from public.event_visits v
      where v.event_id = target.id and v.seen_count > 1);
end $$;

grant execute on function public.event_stats(text, uuid, text) to anon;


-- ── my_going, for real this time ──────────────────────────────────
-- This function has existed since schema 5 and nothing has ever called
-- it. That is why the going button reads from localStorage while the
-- count reads from Postgres, with nothing reconciling them — which is
-- how a lit "you're going" button ends up beside a count of zero.
--
-- Redefined with a nullable id list so the app can simply ask "what am
-- I going to?" on launch instead of having to name every event first.

create or replace function public.my_going(p_viewer uuid, p_event_ids text[] default null)
returns table (short_id text, status text)
language sql stable security definer set search_path = public
as $$
  select e.short_id, a.status
  from public.attendances a
  join public.events e on e.id = a.event_id
  where a.user_id = p_viewer
    and a.status in ('going','attended')
    and (p_event_ids is null or e.short_id = any(p_event_ids))
$$;

grant execute on function public.my_going(uuid, text[]) to anon;


-- ── afterwards ────────────────────────────────────────────────────
--   select short_id, title from public.events order by created_at desc limit 5;
--   select * from public.event_stats('<short_id>', '<your uuid>', '<your secret>');
--   select count(*) from public.event_visits;
--   select count(*), status from public.attendances group by status;
