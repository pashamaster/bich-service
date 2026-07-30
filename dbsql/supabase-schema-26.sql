-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 26
--
--   P1-2  operation ids and replay protection
--   P1-3  publish_event as one transaction
--   P1-7  community stops living only in the browser
--
-- Run after 25. Idempotent.
-- ═══════════════════════════════════════════════════════════════════


-- ── P1-2: client_operations ───────────────────────────────────────
-- Every mutation the browser sends can fail AFTER the database has
-- committed it — a dropped connection on the response, a phone going
-- to sleep, a service worker update mid-flight. The client cannot tell
-- that apart from "it never arrived", so it retries, and a second event
-- appears.
--
-- The fix is for the database that owns the write to own the replay
-- check too. The client generates one uuid per intention and sends it
-- with every attempt; the first attempt records its result, and every
-- later attempt gets that same result back instead of doing the work
-- again.
--
-- PROJECT.md §5: "This is preferable to adding a separate
-- synchronization backend. The database that owns the canonical
-- mutation should own idempotency too."

create table if not exists public.client_operations (
  operation_id   uuid primary key,
  user_id        uuid not null references public.users(id) on delete cascade,
  operation_type text not null,
  result         jsonb not null,
  created_at     timestamptz not null default now()
);

create index if not exists client_operations_user_idx
  on public.client_operations (user_id, created_at desc);

alter table public.client_operations enable row level security;
revoke all on public.client_operations from anon;
-- No policies and no grants, deliberately. This table is written and
-- read only from inside mutation RPCs. It is not a sync feed.


/* Returns the recorded result of an operation, or null if it is new.
   Scoped to the user so one device cannot read another's results by
   guessing a uuid. */
