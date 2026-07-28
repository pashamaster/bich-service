-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 13
--
--   1. an event belongs to a PERSON, not to whoever holds a secret
--   2. events may be created up to 90 days in the past
--   3. every field is editable, including pin, cover and category
--   4. fields the app needs and the model did not have
--
-- Run after 12. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── 1. ownership moves from the event to the person ───────────────
-- Until now every event carried its own random edit_token. The browser
-- kept the plaintext, the database kept a hash. Lose the browser
-- storage and you lose the ability to edit or cancel your own events
-- FOREVER — there was no recovery path, and "cancel event" fails
-- outright whenever the token has gone.
--
-- One secret per person replaces one secret per event. It is generated
-- once, on the device, and hashed here. Everything that person has ever
-- published is editable with it, and when passkeys land it is the only
-- value that has to be restored to give someone their whole history
-- back.
--
-- Why a secret at all rather than just the uuid: users.id is readable
-- by anon (the handle list is public), so a bare uuid would let anyone
-- who can list users edit anyone's events.

alter table public.users
  add column if not exists device_secret_hash text;

-- Attaches a secret to an account, once. Refuses to overwrite one that
-- already exists, so a second device cannot silently take over an
-- account by claiming it — that path needs a passkey, not a guess.
create or replace function public.claim_device_secret(p_user uuid, p_secret text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare existing text;
begin
  if p_secret is null or length(p_secret) < 24 then
    raise exception 'secret too short' using errcode = '22023';
  end if;

  select device_secret_hash into existing from public.users where id = p_user;
  if not found then return false; end if;

  if existing is not null then
    -- already claimed: succeed only if it is the same secret
    return existing = encode(digest(p_secret, 'sha256'), 'hex');
  end if;

  update public.users
     set device_secret_hash = encode(digest(p_secret, 'sha256'), 'hex')
   where id = p_user;
  return true;
end $$;

grant execute on function public.claim_device_secret(uuid, text) to anon;

create or replace function public.owns_event(p_event public.events, p_user uuid, p_secret text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare want text;
begin
  if p_user is null or p_secret is null then return false; end if;
  if p_event.host_id is distinct from p_user then return false; end if;
  select device_secret_hash into want from public.users where id = p_user;
  return want is not null and want = encode(digest(p_secret, 'sha256'), 'hex');
end $$;


-- ── 2 + 3. edit anything, including the past ──────────────────────
-- The old update_event refused any event whose start was more than a
-- day ago, and could not patch category or community_slug at all. The
-- app is also expected to accept events up to 90 days in the past, for
-- backfilling and for testing the community graph with real history.

create or replace function public.update_event_as(
  p_short_id text,
  p_user     uuid,
  p_secret   text,
  p_patch    jsonb
)
returns public.events_public
language plpgsql security definer set search_path = public
as $$
declare
  target    public.events;
  result    public.events_public;
  going_now int;
  new_start timestamptz;
begin
  select * into target from public.events
   where short_id = p_short_id and status <> 'deleted';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours to edit' using errcode = '42501';
  end if;

  /* No "that event is over" guard. A past event is still yours, and
     fixing a typo on last week's gathering harms nobody. */

  new_start := coalesce((p_patch->>'starts_at')::timestamptz, target.starts_at);
  if new_start < now() - interval '90 days' then
    raise exception 'events may not be moved more than 90 days into the past'
      using errcode = '22023';
  end if;

  /* Moving an event people have committed to is not an edit, it is a
     different event. Without notifications there is no honest way to
     tell them. The host's own attendance does not count — otherwise a
     host is locked out of their own event the moment they publish it. */
  if new_start <> target.starts_at then
    select count(*) into going_now from public.attendances
     where event_id = target.id
       and status in ('going','attended')
       and user_id is distinct from target.host_id;
    if going_now > 0 then
      raise exception 'cannot move an event once % other people are going; cancel and repost', going_now
        using errcode = '23514';
    end if;
  end if;

  update public.events e set
    title          = coalesce(p_patch->>'title', e.title),
    description    = coalesce(p_patch->>'description', e.description),
    venue_name     = coalesce(p_patch->>'venue_name', e.venue_name),
    venue_address  = coalesce(p_patch->>'venue_address', e.venue_address),
    venue_lat      = coalesce((p_patch->>'venue_lat')::double precision, e.venue_lat),
    venue_lng      = coalesce((p_patch->>'venue_lng')::double precision, e.venue_lng),
    venue_source   = coalesce(p_patch->>'venue_source', e.venue_source),
    city           = coalesce(p_patch->>'city', e.city),
    community_slug = case when p_patch ? 'community_slug'
                          then p_patch->>'community_slug' else e.community_slug end,
    category       = case when p_patch ? 'category'
                          then p_patch->>'category' else e.category end,
    cover_url      = case when p_patch ? 'cover_url'
                          then p_patch->>'cover_url' else e.cover_url end,
    starts_at      = new_start,
    ends_at        = case when p_patch ? 'ends_at'
                          then (p_patch->>'ends_at')::timestamptz else e.ends_at end,
    recurrence     = case when p_patch ? 'recurrence'
                          then p_patch->>'recurrence' else e.recurrence end,
    price_value    = coalesce((p_patch->>'price_value')::integer, e.price_value),
    price_currency = coalesce(p_patch->>'price_currency', e.price_currency),
    capacity       = case when p_patch ? 'capacity'
                          then (p_patch->>'capacity')::integer else e.capacity end,
    contact        = case when p_patch ? 'contact'
                          then p_patch->>'contact' else e.contact end,
    updated_at     = now()
  where e.id = target.id;

  select * into result from public.events_public where short_id = p_short_id;
  return result;
end $$;

grant execute on function public.update_event_as(text, uuid, text, jsonb) to anon;

create or replace function public.cancel_event_as(
  p_short_id text, p_user uuid, p_secret text
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare target public.events;
begin
  select * into target from public.events where short_id = p_short_id;
  if not found then return false; end if;
  if not public.owns_event(target, p_user, p_secret) then
    raise exception 'not yours to cancel' using errcode = '42501';
  end if;
  -- soft delete: a share link stays resolvable and says the event is
  -- off, rather than 404ing at somebody standing outside the venue
  update public.events set status = 'deleted', updated_at = now() where id = target.id;
  return true;
end $$;

grant execute on function public.cancel_event_as(text, uuid, text) to anon;

-- Everything this person has published, so a restored device can find
-- its own events again without holding any per-event secret.
create or replace function public.my_hosted(p_user uuid, p_secret text)
returns setof public.events_public
language plpgsql stable security definer set search_path = public
as $$
declare want text;
begin
  if p_user is null or p_secret is null then return; end if;
  select device_secret_hash into want from public.users where id = p_user;
  if want is null or want <> encode(digest(p_secret, 'sha256'), 'hex') then return; end if;

  return query
    select p.* from public.events_public p
    join public.events e on e.short_id = p.short_id
    where e.host_id = p_user
    order by e.starts_at desc;
end $$;

grant execute on function public.my_hosted(uuid, text) to anon;


-- ── 4. fields the app needs ───────────────────────────────────────
-- Suggested rather than requested. Each one exists because something
-- in the app currently cannot be expressed without it.

alter table public.events
  -- Which of the three community signals, if any, placed this event.
  -- Without it there is no way to tell a pin somebody chose from one
  -- inferred off a photo, and no way to audit a bad inference later.
  add column if not exists pin_source text
    check (pin_source is null or pin_source in ('manual','exif','extracted','venue')),

  -- Backfilled and test events should be visible to their creator and
  -- countable for the community graph, without pretending to be
  -- something anyone can still attend.
  add column if not exists is_backfill boolean not null default false,

  -- Set when magic created it, so the app can offer a "check this" pass
  -- over exactly the events a model wrote and no others.
  add column if not exists needs_review boolean not null default false;

-- A person's own label for themselves. Not a real name and never
-- required — the generated handle stays the fallback. Exists so the
-- "editable under your username" model has something to show.
alter table public.users
  add column if not exists display_name text
    check (display_name is null or length(btrim(display_name)) between 2 and 24);

-- Feed functions filter on starts_at >= now(). A backfilled event would
-- never appear even to its own host, so hosts get their own listing.
create or replace function public.my_events_as(p_user uuid, p_secret text)
returns setof public.events_public
language sql stable security definer set search_path = public
as $$
  select * from public.my_hosted(p_user, p_secret);
$$;

grant execute on function public.my_events_as(uuid, text) to anon;


-- ── afterwards ────────────────────────────────────────────────────
--   select id, handle, device_secret_hash is not null as claimed from public.users;
--   select short_id, title, starts_at, is_backfill, needs_review from public.events
--     order by created_at desc limit 20;


-- ── 5. let the past in ────────────────────────────────────────────
-- The insert policy carried `starts_at > now() - interval '1 day'`, so
-- publishing anything older than yesterday was refused by row level
-- security. That is the error behind "the database refused it — check
-- the date isn't in the past".
--
-- 90 days back is now allowed, for backfilling real history and for
-- testing the community graph with events that already happened.
-- Everything else in the old policy is preserved exactly.

drop policy if exists "anyone may publish a well formed event" on public.events;
create policy "anyone may publish a well formed event"
  on public.events for insert to anon
  with check (
    length(title) between 1 and 200
    and (description is null or length(description) <= 2000)
    and (venue_name is null or length(venue_name) <= 200)
    -- was now() - 1 day. Ninety days back, still no fantasy futures.
    and starts_at > now() - interval '90 days'
    and starts_at < now() + interval '2 years'
    and (ends_at is null or ends_at > starts_at)
    and price_value >= 0 and price_value <= 10000000
    and (capacity is null or (capacity > 0 and capacity <= 100000))
    and ((venue_lat is null and venue_lng is null)
      or (venue_lat between -90 and 90 and venue_lng between -180 and 180))
    and status = 'live'
  );

-- Marking yourself going to something that already happened is a
-- legitimate act — it is how a backfilled event enters the graph at
-- all. Nothing in the attendance policies blocked it, and nothing
-- should start to.
