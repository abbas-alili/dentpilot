-- LOCAL TESTING ONLY — never run against a Supabase project.
-- Recreates the small part of Supabase that the migrations depend on, so they
-- can be tested on plain Postgres: the anon/authenticated/service_role roles,
-- auth.users and auth.uid().

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin;          end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
end
$$;

create schema if not exists auth;
create schema if not exists extensions;   -- Supabase installs extensions here

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text
);

-- Same behaviour as Supabase: the user id comes from the request's JWT claims.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Supabase Vault (secrets encrypted at rest in production; plain here for tests).
create schema if not exists vault;
create table if not exists vault.secrets (
  id     uuid primary key default gen_random_uuid(),
  name   text unique,
  secret text not null
);
create or replace view vault.decrypted_secrets as
  select id, name, secret as decrypted_secret from vault.secrets;
create or replace function vault.create_secret(new_secret text, new_name text default null,
                                               new_description text default '', new_key_id uuid default null)
returns uuid language sql as $$ insert into vault.secrets (name, secret) values (new_name, new_secret) returning id $$;
create or replace function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null,
                                               new_description text default null, new_key_id uuid default null)
returns void language sql as $$ update vault.secrets set secret = coalesce(new_secret, secret) where id = secret_id $$;
