-- Player actions (Stage 2b, part 1). Every change a player can make is one function in this file.
-- A caller is either a signed-in player, checked against auth.uid(), or the server itself
-- (service role, engine, bots), which has no user id and may act for any airline.
-- Day convention: worlds.game_day is the last day processed; actions happen on game_day + 1.

-- ---------- Schema additions ----------

alter table public.worlds
  add column max_airlines int not null default 50,
  add column fuel_walk numeric not null default 100,   -- engine state: prices before event shocks
  add column fx_walk numeric not null default 90;

alter table public.aircraft_types
  add column pool_per_airline numeric not null default 0,            -- lessor pool size per airline place
  add column deliveries_per_airline_qtr numeric not null default 0,  -- manufacturer slots a quarter per airline place
  add column pilot_fixed_inr_day numeric not null default 0,         -- pilot salaries per aircraft
  add column pilot_inr_bh numeric not null default 0,                -- pilot flying pay per block hour
  add column landing_inr numeric not null default 0,                 -- landing charge at an Indian airport
  add column nav_inr_km numeric not null default 0;                  -- navigation charge per km

update public.aircraft_types t
set pool_per_airline = v.pool, deliveries_per_airline_qtr = v.dlv, pilot_fixed_inr_day = v.pfix,
    pilot_inr_bh = v.pbh, landing_inr = v.land, nav_inr_km = v.nav
from (values
  ('AT76', 1.5, 0.12, 100000,  3000,   8000,  4),
  ('A20N', 3.0, 0.30, 190000,  6000,  30000, 10),
  ('A21N', 1.5, 0.16, 190000,  6000,  36000, 11),
  ('A21X', 0.5, 0.06, 210000,  7000,  38000, 11),
  ('A359', 0.4, 0.04, 420000, 14000, 140000, 25)) as v(id, pool, dlv, pfix, pbh, land, nav)
where t.id = v.id;

alter table public.aircraft_terms
  add column start_day int,        -- day the aircraft joins the fleet
  add column wet_usd_bh numeric,   -- wet lease: rate per block hour
  add column ordered_day int,      -- manufacturer order still on its way: day it was placed
  add column pay_plan text check (pay_plan in ('cash','slb'));

alter table public.transactions add column pnl_inr numeric not null default 0;   -- profit effect; amount_inr is the cash effect

alter table public.news add column private boolean not null default false;
create policy news_private on public.news as restrictive for select to authenticated
  using (not private or airline_id in (select id from public.airlines where user_id = (select auth.uid())));

-- one route per airline per city pair, whichever end it starts from
create unique index routes_airline_pair_idx on public.routes (airline_id, least(origin, dest), greatest(origin, dest));

create table public.pool_targets (
  world_id uuid not null references public.worlds on delete cascade,
  type_id  text not null references public.aircraft_types,
  target   int not null,
  primary key (world_id, type_id)
);
alter table public.pool_targets enable row level security;
revoke all on public.pool_targets from anon, authenticated;
grant select on public.pool_targets to authenticated;
create policy read_all on public.pool_targets for select to authenticated using (true);

create sequence game.reg_seq;

insert into public.game_params (key, num, note) values
('lease_term_days', 728, 'operating lease term; renews at the market rent'),
('lease_lead_min_days', 39, 'lease arrival when the pool is full'),
('lease_lead_max_days', 91, 'lease arrival when the pool is empty'),
('age_rent_per_year', 0.03, 'rent discount per year of aircraft age'),
('pool_max_age_years', 12, 'oldest aircraft the lessors offer'),
('pool_refill_share', 0.25, 'share of the pool target added each quarter'),
('wet_lead_days', 13, ''),
('wet_ref_hours_day', 10, 'daily hours used to turn fixed costs into an hourly wet rate'),
('wet_min_hours_day', 6, 'hours billed a day even if the aircraft flies less'),
('order_lead_min_days', 546, 'shortest wait for a new aircraft'),
('order_premium_k', 0.08, 'price rise per extra year of queue'),
('slb_rent_mult', 0.85, 'sale-and-leaseback rent as a share of the base lease rate'),
('depreciation_year', 0.036, 'owned aircraft: share of purchase price a year'),
('sale_discount', 0.85, 'owned aircraft sell at this share of book value'),
('base_open_inr', 50000000, 'Rs 5 crore to open a base after the first'),
('fare_min_mult', 0.25, 'lowest fare as a multiple of the reference fare'),
('fare_max_mult', 4, 'highest fare as a multiple of the reference fare'),
('marketing_max_inr_day', 50000000, ''),
('cabin_fixed_inr_day', 10000, 'salaries per cabin crew position per aircraft'),
('cabin_inr_bh', 600, 'flying pay per cabin crew member per block hour'),
('fleet_max', 300, 'most aircraft one airline can hold, including those on their way'),
('wet_age_years', 5, 'age of a wet-leased aircraft'),
('rent_age_floor', 0.5, 'lowest rent for an old aircraft, as a share of the new rent'),
('book_value_floor', 0.10, 'an owned aircraft never depreciates below this share of its price');

