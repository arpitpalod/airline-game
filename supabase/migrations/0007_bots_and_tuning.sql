-- Stage 2c: computer-run airlines and tuning. Settles open items 7 to 13 of docs/SPEC.md section 17.
-- 7  Six computer-run airlines contest the trunk routes from day 1 (bots, end of this file).
-- 8  Founding an airline comes with one wet-leased aircraft that can fly on day 1, at the normal wet-lease rate.
-- 9  Lessors place at most a few aircraft with one airline a quarter, so no early joiner can corner the pool.
-- 10 Airlines are grouped against the option of not flying (nested logit): more airlines no longer means much more travel.
-- 11 Slot prices: lower base and cap; slot caps scale with the world's demand_scale.
-- Also: head-office overhead per seat rather than per aircraft, so small aircraft are not overcharged;
--       no steady fall of the rupee (fares are fixed in rupees, so it squeezed every airline all season);
--       reference fares re-fitted to costs so short routes are not loss-making by construction.
-- 12 Business travellers weigh the business cabin's comfort against its fare; those who find it full can take economy;
--    spilled travellers weigh fares;
--    an idle aircraft of the same type at the same base covers a grounded one.
-- 13 Aircraft loans: an order can be paid with a loan secured on the aircraft. The season score now counts profit
--    after interest, so how an aircraft is financed does not change the score by itself.
-- This migration only adds and updates. It drops nothing.

-- ---------- Schema additions ----------

alter table public.worlds
  add column bot_scale numeric not null default 1 check (bot_scale >= 0);   -- computer-run fleets, x demand_scale; 0 = none

alter table public.aircraft_types
  add column starter_rank int;   -- founding gift: the lowest rank whose runway fits the first base

alter table public.aircraft_terms
  add column finance_loan boolean not null default false,   -- order: balance paid by an aircraft loan on delivery
  add column loan_usd numeric,                              -- owned aircraft: loan still outstanding
  add column loan_pay_usd_day numeric;                      -- owned aircraft: principal repaid a day

alter table public.airline_daily
  add column loan_repaid numeric not null default 0;        -- loan principal paid (cash, not a cost)

update public.aircraft_types set starter_rank = v.r
from (values ('A20N', 1), ('AT76', 2)) as v(id, r) where aircraft_types.id = v.id;

insert into public.game_params (key, num, note) values
('starter_aircraft', 1, 'wet-leased aircraft that come with a new airline, ready on its first day'),
('pool_lease_max_qtr', 6, 'most aircraft one airline can lease from the pool in 91 days'),
('nest_lambda', 0.5, 'how alike travellers find the airlines: 1 = every airline is a separate option, near 0 = one shared option'),
('seg_biz_cabin_a', -2.2, 'business travellers'' extra reluctance to pay for the business cabin, on top of its comfort'),
('biz_downgrade_share', 0.5, 'business travellers who find the business cabin full and take economy on the same airline'),
('loan_rate_year', 0.08, 'aircraft loan interest, dollar loan'),
('loan_years', 12, 'aircraft loan term'),
('bot_lf_high', 0.88, 'computer-run airlines raise fares above this load factor'),
('bot_lf_low', 0.78, 'and cut them below this one'),
('bot_fare_step', 0.03, 'their daily fare move'),
('bot_max_age_years', 8, 'oldest aircraft in a computer-run fleet'),
('bot_moves_qtr', 3, 'aircraft a computer-run airline may move between its routes each quarter'),
('bot_move_lf_low', 0.75, 'it moves aircraft away from routes below this load factor'),
('bot_move_lf_high', 0.90, 'to routes above this one'),
('bot_floor_lf', 0.80, 'computer-run airlines never price below the fare that breaks even at this load factor'),
('bot_return_lf', 0.70, 'they hand an aircraft back to the lessors when a route stays below this load factor'),
('bot_returns_qtr', 2, 'at most this many a quarter'),
('bot_adds_qtr', 2, 'aircraft a computer-run airline may add each quarter to busy routes with fares in the top half of its band'),
('bot_add_lf', 0.85, 'a route counts as busy above this load factor'),
('bot_fleet_max_mult', 2, 'its fleet never grows beyond this multiple of its starting fleet'),
('bot_window_use', 0.88, 'share of the flying window its aircraft are scheduled for'),
('overhead_seat_inr_day', 1000, 'head-office cost per seat in the fleet a day: Rs 1.8 lakh for a 180-seat A320neo');

-- Utility constants rise by (1 - lambda) x ln 3, so 65% of potential still flies when three airlines
-- each offer four flights a day at reference fares.
update public.game_params set num = v.n
from (values ('seg_biz_a', 0.0993), ('seg_lei_a', 2.3693), ('seg_bud_a', 4.1393),
             ('slot_base_inr', 1500), ('slot_util_cap', 0.90), ('overhead_aircraft_inr_day', 0),
             ('ref_fare_fixed', 2100), ('ref_fare_per_km', 3.3), ('fx_drift_year', 0)) as v(k, n)
where key = v.k;

-- Reference fares now cover a leased A320neo's costs with about a 7% margin at an 85% load factor
-- on any route length (they were Rs 1,800 + 3.4 per km: short routes lost money). Markets are rebuilt to store them.
select game.rebuild_markets();

-- Turboprop maintenance closer to published ATR 72 costs (about $350 a block hour); it was about twice that.
update public.aircraft_types set maint_usd_fh = 300, maint_usd_cycle = 100 where id = 'AT76';
update public.game_params set note = 'share of spilled travellers who try another airline when its offer is as good as the one they lost'
 where key = 'spill_recapture';
update public.game_params set note = 'utility constants: 65% of potential flies when 3 airlines offer 4 flights a day at reference fares (with nest_lambda)'
 where key = 'seg_biz_a';

-- ---------- Computer-run airlines: reference data ----------

create table public.bot_airlines (
  code       text primary key,
  name       text not null unique,
  style      text not null,
  fare_lo    numeric not null,   -- fare band, as multiples of the reference fare
  fare_hi    numeric not null,
  defend_lo  numeric not null,   -- lowest fare when a player undercuts it on a route from one of its bases
  mkt_inr_pax numeric not null,  -- marketing rupees a day per daily passenger
  sort       int not null
);

create table public.bot_network (  -- fleet at demand_scale 1: aircraft on the route and round trips a week each
  code         text not null references public.bot_airlines,
  origin       text not null references public.airports,
  dest         text not null references public.airports,
  type_id      text not null references public.aircraft_types,
  biz_rows     int not null,
  biz_pitch    int,
  econ_pitch   int not null,
  aircraft     int not null,
  weekly_trips int not null,
  primary key (code, origin, dest)
);

