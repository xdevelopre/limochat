-- LIMO CHAT 2.04 — additive session registry migration
-- Apply AFTER migrations 2.0, 2.01, 2.02 and 2.03.
-- Does not drop, truncate, or rewrite existing user/message data.
begin;

create table if not exists public.limo_device_sessions (
  id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_label text not null default 'دستگاه ناشناس',
  user_agent text not null default '',
  ip_address inet,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint limo_device_sessions_label_len check (char_length(device_label) between 1 and 120),
  constraint limo_device_sessions_ua_len check (char_length(user_agent) <= 500)
);
create index if not exists limo_device_sessions_user_seen_idx
  on public.limo_device_sessions(user_id,last_seen_at desc);
create index if not exists limo_device_sessions_active_idx
  on public.limo_device_sessions(user_id) where revoked_at is null;

alter table public.limo_device_sessions enable row level security;
drop policy if exists limo_device_sessions_select_own on public.limo_device_sessions;
create policy limo_device_sessions_select_own on public.limo_device_sessions
  for select to authenticated using (user_id=auth.uid());
-- No direct INSERT/UPDATE/DELETE policy: writes are constrained by owner-checked RPCs.
revoke all on public.limo_device_sessions from anon, authenticated;
grant select on public.limo_device_sessions to authenticated;

create or replace function public.limo_register_device_session(
  p_session_id uuid,
  p_device_label text default 'دستگاه ناشناس',
  p_user_agent text default ''
) returns uuid
language plpgsql security definer set search_path=public,auth
as $$
declare v_user uuid:=auth.uid(); v_id uuid;
begin
  if v_user is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501'; end if;
  if p_session_id is null then raise exception 'INVALID_SESSION_ID' using errcode='22023'; end if;
  insert into public.limo_device_sessions(id,user_id,device_label,user_agent,last_seen_at,revoked_at)
  values(p_session_id,v_user,left(coalesce(nullif(trim(p_device_label),''),'دستگاه ناشناس'),120),left(coalesce(p_user_agent,''),500),now(),null)
  on conflict(id) do update set
    device_label=excluded.device_label,
    user_agent=excluded.user_agent,
    last_seen_at=now()
  where public.limo_device_sessions.user_id=v_user and public.limo_device_sessions.revoked_at is null
  returning id into v_id;
  if v_id is null then raise exception 'SESSION_ID_INVALID_OR_REVOKED' using errcode='42501'; end if;
  return v_id;
end $$;

create or replace function public.limo_revoke_device_session(p_session_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501'; end if;
  update public.limo_device_sessions set revoked_at=coalesce(revoked_at,now()),last_seen_at=now()
  where id=p_session_id and user_id=auth.uid() and revoked_at is null;
  get diagnostics n=row_count;
  return n=1;
end $$;


create or replace function public.limo_touch_device_session(p_session_id uuid)
returns boolean language plpgsql security definer set search_path=public,auth
as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501'; end if;
  update public.limo_device_sessions set last_seen_at=now()
  where id=p_session_id and user_id=auth.uid() and revoked_at is null;
  get diagnostics n=row_count;
  return n=1;
end $$;

revoke all on function public.limo_touch_device_session(uuid) from public,anon;
grant execute on function public.limo_touch_device_session(uuid) to authenticated;

revoke all on function public.limo_register_device_session(uuid,text,text) from public,anon;
revoke all on function public.limo_revoke_device_session(uuid) from public,anon;
grant execute on function public.limo_register_device_session(uuid,text,text) to authenticated;
grant execute on function public.limo_revoke_device_session(uuid) to authenticated;

-- Enable realtime notifications so other open app tabs/devices can react to revocation.
do $$ begin
  alter publication supabase_realtime add table public.limo_device_sessions;
exception when duplicate_object then null;
when undefined_object then raise notice 'supabase_realtime publication not found; create/enable it in Supabase Dashboard.';
end $$;

insert into public.limo_schema_migrations(version,notes)
values('2.04','App device session registry, own-session listing, heartbeat and app-level revocation')
on conflict(version) do update set notes=excluded.notes;
commit;
