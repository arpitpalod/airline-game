-- Airline game: tables, indexes and row-level security.
-- Rules: clients can only read. Every change goes through server functions (added in later migrations).

create schema if not exists game;            -- engine internals, not exposed through the API
revoke all on schema game from public;

-- ---------- Reference data (shared by all worlds) ----------

create table public.game_params (
  key  text primary key,
  num  numeric not null,
  note text not null default ''
);

create table public.aircraft_types (
  id              text primary key,
  name            text not null,
  role            text not null check (role in ('regional','narrowbody','widebody')),
  econ_abreast    int not null,
  biz_abreast     int not null default 0,
  biz_kind        text not null default 'none' check (biz_kind in ('none','recliner','lieflat')),
  cabin_len_in    int not null,
  max_seats       int not null,
  ref_seats       int not null,
  range_km        int not null,
  cruise_kmh      int not null,
  fuel_fixed_kg   numeric not null,
  fuel_per_km_kg  numeric not null,
  block_offset_h  numeric not null,
  base_turn_min   int not null,
  day_window_h    numeric not null,
  lease_usd_month int not null,
  price_usd_m     numeric not null,
  maint_usd_fh    numeric not null,
  maint_usd_cycle numeric not null,
  runway_class    int not null check (runway_class between 1 and 3),
  sort            int not null default 0
);

create table public.airports (
  iata         text primary key check (iata ~ '^[A-Z]{3}$'),
  city         text not null,
  country      text not null,
  region       text not null,
  is_india     boolean not null,
  lat          numeric(7,4) not null,
  lon          numeric(7,4) not null,
  pax_m        numeric,          -- India: passengers handled a year, millions
  pax_src      text check (pax_src in ('V','G')),   -- V = published figure, G = estimate
  intl_share   numeric,          -- India: share of pax_m that is international
  mass         numeric,          -- foreign: weight in India's international travel
  biz_idx      numeric not null,
  tour_idx     numeric not null,
  runway_class int not null check (runway_class between 1 and 3),
  slot_cap     int,              -- daily movements; null = not congested
  opens_day    int not null default 0,
  sibling      text references public.airports,   -- established airport of the same city
  check ((is_india and pax_m is not null and intl_share is not null) or (not is_india and mass is not null))
);

create table public.intl_affinity (
  india_region   text not null,
  foreign_region text not null,
  mult           numeric not null,
  primary key (india_region, foreign_region)
);

create table public.markets (
  a        text not null references public.airports,
  b        text not null references public.airports,
  km       int not null,
  intl     boolean not null,
  n_biz    numeric not null,   -- potential travellers a day, each way, at demand scale 1
  n_lei    numeric not null,
  n_bud    numeric not null,
  ref_fare int not null,       -- reference economy fare, rupees
  primary key (a, b),
  check (a < b)
);
create index markets_b_idx on public.markets (b);

-- ---------- Worlds ----------

create table public.worlds (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique,
  status         text not null default 'setup' check (status in ('setup','running','paused','ended')),
  speed          numeric not null default 13 check (speed > 0),
  started_at     timestamptz,
  paused_at      timestamptz,
  paused_seconds numeric not null default 0,
  game_day       int not null default 0,      -- last game day processed
  season         int not null default 1,
  season_days    int not null default 2366,   -- 26 real weeks at 13x
  demand_scale   numeric not null default 1,
  slot_scale     numeric not null default 1,
  crew_rule      text not null default 'per50' check (crew_rule in ('per50','india')),
  fuel_inr_kg    numeric not null default 100,
  fx_inr_usd     numeric not null default 90,
  settings       jsonb not null default '{}'
);

create table public.world_secrets (     -- never readable by clients
  world_id    uuid primary key references public.worlds on delete cascade,
  invite_code text not null
);

create table public.world_daily (
  world_id    uuid not null references public.worlds on delete cascade,
  game_day    int not null,
  fuel_inr_kg numeric not null,
  fx_inr_usd  numeric not null,
  primary key (world_id, game_day)
);