create or replace function public.op_replay(p_operation_id uuid, p_user uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select o.result from public.client_operations o
   where o.operation_id = p_operation_id and o.user_id = p_user;
$$;

create or replace function public.op_record(
  p_operation_id uuid, p_user uuid, p_type text, p_result jsonb
)
returns void
language sql security definer set search_path = public
as $$
  insert into public.client_operations (operation_id, user_id, operation_type, result)
  values (p_operation_id, p_user, p_type, p_result)
  on conflict (operation_id) do nothing;
$$;

-- Neither is granted to anon. They are internal to the RPCs below.


-- ── P1-3: publish_event, in one transaction ───────────────────────
-- Publishing used to be five independent client operations: insert the
-- event, remember the token, claim the device secret, write the host's
-- attendance, adopt the community. A failure at step four left a live
-- event whose own host was not marked going, belonging to no community,
-- with nothing to repair it — and that state was reachable often enough
-- that "0 people" on your own event was the normal experience.
--
-- A function body is a single transaction. Either all of it happens or
-- none of it does.

create or replace function public.publish_event(
  p_payload      jsonb,
  p_user         uuid,
  p_secret       text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash   text;
  v_prior  jsonb;
  v_short  text;
  v_id     uuid;
  v_start  timestamptz;
  v_end    timestamptz;
  v_result jsonb;
begin
  if p_user is null or p_secret is null or p_operation_id is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  /* Replay check FIRST, before any validation. A retry of something
     already accepted must return the original answer even if the
     payload would no longer validate — the event exists; re-judging it
     would fail a retry for an event that is already live. */
  v_prior := public.op_replay(p_operation_id, p_user);
  if v_prior is not null then
    return v_prior || jsonb_build_object('replayed', true);
  end if;

  -- ── validation, server side, regardless of what the client checked
  if coalesce(btrim(p_payload->>'title'), '') = '' then
    raise exception 'a title is required' using errcode = '22023';
  end if;
  if length(p_payload->>'title') > 200 then
    raise exception 'that title is too long' using errcode = '22023';
  end if;
  if coalesce(btrim(p_payload->>'venue_name'), '') = '' then
    raise exception 'a venue name is required' using errcode = '22023';
  end if;

  v_start := (p_payload->>'starts_at')::timestamptz;
  if v_start is null then
    raise exception 'a date and time are required' using errcode = '22023';
  end if;
  if v_start < now() - interval '90 days' then
    raise exception 'that date is more than 90 days ago' using errcode = '22023';
  end if;
  if v_start > now() + interval '2 years' then
    raise exception 'that date is too far ahead' using errcode = '22023';
  end if;

  v_end := (p_payload->>'ends_at')::timestamptz;
  if v_end is not null and v_end <= v_start then
    raise exception 'the finish must be after the start' using errcode = '22023';
  end if;

  if (p_payload->>'venue_lat') is not null
     and ((p_payload->>'venue_lat')::double precision not between -90 and 90
       or (p_payload->>'venue_lng')::double precision not between -180 and 180) then
    raise exception 'those coordinates are not on earth' using errcode = '22023';
  end if;

  v_short := public.gen_short_id();

  -- ── the event
  insert into public.events (
    short_id, host_id, title, description,
    venue_name, venue_address, venue_lat, venue_lng, venue_source,
    city, community_slug, photo_lat, photo_lng,
    starts_at, ends_at, recurrence,
    price_value, price_currency, capacity,
    cover_url, contact, source, category,
    pin_source, is_backfill, needs_review,
    status, edit_token_hash
  ) values (
    v_short, p_user,
    btrim(p_payload->>'title'),
    nullif(btrim(coalesce(p_payload->>'description', '')), ''),
    btrim(p_payload->>'venue_name'),
    nullif(btrim(coalesce(p_payload->>'venue_address', '')), ''),
    (p_payload->>'venue_lat')::double precision,
    (p_payload->>'venue_lng')::double precision,
    nullif(p_payload->>'venue_source', ''),
    nullif(p_payload->>'city', ''),
    nullif(p_payload->>'community_slug', ''),
    (p_payload->>'photo_lat')::double precision,
    (p_payload->>'photo_lng')::double precision,
    v_start, v_end,
    nullif(p_payload->>'recurrence', ''),
    coalesce((p_payload->>'price_value')::integer, 0),
    coalesce(nullif(p_payload->>'price_currency', ''), 'EUR'),
    (p_payload->>'capacity')::integer,
    nullif(p_payload->>'cover_url', ''),
    nullif(p_payload->>'contact', ''),
    coalesce(nullif(p_payload->>'source', ''), 'manual'),
    nullif(p_payload->>'category', ''),
    nullif(p_payload->>'pin_source', ''),
    coalesce((p_payload->>'is_backfill')::boolean, v_start < now() - interval '1 hour'),
    coalesce((p_payload->>'needs_review')::boolean, false),
    'live',
    nullif(p_payload->>'edit_token_hash', '')
  )
  returning id into v_id;

  /* If you are posting the walk, you are going on the walk. Same
     transaction, so an event can never exist without its host's
     attendance again. */
  insert into public.attendances (event_id, user_id, status, joined_at)
  values (v_id, p_user, 'going', now())
  on conflict (event_id, user_id) do nothing;

  v_result := jsonb_build_object(
    'short_id', v_short,
    'id',       v_id,
    'event',    public.event_json(v_short)
  );

  perform public.op_record(p_operation_id, p_user, 'event.create', v_result);
  return v_result;
end $$;

grant execute on function public.publish_event(jsonb, uuid, text, uuid) to anon;


-- The browser no longer inserts events itself.
revoke insert, update, delete on public.events from anon;

drop policy if exists "anyone may publish a well formed event" on public.events;


-- ── set_attendance records its operation too ──────────────────────
-- Attendance is naturally idempotent, so replay protection is not
-- needed for correctness. Recording it anyway means one consistent
-- story in client_operations, and lets the outbox mark an item
-- acknowledged on evidence rather than on a hopeful 200.

create or replace function public.set_attendance(
  p_short_id     text,
  p_user         uuid,
  p_secret       text,
  p_status       text,
  p_operation_id uuid default null
)
returns table (
  short_id    text,
  status      text,
  going_count integer
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_event public.events;
  v_now   integer;
begin
  if p_status is null or p_status not in ('going', 'cancelled') then
    raise exception 'status must be going or cancelled' using errcode = '22023';
  end if;
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;

  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  /* Every column below is qualified. RETURNS TABLE makes short_id,
     status and going_count into VARIABLES in this body, so an
     unqualified `status` is ambiguous with events.status — which is
     exactly the 42702 this function shipped with. */
  select * into v_event from public.events e
   where e.short_id = p_short_id and e.status = 'live';
  if not found then
    raise exception 'no such event' using errcode = 'P0002';
  end if;

  insert into public.attendances as att (event_id, user_id, status, joined_at)
  values (v_event.id, p_user, p_status, now())
  on conflict (event_id, user_id) do update
    set status = excluded.status,
        confirmed_at = case when excluded.status = 'going'
                            then null else att.confirmed_at end;

  select count(*)::integer into v_now
    from public.attendances a
   where a.event_id = v_event.id and a.status in ('going', 'attended');

  if p_operation_id is not null then
    perform public.op_record(p_operation_id, p_user, 'attendance.set',
      jsonb_build_object('short_id', p_short_id, 'status', p_status, 'going_count', v_now));
  end if;

  return query select p_short_id, p_status, v_now;
end $$;

grant execute on function public.set_attendance(text, uuid, text, text, uuid) to anon;


-- ── P1-7: community belongs on the account ────────────────────────
-- The person's community has lived in localStorage only. A passkey
-- restore therefore returned uid, handle and device secret — and left
-- them with no community, so their feed emptied until they published
-- something or opened a link. That undercuts the point of restoring.

alter table public.users
  add column if not exists community_slug       text,
  add column if not exists community_via        text
    check (community_via is null or community_via in ('link','photo','publish')),
  add column if not exists community_updated_at timestamptz;

create or replace function public.set_my_community(
  p_user uuid, p_secret text, p_slug text, p_via text
)
returns text
language plpgsql security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    raise exception 'not yours' using errcode = '42501';
  end if;

  if p_slug is not null and not exists (
       select 1 from public.communities c where c.slug = p_slug) then
    raise exception 'no such community' using errcode = 'P0002';
  end if;
  if p_via is not null and p_via not in ('link','photo','publish') then
    raise exception 'unknown community signal' using errcode = '22023';
  end if;

  update public.users u
     set community_slug = p_slug,
         community_via = p_via,
         community_updated_at = now()
   where u.id = p_user;

  return p_slug;
end $$;

grant execute on function public.set_my_community(uuid, text, text, text) to anon;


-- get_my_account carries the community back, so a restored device is
-- somewhere the moment it signs in.
drop function if exists public.get_my_account(uuid, text);

create or replace function public.get_my_account(p_user uuid, p_secret text)
returns table (
  uid            uuid,
  handle         text,
  display_name   text,
  magic_enabled  boolean,
  is_admin       boolean,
  community_slug text,
  community_via  text
)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare v_hash text;
begin
  if p_user is null or p_secret is null then return; end if;
  select u.device_secret_hash into v_hash from public.users u where u.id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    return;
  end if;

  return query
    select u.id, u.handle, u.display_name, u.magic_enabled, u.is_admin,
           u.community_slug, u.community_via
      from public.users u where u.id = p_user;
end $$;

grant execute on function public.get_my_account(uuid, text) to anon;


-- ── afterwards ────────────────────────────────────────────────────
-- anon must have nothing on events or client_operations:
--   select table_name, privilege_type from information_schema.role_table_grants
--    where grantee = 'anon' and table_schema = 'public'
--      and table_name in ('events','attendances','users','client_operations');
--   -- expect zero rows
--
-- Publishing twice with the SAME operation id must produce ONE event:
--   select public.publish_event(
--     '{"title":"replay test","venue_name":"nowhere","starts_at":"2027-01-01T19:00:00Z"}'::jsonb,
--     '<uuid>', '<secret>', '11111111-1111-1111-1111-111111111111');
--   -- run it again; the second call returns "replayed": true and the
--   -- same short_id, and select count(*) from events where title =
--   -- 'replay test' returns 1.
