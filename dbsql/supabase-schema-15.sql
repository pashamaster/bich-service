-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 15  (REPLACES the earlier 15 and 16)
--
-- Three fixes and one feature:
--
--   1. REPAIR: every function from schema 13 that hashes the device
--      secret has been unable to run at all. See section 0 — this is
--      almost certainly why editing and cancelling kept falling back
--      to the old per-event tokens.
--   2. FIX: "position" is a reserved word in Postgres and cannot be a
--      column name in a RETURNS TABLE. That one word killed the old 15.
--   3. FIX: signup_index may never have been created, so the old 16
--      referenced a column that did not exist. Now guarded.
--   4. FEATURE: magic access becomes a flag on the account, granted by
--      hand or by redeeming a code. The first-100 cohort is dropped.
--
-- Safe to run more than once. Run after 14.
-- ═══════════════════════════════════════════════════════════════════


-- ── 0. the repair, and why it was needed ──────────────────────────
-- Supabase installs pgcrypto into the `extensions` schema, not into
-- `public`. Every function in schema 13 was declared:
--
--     security definer set search_path = public
--
-- so inside them `digest()` could not be resolved at all — Postgres
-- looked only in `public`, where pgcrypto is not. claim_device_secret,
-- owns_event, update_event_as, cancel_event_as and my_hosted therefore
-- raised "function digest(text, unknown) does not exist" every time
-- they were called.
--
-- The client catches those failures and quietly falls back to the old
-- per-event token, which is exactly why nothing looked broken and the
-- device-secret path never actually took effect.
--
-- Fixed by naming `extensions` on the search path everywhere. It stays
-- explicit rather than inherited, because a SECURITY DEFINER function
-- with a loose search_path is a real privilege-escalation risk.

create extension if not exists pgcrypto with schema extensions;

-- One place that knows how to hash, so this cannot drift again.
create or replace function public.bich_hash(p_text text)
returns text
language sql immutable
security definer
set search_path = public, extensions
as $$
  select encode(digest(p_text, 'sha256'), 'hex');
$$;

grant execute on function public.bich_hash(text) to anon;


-- ── 1. the schema 13 functions, rebuilt ───────────────────────────

create or replace function public.claim_device_secret(p_user uuid, p_secret text)
returns boolean
language plpgsql security definer set search_path = public, extensions
as $$
declare existing text;
begin
  if p_secret is null or length(p_secret) < 24 then
    raise exception 'secret too short' using errcode = '22023';
  end if;

  select device_secret_hash into existing from public.users where id = p_user;
  if not found then return false; end if;

  -- already claimed: succeed only if it is the same secret, so a second
  -- device cannot silently take over an account
  if existing is not null then
    return existing = public.bich_hash(p_secret);
  end if;

  update public.users set device_secret_hash = public.bich_hash(p_secret)
   where id = p_user;
  return true;
end $$;

grant execute on function public.claim_device_secret(uuid, text) to anon;


create or replace function public.owns_event(p_event public.events, p_user uuid, p_secret text)
returns boolean
language plpgsql stable security definer set search_path = public, extensions
as $$
declare want text;
begin
  if p_user is null or p_secret is null then return false; end if;
  if p_event.host_id is distinct from p_user then return false; end if;
  select device_secret_hash into want from public.users where id = p_user;
  return want is not null and want = public.bich_hash(p_secret);
end $$;


create or replace function public.my_hosted(p_user uuid, p_secret text)
returns setof public.events_public
language plpgsql stable security definer set search_path = public, extensions
as $$
declare want text;
begin
  if p_user is null or p_secret is null then return; end if;
  select device_secret_hash into want from public.users where id = p_user;
  if want is null or want <> public.bich_hash(p_secret) then return; end if;

  return query
    select p.* from public.events_public p
    join public.events e on e.short_id = p.short_id
    where e.host_id = p_user
    order by e.starts_at desc;
end $$;

grant execute on function public.my_hosted(uuid, text) to anon;


-- ── 2. drop the cohort, however far it got ────────────────────────
-- signup_index may or may not exist: it was appended to schema 13 late,
-- and that run may predate the append. Everything here is guarded so it
-- works either way.

drop function if exists public.may_use_magic(uuid, integer);
drop function if exists public.may_use_magic_as(uuid, text, integer);
drop function if exists public.cohort_status(integer);
drop trigger  if exists users_assign_signup_index on public.users;
drop function if exists public.assign_signup_index();

alter table public.users
  add column if not exists magic_enabled    boolean not null default false,
  add column if not exists magic_granted_at timestamptz,
  add column if not exists magic_source     text;

do $outer$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'users'
       and column_name = 'signup_index'
  ) then
    -- anyone already inside the old window keeps what they had; nobody
    -- loses a working feature because the rule behind it changed
    execute $q$
      update public.users
         set magic_enabled = true,
             magic_granted_at = coalesce(magic_granted_at, now()),
             magic_source = coalesce(magic_source, 'legacy-cohort')
       where magic_enabled = false
         and signup_index is not null
         and signup_index <= 100
    $q$;
    execute 'drop index if exists users_signup_index_idx';
    execute 'alter table public.users drop column signup_index';
  end if;