create table public.profiles (
  user_id      uuid primary key references auth.users on delete cascade,
  display_name text not null,
  is_admin     boolean not null default false,
  created_at   timestamptz not null default now()
);

-- ---------- Airlines ----------

create table public.airlines (
  id                uuid primary key default gen_random_uuid(),
  world_id          uuid not null references public.worlds on delete cascade,
  user_id           uuid references auth.users on delete set null,
  is_ai             boolean not null default false,
  name              text not null,
  code              text not null check (code ~ '^[A-Z0-9]{2,3}$'),
  livery            jsonb not null default '{}',
  status            text not null default 'active' check (status in ('active','administration','closed')),
  brand             numeric not null default 50,
  otp               numeric not null default 0.85,
  marketing_inr_day numeric not null default 0,
  created_day       int not null default 0,
  unique (world_id, name),
  unique (world_id, code),
  unique (world_id, user_id)
);
create index airlines_user_idx on public.airlines (user_id);

create table public.airline_finance (    -- private to the owner
  airline_id       uuid primary key references public.airlines on delete cascade,
  cash_inr         numeric not null,
  debt_inr         numeric not null default 0,
  credit_limit_inr numeric not null
);

create table public.bases (
  airline_id uuid not null references public.airlines on delete cascade,
  iata       text not null references public.airports,
  opened_day int not null,
  primary key (airline_id, iata)
);
create index bases_iata_idx on public.bases (iata);

create table public.aircraft (           -- public: who flies what, in which layout
  id            uuid primary key default gen_random_uuid(),
  world_id      uuid not null references public.worlds on delete cascade,
  type_id       text not null references public.aircraft_types,
  airline_id    uuid references public.airlines on delete set null,   -- null = lessor pool
  reg           text not null,
  built_day     int not null,            -- negative = older than the world
  status        text not null check (status in ('pool','delivering','active','grounded','refit','returned')),
  available_day int not null default 0,  -- day it can next fly
  base_iata     text references public.airports,
  biz_rows      int not null default 0,
  biz_pitch     int,
  econ_pitch    int not null,
  seats_biz     int not null default 0,
  seats_econ    int not null,
  unique (world_id, reg)
);
create index aircraft_airline_idx on public.aircraft (airline_id);
create index aircraft_type_idx on public.aircraft (type_id);
create index aircraft_base_idx on public.aircraft (base_iata);

create table public.aircraft_terms (     -- private to the operator
  aircraft_id     uuid primary key references public.aircraft on delete cascade,
  airline_id      uuid not null references public.airlines on delete cascade,
  holding         text not null check (holding in ('lease','owned','wet')),
  lease_usd_month numeric,
  lease_end_day   int,
  deposit_inr     numeric not null default 0,
  price_usd       numeric
);
create index aircraft_terms_airline_idx on public.aircraft_terms (airline_id);

create table public.routes (             -- public: fares and where each airline flies
  id         uuid primary key default gen_random_uuid(),
  world_id   uuid not null references public.worlds on delete cascade,
  airline_id uuid not null references public.airlines on delete cascade,
  origin     text not null references public.airports,   -- one of the airline's bases
  dest       text not null references public.airports,
  fare_econ  int not null check (fare_econ > 0),
  fare_biz   int check (fare_biz > 0),
  opened_day int not null,
  status     text not null default 'open' check (status in ('open','closed')),
  unique (airline_id, origin, dest),
  check (origin <> dest)
);
create index routes_world_pair_idx on public.routes (world_id, origin, dest);
create index routes_origin_idx on public.routes (origin);
create index routes_dest_idx on public.routes (dest);

create table public.rotations (          -- public: frequencies
  aircraft_id  uuid not null references public.aircraft on delete cascade,
  route_id     uuid not null references public.routes on delete cascade,
  weekly_trips int not null check (weekly_trips between 1 and 84),   -- round trips a week
  primary key (aircraft_id, route_id)
);
create index rotations_route_idx on public.rotations (route_id);

