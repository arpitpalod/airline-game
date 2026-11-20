-- Stand-ins for Supabase's roles and auth schema, for the local stack only.
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text unique, password text,
                         confirmed boolean not null default true);
create function auth.uid() returns uuid language sql stable as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;
grant usage on schema auth to authenticated, anon;
grant usage on schema public to authenticated, anon, service_role;
