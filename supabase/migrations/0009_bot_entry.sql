-- Computer-run airlines contest routes where players earn well (owner request, 18 Nov 2026).
-- Before this, their route networks were fixed, so a player could find a route none of them flew and keep it.
-- Once a quarter each computer-run airline may now start one route a player has made full at a good fare, from one of
-- its own bases, and leaves such a route again if it stays empty. Every number is a game value (G) in game_params.
-- Adds and updates only.

insert into public.game_params (key, num, note) values
('bot_enter_qtr', 1, 'routes a computer-run airline may start each quarter to contest players'),
('bot_enter_lf', 0.85, 'players'' load factor on the city pair over 28 days that draws a computer-run airline in'),
('bot_enter_fare_mult', 1.0, 'and the players'' lowest economy fare there, as a multiple of the reference fare'),
('bot_enter_min_days', 28, 'days a player route must have been open before it can be contested'),
('bot_enter_max_airlines', 3, 'a city pair already flown by this many airlines is left alone'),
('bot_enter_undercut', 0.95, 'entry economy fare as a share of the players'' lowest fare, inside the airline''s band'),
('bot_exit_lf', 0.6, 'a contested route below this load factor over 28 days is given up'),
('bot_exit_min_days', 56, 'days a computer-run airline flies a contested route before it may give it up'),
('bot_retry_days', 364, 'a city pair a computer-run airline gave up is not contested again by any of them for this many days')
on conflict (key) do update set num = excluded.num, note = excluded.note;

-- Routes a computer-run airline flies that are not in its starting network are the ones it entered to contest players.
create or replace function game.bot_entered(p_airline uuid, p_a text, p_b text) returns boolean
language sql stable set search_path = '' as $$
  select not exists (select 1 from public.bot_network n join public.airlines al on al.code = n.code
                      where al.id = p_airline and least(n.origin, n.dest) = least(p_a, p_b) and greatest(n.origin, n.dest) = greatest(p_a, p_b))
$$;

create or replace function game.bot_enter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; cand record; dn record;
  v_taken text[] := '{}';
  v_n int := 0; v_k int; v_route uuid; v_ac uuid; v_fare int; v_done boolean;
begin
  for al in select a.id, a.name, a.code, ba.fare_lo, ba.fare_hi
              from public.airlines a join public.bot_airlines ba on ba.code = a.code
             where a.world_id = p_world and a.is_ai and a.status = 'active' order by a.code loop
    v_k := 0;
    for cand in
      with pr as (   -- city pairs players fly, over the last 28 days
        select least(r.origin, r.dest) as a, greatest(r.origin, r.dest) as b,
               sum(d.pax_econ + d.pax_biz)::numeric / nullif(sum(d.seats_econ + d.seats_biz), 0) as lf,
               sum(d.revenue_inr) as rev, min(r.fare_econ) as fare
          from public.routes r
          join public.airlines pa on pa.id = r.airline_id and not pa.is_ai and pa.status = 'active'
          join public.route_daily d on d.route_id = r.id and d.game_day > p_day - 28
         where r.world_id = p_world and r.status = 'open' and r.opened_day <= p_day - game.param('bot_enter_min_days')
         group by 1, 2)
      select pr.*, m.km, m.ref_fare, bs.iata as base, case when bs.iata = pr.a then pr.b else pr.a end as other
        from pr
        join public.markets m on m.a = pr.a and m.b = pr.b
        join public.bases bs on bs.airline_id = al.id and bs.iata in (pr.a, pr.b)
       where pr.lf >= game.param('bot_enter_lf') and pr.fare >= game.param('bot_enter_fare_mult') * m.ref_fare
         and not (pr.a || '-' || pr.b = any (v_taken))
         and not exists (select 1 from public.routes x where x.airline_id = al.id and x.status = 'open'
                            and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b)
         and not exists (select 1 from public.routes x join public.airlines xa on xa.id = x.airline_id and xa.is_ai
                          where x.world_id = p_world and x.status = 'closed' and x.opened_day > p_day - game.param('bot_retry_days')
                            and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b)
         and (select count(distinct x.airline_id) from public.routes x
               where x.world_id = p_world and x.status = 'open' and least(x.origin, x.dest) = pr.a and greatest(x.origin, x.dest) = pr.b
                 and exists (select 1 from public.rotations ro where ro.route_id = x.id)) < game.param('bot_enter_max_airlines')
       order by pr.rev desc
    loop
      exit when v_k >= game.param('bot_enter_qtr');
      v_fare := round(greatest(al.fare_lo * cand.ref_fare, least(al.fare_hi * cand.ref_fare, cand.fare * game.param('bot_enter_undercut'))));
      v_done := false;
      -- an aircraft from the airline's own routes that have more than one, emptiest route first
      for dn in
        select ro.aircraft_id
          from public.rotations ro
          join public.routes r on r.id = ro.route_id and r.airline_id = al.id and r.status = 'open'
          join public.aircraft x on x.id = ro.aircraft_id and x.status = 'active'
          left join lateral (select sum(z.pax_econ + z.pax_biz)::numeric / nullif(sum(z.seats_econ + z.seats_biz), 0) as lf
                               from public.route_daily z where z.route_id = r.id and z.game_day > p_day - 28) s on true
         where (select count(*) from public.rotations y where y.route_id = r.id) >= 2
         order by s.lf nulls first, (x.base_iata = cand.base) desc
         limit 5
      loop
        begin
          delete from public.rotations where aircraft_id = dn.aircraft_id;
          if (select base_iata from public.aircraft where id = dn.aircraft_id) <> cand.base then
            perform public.rebase_aircraft(al.id, dn.aircraft_id, cand.base);
          end if;
          v_route := public.open_route(al.id, cand.base, cand.other, v_fare);
          perform public.set_rotation(al.id, dn.aircraft_id, v_route, game.fit_trips(dn.aircraft_id, cand.km));
          v_done := true;
        exception when others then
          v_done := false;   -- this aircraft cannot fly it (range, runway): the attempt is rolled back
        end;
        exit when v_done;
      end loop;
      if v_done then
        insert into public.news (world_id, game_day, airline_id, kind, body, private)
        values (p_world, p_day, al.id, 'route',
                format('%s starts flying %s to %s, against the airlines already there.', al.name,
                       (select city from public.airports where iata = cand.base), (select city from public.airports where iata = cand.other)),
                false);
        v_taken := v_taken || (cand.a || '-' || cand.b);
        v_k := v_k + 1; v_n := v_n + 1;
      end if;
    end loop;
  end loop;
  return v_n;
