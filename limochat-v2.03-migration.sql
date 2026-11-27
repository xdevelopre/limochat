-- Limo Chat 2.03 additive migration. Run AFTER 2.02 migration.
-- No existing tables, users, or messages are dropped or truncated.
begin;
insert into public.limo_schema_migrations(version,notes)
values('2.03','Admin console, timed suspension, exact-text message removal, private communities')
on conflict(version) do nothing;

alter table public.profiles add column if not exists suspended_until timestamptz;
alter table public.profiles add column if not exists last_seen_at timestamptz;
create index if not exists profiles_last_seen_idx on public.profiles(last_seen_at desc);
create or replace function public.limo_touch_presence()
returns timestamptz language plpgsql security definer set search_path=public
as $$ declare v timestamptz; begin
 if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501'; end if;
 update public.profiles set last_seen_at=now(),updated_at=now() where id=auth.uid() returning last_seen_at into v;
 return v;
end $$;
revoke all on function public.limo_touch_presence() from public,anon;

grant execute on function public.limo_touch_presence() to authenticated;
create or replace function public.limo_get_presence(p_target_user uuid)
returns timestamptz language sql stable security definer set search_path=public
as $$
 select case when p.public_profile and not p.is_suspended then p.last_seen_at else null end
 from public.profiles p where p.id=p_target_user and auth.uid() is not null;
$$;
revoke all on function public.limo_get_presence(uuid) from public,anon;
grant execute on function public.limo_get_presence(uuid) to authenticated;

alter table public.profiles add column if not exists suspension_reason text not null default '';
create index if not exists profiles_suspended_until_idx on public.profiles(suspended_until) where is_suspended=true;

create or replace function public.limo_admin_set_suspension(
  p_target_user uuid, p_duration_seconds bigint, p_reason text default ''
) returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'ADMIN_ONLY' using errcode='42501'; end if;
  if p_duration_seconds < -1 or p_duration_seconds > 31536000 then raise exception 'INVALID_SUSPENSION_DURATION' using errcode='22023'; end if;
  if p_duration_seconds=0 then
    update public.profiles set is_suspended=false,suspended_until=null,suspension_reason='',updated_at=now() where id=p_target_user;
  else
    update public.profiles set is_suspended=true,suspended_until=case when p_duration_seconds=-1 then null else now()+make_interval(secs=>p_duration_seconds::double precision) end,suspension_reason=left(coalesce(p_reason,''),500),updated_at=now() where id=p_target_user;
  end if;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
end $$;

create or replace function public.limo_admin_update_report(target_report uuid,new_status text,note text default '')
returns void language plpgsql security definer set search_path=public
as $$
begin
 if not public.limo_is_admin() then raise exception 'ADMIN_ONLY' using errcode='42501'; end if;
 if new_status not in ('new','reviewing','resolved','rejected') then raise exception 'INVALID_REPORT_STATUS' using errcode='22023'; end if;
 update public.reports set status=new_status,admin_note=left(coalesce(note,''),1000) where id=target_report;
 if not found then raise exception 'REPORT_NOT_FOUND'; end if;
end $$;

create or replace function public.limo_admin_delete_message_by_text(p_exact_text text)
returns table(private_deleted bigint,global_deleted bigint,room_deleted bigint)
language plpgsql security definer set search_path=public
as $$
declare n1 bigint:=0; n2 bigint:=0; n3 bigint:=0; v text;
begin
 if not public.limo_is_admin() then raise exception 'ADMIN_ONLY' using errcode='42501'; end if;
 v:=coalesce(p_exact_text,'');
 if length(v)<1 or length(v)>10000 then raise exception 'INVALID_MESSAGE_TEXT' using errcode='22023'; end if;
 delete from public.messages where text=v; get diagnostics n1=row_count;
 delete from public.global_messages where text=v; get diagnostics n2=row_count;
 delete from public.limo_room_messages where text=v; get diagnostics n3=row_count;
 return query select n1,n2,n3;
