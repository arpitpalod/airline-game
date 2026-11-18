-- Stage 3 (app): what the app needs beyond the Stage 2 functions. Adds only; changes no rule.

-- The invite code of a world, for the admin screen's invite link. Admins only; world_secrets stays unreadable.
create or replace function public.admin_world_invite(p_world uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_code text;
begin
  perform game.require_admin();
  select invite_code into v_code from public.world_secrets where world_id = p_world;
  if v_code is null then raise exception 'World not found'; end if;
  return v_code;
end $$;

revoke all on function public.admin_world_invite(uuid) from public, anon;
grant execute on function public.admin_world_invite(uuid) to authenticated, service_role;
