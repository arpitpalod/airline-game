-- Admins can change how long a game day takes in real time (owner request, 19 Nov 2026: "1 hour for 1 day feels like
-- a lot"). The world keeps the day it has processed and the next day starts counting at the new pace, so nothing
-- jumps. Lead times stay in game days, so in real time they shrink with the clock. Adds only.

create or replace function public.admin_set_speed(p_world uuid, p_minutes_per_day numeric) returns numeric
language plpgsql security definer set search_path = '' as $$
declare w public.worlds; v_speed numeric;
begin
  perform game.require_admin();
  if p_minutes_per_day is null or p_minutes_per_day < 5 or p_minutes_per_day > 1440 then
    raise exception 'Choose between 5 minutes and 24 hours for a game day';
  end if;
  select * into w from public.worlds where id = p_world for update;
  if not found then raise exception 'World not found'; end if;
  if w.status = 'ended' then raise exception 'This season is over'; end if;
  v_speed := round(1440 / p_minutes_per_day, 4);
  if w.status in ('running', 'paused') then
    -- restart the clock at the processed day, as if the world had always run at the new pace
    update public.worlds
       set speed = v_speed, paused_seconds = 0,
           started_at = now() - make_interval(secs => w.game_day * 86400 / v_speed),
           paused_at = case when w.status = 'paused' then now() else null end
     where id = p_world;
  else
    update public.worlds set speed = v_speed where id = p_world;
  end if;
  insert into public.news (world_id, game_day, kind, body, private)
  values (p_world, w.game_day, 'world', format('The clock changes: a game day now takes %s minutes of real time.', round(p_minutes_per_day)), false);
  return v_speed;
end $$;

revoke all on function public.admin_set_speed(uuid, numeric) from public, anon;
grant execute on function public.admin_set_speed(uuid, numeric) to authenticated, service_role;