end $$;

create or replace function public.limo_create_private_community(p_name text,p_kind text,p_member_ids uuid[] default '{}')
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_chat uuid; v_ids uuid[]; v_id uuid; v_role text;
begin
 if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='42501'; end if;
 if exists(select 1 from public.profiles where id=auth.uid() and is_suspended and (suspended_until is null or suspended_until>now())) and not public.limo_is_admin() then raise exception 'ACCOUNT_SUSPENDED' using errcode='42501'; end if;
 if length(trim(coalesce(p_name,'')))<2 or length(p_name)>80 then raise exception 'INVALID_NAME' using errcode='22023'; end if;
 if p_kind not in ('group','channel') then raise exception 'INVALID_KIND' using errcode='22023'; end if;
 select coalesce(array_agg(distinct x),array[]::uuid[]) into v_ids from unnest(coalesce(p_member_ids,array[]::uuid[])) x where x is not null and x<>auth.uid();
 if cardinality(v_ids)>99 then raise exception 'TOO_MANY_MEMBERS' using errcode='22023'; end if;
 if exists(select 1 from unnest(v_ids) x left join public.profiles p on p.id=x where p.id is null or p.is_suspended) then raise exception 'INVALID_OR_SUSPENDED_MEMBER'; end if;
 if exists(select 1 from public.user_blocks b where (b.user_id=auth.uid() and b.blocked_user_id=any(v_ids)) or (b.blocked_user_id=auth.uid() and b.user_id=any(v_ids))) then raise exception 'BLOCKED_MEMBER_PAIR' using errcode='42501'; end if;
 insert into public.chats(name,chat_type,created_by) values(trim(p_name),p_kind,auth.uid()) returning id into v_chat;
 insert into public.chat_members(chat_id,user_id,role) values(v_chat,auth.uid(),'owner');
 foreach v_id in array v_ids loop
   v_role:=case when p_kind='channel' then 'subscriber' else 'member' end;
   insert into public.chat_members(chat_id,user_id,role) values(v_chat,v_id,v_role) on conflict do nothing;
 end loop;
 return v_chat;
end $$;

revoke all on function public.limo_admin_set_suspension(uuid,bigint,text) from public,anon;
revoke all on function public.limo_admin_update_report(uuid,text,text) from public,anon;
revoke all on function public.limo_admin_delete_message_by_text(text) from public,anon;
revoke all on function public.limo_create_private_community(text,text,uuid[]) from public,anon;
grant execute on function public.limo_admin_set_suspension(uuid,bigint,text) to authenticated;
grant execute on function public.limo_admin_update_report(uuid,text,text) to authenticated;
grant execute on function public.limo_admin_delete_message_by_text(text) to authenticated;
grant execute on function public.limo_create_private_community(text,text,uuid[]) to authenticated;

-- Keep existing is_suspended boolean in sync with timed expiry. Policies continue
-- to fail closed until this trusted cleanup function runs; client cannot un-suspend.
create or replace function public.limo_cleanup_expired_suspensions()
returns bigint language plpgsql security definer set search_path=public
as $$ declare n bigint; begin
 update public.profiles set is_suspended=false,suspended_until=null,suspension_reason='',updated_at=now()
 where is_suspended=true and suspended_until is not null and suspended_until<=now();
 get diagnostics n=row_count; return n;
end $$;
revoke all on function public.limo_cleanup_expired_suspensions() from public,anon,authenticated;
-- Optional pg_cron schedule. If pg_cron is unavailable, invoke this function from a trusted scheduler.
do $$ begin
 if exists(select 1 from pg_extension where extname='pg_cron') then
   perform cron.schedule('limo-suspension-expiry','* * * * *','select public.limo_cleanup_expired_suspensions()');
 end if;
exception when others then raise notice 'Could not schedule timed suspension cleanup: %',sqlerrm;
end $$;
commit;