-- ---------- Helpers ----------

create or replace function game.is_server() returns boolean
language sql stable set search_path = '' as $$
  select auth.uid() is null
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'service_role') = 'service_role'
$$;

create or replace function game.require_admin() returns void
language plpgsql stable set search_path = '' as $$
begin
  if not game.is_server()
     and not exists (select 1 from public.profiles where user_id = auth.uid() and is_admin) then
    raise exception 'Admins only';
  end if;
end $$;

-- Checks that the caller may act for this airline, locks it, and returns its world.
create or replace function game.actor(p_airline uuid, p_running boolean default true) returns public.worlds
language plpgsql set search_path = '' as $$
declare
  ra public.airlines%rowtype;
  rw public.worlds%rowtype;
begin
  select * into ra from public.airlines where id = p_airline;
  if not found then raise exception 'Airline not found'; end if;
  if not game.is_server() and (auth.uid() is null or ra.user_id is distinct from auth.uid()) then
    raise exception 'This is not your airline';
  end if;
  if ra.status <> 'active' then raise exception 'This airline is not active'; end if;
  select * into rw from public.worlds where id = ra.world_id for share;   -- waits while a game day is being processed
  if p_running and rw.status <> 'running' then raise exception 'This world is not running'; end if;
  perform 1 from public.airline_finance where airline_id = p_airline for update;
  return rw;
end $$;

-- Moves cash and records it. p_cash: + in, - out. p_pnl: effect on profit (0 for deposits, loans, purchases).
create or replace function game.book(p_airline uuid, p_day int, p_cash numeric, p_kind text, p_note text,
                                     p_pnl numeric default 0, p_force boolean default false) returns void
language plpgsql set search_path = '' as $$
begin
  update public.airline_finance set cash_inr = cash_inr + p_cash
   where airline_id = p_airline and (p_force or p_cash >= 0 or cash_inr >= -p_cash);
  if not found then
    raise exception 'Not enough cash: this needs Rs % crore. Borrow or free up cash first.', round(-p_cash / 1e7, 2);
  end if;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  values (p_airline, p_day, p_kind, p_cash, p_note, p_pnl);
end $$;

create or replace function game.next_reg() returns text
language plpgsql set search_path = '' as $$
declare
  n bigint := nextval('game.reg_seq') - 1;
  s text := '';
begin
  loop
    s := chr(65 + (n % 26)::int) || s;
    n := n / 26;
    exit when n = 0 and length(s) >= 3;
  end loop;
  return 'VT-' || s;
end $$;

create or replace function game.book_value_usd(p_price numeric, p_start int, p_day int) returns numeric
language sql stable set search_path = '' as $$
  select p_price * greatest(game.param('book_value_floor'), 1 - game.param('depreciation_year') * greatest(0, p_day - p_start) / 364.0)
$$;

-- Three standard cabins per type: 0 = roomy all-economy, 1 = standard all-economy, 2 = two-class (or dense).
create or replace function game.std_layout(p_type text, p_variant int, out biz_rows int, out biz_pitch int, out econ_pitch int)
language sql stable set search_path = '' as $$
  select case when p_variant % 3 = 2 then case t.biz_kind when 'recliner' then 3 when 'lieflat' then 9 else 0 end else 0 end,
         case when p_variant % 3 = 2 then case t.biz_kind when 'recliner' then 38 when 'lieflat' then 44 end end,
         case p_variant % 3 when 0 then 30 when 1 then 29
              else case t.biz_kind when 'none' then 28 when 'lieflat' then 31 else 30 end end
  from public.aircraft_types t where t.id = p_type
$$;

-- Lessor pool for one type: aircraft available, target, shortage premium on rent, days to arrive.
create or replace function game.pool_state(p_world uuid, p_type text,
  out n_avail int, out n_target int, out rent_mult numeric, out lead_days int)
language plpgsql stable set search_path = '' as $$
declare
  v_short numeric;
  v_min numeric := game.param('lease_lead_min_days');
begin
  select count(*) into n_avail from public.aircraft x
   where x.world_id = p_world and x.type_id = p_type and x.status = 'pool';
  select coalesce(max(x.target), 0) into n_target from public.pool_targets x
   where x.world_id = p_world and x.type_id = p_type;
  v_short := case when n_target > 0 then greatest(0, 1 - n_avail::numeric / n_target) else 1 end;
  rent_mult := round(1 + game.param('pool_premium_k') * v_short * v_short, 4);
  lead_days := round(v_min + (game.param('lease_lead_max_days') - v_min) * v_short)::int;
end $$;