end
$outer$;


-- ── 3. codes ──────────────────────────────────────────────────────
-- A code is an opaque string you hand to a person — never a name, never
-- an identity. Redeeming one sets the flag permanently, so the code can
-- be retired afterwards without anyone losing access: hand one out at
-- an event, kill it the next morning.

create table if not exists public.magic_codes (
  code       text primary key,
  label      text,                        -- a note to yourself, never shown
  max_uses   integer,                     -- null = unlimited
  used_count integer not null default 0,
  expires_at timestamptz,                 -- null = never
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.magic_codes enable row level security;
-- No policies at all, deliberately. Nobody reads or writes this table
-- directly; redeem_magic_code() is the only way in.

create or replace function public.redeem_magic_code(
  p_user uuid, p_secret text, p_code text
)
returns table (ok boolean, reason text)
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_row  public.magic_codes;
  v_norm text;
begin
  if p_user is null or p_secret is null or p_code is null then
    return query select false, 'missing details'; return;
  end if;

  select device_secret_hash into v_hash from public.users where id = p_user;
  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    -- identical answer to a bad code, so this cannot probe accounts
    return query select false, 'that code did not work'; return;
  end if;

  -- case and spacing should never be why a code fails
  v_norm := lower(regexp_replace(btrim(p_code), '\s+', '', 'g'));

  select * into v_row from public.magic_codes where code = v_norm and active = true;

  if not found
     or (v_row.expires_at is not null and v_row.expires_at < now())
     or (v_row.max_uses   is not null and v_row.used_count >= v_row.max_uses) then
    return query select false, 'that code did not work'; return;
  end if;

  update public.users
     set magic_enabled = true,
         magic_granted_at = coalesce(magic_granted_at, now()),
         magic_source = coalesce(magic_source, v_norm)
   where id = p_user;

  update public.magic_codes set used_count = used_count + 1 where code = v_norm;

  return query select true, 'magic is on';
end $$;

grant execute on function public.redeem_magic_code(uuid, text, text) to anon;


-- ── 4. the check the worker makes ─────────────────────────────────
-- Called by the Cloudflare worker immediately before it spends anything
-- on a model. The device secret is required as well as the uid, because
-- public.users has an open select policy: every user id is listable, so
-- a uid on its own could simply be borrowed from another account.
--
-- NOTE the column names below. `position` is reserved in Postgres and
-- cannot appear in a RETURNS TABLE list — that single word is what made
-- the previous version of this file fail on its first statement.

create or replace function public.may_use_magic_as(p_user uuid, p_secret text)
returns table (allowed boolean, granted_at timestamptz)
language plpgsql stable security definer set search_path = public, extensions
as $$
declare
  v_hash text;
  v_on   boolean;
  v_at   timestamptz;
begin
  if p_user is null or p_secret is null then
    return query select false, null::timestamptz; return;
  end if;

  select device_secret_hash, magic_enabled, magic_granted_at
    into v_hash, v_on, v_at
  from public.users where id = p_user;

  if not found or v_hash is null or v_hash <> public.bich_hash(p_secret) then
    return query select false, null::timestamptz; return;
  end if;

  return query select coalesce(v_on, false), v_at;
end $$;

grant execute on function public.may_use_magic_as(uuid, text) to anon;


-- Lets the app decide whether to show the magic button at all, so
-- nobody arms a feature that is going to refuse them.
create or replace function public.my_magic(p_user uuid, p_secret text)
returns boolean
language sql stable security definer set search_path = public, extensions
as $$
  select coalesce((select allowed from public.may_use_magic_as(p_user, p_secret)), false);
$$;

grant execute on function public.my_magic(uuid, text) to anon;


-- ── 5. grant it ───────────────────────────────────────────────────

update public.users
   set magic_enabled = true,
       magic_granted_at = coalesce(magic_granted_at, now()),
       magic_source = coalesce(magic_source, 'manual')
 where handle = 'pine tem';


-- ── 6. did it work ────────────────────────────────────────────────
-- Run these separately afterwards. bich_hash returning 64 hex
-- characters is the proof that the repair in section 0 took.
--
--   select public.bich_hash('test') as should_be_64_hex_chars;
--
--   select handle, magic_enabled, magic_source,
--          device_secret_hash is not null as secret_claimed
--     from public.users order by created_at;


-- ── running this yourself later ───────────────────────────────────
-- Give somebody magic:
--   update public.users set magic_enabled = true, magic_granted_at = now(),
--          magic_source = 'manual' where handle = 'heath quill';
--
-- Take it away:
--   update public.users set magic_enabled = false where handle = 'heath quill';
--
-- A code for an event, 20 people, expires Sunday:
--   insert into public.magic_codes (code, label, max_uses, expires_at)
--   values ('ericeira', 'friday market', 20, now() + interval '3 days');
--
-- Retire a code without anyone losing what it granted:
--   update public.magic_codes set active = false where code = 'ericeira';
