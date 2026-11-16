-- Rule functions: parameters, geometry, cabin layout, flight physics, market builder.

create or replace function game.param(p_key text) returns numeric
language sql stable set search_path = '' as $$
  select num from public.game_params where key = p_key
$$;

create or replace function game.haversine_km(lat1 float8, lon1 float8, lat2 float8, lon2 float8) returns float8
language sql immutable set search_path = '' as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

-- Share of travellers who fly rather than go by road or rail.
create or replace function game.air_share(p_km float8) returns float8
language sql stable set search_path = '' as $$
  select 1 - 1 / (1 + power(p_km / game.param('air_share_d0_km')::float8, game.param('air_share_pow')::float8))
$$;

create or replace function game.block_hours(p_type text, p_km numeric) returns numeric
language sql stable set search_path = '' as $$
  select p_km / t.cruise_kmh + t.block_offset_h from public.aircraft_types t where t.id = p_type
$$;

create or replace function game.sector_fuel_kg(p_type text, p_km numeric, p_pax numeric) returns numeric
language sql stable set search_path = '' as $$
  select (t.fuel_fixed_kg + t.fuel_per_km_kg * p_km) * (0.80 + 0.20 * p_pax / t.ref_seats)
  from public.aircraft_types t where t.id = p_type
$$;

-- Cabin layout calculator. Safe for clients to call: it only reads public reference data.
create or replace function public.layout_calc(
  p_type text, p_biz_rows int, p_biz_pitch int, p_econ_pitch int, p_crew_rule text default 'per50')
returns table (
  valid boolean, reason text, seats_econ int, seats_biz int, seats int, cabin_crew int,
  comfort_econ numeric, comfort_biz numeric, range_km int, min_turn_min numeric)
language plpgsql stable set search_path = '' as $$
declare
  t public.aircraft_types%rowtype;
  v_bp int := 0;
begin
  valid := false;
  select * into t from public.aircraft_types where id = p_type;
  if not found then reason := 'Unknown aircraft type'; return next; return; end if;
  if p_econ_pitch is null or p_econ_pitch not between 28 and 34 then
    reason := 'Economy pitch must be 28 to 34 inches'; return next; return;
  end if;
  if p_biz_rows is null or p_biz_rows < 0 then
    reason := 'Business rows cannot be negative'; return next; return;
  end if;
  if p_biz_rows > 0 then
    if t.biz_kind = 'none' then
      reason := 'This aircraft cannot take a business cabin'; return next; return;
    elsif t.biz_kind = 'lieflat' then
      v_bp := 44;
    else
      if p_biz_pitch is null or p_biz_pitch not between 36 and 42 then
        reason := 'Business pitch must be 36 to 42 inches'; return next; return;
      end if;
      v_bp := p_biz_pitch;
    end if;
    if p_biz_rows * v_bp > t.cabin_len_in then
      reason := 'The business cabin does not fit'; return next; return;
    end if;
  end if;

  seats_biz  := p_biz_rows * t.biz_abreast;
  seats_econ := least(floor((t.cabin_len_in - p_biz_rows * v_bp)::numeric / p_econ_pitch)::int * t.econ_abreast,
                      t.max_seats - seats_biz);
  if seats_econ < 0 then
    reason := 'Too many seats for this aircraft'; return next; return;
  end if;
  seats := seats_econ + seats_biz;

  cabin_crew := case
    when p_crew_rule = 'india' and seats <= 50 then 1
    when p_crew_rule = 'india' and seats < 100 then 2
    when p_crew_rule = 'india' then 2 + ceil((seats - 99) / 50.0)::int
    else ceil(seats / 50.0)::int end;
  comfort_econ := round((p_econ_pitch - 28) / 6.0, 2);
  comfort_biz  := case when p_biz_rows = 0 then null
                       when t.biz_kind = 'lieflat' then 2.6
                       else round(1.6 + (v_bp - 36) / 12.0, 2) end;
  range_km     := round(t.range_km * least(1.10, 1 - 0.4 * (seats - t.ref_seats)::numeric / t.ref_seats))::int;
  min_turn_min := greatest(t.base_turn_min - 5, t.base_turn_min + 0.1 * (seats - t.ref_seats));
  valid := true; reason := null;
  return next;
end $$;

revoke all on function public.layout_calc(text, int, int, int, text) from public, anon;
grant execute on function public.layout_calc(text, int, int, int, text) to authenticated;

-- Working tables for the market builder (engine-only).
create table game.market_balance (iata text primary key, f float8 not null);
create table game.market_weights (
  a text not null, b text not null, km float8 not null, w float8 not null,
  primary key (a, b)
);
alter table game.market_balance enable row level security;
alter table game.market_weights enable row level security;

-- Rebuilds every market from the airport table. Safe to re-run: it only inserts and updates.
-- Domestic: balanced gravity model. Each airport's pairs add up to its real domestic traffic.
-- International: each Indian airport's international traffic is split over foreign airports
-- by mass x affinity. Stored values are potential travellers a day, each way.
create or replace function game.rebuild_markets() returns int
language plpgsql set search_path = '' as $$
declare
  v_cap float8 := game.param('capture_ref');
  v_ff  float8 := game.param('ref_fare_fixed');
  v_fk  float8 := game.param('ref_fare_per_km');
  v_n   int;