create or replace function game.lease_rent_usd(p_world uuid, p_type text, p_built_day int, p_day int) returns numeric
language sql stable set search_path = '' as $$
  select round(t.lease_usd_month * ps.rent_mult
               * greatest(game.param('rent_age_floor'), 1 - game.param('age_rent_per_year') * greatest(0, p_day - p_built_day) / 364.0))
  from public.aircraft_types t, game.pool_state(p_world, p_type) ps
  where t.id = p_type
$$;

-- Manufacturer queue: the first free delivery slot at least order_lead_min_days away, and its price.
create or replace function game.order_quote(p_world uuid, p_type text, p_day int,
  out delivery_day int, out price_usd numeric)
language plpgsql stable set search_path = '' as $$
declare
  rt public.aircraft_types%rowtype;
  v_lead int := game.param('order_lead_min_days')::int;
  v_slots int;
  v_q int;
  v_n int;
begin
  select * into rt from public.aircraft_types where id = p_type;
  select greatest(1, round(rt.deliveries_per_airline_qtr * x.max_airlines))::int into v_slots
    from public.worlds x where x.id = p_world;
  v_q := (p_day + v_lead - 1 + 90) / 91;   -- first quarter that starts on or after day + lead
  loop
    select count(*) into v_n from public.aircraft x join public.aircraft_terms y on y.aircraft_id = x.id
     where x.world_id = p_world and x.type_id = p_type and x.status = 'delivering'
       and y.ordered_day is not null and (x.available_day - 1) / 91 = v_q;
    exit when v_n < v_slots;
    v_q := v_q + 1;
  end loop;
  delivery_day := v_q * 91 + 1 + (v_n * 91) / v_slots;
  price_usd := round(rt.price_usd_m * 1e6
                     * (1 + game.param('order_premium_k') * greatest(0, delivery_day - p_day - v_lead) / 364.0));
end $$;

-- Wet lease rate per block hour: a multiple of the all-in hourly cost of rent, crew and maintenance.
create or replace function game.wet_rate_usd(p_world uuid, p_type text) returns numeric
language sql stable set search_path = '' as $$
  select round(game.param('wet_lease_mult') * (
           (t.lease_usd_month / 30.33
              + (t.pilot_fixed_inr_day + l.cabin_crew * game.param('cabin_fixed_inr_day')) / w.fx_inr_usd)
             / game.param('wet_ref_hours_day')
           + t.maint_usd_fh + t.maint_usd_cycle / 2.0
           + (t.pilot_inr_bh + l.cabin_crew * game.param('cabin_inr_bh')) / w.fx_inr_usd))
  from public.aircraft_types t, public.worlds w, game.std_layout(t.id, 1) s,
       public.layout_calc(t.id, s.biz_rows, s.biz_pitch, s.econ_pitch, w.crew_rule) l
  where t.id = p_type and w.id = p_world
$$;

create or replace function game.check_base(p_airline uuid, p_base text, p_runway int) returns text
language plpgsql stable set search_path = '' as $$
declare
  v_base text := upper(trim(p_base));
begin
  if not exists (select 1 from public.bases where airline_id = p_airline and iata = v_base) then
    raise exception 'You have no base at %', v_base;
  end if;
  if (select runway_class from public.airports where iata = v_base) < p_runway then
    raise exception 'The runway at % is too short for this aircraft', v_base;
  end if;
  return v_base;
end $$;