do $$
declare t text;
begin
  foreach t in array array['bot_airlines', 'bot_network'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy read_all on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;

insert into public.bot_airlines (code, name, style, fare_lo, fare_hi, defend_lo, mkt_inr_pax, sort) values
('SRW', 'Sarus Airways',    'Full service: two-class trunks from Delhi and Mumbai, long haul to London and Singapore', 1.00, 1.60, 0.95, 60, 1),
('KOL', 'Koel Air',         'Large low-cost carrier: dense cabins on the busiest trunks',                             0.90, 1.30, 0.85, 20, 2),
('BLB', 'Bulbul Air',       'Low-cost carrier from Bengaluru, Chennai and Kolkata',                                    0.90, 1.30, 0.85, 15, 3),
('MYN', 'Myna Regional',    'Turboprop short hops from Hyderabad and Bengaluru',                                       1.05, 1.60, 1.00, 10, 4),
('HRN', 'Hornbill Airways', 'East and North-East from Kolkata, Guwahati and Bhubaneswar',                              0.95, 1.40, 0.90, 10, 5),
('FLM', 'Flamingo Air',     'Kerala and Mumbai to the Gulf, plus leisure routes',                                      0.90, 1.40, 0.85, 15, 6);

insert into public.bot_network (code, origin, dest, type_id, biz_rows, biz_pitch, econ_pitch, aircraft, weekly_trips) values
('SRW','BOM','DEL','A20N',3,38,30,12,20),
('KOL','BOM','DEL','A21N',0,null,28,19,19),
('SRW','DEL','BLR','A20N',3,38,30,16,16),
('KOL','BLR','DEL','A21N',0,null,28,17,15),
('BLB','BLR','DEL','A20N',0,null,28,8,16),
('SRW','BOM','BLR','A20N',3,38,30,6,24),
('KOL','BLR','BOM','A20N',0,null,28,12,23),
('SRW','DEL','HYD','A20N',3,38,30,7,19),
('KOL','DEL','HYD','A20N',0,null,28,14,19),
('SRW','DEL','MAA','A20N',3,38,30,9,15),
('BLB','MAA','DEL','A20N',0,null,28,9,15),
('SRW','DEL','CCU','A20N',3,38,30,7,19),
('HRN','CCU','DEL','A20N',0,null,28,8,18),
('KOL','BOM','HYD','A20N',0,null,28,9,26),
('KOL','BLR','HYD','A20N',0,null,28,3,29),
('MYN','BLR','HYD','AT76',0,null,28,3,30),
('SRW','BOM','CCU','A20N',3,38,30,3,16),
('BLB','CCU','BOM','A20N',0,null,28,3,16),
('SRW','BOM','MAA','A20N',3,38,30,2,21),
('BLB','MAA','BOM','A20N',0,null,28,2,21),
('KOL','DEL','PNQ','A20N',0,null,28,5,20),
('BLB','BLR','CCU','A20N',0,null,28,5,17),
('KOL','DEL','AMD','A20N',0,null,28,3,24),
('BLB','CCU','HYD','A20N',0,null,28,2,19),
('MYN','HYD','MAA','AT76',0,null,28,3,28),
('HRN','GAU','DEL','A20N',0,null,28,2,17),
('MYN','BLR','MAA','AT76',0,null,28,2,38),
('BLB','CCU','MAA','A20N',0,null,28,1,18),
('MYN','BLR','COK','AT76',0,null,28,1,33),
('MYN','BLR','GOI','AT76',0,null,28,1,29),
('MYN','HYD','PNQ','AT76',0,null,28,2,29),
('HRN','CCU','GAU','AT76',0,null,28,1,29),
('HRN','BBI','DEL','A20N',0,null,28,1,19),
('FLM','BOM','GOI','A20N',0,null,28,1,30),
('FLM','BOM','COK','A20N',0,null,28,1,21),
('SRW','DEL','DXB','A21N',3,38,30,3,13),
('KOL','DEL','DXB','A20N',0,null,28,3,13),
('SRW','BOM','DXB','A21N',3,38,30,2,14),
('FLM','BOM','DXB','A21N',0,null,28,2,14),
('FLM','COK','DXB','A21N',0,null,28,2,11),
('FLM','BOM','AUH','A21N',0,null,28,1,14),
('FLM','COK','AUH','A21N',0,null,28,1,11),
('FLM','CCJ','DXB','A21N',0,null,28,1,11),
('FLM','TRV','DXB','A21N',0,null,28,1,10),
('FLM','COK','DOH','A21N',0,null,28,1,10),
('SRW','DEL','LHR','A359',9,null,31,2,7),
('SRW','BOM','LHR','A359',9,null,31,2,6),
('SRW','DEL','SIN','A21X',3,38,30,2,9);

-- ---------- Player actions ----------

-- Adds a wet-leased aircraft in the standard cabin. It flies from p_arrive.
create or replace function game.add_wet(p_airline uuid, p_world uuid, p_type text, p_base text, p_day int, p_arrive int,
  out o_id uuid, out o_reg text, out o_rate numeric)
language plpgsql set search_path = '' as $$
declare
  s record; l record;
begin
  select * into s from game.std_layout(p_type, 1);
  select * into l from public.layout_calc(p_type, s.biz_rows, s.biz_pitch, s.econ_pitch,
                                          (select crew_rule from public.worlds where id = p_world));
  o_rate := game.wet_rate_usd(p_world, p_type);
  insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                               biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
  values (p_world, p_type, p_airline, game.next_reg(), p_day - game.param('wet_age_years')::int * 364,
          case when p_arrive <= p_day then 'active' else 'delivering' end, p_arrive, p_base,
          s.biz_rows, s.biz_pitch, s.econ_pitch, l.seats_biz, l.seats_econ)
  returning id, reg into o_id, o_reg;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, wet_usd_bh, start_day)
  values (o_id, p_airline, 'wet', o_rate, p_arrive);
end $$;

-- Join a world with its invite code and found an airline. The first base is free, and a wet-leased
-- aircraft is ready there on the airline's first day.
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
  v_type text;
  w record;
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
  if exists (select 1 from public.airlines where world_id = rw.id and (lower(name) = lower(v_name) or code = v_code))
     or exists (select 1 from public.bot_airlines where lower(name) = lower(v_name) or code = v_code) then
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

  select t.id into v_type from public.aircraft_types t
   where t.starter_rank is not null and t.runway_class <= rp.runway_class order by t.starter_rank limit 1;
  if v_type is not null then
    for i in 1..game.param('starter_aircraft')::int loop
      select * into w from game.add_wet(v_id, rw.id, v_type, rp.iata, v_day, v_day);
      insert into public.news (world_id, game_day, airline_id, kind, body, private)
      select rw.id, v_day, v_id, 'fleet', 'A wet-leased ' || t.name || ', ' || w.o_reg || ', is ready at ' || rp.iata
             || ' and can fly today. It costs $' || w.o_rate || ' a block hour, at least '
             || game.param('wet_min_hours_day') || ' hours a day.', true
        from public.aircraft_types t where t.id = v_type;
    end loop;
  end if;
  return v_id;
end $$;

