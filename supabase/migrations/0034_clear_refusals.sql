-- 0034: refusals that read like the app (in-game QA, 26 Nov 2026; spec open item 28).
-- The app now checks most of these before the tap; when the server still refuses, its message uses the app's money
-- format and grouped numbers. No rule changes.
--  1. game.inr_text: money as the app shows it (₹238.9 cr, ₹4.5 lakh, ₹12,345).
--  2. game.book: a payment larger than the cash in hand says what it needs and what there is.
--  3. set_rotation (from 0033): the seats between countries refusal with grouped numbers.

create or replace function game.inr_text(p numeric) returns text
language sql immutable set search_path = '' as $$
  select case when p is null then '–' else
    case when p < 0 then '−' else '' end || '₹' ||
    case when abs(p) >= 1e9 then to_char(round(abs(p) / 1e7), 'FM999,999,990') || ' cr'
         when abs(p) >= 1e8 then rtrim(to_char(round(abs(p) / 1e7, 1), 'FM999,990.9'), '.') || ' cr'
         when abs(p) >= 1e7 then rtrim(to_char(round(abs(p) / 1e7, 2), 'FM990.99'), '.') || ' cr'
         when abs(p) >= 1e5 then rtrim(to_char(round(abs(p) / 1e5, 1), 'FM990.9'), '.') || ' lakh'
         else to_char(round(abs(p)), 'FM99,990') end end
$$;

create or replace function game.book(p_airline uuid, p_day int, p_cash numeric, p_kind text, p_note text,
                                     p_pnl numeric default 0, p_force boolean default false) returns void
language plpgsql set search_path = '' as $$
declare
  v_cash numeric;
begin
  update public.airline_finance set cash_inr = cash_inr + p_cash
   where airline_id = p_airline and (p_force or p_cash >= 0 or cash_inr >= -p_cash);
  if not found then
    select cash_inr into v_cash from public.airline_finance where airline_id = p_airline;
    raise exception 'Not enough cash: this needs % and you have % in hand. Borrow on Money or free up cash first.',
      game.inr_text(-p_cash), game.inr_text(v_cash);
  end if;
  insert into public.transactions (airline_id, game_day, kind, amount_inr, note, pnl_inr)
  values (p_airline, p_day, p_kind, p_cash, p_note, p_pnl);
end $$;

-- set_rotation from 0033: the seats refusal with grouped numbers
create or replace function public.set_rotation(p_airline uuid, p_aircraft uuid, p_route uuid, p_weekly_trips int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  rw public.worlds%rowtype;
  rc public.aircraft%rowtype;
  rr public.routes%rowtype;
  l record;
  v_issue text;
  v_cc text; v_cname text; v_lim numeric; v_used numeric; v_seats int;
begin
  rw := game.actor(p_airline, false);
  if rw.status not in ('setup', 'running') then raise exception 'This world is not running'; end if;
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
  -- 0028: seats between countries. A player may add seats to a country with a limit only while seats are free; the
  -- computer-run airlines (incumbents) are counted but never refused.
  select f.country, sl.name into v_cc, v_cname
    from public.airports f join public.seat_limits sl on sl.country = f.country
   where f.iata in (rr.origin, rr.dest) and not f.is_india
     and exists (select 1 from public.airports i where i.iata in (rr.origin, rr.dest) and i.is_india);
  v_lim := case when v_cc is not null then game.seat_limit(rw.id, v_cc) end;
  -- 0033: a computer-run airline trims its flights to the free seats (its starting network excepted)
  if v_lim is not null and (select is_ai from public.airlines where id = p_airline) and rw.game_day > 0
     and game.param('bot_equal_rules') >= 1 then
    v_seats := rc.seats_econ + rc.seats_biz;
    v_used := game.seats_used(rw.id, v_cc) - coalesce((select weekly_trips from public.rotations
                                                         where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats;
    if v_used + p_weekly_trips * v_seats > v_lim then
      p_weekly_trips := least(p_weekly_trips, greatest(0, floor((v_lim - v_used) / v_seats))::int);
      if p_weekly_trips = 0 then
        delete from public.rotations where aircraft_id = rc.id and route_id = rr.id;
        return jsonb_build_object('weekly_trips', 0);
      end if;
    end if;
  end if;
  if v_lim is not null and not (select is_ai from public.airlines where id = p_airline) then
    v_seats := rc.seats_econ + rc.seats_biz;
    v_used := game.seats_used(rw.id, v_cc) - coalesce((select weekly_trips from public.rotations
                                                         where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats;
    if p_weekly_trips * v_seats > coalesce((select weekly_trips from public.rotations where aircraft_id = rc.id and route_id = rr.id), 0) * v_seats
       and v_used + p_weekly_trips * v_seats > v_lim then
      raise exception 'Seats between India and % are full in this world: % of % a week are taken, so % are free (% with this aircraft). Free seats go to whoever flies them first.',
        v_cname, to_char(round(v_used), 'FM999,999,999'), to_char(round(v_lim), 'FM999,999,999'),
        to_char(greatest(0, round(v_lim - v_used)), 'FM999,999,999'),
        case when floor((v_lim - v_used) / v_seats) = 1 then '1 round trip' else greatest(0, floor((v_lim - v_used) / v_seats)) || ' round trips' end;
    end if;
  end if;
  insert into public.rotations (aircraft_id, route_id, weekly_trips) values (rc.id, rr.id, p_weekly_trips)
    on conflict (aircraft_id, route_id) do update set weekly_trips = excluded.weekly_trips;
  return jsonb_build_object('weekly_trips', p_weekly_trips);
end $$;