-- ---------- Results ----------

create table public.route_daily (        -- private; kept for recent days only
  route_id     uuid not null references public.routes on delete cascade,
  game_day     int not null,
  airline_id   uuid not null references public.airlines on delete cascade,
  flights      numeric not null,
  seats_econ   int not null,
  seats_biz    int not null,
  pax_econ     int not null,
  pax_biz      int not null,
  spill        int not null default 0,
  revenue_inr  numeric not null,
  var_cost_inr numeric not null,
  primary key (route_id, game_day)
);
create index route_daily_airline_idx on public.route_daily (airline_id, game_day);

create table public.airline_daily (      -- private
  airline_id  uuid not null references public.airlines on delete cascade,
  game_day    int not null,
  pax         int not null default 0,
  ask         numeric not null default 0,
  rpk         numeric not null default 0,
  rev_ticket  numeric not null default 0,
  rev_anc     numeric not null default 0,
  c_fuel      numeric not null default 0,
  c_crew      numeric not null default 0,
  c_maint     numeric not null default 0,
  c_airport   numeric not null default 0,
  c_rent      numeric not null default 0,
  c_slots     numeric not null default 0,
  c_dist      numeric not null default 0,
  c_marketing numeric not null default 0,
  c_overhead  numeric not null default 0,
  c_interest  numeric not null default 0,
  c_other     numeric not null default 0,
  cash_end    numeric not null default 0,
  brand       numeric,
  otp         numeric,
  primary key (airline_id, game_day)
);

create table public.transactions (       -- private: one-off money movements
  id         bigint generated always as identity primary key,
  airline_id uuid not null references public.airlines on delete cascade,
  game_day   int not null,
  kind       text not null,
  amount_inr numeric not null,
  note       text not null default ''
);
create index transactions_airline_idx on public.transactions (airline_id, game_day);

create table public.quarterly_reports (  -- public headline results
  airline_id uuid not null references public.airlines on delete cascade,
  quarter    int not null,
  revenue    numeric not null,
  op_profit  numeric not null,
  net_profit numeric not null,
  pax        bigint not null,
  load_factor numeric,
  rask       numeric,
  cask       numeric,
  otp        numeric,
  brand      numeric,
  net_worth  numeric,
  score      numeric,
  rank       int,
  primary key (airline_id, quarter)
);

create table public.events (
  id            uuid primary key default gen_random_uuid(),
  world_id      uuid not null references public.worlds on delete cascade,
  kind          text not null,
  announced_day int not null,
  starts_day    int not null,
  ends_day      int,
  payload       jsonb not null default '{}'
);
create index events_world_idx on public.events (world_id, starts_day);

create table public.news (
  id         bigint generated always as identity primary key,
  world_id   uuid not null references public.worlds on delete cascade,
  game_day   int not null,
  airline_id uuid references public.airlines on delete cascade,
  kind       text not null,
  body       text not null
);
create index news_world_idx on public.news (world_id, game_day desc);
create index news_airline_idx on public.news (airline_id);

-- ---------- Row-level security ----------
-- No insert, update or delete policy exists anywhere: clients cannot write.

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;

  -- readable by any signed-in player
  foreach t in array array['game_params','aircraft_types','airports','intl_affinity','markets','worlds',
                           'world_daily','profiles','airlines','bases','aircraft','routes','rotations',
                           'quarterly_reports','news'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy read_all on public.%I for select to authenticated using (true)', t);
  end loop;

  -- readable only by the airline's owner
  foreach t in array array['airline_finance','aircraft_terms','route_daily','airline_daily','transactions'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format($p$create policy read_own on public.%I for select to authenticated
      using (airline_id in (select id from public.airlines where user_id = (select auth.uid())))$p$, t);
  end loop;
end $$;

-- events are visible once announced
grant select on public.events to authenticated;
create policy read_announced on public.events for select to authenticated
  using (announced_day <= (select w.game_day from public.worlds w where w.id = world_id));

-- world_secrets: no grants, no policies.
