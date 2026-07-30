-- ═══════════════════════════════════════════════════════════════════
-- bich.service — schema part 19
--
--   explicit table privileges
--
-- Run after 18. Idempotent and safe to re-run.
-- ═══════════════════════════════════════════════════════════════════


-- ── grants are not policies ───────────────────────────────────────
-- Every table in this project has row level security and carefully
-- written policies, and not one migration has ever issued a GRANT.
--
-- Those are two separate gates and BOTH must pass. A policy says which
-- rows a role may touch; a grant says whether the role may touch the
-- table at all. Without the grant, Postgres refuses with
--
--     42501: permission denied for table attendances
--
-- before any policy is even consulted — and the app reports that as a
-- refusal, rolls the optimistic count back, and shows exactly the
-- "1 then 0" flicker with nothing written.
--
-- Supabase normally sets default privileges so tables created by the
-- postgres role inherit grants for anon. That usually holds, which is
-- why most of this app works. But default privileges only apply to
-- tables created AFTER they were configured, and only for the role
-- that created them — so a table made in a different session, restored
-- from a dump, or created before that setting can quietly miss out.
--
-- Stating them explicitly costs nothing and removes the variable.


-- Read: everything the feed needs. attendances and event_visits are
-- deliberately NOT here — nobody reads those directly, counts come out
-- of SECURITY DEFINER functions that return integers.
grant select on public.events       to anon;
grant select on public.users        to anon;
grant select on public.venues       to anon;
grant select on public.communities  to anon;
grant select on public.handle_words to anon;

-- Write: the three things a browser is allowed to create.
grant insert         on public.events      to anon;
grant insert, update on public.attendances to anon;
grant insert         on public.venues      to anon;
grant insert         on public.users       to anon;

/* attendances also needs SELECT for the upsert path specifically.
   INSERT ... ON CONFLICT DO UPDATE has to read the conflicting row to
   apply the update, so Postgres requires the SELECT privilege on it —
   even though there is still no SELECT POLICY, which means the grant
   permits the operation while the missing policy keeps every row
   invisible. Privilege and policy doing different jobs, exactly as
   intended: the upsert works, and nobody can list who is going. */
grant select on public.attendances to anon;

-- Sequences, if any table ever uses one.
grant usage on all sequences in schema public to anon;

-- And make sure anything added later inherits the same treatment.
alter default privileges in schema public
  grant select on tables to anon;


-- ── afterwards ────────────────────────────────────────────────────
-- What anon may actually do:
--
--   select table_name, privilege_type
--     from information_schema.role_table_grants
--    where grantee = 'anon' and table_schema = 'public'
--    order by table_name, privilege_type;
--
-- attendances should list INSERT, SELECT and UPDATE. If it lists
-- nothing, that was the bug.
--
-- Prove the write works, as anon, with your own ids:
--
--   set local role anon;
--   insert into public.attendances (event_id, user_id, status)
--   values ('<event uuid>', '<your user uuid>', 'going')
--   on conflict (event_id, user_id) do update set status = 'going';
--   reset role;