end $$;

-- A contested route that stays empty is given up: its aircraft go back to the lessor pool, where players can lease them.
create or replace function game.bot_exit(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare r record; x record; v_n int := 0;
begin
  for r in
    select rt.id, rt.airline_id, rt.origin, rt.dest, al.name
      from public.routes rt join public.airlines al on al.id = rt.airline_id and al.is_ai and al.status = 'active'
     where rt.world_id = p_world and rt.status = 'open' and rt.opened_day <= p_day - game.param('bot_exit_min_days')
       and game.bot_entered(rt.airline_id, rt.origin, rt.dest)
       and coalesce((select sum(z.pax_econ + z.pax_biz)::numeric / nullif(sum(z.seats_econ + z.seats_biz), 0)
                       from public.route_daily z where z.route_id = rt.id and z.game_day > p_day - 28), 0) < game.param('bot_exit_lf')
  loop
    for x in select aircraft_id from public.rotations where route_id = r.id loop
      perform public.return_aircraft(r.airline_id, x.aircraft_id);
    end loop;
    perform public.close_route(r.airline_id, r.id);
    insert into public.news (world_id, game_day, airline_id, kind, body, private)
    values (p_world, p_day, r.airline_id, 'route',
            format('%s stops flying %s to %s.', r.name, (select city from public.airports where iata = r.origin),
                   (select city from public.airports where iata = r.dest)), false);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Every quarter a computer-run airline first leaves routes it entered that did not work (bot_exit), then moves aircraft
-- from its emptiest route to its fullest one, hands aircraft back to the lessors from routes that stay empty, adds
-- aircraft (from its own orders, not the lessor pool) to routes that stay busy at high fares, up to bot_fleet_max_mult
-- times its starting fleet, and finally contests a route where a player is earning well (bot_enter).
create or replace function game.bot_quarter(p_world uuid, p_day int) returns int
language plpgsql set search_path = '' as $$
declare
  al record; s record; ac record;
  v_weak uuid; v_strong uuid; v_moves int := 0;
begin
  v_moves := game.bot_exit(p_world, p_day);
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
  return v_moves + game.bot_enter(p_world, p_day);
end $$;

revoke all on function game.bot_entered(uuid, text, text), game.bot_enter(uuid, int), game.bot_exit(uuid, int), game.bot_quarter(uuid, int)
  from public, anon, authenticated;