create or replace function game.check_fleet_room(p_airline uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if (select count(*) from public.aircraft where airline_id = p_airline) >= game.param('fleet_max') then
    raise exception 'Your fleet is at the limit of % aircraft', game.param('fleet_max')::int;
  end if;
end $$;

create or replace function game.check_fares(p_ref int, p_econ int, p_biz int, out econ int, out biz int)
language plpgsql stable set search_path = '' as $$
declare
  v_lo numeric := game.param('fare_min_mult');
  v_hi numeric := game.param('fare_max_mult');
  v_bref numeric := p_ref * game.param('biz_fare_mult');
begin
  econ := coalesce(p_econ, p_ref);
  biz := coalesce(p_biz, round(v_bref)::int);
  if econ not between p_ref * v_lo and p_ref * v_hi then
    raise exception 'Economy fare must be between Rs % and Rs %', ceil(p_ref * v_lo), floor(p_ref * v_hi);
  end if;
  if biz not between v_bref * v_lo and v_bref * v_hi then
    raise exception 'Business fare must be between Rs % and Rs %', ceil(v_bref * v_lo), floor(v_bref * v_hi);
  end if;
end $$;

-- Does this aircraft's weekly plan fit its range and flying window? Returns the problem, or null.
-- p_route / p_trips: a rotation being added or changed, checked together with the rest.
create or replace function game.schedule_issue(p_aircraft uuid, p_range int, p_turn numeric,
                                               p_route uuid default null, p_trips int default null) returns text
language plpgsql stable set search_path = '' as $$
declare
  rt public.aircraft_types%rowtype;
  v_hours numeric;
  v_far text;
begin
  select y.* into rt from public.aircraft x join public.aircraft_types y on y.id = x.type_id where x.id = p_aircraft;
  with plan as (
    select r.origin, r.dest, m.km, ro.weekly_trips as trips
      from public.rotations ro
      join public.routes r on r.id = ro.route_id
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where ro.aircraft_id = p_aircraft and r.id is distinct from p_route
    union all
    select r.origin, r.dest, m.km, p_trips
      from public.routes r
      join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
     where r.id = p_route and p_trips > 0)
  select sum(trips * 2 * (km::numeric / rt.cruise_kmh + rt.block_offset_h + p_turn / 60)),
         min(origin || '-' || dest) filter (where km > p_range)
    into v_hours, v_far from plan;
  if v_far is not null then
    return 'Route ' || v_far || ' is beyond this cabin''s range of ' || p_range || ' km';
  end if;
  if coalesce(v_hours, 0) > 7 * rt.day_window_h then
    return 'This plan needs ' || round(v_hours, 1) || ' hours a week; the aircraft can fly '
           || round(7 * rt.day_window_h) || '. Cut some frequencies first.';
  end if;
  return null;
end $$;

-- Adds aircraft to the lessor pool with a mix of ages and cabins.
create or replace function game.fill_pool(p_world uuid, p_type text, p_n int, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  v_rule text;
  v_age numeric := game.param('pool_max_age_years');
  s record;
  l record;
begin
  select crew_rule into v_rule from public.worlds where id = p_world;
  for i in 1..p_n loop
    select * into s from game.std_layout(p_type, floor(random() * 3)::int);
    select * into l from public.layout_calc(p_type, s.biz_rows, s.biz_pitch, s.econ_pitch, v_rule);
    insert into public.aircraft (world_id, type_id, reg, built_day, status, biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
    values (p_world, p_type, game.next_reg(), p_day - floor(random() * v_age * 364)::int, 'pool',
            s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ);
  end loop;
  return greatest(p_n, 0);
end $$;

-- ---------- World start, pause, resume ----------

create or replace function game.start_world(p_world uuid) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  r record;
  v_target int;
begin
  select * into rw from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if rw.status <> 'setup' then raise exception 'This world has already been started'; end if;
  for r in select id, pool_per_airline from public.aircraft_types order by sort loop
    v_target := ceil(r.pool_per_airline * rw.max_airlines)::int;
    insert into public.pool_targets (world_id, type_id, target) values (p_world, r.id, v_target)
      on conflict (world_id, type_id) do update set target = excluded.target;
    perform game.fill_pool(p_world, r.id, v_target, 1);
  end loop;
  insert into public.events (world_id, kind, announced_day, starts_day, payload)
  select p_world, 'airport_opening', greatest(1, opens_day - 91), opens_day, jsonb_build_object('iata', iata, 'city', city)
    from public.airports where opens_day > 0;
  update public.worlds
     set status = 'running', started_at = now(), paused_at = null, paused_seconds = 0,
         fuel_walk = fuel_inr_kg, fx_walk = fx_inr_usd
   where id = p_world;
end $$;

create or replace function public.admin_start_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_admin();
  perform game.start_world(p_world);
end $$;

create or replace function public.admin_pause_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_admin();
  update public.worlds set status = 'paused', paused_at = now() where id = p_world and status = 'running';
  if not found then raise exception 'This world is not running'; end if;
end $$;

create or replace function public.admin_resume_world(p_world uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform game.require_admin();
  update public.worlds
     set status = 'running', paused_seconds = paused_seconds + extract(epoch from now() - paused_at), paused_at = null
   where id = p_world and status = 'paused';
  if not found then raise exception 'This world is not paused'; end if;
end $$;

-- ---------- Read helper: today's aircraft market ----------

create or replace function public.aircraft_market(p_world uuid)
returns table (type_id text, pool_available int, pool_target int, rent_mult numeric, lease_lead_days int,
               order_price_usd numeric, order_delivery_day int, wet_usd_bh numeric, wet_lead_days int)
language sql stable security definer set search_path = '' as $$
  select t.id, ps.n_avail, ps.n_target, ps.rent_mult, ps.lead_days, oq.price_usd, oq.delivery_day,
         game.wet_rate_usd(w.id, t.id), game.param('wet_lead_days')::int
  from public.worlds w
  cross join public.aircraft_types t
  cross join lateral game.pool_state(w.id, t.id) ps
  cross join lateral game.order_quote(w.id, t.id, w.game_day + 1) oq
  where w.id = p_world
  order by t.sort
$$;

-- ---------- Player actions ----------

-- Join a world with its invite code and found an airline. The first base is free.
create or replace function public.found_airline(p_invite text, p_name text, p_code text, p_base text,
                                                p_display_name text default null, p_livery jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rp public.airports%rowtype;
  v_uid uuid := auth.uid();
  v_name text := trim(p_name);
  v_code text := upper(trim(p_code));
  v_day int;
  v_id uuid;
begin
  if v_uid is null and not game.is_server() then raise exception 'Sign in first'; end if;
  select x.* into rw from public.world_secrets s join public.worlds x on x.id = s.world_id
   where s.invite_code = lower(trim(p_invite)) for update of x;
  if not found then raise exception 'That invite code is not valid'; end if;
  if rw.status = 'ended' then raise exception 'This world has ended'; end if;
  v_day := rw.game_day + 1;
  if (select count(*) from public.airlines where world_id = rw.id and not is_ai) >= rw.max_airlines then
    raise exception 'This world is full';
  end if;
  if v_uid is not null and exists (select 1 from public.airlines where world_id = rw.id and user_id = v_uid) then
    raise exception 'You already have an airline in this world';
  end if;
  if v_name is null or length(v_name) not between 3 and 30 then raise exception 'Airline name must be 3 to 30 characters'; end if;
  if v_code is null or v_code !~ '^[A-Z0-9]{2,3}$' then raise exception 'Airline code must be 2 or 3 letters or digits'; end if;
  if exists (select 1 from public.airlines where world_id = rw.id and (lower(name) = lower(v_name) or code = v_code)) then
    raise exception 'That name or code is already taken in this world';
  end if;
  select * into rp from public.airports where iata = upper(trim(p_base));
  if not found or not rp.is_india then raise exception 'Bases can only be opened at Indian airports'; end if;
  if rp.opens_day > v_day then raise exception '% airport has not opened yet', rp.city; end if;
  if length(coalesce(p_livery, '{}')::text) > 2000 then raise exception 'That livery is too large'; end if;

  if v_uid is not null then
    insert into public.profiles (user_id, display_name)
    values (v_uid, left(coalesce(nullif(trim(p_display_name), ''), v_name), 40)) on conflict (user_id) do nothing;
  end if;
  insert into public.airlines (world_id, user_id, name, code, livery, created_day)
  values (rw.id, v_uid, v_name, v_code, coalesce(p_livery, '{}'), v_day) returning id into v_id;
  insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr)
  values (v_id, 0, game.param('credit_limit_inr'));
  perform game.book(v_id, v_day, game.param('start_cash_inr'), 'equity', 'Founding equity');
  insert into public.bases (airline_id, iata, opened_day) values (v_id, rp.iata, v_day);
  insert into public.news (world_id, game_day, airline_id, kind, body)
  values (rw.id, v_day, v_id, 'founded', v_name || ' has been founded, based at ' || rp.city || '.');
  return v_id;
end $$;

create or replace function public.open_base(p_airline uuid, p_iata text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rp public.airports%rowtype;
  v_day int;
  v_cost numeric := game.param('base_open_inr');
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rp from public.airports where iata = upper(trim(p_iata));
  if not found or not rp.is_india then raise exception 'Bases can only be opened at Indian airports'; end if;
  if rp.opens_day > v_day then raise exception '% airport has not opened yet', rp.city; end if;
  if exists (select 1 from public.bases where airline_id = p_airline and iata = rp.iata) then
    raise exception 'You already have a base at %', rp.iata;
  end if;
  perform game.book(p_airline, v_day, -v_cost, 'base', 'Opened a base at ' || rp.city, -v_cost);
  insert into public.bases (airline_id, iata, opened_day) values (p_airline, rp.iata, v_day);
end $$;

-- Operating lease of one aircraft from the lessor pool.
create or replace function public.lease_aircraft(p_airline uuid, p_aircraft uuid, p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  v_day int; v_base text; v_lead int; v_rent numeric; v_dep numeric;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rc from public.aircraft where id = p_aircraft and world_id = rw.id for update;
  if not found or rc.status <> 'pool' then raise exception 'That aircraft is no longer available'; end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, (select runway_class from public.aircraft_types where id = rc.type_id));
  select lead_days into v_lead from game.pool_state(rw.id, rc.type_id);
  v_rent := game.lease_rent_usd(rw.id, rc.type_id, rc.built_day, v_day);
  v_dep := round(v_rent * game.param('lease_deposit_months') * rw.fx_inr_usd);
  perform game.book(p_airline, v_day, -v_dep, 'deposit', 'Lease deposit for ' || rc.reg);
  update public.aircraft set airline_id = p_airline, status = 'delivering', available_day = v_day + v_lead, base_iata = v_base
   where id = rc.id;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
  values (rc.id, p_airline, 'lease', v_rent, v_day + v_lead + game.param('lease_term_days')::int, v_dep, v_day + v_lead);
  return jsonb_build_object('aircraft_id', rc.id, 'reg', rc.reg, 'arrives_day', v_day + v_lead,
                            'rent_usd_month', v_rent, 'deposit_inr', v_dep);
end $$;

-- New aircraft from the manufacturer, in the cabin the buyer chooses. p_pay: 'cash' or 'slb' (sale and leaseback).
create or replace function public.order_aircraft(p_airline uuid, p_type text, p_base text, p_biz_rows int,
                                                 p_biz_pitch int, p_econ_pitch int, p_pay text default 'cash')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rt public.aircraft_types%rowtype;
  l record; q record;
  v_day int; v_base text; v_dep numeric; v_id uuid; v_reg text;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rt from public.aircraft_types where id = p_type;
  if not found then raise exception 'Unknown aircraft type'; end if;
  if p_pay is null or p_pay not in ('cash', 'slb') then raise exception 'Payment plan must be cash or slb'; end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, rt.runway_class);
  select * into l from public.layout_calc(p_type, p_biz_rows, p_biz_pitch, p_econ_pitch, rw.crew_rule);
  if not l.valid then raise exception '%', l.reason; end if;
  perform pg_advisory_xact_lock(hashtextextended('order:' || rw.id || ':' || p_type, 0));
  select * into q from game.order_quote(rw.id, p_type, v_day);
  if q.delivery_day > rw.season_days then raise exception 'The next delivery slot is after the season ends'; end if;
  v_dep := round(q.price_usd * game.param('order_deposit_share') * rw.fx_inr_usd);
  perform game.book(p_airline, v_day, -v_dep, 'deposit', 'Order deposit for one ' || rt.name);
  insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                               biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
  values (rw.id, p_type, p_airline, game.next_reg(), q.delivery_day, 'delivering', q.delivery_day, v_base, p_biz_rows,
          case when p_biz_rows > 0 then case when rt.biz_kind = 'lieflat' then 44 else p_biz_pitch end end,
          p_econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into v_id, v_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, deposit_inr, price_usd, start_day, ordered_day, pay_plan)
  values (v_id, p_airline, 'owned', v_dep, q.price_usd, q.delivery_day, v_day, p_pay);
  return jsonb_build_object('aircraft_id', v_id, 'reg', v_reg, 'arrives_day', q.delivery_day,
                            'price_usd', q.price_usd, 'deposit_inr', v_dep);
end $$;

-- Aircraft with crew, paid by the block hour. Always available.
create or replace function public.wet_lease(p_airline uuid, p_type text, p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rt public.aircraft_types%rowtype;
  s record; l record;
  v_day int; v_base text; v_arr int; v_rate numeric; v_id uuid; v_reg text;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rt from public.aircraft_types where id = p_type;
  if not found then raise exception 'Unknown aircraft type'; end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, rt.runway_class);
  select * into s from game.std_layout(p_type, 1);
  select * into l from public.layout_calc(p_type, s.biz_rows, s.biz_pitch, s.econ_pitch, rw.crew_rule);
  v_arr := v_day + game.param('wet_lead_days')::int;
  v_rate := game.wet_rate_usd(rw.id, p_type);
  insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                               biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
  values (rw.id, p_type, p_airline, game.next_reg(), v_day - game.param('wet_age_years')::int * 364, 'delivering', v_arr, v_base,
          s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into v_id, v_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, wet_usd_bh, start_day)
  values (v_id, p_airline, 'wet', v_rate, v_arr);
  return jsonb_build_object('aircraft_id', v_id, 'reg', v_reg, 'arrives_day', v_arr, 'wet_usd_bh', v_rate);
end $$;

-- Hand back a lease, end a wet lease, cancel an order, or sell an owned aircraft.
create or replace function public.return_aircraft(p_airline uuid, p_aircraft uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rm public.aircraft_terms%rowtype;
  v_day int; v_cash numeric := 0; v_pnl numeric := 0; v_book numeric; v_note text; v_pool boolean := false;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('delivering', 'active', 'grounded', 'refit') then
    raise exception 'That aircraft is not in your fleet';
  end if;
  select * into rm from public.aircraft_terms where aircraft_id = rc.id;
  if rm.holding = 'lease' then
    -- the rent for the rest of the term is owed, up to the deposit
    v_pnl := -case when rc.status = 'delivering' then rm.deposit_inr
                   else least(rm.deposit_inr, round(rm.lease_usd_month * rw.fx_inr_usd / 30.33
                                                    * greatest(0, rm.lease_end_day - v_day))) end;
    v_cash := rm.deposit_inr + v_pnl; v_pool := true;
    v_note := 'Returned ' || rc.reg || case when v_pnl < 0 then '; early-return fee taken from the deposit' else '' end;
  elsif rm.holding = 'wet' then
    v_note := 'Ended the wet lease of ' || rc.reg;
  elsif rc.status = 'delivering' then
    v_pnl := -rm.deposit_inr;
    v_note := 'Cancelled the order for ' || rc.reg || '; deposit forfeited';
  else
    v_book := round(game.book_value_usd(rm.price_usd, rm.start_day, v_day) * rw.fx_inr_usd);
    v_cash := round(v_book * game.param('sale_discount')); v_pnl := v_cash - v_book; v_pool := true;
    v_note := 'Sold ' || rc.reg;
  end if;
  delete from public.rotations where aircraft_id = rc.id;
  delete from public.aircraft_terms where aircraft_id = rc.id;
  update public.aircraft
     set airline_id = null, base_iata = null, available_day = v_day,
         status = case when v_pool then 'pool' else 'returned' end
   where id = rc.id;
  perform game.book(p_airline, v_day, v_cash, 'return', v_note, v_pnl);
  return jsonb_build_object('cash_inr', v_cash, 'pnl_inr', v_pnl);
end $$;

-- Change the cabin. The aircraft is on the ground for the refit.
create or replace function public.refit_aircraft(p_airline uuid, p_aircraft uuid, p_biz_rows int,
                                                 p_biz_pitch int, p_econ_pitch int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  l record;
  v_day int; v_cost numeric; v_issue text; v_bp int;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('active', 'grounded') then
    raise exception 'Only an aircraft in service can be refitted';
  end if;
  if (select holding from public.aircraft_terms where aircraft_id = rc.id) = 'wet' then
    raise exception 'A wet-leased aircraft cannot be refitted';
  end if;
  select * into l from public.layout_calc(rc.type_id, p_biz_rows, p_biz_pitch, p_econ_pitch, rw.crew_rule);
  if not l.valid then raise exception '%', l.reason; end if;
  v_bp := case when p_biz_rows > 0 then coalesce((select 44 from public.aircraft_types where id = rc.type_id and biz_kind = 'lieflat'), p_biz_pitch) end;
  if l.seats_econ = rc.seats_econ and l.seats_biz = rc.seats_biz and p_econ_pitch = rc.econ_pitch
     and v_bp is not distinct from rc.biz_pitch then
    raise exception 'That is the cabin it already has';
  end if;
  v_issue := game.schedule_issue(rc.id, l.range_km, l.min_turn_min);
  if v_issue is not null then raise exception '%', v_issue; end if;
  v_cost := game.param('refit_fixed_inr')
            + game.param('refit_per_seat_inr') * (abs(l.seats_econ - rc.seats_econ) + abs(l.seats_biz - rc.seats_biz));
  perform game.book(p_airline, v_day, -v_cost, 'refit', 'Refit of ' || rc.reg, -v_cost);
  update public.aircraft
     set biz_rows = p_biz_rows, biz_pitch = v_bp, econ_pitch = p_econ_pitch, seats_biz = l.seats_biz,
         seats_econ = l.seats_econ, status = 'refit', available_day = v_day + game.param('refit_days')::int
   where id = rc.id;
  return jsonb_build_object('cost_inr', v_cost, 'back_day', v_day + game.param('refit_days')::int, 'seats', l.seats);
end $$;

-- Move an aircraft with no rotations to another of the airline's bases.
create or replace function public.rebase_aircraft(p_airline uuid, p_aircraft uuid, p_base text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  v_base text;
begin
  rw := game.actor(p_airline);
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found then raise exception 'That aircraft is not in your fleet'; end if;
  if exists (select 1 from public.rotations where aircraft_id = rc.id) then
    raise exception 'Remove this aircraft''s rotations before moving it';
  end if;
  v_base := game.check_base(p_airline, p_base, (select runway_class from public.aircraft_types where id = rc.type_id));
  update public.aircraft set base_iata = v_base where id = rc.id;
end $$;

-- Open (or reopen) a route from one of the airline's bases. Fares default to the reference fares.
create or replace function public.open_route(p_airline uuid, p_origin text, p_dest text,
                                             p_fare_econ int default null, p_fare_biz int default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rk public.markets%rowtype;
  f record;
  v_day int; v_o text := upper(trim(p_origin)); v_d text := upper(trim(p_dest)); v_id uuid;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  if not exists (select 1 from public.bases where airline_id = p_airline and iata = v_o) then
    raise exception 'Routes must start at one of your bases';
  end if;
  select * into rk from public.markets where a = least(v_o, v_d) and b = greatest(v_o, v_d);
  if not found then raise exception 'There is no market between % and %', v_o, v_d; end if;
  if exists (select 1 from public.airports where iata in (v_o, v_d) and opens_day > v_day) then
    raise exception 'That airport has not opened yet';
  end if;
  select * into f from game.check_fares(rk.ref_fare, p_fare_econ, p_fare_biz);
  select id into v_id from public.routes
   where airline_id = p_airline and least(origin, dest) = rk.a and greatest(origin, dest) = rk.b;
  if found then
    update public.routes set status = 'open', origin = v_o, dest = v_d, fare_econ = f.econ, fare_biz = f.biz, opened_day = v_day
     where id = v_id and status = 'closed';
    if not found then raise exception 'You already fly this route'; end if;
  else
    insert into public.routes (world_id, airline_id, origin, dest, fare_econ, fare_biz, opened_day)
    values (rw.id, p_airline, v_o, v_d, f.econ, f.biz, v_day) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.close_route(p_airline uuid, p_route uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
begin
  rw := game.actor(p_airline);
  update public.routes set status = 'closed' where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  delete from public.rotations where route_id = p_route;
end $$;

-- Fares take effect on the next game day processed. Null keeps the current fare.
create or replace function public.set_fares(p_airline uuid, p_route uuid, p_fare_econ int, p_fare_biz int default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rr public.routes%rowtype;
  f record;
begin
  rw := game.actor(p_airline);
  select * into rr from public.routes where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  select * into f from game.check_fares(
    (select ref_fare from public.markets where a = least(rr.origin, rr.dest) and b = greatest(rr.origin, rr.dest)),
    coalesce(p_fare_econ, rr.fare_econ), coalesce(p_fare_biz, rr.fare_biz));
  update public.routes set fare_econ = f.econ, fare_biz = f.biz where id = p_route;
end $$;

-- Round trips a week for one aircraft on one route. 0 removes the rotation.
create or replace function public.set_rotation(p_airline uuid, p_aircraft uuid, p_route uuid, p_weekly_trips int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rr public.routes%rowtype;
  l record;
  v_issue text;
begin
  rw := game.actor(p_airline);
  select * into rc from public.aircraft where id = p_aircraft and airline_id = p_airline for update;
  if not found or rc.status not in ('delivering', 'active', 'grounded', 'refit') then
    raise exception 'That aircraft is not in your fleet';
  end if;
  select * into rr from public.routes where id = p_route and airline_id = p_airline and status = 'open';
  if not found then raise exception 'That route is not open'; end if;
  if coalesce(p_weekly_trips, 0) = 0 then
    delete from public.rotations where aircraft_id = rc.id and route_id = rr.id;
    return jsonb_build_object('weekly_trips', 0);
  end if;
  if p_weekly_trips not between 1 and 84 then raise exception 'Round trips a week must be between 0 and 84'; end if;
  if rc.base_iata is null or rc.base_iata not in (rr.origin, rr.dest) then
    raise exception 'This aircraft is based at %, which is not on this route', rc.base_iata;
  end if;
  if (select min(runway_class) from public.airports where iata in (rr.origin, rr.dest))
     < (select runway_class from public.aircraft_types where id = rc.type_id) then
    raise exception 'A runway on this route is too short for this aircraft';
  end if;
  select * into l from public.layout_calc(rc.type_id, rc.biz_rows, rc.biz_pitch, rc.econ_pitch, rw.crew_rule);
  v_issue := game.schedule_issue(rc.id, l.range_km, l.min_turn_min, rr.id, p_weekly_trips);
  if v_issue is not null then raise exception '%', v_issue; end if;
  insert into public.rotations (aircraft_id, route_id, weekly_trips) values (rc.id, rr.id, p_weekly_trips)
    on conflict (aircraft_id, route_id) do update set weekly_trips = excluded.weekly_trips;
  return jsonb_build_object('weekly_trips', p_weekly_trips);
end $$;

create or replace function public.set_marketing(p_airline uuid, p_inr_day numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
begin
  rw := game.actor(p_airline);
  if p_inr_day is null or p_inr_day not between 0 and game.param('marketing_max_inr_day') then
    raise exception 'Marketing spend must be between 0 and Rs % crore a day', round(game.param('marketing_max_inr_day') / 1e7, 1);
  end if;
  update public.airlines set marketing_inr_day = round(p_inr_day) where id = p_airline;
end $$;

create or replace function public.borrow(p_airline uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
begin
  rw := game.actor(p_airline);
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount to borrow'; end if;
  update public.airline_finance set debt_inr = debt_inr + round(p_amount)
   where airline_id = p_airline and debt_inr + round(p_amount) <= credit_limit_inr;
  if not found then raise exception 'That is more than your credit line allows'; end if;
  perform game.book(p_airline, rw.game_day + 1, round(p_amount), 'borrow', 'Drew on the credit line');
end $$;

create or replace function public.repay(p_airline uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
begin
  rw := game.actor(p_airline);
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount to repay'; end if;
  update public.airline_finance set debt_inr = debt_inr - round(p_amount)
   where airline_id = p_airline and debt_inr >= round(p_amount);
  if not found then raise exception 'That is more than you owe'; end if;
  perform game.book(p_airline, rw.game_day + 1, -round(p_amount), 'repay', 'Repaid the credit line');
end $$;

-- ---------- Permissions ----------
-- Engine internals stay closed. Public functions: signed-in players and the server only.

revoke all on all functions in schema game from public, anon, authenticated;
revoke all on all sequences in schema game from public, anon, authenticated;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prosecdef loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
