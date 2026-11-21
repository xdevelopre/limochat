-- Limo Chat v1.10 profile repair migration
-- Run in Supabase Dashboard > SQL Editor while the v1.09 schema is already installed.
-- This function can create a missing profile only for the currently authenticated user.

create or replace function public.ensure_limo_profile()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  auth_row auth.users%rowtype;
  profile_row public.profiles%rowtype;
  base_username text;
  candidate text;
  display_value text;
  attempt integer;
begin
  if me is null then
    raise exception 'AUTH_REQUIRED' using errcode = '28000';
  end if;

  select * into profile_row from public.profiles where id = me;
  if found then return to_jsonb(profile_row); end if;

  select * into auth_row from auth.users where id = me;
  if not found then raise exception 'AUTH_USER_NOT_FOUND'; end if;

  base_username := lower(coalesce(
    nullif(auth_row.raw_user_meta_data ->> 'username', ''),
    split_part(coalesce(auth_row.email, 'user@limochat.app'), '@', 1)
  ));
  base_username := left(regexp_replace(base_username, '[^a-z0-9_.]', '', 'g'), 24);
  if char_length(base_username) < 3 then
    base_username := 'user_' || left(replace(me::text, '-', ''), 8);
  end if;
  display_value := left(coalesce(
    nullif(auth_row.raw_user_meta_data ->> 'display_name', ''),
    nullif(auth_row.raw_user_meta_data ->> 'full_name', ''),
    base_username
  ), 40);

  for attempt in 0..8 loop
    if attempt = 0 then
      candidate := base_username;
    else
      -- Length is always <= 24 to satisfy profiles_username_check.
      candidate := left(base_username, 14) || '_' || substr(replace(me::text, '-', ''), 1, 8) || substr('12345678', attempt, 1);
    end if;

    insert into public.profiles (id, username, display_name)
    values (me, candidate, display_value)
    on conflict do nothing;

    select * into profile_row from public.profiles where id = me;
    if found then return to_jsonb(profile_row); end if;
  end loop;

  raise exception 'PROFILE_CREATE_FAILED';
end;
$$;

revoke all on function public.ensure_limo_profile() from public, anon;
grant execute on function public.ensure_limo_profile() to authenticated;