begin
  insert into game.market_balance (iata, f)
  select iata, 1.0 from public.airports where is_india
  on conflict (iata) do update set f = 1.0;

  insert into game.market_weights (a, b, km, w)
  select p.iata, q.iata,
         game.haversine_km(p.lat::float8, p.lon::float8, q.lat::float8, q.lon::float8),
         game.air_share(game.haversine_km(p.lat::float8, p.lon::float8, q.lat::float8, q.lon::float8))
  from public.airports p join public.airports q on p.iata <> q.iata and p.is_india and q.is_india
  on conflict (a, b) do update set km = excluded.km, w = excluded.w;

  -- balance airports that are open from day 0
  for i in 1..150 loop
    update game.market_balance x set f = x.f * sqrt(s.dom / s.tot)
    from (select p.iata, (p.pax_m * (1 - p.intl_share))::float8 as dom,
                 sum(bp.f * bq.f * (p.pax_m * (1 - p.intl_share))::float8
                     * (q.pax_m * (1 - q.intl_share))::float8 * w.w) as tot
          from public.airports p
          join game.market_balance bp on bp.iata = p.iata
          join game.market_weights w on w.a = p.iata
          join public.airports q on q.iata = w.b
          join game.market_balance bq on bq.iata = q.iata
          where p.is_india and q.is_india and p.opens_day = 0 and q.opens_day = 0
          group by p.iata, p.pax_m, p.intl_share) s
    where x.iata = s.iata;
  end loop;
  -- airports that open later borrow the factor of their city's established airport
  update game.market_balance x set f = s.f
  from public.airports p join game.market_balance s on s.iata = p.sibling
  where x.iata = p.iata and p.opens_day > 0;

  update public.markets set n_biz = 0, n_lei = 0, n_bud = 0 where n_biz + n_lei + n_bud > 0;

  insert into public.markets (a, b, km, intl, n_biz, n_lei, n_bud, ref_fare)
  select a, b, round(km)::int, false,
         round((n * sb)::numeric, 1), round((n * (1 - sb) * sl)::numeric, 1), round((n * (1 - sb) * (1 - sl))::numeric, 1),
         (round((v_ff + v_fk * km) / 10) * 10)::int
  from (select p.iata as a, q.iata as b, w.km,
               bp.f * bq.f * (p.pax_m * (1 - p.intl_share))::float8 * (q.pax_m * (1 - q.intl_share))::float8
                 * w.w * 1e6 / 2 / 365 / v_cap as n,
               0.08 + 0.27 * (p.biz_idx + q.biz_idx)::float8 / 2 as sb,
               0.30 + 0.45 * greatest(p.tour_idx, q.tour_idx)::float8 as sl
        from public.airports p
        join game.market_balance bp on bp.iata = p.iata
        join game.market_weights w on w.a = p.iata
        join public.airports q on q.iata = w.b
        join game.market_balance bq on bq.iata = q.iata
        where p.is_india and q.is_india and p.iata < q.iata) x
  on conflict (a, b) do update set km = excluded.km, intl = excluded.intl, n_biz = excluded.n_biz,
    n_lei = excluded.n_lei, n_bud = excluded.n_bud, ref_fare = excluded.ref_fare;

  insert into public.markets (a, b, km, intl, n_biz, n_lei, n_bud, ref_fare)
  select least(ia, fa), greatest(ia, fa), round(km)::int, true,
         round((n * sb)::numeric, 1), round((n * (1 - sb) * sl)::numeric, 1), round((n * (1 - sb) * (1 - sl))::numeric, 1),
         (round((v_ff + v_fk * km) / 10) * 10)::int
  from (select i.iata as ia, f.iata as fa,
               game.haversine_km(i.lat::float8, i.lon::float8, f.lat::float8, f.lon::float8) as km,
               (i.pax_m * i.intl_share)::float8 * (f.mass * coalesce(af.mult, 1))::float8 / tot.w
                 * 1e6 / 2 / 365 / v_cap as n,
               0.08 + 0.27 * (i.biz_idx + f.biz_idx)::float8 / 2 as sb,
               0.30 + 0.45 * greatest(i.tour_idx, f.tour_idx)::float8 as sl
        from public.airports i
        join public.airports f on not f.is_india
        left join public.intl_affinity af on af.india_region = i.region and af.foreign_region = f.region
        join (select i2.iata, sum(f2.mass * coalesce(af2.mult, 1))::float8 as w
              from public.airports i2
              join public.airports f2 on not f2.is_india
              left join public.intl_affinity af2 on af2.india_region = i2.region and af2.foreign_region = f2.region
              where i2.is_india
              group by i2.iata) tot on tot.iata = i.iata
        where i.is_india and i.pax_m * i.intl_share > 0) x
  where n >= 1
  on conflict (a, b) do update set km = excluded.km, intl = excluded.intl, n_biz = excluded.n_biz,
    n_lei = excluded.n_lei, n_bud = excluded.n_bud, ref_fare = excluded.ref_fare;

  select count(*) into v_n from public.markets;
  return v_n;
end $$;

revoke all on all functions in schema game from public, anon, authenticated;
