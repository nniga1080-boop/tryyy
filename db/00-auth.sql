-- =====================================================================
--  ESST — accounts layer for a plain PostgreSQL database (Railway).
--  Supabase provides an "auth" schema with auth.users + auth.uid().
--  Here we provide the same minimal pieces so supabase/schema.sql runs
--  unchanged, but passwords are checked by our own server (server.js).
-- =====================================================================

create extension if not exists pgcrypto;

create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text not null unique,
  encrypted_password  text not null,
  raw_user_meta_data  jsonb not null default '{}'::jsonb,
  email_confirmed_at  timestamptz default now(),
  created_at          timestamptz not null default now(),
  last_sign_in_at     timestamptz
);

create table if not exists auth.refresh_tokens (
  token       text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null,
  revoked     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists refresh_tokens_user_idx on auth.refresh_tokens (user_id);

-- The current user's id, taken from a per-request session setting.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

-- Roles the schema's security rules expect.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit;
  end if;
end $$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