-- Operating lease of one aircraft from the lessor pool. Lessors place a limited number with one airline a quarter.
create or replace function public.lease_aircraft(p_airline uuid, p_aircraft uuid, p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  v_day int; v_base text; v_lead int; v_rent numeric; v_dep numeric;
  v_max int := game.param('pool_lease_max_qtr')::int;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rc from public.aircraft where id = p_aircraft and world_id = rw.id for update;
  if not found or rc.status <> 'pool' then raise exception 'That aircraft is no longer available'; end if;
  perform game.check_fleet_room(p_airline);
  if (select count(*) from public.transactions
       where airline_id = p_airline and kind = 'lease' and game_day > v_day - 91) >= v_max then
    raise exception 'Lessors place at most % aircraft with one airline in a quarter. Wet lease or order new in the meantime.', v_max;
  end if;
  v_base := game.check_base(p_airline, p_base, (select runway_class from public.aircraft_types where id = rc.type_id));
  select lead_days into v_lead from game.pool_state(rw.id, rc.type_id);
  v_rent := game.lease_rent_usd(rw.id, rc.type_id, rc.built_day, v_day);
  v_dep := round(v_rent * game.param('lease_deposit_months') * rw.fx_inr_usd);
  perform game.book(p_airline, v_day, -v_dep, 'lease', 'Lease deposit for ' || rc.reg);
  update public.aircraft set airline_id = p_airline, status = 'delivering', available_day = v_day + v_lead, base_iata = v_base
   where id = rc.id;
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
  values (rc.id, p_airline, 'lease', v_rent, v_day + v_lead + game.param('lease_term_days')::int, v_dep, v_day + v_lead);
  return jsonb_build_object('aircraft_id', rc.id, 'reg', rc.reg, 'arrives_day', v_day + v_lead,
                            'rent_usd_month', v_rent, 'deposit_inr', v_dep);
end $$;

-- New aircraft from the manufacturer, in the cabin the buyer chooses.
-- p_pay: 'cash' (balance paid on delivery), 'loan' (balance borrowed against the aircraft) or 'slb' (sale and leaseback).
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
  if p_pay is null or p_pay not in ('cash', 'loan', 'slb') then raise exception 'Payment plan must be cash, loan or slb'; end if;
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
  insert into public.aircraft_terms (aircraft_id, airline_id, holding, deposit_inr, price_usd, start_day, ordered_day,
                                     pay_plan, finance_loan)
  values (v_id, p_airline, 'owned', v_dep, q.price_usd, q.delivery_day, v_day,
          case when p_pay = 'slb' then 'slb' else 'cash' end, p_pay = 'loan');
  return jsonb_build_object('aircraft_id', v_id, 'reg', v_reg, 'arrives_day', q.delivery_day,
                            'price_usd', q.price_usd, 'deposit_inr', v_dep);
end $$;

-- Aircraft with crew, paid by the block hour. Always available.
create or replace function public.wet_lease(p_airline uuid, p_type text, p_base text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rt public.aircraft_types%rowtype;
  w record;
  v_day int; v_base text; v_arr int;
begin
  rw := game.actor(p_airline); v_day := rw.game_day + 1;
  select * into rt from public.aircraft_types where id = p_type;
  if not found then raise exception 'Unknown aircraft type'; end if;
  perform game.check_fleet_room(p_airline);
  v_base := game.check_base(p_airline, p_base, rt.runway_class);
  v_arr := v_day + game.param('wet_lead_days')::int;
  select * into w from game.add_wet(p_airline, rw.id, p_type, v_base, v_day, v_arr);
  return jsonb_build_object('aircraft_id', w.o_id, 'reg', w.o_reg, 'arrives_day', v_arr, 'wet_usd_bh', w.o_rate);
end $$;

-- Hand back a lease, end a wet lease, cancel an order, or sell an owned aircraft (its loan is repaid from the sale).
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
    if coalesce(rm.loan_usd, 0) > 0 then
      v_cash := v_cash - round(rm.loan_usd * rw.fx_inr_usd);
      v_note := v_note || '; its loan was repaid from the sale';
    end if;
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

-- ---------- Daily engine ----------

create or replace function game.day_fleet(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_bal numeric; v_rent numeric; v_dep numeric; v_loan numeric;
  v_term int := game.param('lease_term_days')::int;
  v_gmin int := game.param('ground_days_min')::int;
  v_gmax int := game.param('ground_days_max')::int;
  v_gprob numeric := game.param('ground_prob_day');
  v_gage numeric := game.param('ground_age_k');
begin
  select * into rw from public.worlds where id = p_world;

  insert into public.news (world_id, game_day, airline_id, kind, body, private)
  select p_world, p_day, x.airline_id, 'fleet', t.name || ' ' || x.reg || ' has joined your fleet at ' || x.base_iata || '.', true
    from public.aircraft x join public.aircraft_types t on t.id = x.type_id
   where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and x.airline_id is not null;

  -- new aircraft from the manufacturer: borrow the balance, pay it, or sell and lease back
  for rec in
    select x.id, x.reg, y.airline_id, y.price_usd, y.deposit_inr, y.pay_plan, y.finance_loan, t.lease_usd_month
      from public.aircraft x
      join public.aircraft_terms y on y.aircraft_id = x.id
      join public.aircraft_types t on t.id = x.type_id
     where x.world_id = p_world and x.status = 'delivering' and x.available_day <= p_day and y.ordered_day is not null
  loop
    v_bal := round(rec.price_usd * rw.fx_inr_usd) - rec.deposit_inr;
    if rec.finance_loan then
      v_loan := round(v_bal / rw.fx_inr_usd, 2);
      update public.aircraft_terms
         set deposit_inr = 0, start_day = p_day, ordered_day = null, loan_usd = v_loan,
             loan_pay_usd_day = round(v_loan / (game.param('loan_years') * 364), 4)
       where aircraft_id = rec.id;
      perform game.book(rec.airline_id, p_day, 0, 'loan', 'Aircraft loan of $' || v_loan || ' for ' || rec.reg || ' on delivery');
    elsif rec.pay_plan = 'cash'
       and (select cash_inr from public.airline_finance where airline_id = rec.airline_id) >= v_bal then
      perform game.book(rec.airline_id, p_day, -v_bal, 'purchase', 'Balance paid on delivery of ' || rec.reg);
      update public.aircraft_terms set deposit_inr = 0, start_day = p_day, ordered_day = null where aircraft_id = rec.id;
    else
      v_rent := round(rec.lease_usd_month * game.param('slb_rent_mult'));
      v_dep := round(v_rent * game.param('lease_deposit_months') * rw.fx_inr_usd);
      perform game.book(rec.airline_id, p_day, rec.deposit_inr - v_dep, 'leaseback',
                        'Sale and leaseback of ' || rec.reg || ': order deposit returned, lease deposit paid', 0, true);
      update public.aircraft_terms
         set holding = 'lease', lease_usd_month = v_rent, lease_end_day = p_day + v_term, deposit_inr = v_dep,
             price_usd = null, start_day = p_day, ordered_day = null
       where aircraft_id = rec.id;
    end if;
  end loop;

  -- arrivals, finished refits, groundings that are over
  update public.aircraft set status = 'active'
   where world_id = p_world and airline_id is not null
     and status in ('delivering', 'refit', 'grounded') and available_day <= p_day;

  -- leases at the end of their term renew at today's market rent
  for rec in
    select y.aircraft_id, y.airline_id, y.lease_usd_month, x.reg, x.type_id, x.built_day
      from public.aircraft_terms y join public.aircraft x on x.id = y.aircraft_id
     where x.world_id = p_world and y.holding = 'lease' and y.lease_end_day < p_day and x.status <> 'delivering'
  loop
    v_rent := game.lease_rent_usd(p_world, rec.type_id, rec.built_day, p_day);
    update public.aircraft_terms set lease_usd_month = v_rent, lease_end_day = lease_end_day + v_term
     where aircraft_id = rec.aircraft_id;
    insert into public.news (world_id, game_day, airline_id, kind, body, private)
    values (p_world, p_day, rec.airline_id, 'fleet', 'The lease on ' || rec.reg || ' was renewed at $' || v_rent
            || ' a month (was $' || rec.lease_usd_month || ').', true);
  end loop;

  -- fleet-wide engine events starting today
  for rec in select * from public.events where world_id = p_world and kind = 'engine_grounding' and starts_day = p_day loop
    update public.aircraft set status = 'grounded', available_day = rec.ends_day + 1
     where world_id = p_world and type_id = rec.payload ->> 'type' and status = 'active' and airline_id is not null
       and random() < (rec.payload ->> 'share')::numeric;
  end loop;

  -- random technical groundings, more often with age (a wet lessor covers its own aircraft)
  update public.aircraft x
     set status = 'grounded', available_day = p_day + v_gmin + floor(random() * (v_gmax - v_gmin + 1))::int
   where x.world_id = p_world and x.status = 'active' and x.airline_id is not null
     and exists (select 1 from public.aircraft_terms y where y.aircraft_id = x.id and y.holding <> 'wet')
     and random() < v_gprob * (1 + v_gage * greatest(0, p_day - x.built_day) / 364.0);
end $$;

create or replace function game.day_ops(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  g record;
  v_sb numeric; v_sl numeric; v_su numeric; v_grow numeric;
begin
  select * into rw from public.worlds where id = p_world;
  select * into g from jsonb_to_record((select jsonb_object_agg(key, num) from public.game_params)) as x(
    seg_biz_a numeric, seg_biz_price numeric, seg_biz_freq numeric, seg_biz_comfort numeric, seg_biz_brand numeric,
    seg_lei_a numeric, seg_lei_price numeric, seg_lei_freq numeric, seg_lei_comfort numeric, seg_lei_brand numeric,
    seg_bud_a numeric, seg_bud_price numeric, seg_bud_freq numeric, seg_bud_comfort numeric, seg_bud_brand numeric,
    biz_fare_mult numeric, spill_recapture numeric, ancillary_share numeric, demand_noise_sd numeric,
    growth_year numeric, season_start_month numeric, age_fuel_per_year numeric, age_maint_per_year numeric,
    maint_fh_offset numeric, cabin_inr_bh numeric, cabin_fixed_inr_day numeric, intl_airport_mult numeric,
    handling_inr_pax numeric, slot_base_inr numeric, slot_util_cap numeric, dist_rev_share numeric,
    service_inr_pax numeric, wet_min_hours_day numeric, depreciation_year numeric, overhead_fixed_inr_day numeric,
    overhead_aircraft_inr_day numeric, overhead_seat_inr_day numeric, base_fixed_inr_day numeric, interest_year numeric, otp_base numeric,
    otp_util_k numeric, otp_smooth numeric, brand_drift numeric, brand_otp_ref numeric, brand_otp_k numeric, brand_cancel_k numeric,
    brand_comfort_ref numeric, brand_comfort_k numeric, brand_mkt_max numeric, brand_mkt_inr_pax numeric,
    brand_mkt_min_pax numeric, route_keep_days numeric, nest_lambda numeric, biz_downgrade_share numeric, seg_biz_cabin_a numeric,
    loan_rate_year numeric);

  select biz, lei, bud into v_sb, v_sl, v_su from public.season_factors
   where month = ((g.season_start_month::int - 1 + (((p_day - 1) % 364) * 12) / 364) % 12) + 1;
  v_grow := power(1 + g.growth_year, (p_day - 1) / 364.0) * rw.demand_scale;

  create temp table if not exists _rot (   -- one row per aircraft per route
    route_id uuid, airline_id uuid, aircraft_id uuid, type_id text, a text, b text, km int, intl boolean,
    f numeric,                -- round trips a day
    flown boolean, wet boolean, seats_e int, seats_b int, comf_e numeric, comf_b numeric,
    block_h numeric, turn_min numeric, age_y numeric, crew int,
    c_fuel numeric default 0, c_crew numeric default 0, c_maint numeric default 0,
    c_airport numeric default 0, c_slots numeric default 0
  ) on commit drop;
  create temp table if not exists _prod (  -- one row per airline per market: what it offers and what it sells
    route_id uuid primary key, airline_id uuid, a text, b text, km int,
    f numeric, f_b numeric, cap_e numeric, cap_b numeric,   -- flights and seats a day, each way
    comf_e numeric, comf_b numeric, block_h numeric, fare_e numeric, fare_b numeric, ref numeric, brand numeric,
    n_biz numeric, n_lei numeric, n_bud numeric,
    xb_e numeric, xb_b numeric, xl numeric, xu numeric,     -- exp(utility / lambda) by segment and cabin
    d_be numeric, d_bb numeric, d_l numeric, d_u numeric,   -- demand by segment: business in economy, in business, leisure, budget
    dg numeric,                                             -- business travellers moved down to economy
    dem_e numeric, dem_b numeric, pax_e numeric, pax_b numeric, spill numeric,
    pe numeric, pb numeric, rev numeric                      -- both directions
  ) on commit drop;
  truncate pg_temp._rot, pg_temp._prod;

  -- Step 3: capacity from the rotations of aircraft in service (grounded aircraft cancel their flights)
  insert into pg_temp._rot (route_id, airline_id, aircraft_id, type_id, a, b, km, intl, f, flown, wet,
                            seats_e, seats_b, comf_e, comf_b, block_h, turn_min, age_y, crew)
  select r.id, r.airline_id, ac.id, ac.type_id, m.a, m.b, m.km, m.intl, ro.weekly_trips / 7.0,
         ac.status = 'active', tm.holding = 'wet', ac.seats_econ, ac.seats_biz,
         (ac.econ_pitch - 28) / 6.0,
         case when ac.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (ac.biz_pitch - 36) / 12.0 end,
         m.km::numeric / t.cruise_kmh + t.block_offset_h,
         greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (ac.seats_econ + ac.seats_biz - t.ref_seats)),
         greatest(0, p_day - ac.built_day) / 364.0,
         game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz)
    from public.routes r
    join public.airlines al on al.id = r.airline_id and al.status = 'active'
    join public.rotations ro on ro.route_id = r.id
    join public.aircraft ac on ac.id = ro.aircraft_id and ac.airline_id = r.airline_id and ac.status in ('active', 'grounded')
    join public.aircraft_types t on t.id = ac.type_id
    join public.aircraft_terms tm on tm.aircraft_id = ac.id
    join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
   where r.world_id = p_world and r.status = 'open';

  -- an idle aircraft (no rotations) of the same type at the same base flies a grounded aircraft's rotations
  with gr as (
    select x.aircraft_id, x.airline_id, x.type_id, ac.base_iata,
           row_number() over (partition by x.airline_id, x.type_id, ac.base_iata order by x.aircraft_id) as n
      from (select distinct aircraft_id, airline_id, type_id from pg_temp._rot where not flown) x
      join public.aircraft ac on ac.id = x.aircraft_id),
  sp as (
    select ac.*, tm.holding,
           row_number() over (partition by ac.airline_id, ac.type_id, ac.base_iata order by ac.id) as n
      from public.aircraft ac
      join public.aircraft_terms tm on tm.aircraft_id = ac.id
     where ac.world_id = p_world and ac.status = 'active' and ac.airline_id is not null
       and not exists (select 1 from public.rotations ro where ro.aircraft_id = ac.id))
  update pg_temp._rot x
     set aircraft_id = sp.id, flown = true, wet = sp.holding = 'wet', seats_e = sp.seats_econ, seats_b = sp.seats_biz,
         comf_e = (sp.econ_pitch - 28) / 6.0,
         comf_b = case when sp.seats_biz = 0 then 0 when t.biz_kind = 'lieflat' then 2.6 else 1.6 + (sp.biz_pitch - 36) / 12.0 end,
         turn_min = greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (sp.seats_econ + sp.seats_biz - t.ref_seats)),
         age_y = greatest(0, p_day - sp.built_day) / 364.0,
         crew = game.cabin_crew(rw.crew_rule, sp.seats_econ + sp.seats_biz)
    from gr
    join sp on sp.airline_id = gr.airline_id and sp.type_id = gr.type_id and sp.base_iata = gr.base_iata and sp.n = gr.n
    join public.aircraft_types t on t.id = sp.type_id
   where x.aircraft_id = gr.aircraft_id and not x.flown;

  -- Step 4: demand. Market size today, then each airline's share, then spill.
  insert into pg_temp._prod (route_id, airline_id, a, b, km, f, f_b, cap_e, cap_b, comf_e, comf_b, block_h,
                             fare_e, fare_b, ref, brand, n_biz, n_lei, n_bud)
  with mk as materialized (
    select q.a, q.b, exp(g.demand_noise_sd * game.rand_normal() - g.demand_noise_sd * g.demand_noise_sd / 2) * v_grow as k
      from (select distinct a, b from pg_temp._rot where flown) q)
  select s.route_id, s.airline_id, s.a, s.b, s.km, s.f, s.f_b, s.cap_e, s.cap_b, coalesce(s.comf_e, 0), coalesce(s.comf_b, 0),
         s.block_h, r.fare_econ, coalesce(r.fare_biz, round(m.ref_fare * g.biz_fare_mult)), m.ref_fare, al.brand,
         m.n_biz * v_sb * mk.k, m.n_lei * v_sl * mk.k, m.n_bud * v_su * mk.k
    from (select route_id, airline_id, a, b, km, sum(f) as f, coalesce(sum(f) filter (where seats_b > 0), 0) as f_b,
                 sum(f * seats_e) as cap_e, sum(f * seats_b) as cap_b,
                 sum(f * seats_e * comf_e) / nullif(sum(f * seats_e), 0) as comf_e,
                 sum(f * seats_b * comf_b) / nullif(sum(f * seats_b), 0) as comf_b,
                 sum(f * block_h) / sum(f) as block_h
            from pg_temp._rot where flown group by route_id, airline_id, a, b, km) s
    join public.routes r on r.id = s.route_id
    join public.airlines al on al.id = s.airline_id
    join public.markets m on m.a = s.a and m.b = s.b
    join mk on mk.a = s.a and mk.b = s.b;

  -- U = a - b x fare / reference + c x ln(1 + flights) + d x comfort x sqrt(block hours) + e x (brand - 50) / 50
  -- Nested logit: the airlines form one group against the option of not flying.
  -- x = exp(U / lambda); with S the sum of x on the market, P(fly) = S^lambda / (1 + S^lambda), and an airline's share of fliers is x / S.
  update pg_temp._prod set
    xb_e = case when cap_e > 0 then exp(((g.seg_biz_a - g.seg_biz_price * fare_e / ref + g.seg_biz_freq * ln(1 + f)
             + g.seg_biz_comfort * comf_e * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
    xb_b = case when cap_b > 0 then exp(((g.seg_biz_a + g.seg_biz_cabin_a - g.seg_biz_price * fare_b / (ref * g.biz_fare_mult) + g.seg_biz_freq * ln(1 + f_b)
             + g.seg_biz_comfort * comf_b * sqrt(block_h) + g.seg_biz_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
    xl   = case when cap_e > 0 then exp(((g.seg_lei_a - g.seg_lei_price * fare_e / ref + g.seg_lei_freq * ln(1 + f)
             + g.seg_lei_comfort * comf_e * sqrt(block_h) + g.seg_lei_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end,
    xu   = case when cap_e > 0 then exp(((g.seg_bud_a - g.seg_bud_price * fare_e / ref + g.seg_bud_freq * ln(1 + f)
             + g.seg_bud_comfort * comf_e * sqrt(block_h) + g.seg_bud_brand * (brand - 50) / 50) / g.nest_lambda)::float8) else 0 end;

  update pg_temp._prod p
     set d_be = p.n_biz * p.xb_e * s.kb, d_bb = p.n_biz * p.xb_b * s.kb, d_l = p.n_lei * p.xl * s.kl, d_u = p.n_bud * p.xu * s.ku
    from (select route_id, game.nest_k(sum(xb_e + xb_b) over mkt, g.nest_lambda) as kb,
                 game.nest_k(sum(xl) over mkt, g.nest_lambda) as kl, game.nest_k(sum(xu) over mkt, g.nest_lambda) as ku
            from pg_temp._prod window mkt as (partition by a, b)) s
   where s.route_id = p.route_id;

  -- Business cabin. When it is full, part of the overflow takes economy on the same airline; the rest is spilled.
  -- Spilled travellers try airlines with seats left in the same cabin, in proportion to how attractive they are:
  -- a share spill_recapture x P(fly | airlines with seats) / P(fly | all airlines) finds a seat.
  update pg_temp._prod p
     set dem_b = p.d_bb, dg = g.biz_downgrade_share * greatest(p.d_bb - p.cap_b, 0),
         pax_b = least(p.d_bb, p.cap_b)
                 + case when p.cap_b > p.d_bb and s.sf > 0
                        then least(p.cap_b - p.d_bb, s.r * s.sp * p.xb_b / s.sf) else 0 end
    from (select route_id, sp, sf,
                 g.spill_recapture * least(1, game.nest_p(sf, g.nest_lambda) / nullif(game.nest_p(st, g.nest_lambda), 0)) as r
            from (select route_id,
                         sum((1 - g.biz_downgrade_share) * greatest(d_bb - cap_b, 0)) over mkt as sp,
                         sum(case when cap_b > d_bb then xb_b else 0 end) over mkt as sf,
                         sum(xb_e + xb_b) over mkt as st
                    from pg_temp._prod window mkt as (partition by a, b)) z) s
   where s.route_id = p.route_id;

  -- Economy cabin, with the business travellers who moved down.
  update pg_temp._prod set dem_e = d_be + dg + d_l + d_u;
  update pg_temp._prod p
     set pax_e = least(p.dem_e, p.cap_e)
                 + case when p.cap_e > p.dem_e then least(p.cap_e - p.dem_e,
                          coalesce(s.rb * s.spb * p.xb_e / nullif(s.sfb, 0), 0)
                        + coalesce(s.rl * s.spl * p.xl / nullif(s.sfl, 0), 0)
                        + coalesce(s.ru * s.spu * p.xu / nullif(s.sfu, 0), 0)) else 0 end
    from (select route_id, spb, spl, spu, sfb, sfl, sfu,
                 g.spill_recapture * least(1, game.nest_p(sfb, g.nest_lambda) / nullif(game.nest_p(stb, g.nest_lambda), 0)) as rb,
                 g.spill_recapture * least(1, game.nest_p(sfl, g.nest_lambda) / nullif(game.nest_p(stl, g.nest_lambda), 0)) as rl,
                 g.spill_recapture * least(1, game.nest_p(sfu, g.nest_lambda) / nullif(game.nest_p(stu, g.nest_lambda), 0)) as ru
            from (select route_id,
                         sum(case when dem_e > cap_e then (dem_e - cap_e) * (d_be + dg) / dem_e else 0 end) over mkt as spb,
                         sum(case when dem_e > cap_e then (dem_e - cap_e) * d_l / dem_e else 0 end) over mkt as spl,
                         sum(case when dem_e > cap_e then (dem_e - cap_e) * d_u / dem_e else 0 end) over mkt as spu,
                         sum(case when cap_e > dem_e then xb_e else 0 end) over mkt as sfb,
                         sum(case when cap_e > dem_e then xl else 0 end) over mkt as sfl,
                         sum(case when cap_e > dem_e then xu else 0 end) over mkt as sfu,
                         sum(xb_e + xb_b) over mkt as stb, sum(xl) over mkt as stl, sum(xu) over mkt as stu
                    from pg_temp._prod window mkt as (partition by a, b)) z) s
   where s.route_id = p.route_id;

  update pg_temp._prod
     set spill = greatest(dem_e - cap_e, 0) + greatest(dem_b - cap_b, 0) - dg,
         pe = round(2 * pax_e), pb = round(2 * pax_b), rev = round(2 * pax_e) * fare_e + round(2 * pax_b) * fare_b;

  -- Step 5: costs per flight. Slots at congested airports are priced by how full the airport is;
  -- a world scaled down in demand has proportionally fewer slots.
  with mv as (
    select z.iata, sum(z.m) as moves
      from (select a as iata, 2 * f as m from pg_temp._rot where flown
            union all select b, 2 * f from pg_temp._rot where flown) z
     group by z.iata),
  sp as (
    select ap.iata, g.slot_base_inr / power(1 - least(g.slot_util_cap, mv.moves / (ap.slot_cap * rw.slot_scale * rw.demand_scale)), 2) as price
      from mv join public.airports ap on ap.iata = mv.iata
     where ap.slot_cap is not null)
  update pg_temp._rot x set
    c_fuel = 2 * x.f * (t.fuel_fixed_kg + t.fuel_per_km_kg * x.km)
             * (0.80 + 0.20 * (x.seats_e * p.lf_e + x.seats_b * p.lf_b) / t.ref_seats)
             * (1 + g.age_fuel_per_year * x.age_y) * rw.fuel_inr_kg,
    c_crew = case when x.wet then 0 else 2 * x.f * x.block_h * (t.pilot_inr_bh + x.crew * g.cabin_inr_bh) end,
    c_maint = case when x.wet then 0 else
                2 * x.f * ((x.km::numeric / t.cruise_kmh + g.maint_fh_offset) * t.maint_usd_fh + t.maint_usd_cycle)
                * (1 + g.age_maint_per_year * x.age_y) * rw.fx_inr_usd end,
    c_airport = 2 * x.f * (t.landing_inr * case when x.intl then (1 + g.intl_airport_mult) / 2 else 1 end
                           + t.nav_inr_km * x.km + g.handling_inr_pax * (x.seats_e * p.lf_e + x.seats_b * p.lf_b)),
    c_slots = 2 * x.f * (coalesce(sa.price, 0) + coalesce(sb.price, 0))
  from (select route_id, a, b, coalesce(pax_e / nullif(cap_e, 0), 0) as lf_e, coalesce(pax_b / nullif(cap_b, 0), 0) as lf_b
          from pg_temp._prod) p
  join public.aircraft_types t on true
  left join sp sa on sa.iata = p.a
  left join sp sb on sb.iata = p.b
  where x.flown and p.route_id = x.route_id and t.id = x.type_id;

  -- Step 6: results
  insert into public.route_daily (route_id, game_day, airline_id, flights, seats_econ, seats_biz, pax_econ, pax_biz,
                                  spill, revenue_inr, var_cost_inr)
  select p.route_id, p_day, p.airline_id, 2 * p.f, round(2 * p.cap_e), round(2 * p.cap_b), p.pe, p.pb, round(2 * p.spill),
         round(p.rev * (1 + g.ancillary_share)),
         round(c.var + g.dist_rev_share * p.rev + g.service_inr_pax * (p.pe + p.pb))
    from pg_temp._prod p
    join (select route_id, sum(c_fuel + c_crew + c_maint + c_airport + c_slots) as var
            from pg_temp._rot where flown group by route_id) c on c.route_id = p.route_id;

  insert into public.airline_daily (airline_id, game_day, pax, ask, rpk, rev_ticket, rev_anc, c_fuel, c_crew, c_maint,
    c_airport, c_rent, c_slots, c_dist, c_marketing, c_overhead, c_interest, c_other, c_depr, flights, cancelled, loan_repaid)
  select al.id, p_day, coalesce(pr.pax, 0), coalesce(pr.ask, 0), coalesce(pr.rpk, 0),
         coalesce(pr.rev, 0), round(coalesce(pr.rev, 0) * g.ancillary_share),
         round(coalesce(rc.fuel, 0)), round(coalesce(rc.crew, 0) + coalesce(fl.crew_fixed, 0)), round(coalesce(rc.maint, 0)),
         round(coalesce(rc.airport, 0)), round(coalesce(fl.rent, 0)), round(coalesce(rc.slots, 0)),
         round(coalesce(g.dist_rev_share * pr.rev + g.service_inr_pax * pr.pax, 0)), al.marketing_inr_day,
         round(g.overhead_fixed_inr_day + g.overhead_aircraft_inr_day * coalesce(fl.n, 0) + g.overhead_seat_inr_day * coalesce(fl.seats, 0)
               + g.base_fixed_inr_day * (select count(*) from public.bases bs where bs.airline_id = al.id)),
         round(fin.debt_inr * g.interest_year / 364 + coalesce(fl.loan_int, 0)), coalesce(tx.other, 0), round(coalesce(fl.depr, 0)),
         coalesce(rc.flights, 0), coalesce(rc.cancelled, 0), round(coalesce(fl.loan_prin, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    left join (select airline_id, sum(pe + pb) as pax, sum(2 * (cap_e + cap_b) * km) as ask,
                      sum((pe + pb) * km) as rpk, sum(rev) as rev
                 from pg_temp._prod group by airline_id) pr on pr.airline_id = al.id
    left join (select airline_id, sum(c_fuel) as fuel, sum(c_crew) as crew, sum(c_maint) as maint,
                      sum(c_airport) as airport, sum(c_slots) as slots,
                      sum(2 * f) filter (where flown) as flights, sum(2 * f) filter (where not flown) as cancelled
                 from pg_temp._rot group by airline_id) rc on rc.airline_id = al.id
    left join (select tm.airline_id, count(*) as n, sum(ac.seats_econ + ac.seats_biz) as seats,
                      sum(case tm.holding
                            when 'lease' then tm.lease_usd_month * rw.fx_inr_usd / 30.33
                            when 'wet' then tm.wet_usd_bh * rw.fx_inr_usd * greatest(g.wet_min_hours_day, coalesce(u.bh, 0))
                            else 0 end) as rent,
                      sum(case when tm.holding = 'owned' then tm.price_usd * rw.fx_inr_usd * g.depreciation_year / 364 else 0 end) as depr,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then tm.loan_usd * g.loan_rate_year / 364 * rw.fx_inr_usd else 0 end) as loan_int,
                      sum(case when tm.holding = 'owned' and tm.loan_usd > 0
                               then least(tm.loan_usd, tm.loan_pay_usd_day) * rw.fx_inr_usd else 0 end) as loan_prin,
                      sum(case when tm.holding = 'wet' then 0 else
                            t.pilot_fixed_inr_day + game.cabin_crew(rw.crew_rule, ac.seats_econ + ac.seats_biz) * g.cabin_fixed_inr_day end) as crew_fixed
                 from public.aircraft ac
                 join public.aircraft_terms tm on tm.aircraft_id = ac.id
                 join public.aircraft_types t on t.id = ac.type_id
                 left join (select aircraft_id, sum(2 * f * block_h) as bh from pg_temp._rot where flown group by aircraft_id) u
                        on u.aircraft_id = ac.id
                where ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
                group by tm.airline_id) fl on fl.airline_id = al.id
    left join (select airline_id, -sum(pnl_inr) as other from public.transactions where game_day = p_day group by airline_id) tx
           on tx.airline_id = al.id
   where al.world_id = p_world and al.status = 'active';

  update public.airline_finance fin
     set cash_inr = fin.cash_inr + d.rev_ticket + d.rev_anc - (d.c_fuel + d.c_crew + d.c_maint + d.c_airport + d.c_rent
                    + d.c_slots + d.c_dist + d.c_marketing + d.c_overhead + d.c_interest + d.loan_repaid)
    from public.airline_daily d join public.airlines al on al.id = d.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  update public.aircraft_terms tm set loan_usd = tm.loan_usd - least(tm.loan_usd, tm.loan_pay_usd_day)
    from public.aircraft ac join public.airlines al on al.id = ac.airline_id and al.status = 'active'
   where ac.id = tm.aircraft_id and ac.world_id = p_world and ac.status in ('active', 'grounded', 'refit')
     and tm.holding = 'owned' and tm.loan_usd > 0;

  -- punctuality: tight schedules run late. Brand drifts toward a target built from punctuality,
  -- cancellations, cabin comfort and marketing per passenger.
  update public.airlines al set otp = round((1 - g.otp_smooth) * al.otp + g.otp_smooth * s.otp, 4)
    from (select u.airline_id, sum(u.fl * (g.otp_base - g.otp_util_k * greatest(0, u.util - 0.85) / 0.15)) / sum(u.fl) as otp
            from (select x.airline_id, x.aircraft_id, sum(2 * x.f) as fl,
                         sum(2 * x.f * (x.block_h + x.turn_min / 60)) / max(t.day_window_h) as util
                    from pg_temp._rot x join public.aircraft_types t on t.id = x.type_id
                   where x.flown group by x.airline_id, x.aircraft_id) u
           group by u.airline_id) s
   where al.id = s.airline_id;

  update public.airlines al
     set brand = round(least(100, greatest(0, al.brand + g.brand_drift * (
           50 + g.brand_otp_k * (al.otp - g.brand_otp_ref)
              - g.brand_cancel_k * coalesce(d.cancelled / nullif(d.flights + d.cancelled, 0), 0)
              + g.brand_comfort_k * (coalesce(c.comf, g.brand_comfort_ref) - g.brand_comfort_ref)
              + g.brand_mkt_max * (1 - exp(-al.marketing_inr_day / (g.brand_mkt_inr_pax * greatest(d.pax, g.brand_mkt_min_pax))))
           - al.brand))), 2)
    from public.airline_daily d
    left join (select airline_id, sum(cap_e * comf_e) / nullif(sum(cap_e), 0) as comf from pg_temp._prod group by airline_id) c
           on c.airline_id = d.airline_id
   where d.airline_id = al.id and d.game_day = p_day and al.world_id = p_world and al.status = 'active';

  delete from public.route_daily rd using public.airlines al
   where al.id = rd.airline_id and al.world_id = p_world and rd.game_day <= p_day - g.route_keep_days::int;
end $$;

create or replace function game.day_quarter(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rec record;
  v_q int := p_day / 91;
  v_n int;
begin
  select * into rw from public.worlds where id = p_world;

  insert into public.quarterly_reports (airline_id, quarter, revenue, op_profit, net_profit, pax, load_factor, rask, cask,
                                        otp, brand, net_worth)
  select al.id, v_q, s.rev, s.rev - s.cost, s.rev - s.cost - s.interest, s.pax,
         round(s.rpk / nullif(s.ask, 0), 4), round(s.rev / nullif(s.ask, 0), 3), round(s.cost / nullif(s.ask, 0), 3),
         al.otp, al.brand, round(fin.cash_inr - fin.debt_inr + coalesce(ast.v, 0))
    from public.airlines al
    join public.airline_finance fin on fin.airline_id = al.id
    join (select airline_id, sum(rev_ticket + rev_anc) as rev, sum(c_interest) as interest, sum(pax) as pax,
                 sum(ask) as ask, sum(rpk) as rpk,
                 sum(c_fuel + c_crew + c_maint + c_airport + c_rent + c_slots + c_dist + c_marketing + c_overhead
                     + c_other + c_depr) as cost
            from public.airline_daily where game_day > p_day - 91 and game_day <= p_day group by airline_id) s
      on s.airline_id = al.id
    left join (select airline_id,
                      sum(deposit_inr + case when holding = 'owned' and ordered_day is null
                            then game.book_value_usd(price_usd, start_day, p_day) * rw.fx_inr_usd else 0 end
                          - coalesce(loan_usd, 0) * rw.fx_inr_usd) as v
                 from public.aircraft_terms group by airline_id) ast on ast.airline_id = al.id
   where al.world_id = p_world and al.status = 'active';

  -- season score: net worth + 5 x profit after interest of the last four quarters. Computer-run airlines are not ranked.
  update public.quarterly_reports q
     set score = round(q.net_worth + game.param('score_profit_mult')
                 * (select sum(h.net_profit) from public.quarterly_reports h
                     where h.airline_id = q.airline_id and h.quarter > v_q - 4 and h.quarter <= v_q))
    from public.airlines al
   where al.id = q.airline_id and al.world_id = p_world and q.quarter = v_q;
  update public.quarterly_reports q set rank = s.rk
    from (select h.airline_id, rank() over (order by h.score desc) as rk
            from public.quarterly_reports h join public.airlines al on al.id = h.airline_id
           where al.world_id = p_world and h.quarter = v_q and not al.is_ai) s
   where q.airline_id = s.airline_id and q.quarter = v_q;

  insert into public.news (world_id, game_day, kind, body)
  select p_world, p_day, 'results', 'Quarter ' || v_q || ' results are out. Leaders: ' || string_agg(s.name, ', ' order by s.rank) || '.'
    from (select al.name, q.rank from public.quarterly_reports q join public.airlines al on al.id = q.airline_id
           where al.world_id = p_world and q.quarter = v_q and q.rank <= 3) s
  having count(*) > 0;

  -- lessors add aircraft, up to the target
  for rec in select type_id, target from public.pool_targets where world_id = p_world loop
    select count(*) into v_n from public.aircraft where world_id = p_world and type_id = rec.type_id and status = 'pool';
    perform game.fill_pool(p_world, rec.type_id,
                           least(ceil(rec.target * game.param('pool_refill_share'))::int, rec.target - v_n), p_day);
  end loop;
end $$;

create or replace function game.day_solvency(p_world uuid, p_day int) returns void
language plpgsql set search_path = '' as $$
declare
  rec record;
begin
  -- a shortfall is drawn from the credit line while it lasts. Computer-run airlines are backed by their owners
  -- and never go into administration.
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note)
  select fin.airline_id, p_day, 'borrow', least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr), 'Shortfall covered from the credit line'
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;
  update public.airline_finance fin
     set debt_inr = fin.debt_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr),
         cash_inr = fin.cash_inr + least(-fin.cash_inr, fin.credit_limit_inr - fin.debt_inr)
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and fin.cash_inr < 0 and fin.debt_inr < fin.credit_limit_inr;

  update public.airline_finance fin
     set insolvent_days = case when fin.cash_inr < 0 then fin.insolvent_days + 1 else 0 end
    from public.airlines al
   where al.id = fin.airline_id and al.world_id = p_world and al.status = 'active' and not al.is_ai;

  update public.airline_daily d set cash_end = fin.cash_inr, brand = al.brand, otp = al.otp
    from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
   where d.airline_id = fin.airline_id and d.game_day = p_day and al.world_id = p_world;

  for rec in
    select fin.airline_id from public.airline_finance fin join public.airlines al on al.id = fin.airline_id
     where al.world_id = p_world and al.status = 'active' and fin.insolvent_days >= game.param('insolvency_days')
  loop
    perform game.administer(rec.airline_id, p_world, p_day);
  end loop;
end $$;

-- ---------- One game day, and the clock ----------

-- Processes the next game day of a world. Returns the day, or null if the world is not running.
create or replace function game.run_day(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  v_day int;
begin
  perform pg_advisory_xact_lock(hashtextextended('day:' || p_world, 0));
  select * into rw from public.worlds where id = p_world for update;
  if not found or rw.status <> 'running' or rw.game_day >= rw.season_days then return null; end if;
  v_day := rw.game_day + 1;
  if rw.game_day = 0 then perform game.bot_seed(p_world); end if;
  perform game.day_world(p_world, v_day);
  perform game.day_fleet(p_world, v_day);
  perform game.bot_prices(p_world, v_day);
  perform game.day_ops(p_world, v_day);
  if v_day % 91 = 0 then
    perform game.day_quarter(p_world, v_day);
    perform game.bot_quarter(p_world, v_day);
  end if;
  perform game.day_solvency(p_world, v_day);
  update public.worlds set game_day = v_day, status = case when v_day >= season_days then 'ended' else status end
   where id = p_world;
  if v_day >= rw.season_days then
    insert into public.news (world_id, game_day, kind, body) values (p_world, v_day, 'season', 'The season has ended.');
  end if;
  return v_day;
end $$;

-- ---------- Demand helpers ----------

-- Nested logit with S = sum of exp(U / lambda) over a market's airlines:
-- nest_p = P(fly) = S^lambda / (1 + S^lambda); nest_k = P(fly) / S, so an airline's demand is potential x x_k x nest_k.
-- Worked in double precision: numeric power() is about ten times slower and the engine calls these thousands of times a day.
create or replace function game.nest_p(p_s numeric, p_lambda numeric) returns numeric
language sql immutable set search_path = '' as $$
  select case when p_s > 0 then (power(p_s::float8, p_lambda::float8) / (1 + power(p_s::float8, p_lambda::float8)))::numeric else 0 end
$$;

create or replace function game.nest_k(p_s numeric, p_lambda numeric) returns numeric
language sql immutable set search_path = '' as $$
  select case when p_s > 0 then (power(p_s::float8, p_lambda::float8 - 1) / (1 + power(p_s::float8, p_lambda::float8)))::numeric else 0 end
$$;

-- ---------- Computer-run airlines ----------
-- They act through the same public functions as players. The engine calls them, with no user id.

-- Round trips a week on one network route in a world scaled by p_scale. A route worth at least half a daily
-- service (or half the aircraft's trips, if fewer) keeps that service; below that it is not flown (0).
create or replace function game.bot_trips(p_aircraft int, p_trips int, p_scale numeric) returns int
language sql immutable set search_path = '' as $$
  select case when round(p_aircraft * p_trips * p_scale) >= least(7, p_trips) then round(p_aircraft * p_trips * p_scale)::int
              when round(p_aircraft * p_trips * p_scale) * 2 >= least(7, p_trips) then least(7, p_trips)
              else 0 end
$$;

-- Sets up the computer-run airlines on a world's first day: established fleets on operating leases,
-- routes at reference fares, rotations and marketing. Fleet size scales with demand_scale x bot_scale.
create or replace function game.bot_seed(p_world uuid) returns int
language plpgsql set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  b record; n record; l record;
  v_day int; v_al uuid; v_route uuid; v_ac uuid; v_built int;
  v_total int; v_k int; v_seats numeric; v_count int := 0;
  v_age numeric := game.param('bot_max_age_years');
  v_term int := game.param('lease_term_days')::int;
begin
  select * into rw from public.worlds where id = p_world;
  if rw.bot_scale <= 0 or exists (select 1 from public.airlines where world_id = p_world and is_ai) then return 0; end if;
  v_day := rw.game_day + 1;
  for b in select * from public.bot_airlines order by sort loop
    v_al := null;
    insert into public.airlines (world_id, is_ai, name, code, created_day)
    values (p_world, true, b.name, b.code, v_day)
    on conflict do nothing returning id into v_al;
    continue when v_al is null;
    insert into public.airline_finance (airline_id, cash_inr, credit_limit_inr) values (v_al, 0, game.param('credit_limit_inr'));
    perform game.book(v_al, v_day, game.param('start_cash_inr'), 'equity', 'Founding equity');
    insert into public.bases (airline_id, iata, opened_day)
    select distinct v_al, origin, v_day from public.bot_network where code = b.code;
    v_seats := 0;
    for n in select * from public.bot_network where code = b.code order by aircraft desc, origin, dest loop
      v_total := game.bot_trips(n.aircraft, n.weekly_trips, rw.demand_scale * rw.bot_scale);
      continue when v_total = 0;
      v_k := ceil(v_total::numeric / n.weekly_trips)::int;
      v_route := public.open_route(v_al, n.origin, n.dest);
      select * into l from public.layout_calc(n.type_id, n.biz_rows, n.biz_pitch, n.econ_pitch, rw.crew_rule);
      for i in 1..v_k loop
        v_built := v_day - floor(random() * v_age * 364)::int;
        insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                     biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
        values (p_world, n.type_id, v_al, game.next_reg(), v_built, 'active', v_day, n.origin,
                n.biz_rows, case when n.biz_rows > 0 then coalesce(n.biz_pitch, 44) end, n.econ_pitch, l.seats_biz, l.seats_econ)
        returning id into v_ac;
        insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
        values (v_ac, v_al, 'lease', game.lease_rent_usd(p_world, n.type_id, v_built, v_day),
                v_day + floor(random() * v_term)::int, 0, v_day);
        perform public.set_rotation(v_al, v_ac, v_route,
                                    v_total / v_k + case when i <= v_total % v_k then 1 else 0 end);
        v_count := v_count + 1;
      end loop;
      v_seats := v_seats + v_total * l.seats * 2 / 7.0;
    end loop;
    perform public.set_marketing(v_al, least(game.param('marketing_max_inr_day'), round(b.mkt_inr_pax * 0.85 * v_seats)));
  end loop;
  insert into public.news (world_id, game_day, kind, body)
  select p_world, v_day, 'world', 'Established airlines in this world: ' || string_agg(al.name, ', ' order by al.name) || '.'
    from public.airlines al where al.world_id = p_world and al.is_ai
  having count(*) > 0;
  return v_count;
end $$;

-- Daily fares of the computer-run airlines, from the last 7 days' load factors and today's rival fares.
-- They raise fares when full; when they lose passengers they cut fares and follow the lowest rival fare, within their band
-- and never below the fare at which the route breaks even at bot_floor_lf. On routes from their own bases they defend
-- down to a lower band floor when a player undercuts them.
create or replace function game.bot_prices(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  r record;
  v_hi numeric := game.param('bot_lf_high');
  v_lo numeric := game.param('bot_lf_low');
  v_step numeric := game.param('bot_fare_step');
  v_bm numeric := game.param('biz_fare_mult');
  v_net numeric := 1 + game.param('ancillary_share') - game.param('dist_rev_share');
  v_flf numeric := game.param('bot_floor_lf');
  v_floor numeric; v_be numeric; v_e numeric; v_b numeric; v_n int := 0;
begin
  for r in
    with fly as (
      select rt.id, rt.airline_id, al.is_ai, least(rt.origin, rt.dest) as a, greatest(rt.origin, rt.dest) as b, rt.fare_econ
        from public.routes rt join public.airlines al on al.id = rt.airline_id and al.status = 'active'
       where rt.world_id = p_world and rt.status = 'open'
         and exists (select 1 from public.rotations ro where ro.route_id = rt.id))
    select f.id, f.airline_id, f.fare_econ, rt.fare_biz, m.ref_fare, ba.fare_lo, ba.fare_hi, ba.defend_lo,
           exists (select 1 from public.bases bs where bs.airline_id = f.airline_id and bs.iata in (f.a, f.b)) as home,
           rd.lf_e, rd.lf_b, rd.var_day, rd.seats_e_day, rd.pax_b_day, fc.fixed_day,
           (select min(x.fare_econ) from fly x where x.a = f.a and x.b = f.b and x.airline_id <> f.airline_id) as rival,
           (select min(x.fare_econ) from fly x where x.a = f.a and x.b = f.b and not x.is_ai) as player
      from fly f
      join public.routes rt on rt.id = f.id
      join public.airlines al on al.id = f.airline_id
      join public.bot_airlines ba on ba.code = al.code
      join public.markets m on m.a = f.a and m.b = f.b
      left join lateral (select sum(d.pax_econ)::numeric / nullif(sum(d.seats_econ), 0) as lf_e,
                                sum(d.pax_biz)::numeric / nullif(sum(d.seats_biz), 0) as lf_b,
                                avg(d.var_cost_inr) as var_day, avg(d.seats_econ) as seats_e_day, avg(d.pax_biz) as pax_b_day
                           from public.route_daily d where d.route_id = f.id and d.game_day between p_day - 7 and p_day - 1) rd on true
      -- the route's share of fixed costs: each computer-run aircraft flies one route
      left join lateral (select sum(tm.lease_usd_month * w.fx_inr_usd / 30.33 + t.pilot_fixed_inr_day
                                    + game.cabin_crew(w.crew_rule, x.seats_econ + x.seats_biz) * game.param('cabin_fixed_inr_day')
                                    + game.param('overhead_seat_inr_day') * (x.seats_econ + x.seats_biz)) as fixed_day
                           from public.rotations ro
                           join public.aircraft x on x.id = ro.aircraft_id
                           join public.aircraft_terms tm on tm.aircraft_id = x.id
                           join public.aircraft_types t on t.id = x.type_id
                           join public.worlds w on w.id = x.world_id
                          where ro.route_id = f.id) fc on true
     where f.is_ai
  loop
    -- break-even economy fare at bot_floor_lf, after business revenue
    v_be := ((r.var_day + r.fixed_day) / v_net - r.pax_b_day * r.fare_biz) / nullif(r.seats_e_day * v_flf, 0);
    v_floor := greatest(case when r.home and r.player < r.fare_econ then r.defend_lo else r.fare_lo end * r.ref_fare,
                        least(r.fare_hi * r.ref_fare, coalesce(v_be, 0)));
    v_e := r.fare_econ;
    if r.lf_e >= v_hi then v_e := v_e * (1 + v_step);
    elsif r.lf_e < v_lo then v_e := v_e * (1 - v_step);
    end if;
    if r.rival < v_e and r.lf_e < v_lo then v_e := r.rival; end if;   -- losing passengers to a cheaper rival: follow it
    v_e := round(least(r.fare_hi * r.ref_fare, greatest(v_floor, v_e)));
    v_b := r.fare_biz;
    if r.lf_b >= v_hi then v_b := v_b * (1 + v_step);
    elsif r.lf_b < v_lo then v_b := v_b * (1 - v_step);
    end if;
    v_b := round(least(r.fare_hi * r.ref_fare * v_bm, greatest(r.fare_lo * r.ref_fare * v_bm, v_b)));
    if v_e <> r.fare_econ or v_b <> r.fare_biz then
      perform public.set_fares(r.airline_id, r.id, v_e::int, v_b::int);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- A computer-run airline's starting fleet in a world (the same rounding as game.bot_seed).
create or replace function game.bot_start_fleet(p_world uuid, p_code text) returns int
language sql stable set search_path = '' as $$
  select coalesce(sum(ceil(game.bot_trips(n.aircraft, n.weekly_trips, w.demand_scale * w.bot_scale)::numeric / n.weekly_trips)), 0)::int
  from public.bot_network n, public.worlds w
  where n.code = p_code and w.id = p_world
$$;

-- Round trips a week that fit the share bot_window_use of an aircraft's flying window on a route of p_km.
create or replace function game.fit_trips(p_aircraft uuid, p_km numeric) returns int
language sql stable set search_path = '' as $$
  select least(84, floor(game.param('bot_window_use') * 7 * t.day_window_h
                         / (2 * (p_km / t.cruise_kmh + t.block_offset_h + l.min_turn_min / 60))))::int
  from public.aircraft a join public.aircraft_types t on t.id = a.type_id,
       public.layout_calc(a.type_id, a.biz_rows, a.biz_pitch, a.econ_pitch) l
  where a.id = p_aircraft
$$;

-- Every quarter a computer-run airline moves aircraft from its emptiest route to its fullest one, hands aircraft back
-- to the lessors from routes that stay empty, and adds aircraft (from its own orders, not the lessor pool) to routes
-- that stay busy at high fares, up to bot_fleet_max_mult times its starting fleet. Its set of routes stays fixed.
create or replace function game.bot_quarter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; s record; ac record;
  v_weak uuid; v_strong uuid; v_moves int := 0;
begin
  for al in select a.id from public.airlines a where a.world_id = p_world and a.is_ai and a.status = 'active' loop
    for i in 1..game.param('bot_moves_qtr')::int loop
      with st as (
        select r.id, r.origin, r.dest, m.km,
               sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0) as lf,
               (select count(*) from public.rotations ro where ro.route_id = r.id) as n
          from public.routes r
          join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
          join public.route_daily d on d.route_id = r.id and d.game_day > p_day - 28
         where r.airline_id = al.id and r.status = 'open'
         group by r.id, m.km)
      select (select x.id from st x where x.n >= 2 and x.lf < game.param('bot_move_lf_low') order by x.lf limit 1),
             (select x.id from st x where x.lf > game.param('bot_move_lf_high') order by x.lf desc limit 1)
        into v_weak, v_strong;
      exit when v_weak is null or v_strong is null;
      select r.id, r.origin, r.dest, m.km into s
        from public.routes r join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
       where r.id = v_strong;
      select x.id into ac
        from public.rotations ro join public.aircraft x on x.id = ro.aircraft_id
       where ro.route_id = v_weak and x.status = 'active'
       order by ro.weekly_trips limit 1;
      exit when not found;
      begin
        delete from public.rotations where aircraft_id = ac.id;   -- bot aircraft fly one route each
        if (select base_iata from public.aircraft where id = ac.id) not in (s.origin, s.dest) then
          perform public.rebase_aircraft(al.id, ac.id, s.origin);
        end if;
        perform public.set_rotation(al.id, ac.id, s.id, game.fit_trips(ac.id, s.km));
        v_moves := v_moves + 1;
      exception when others then
        exit;   -- the move is rolled back
      end;
    end loop;
    -- routes that stay empty give an aircraft back to the lessors, where players can lease it (each route keeps one)
    for ac in
      select (select ro.aircraft_id from public.rotations ro where ro.route_id = z.id order by ro.weekly_trips limit 1) as id
        from (select r.id, sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0) as lf
                from public.routes r join public.route_daily d on d.route_id = r.id and d.game_day > p_day - 28
               where r.airline_id = al.id and r.status = 'open' group by r.id) z
       where z.lf < game.param('bot_return_lf') and (select count(*) from public.rotations ro where ro.route_id = z.id) >= 2
       order by z.lf limit game.param('bot_returns_qtr')::int
    loop
      perform public.return_aircraft(al.id, ac.id);
      v_moves := v_moves + 1;
    end loop;
    -- routes that stay full at fares in the top half of the band get another aircraft from the airline's own orders
    for s in
      select z.id, z.km, (select ro.aircraft_id from public.rotations ro where ro.route_id = z.id limit 1) as model
        from (select r.id, m.km, r.fare_econ, m.ref_fare,
                     sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0) as lf
                from public.routes r
                join public.markets m on m.a = least(r.origin, r.dest) and m.b = greatest(r.origin, r.dest)
                join public.route_daily d on d.route_id = r.id and d.game_day > p_day - 28
               where r.airline_id = al.id and r.status = 'open' group by r.id, m.km, m.ref_fare) z
        join public.airlines a on a.id = al.id
        join public.bot_airlines ba on ba.code = a.code
       where z.lf > game.param('bot_add_lf') and z.fare_econ >= z.ref_fare * (ba.fare_lo + ba.fare_hi) / 2
       order by z.lf desc limit game.param('bot_adds_qtr')::int
    loop
      exit when (select count(*) from public.aircraft where airline_id = al.id)
                >= game.param('bot_fleet_max_mult') * game.bot_start_fleet(p_world, (select code from public.airlines where id = al.id));
      insert into public.aircraft (world_id, type_id, airline_id, reg, built_day, status, available_day, base_iata,
                                   biz_rows, biz_pitch, econ_pitch, seats_biz, seats_econ)
      select p_world, x.type_id, al.id, game.next_reg(), p_day, 'active', p_day, x.base_iata,
             x.biz_rows, x.biz_pitch, x.econ_pitch, x.seats_biz, x.seats_econ
        from public.aircraft x where x.id = s.model
      returning id into ac;
      insert into public.aircraft_terms (aircraft_id, airline_id, holding, lease_usd_month, lease_end_day, deposit_inr, start_day)
      select ac.id, al.id, 'lease', game.lease_rent_usd(p_world, x.type_id, p_day, p_day), p_day + game.param('lease_term_days')::int, 0, p_day
        from public.aircraft x where x.id = ac.id;
      perform public.set_rotation(al.id, ac.id, s.id, game.fit_trips(ac.id, s.km));
      v_moves := v_moves + 1;
    end loop;
  end loop;
  return v_moves;
end $$;

-- ---------- Permissions ----------
-- Engine internals stay closed. Public functions: signed-in players and the server only.

revoke all on all functions in schema game from public, anon, authenticated;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prosecdef loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
