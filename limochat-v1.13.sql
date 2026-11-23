-- Limo Chat v1.13 - Supabase single-file setup/migration
-- Run once in Supabase SQL Editor as project owner.
-- This script is additive and uses IF NOT EXISTS where practical.
-- Never put the Supabase service_role key in browser code.

create extension if not exists pgcrypto;

-- Profiles: one row per Supabase Auth user.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text,
  bio text not null default '',
  avatar_url text,
  is_premium boolean not null default false,
  is_suspended boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles add column if not exists is_premium boolean not null default false;
alter table public.profiles add column if not exists is_suspended boolean not null default false;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  name text,
  chat_type text not null default 'private' check (chat_type in ('private','group','channel')),
  created_by uuid references public.profiles(id) on delete set null,
  last_message text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.chats add column if not exists chat_type text not null default 'private';
alter table public.chats add column if not exists created_by uuid references public.profiles(id) on delete set null;

create table if not exists public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member','subscriber')),
  joined_at timestamptz not null default now(),
  primary key (chat_id,user_id)
);
alter table public.chat_members add column if not exists role text not null default 'member';

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  sender_name text,
  text text not null default '',
  image_path text,
  image_name text,
  image_size bigint not null default 0,
  reply_to jsonb,
  reactions jsonb not null default '{}'::jsonb,
  status text not null default 'sent',
  edited boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
create index if not exists messages_chat_created_idx on public.messages(chat_id,created_at);
create index if not exists messages_sender_created_idx on public.messages(sender_id,created_at desc);
alter table public.messages add column if not exists expires_at timestamptz;

create table if not exists public.global_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  sender_name text,
  text text not null default '',
  image_path text,
  image_name text,
  image_size bigint not null default 0,
  reply_to jsonb,
  reactions jsonb not null default '{}'::jsonb,
  status text not null default 'sent',
  edited boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
create index if not exists global_messages_created_idx on public.global_messages(created_at);
create index if not exists global_messages_sender_idx on public.global_messages(sender_id,created_at desc);
alter table public.global_messages add column if not exists expires_at timestamptz;

create table if not exists public.user_blocks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  blocked_user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id,blocked_user_id),
  check(user_id <> blocked_user_id)
);

create table if not exists public.user_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table if not exists public.chat_states (
  user_id uuid not null references public.profiles(id) on delete cascade,
  chat_key text not null,
  pinned boolean not null default false,
  hidden boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key(user_id,chat_key)
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  reporter_username text,
  type text not null default 'other',
  target_uid uuid references public.profiles(id) on delete set null,
  target_name text,
  message_id uuid,
  chat_id uuid,
  reason text not null,
  content text not null default '',
  destination text not null default '@Report',
  status text not null default 'new' check(status in ('new','reviewing','resolved','rejected')),
  admin_note text,
  created_at timestamptz not null default now()
);
create index if not exists reports_status_created_idx on public.reports(status,created_at desc);

create table if not exists public.bot_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  sender_role text not null check(sender_role in ('user','bot')),
  text text not null,
  created_at timestamptz not null default now()
);
create index if not exists bot_messages_user_created_idx on public.bot_messages(user_id,created_at);

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  caller_name text,
  chat_id uuid references public.chats(id) on delete cascade,
  status text not null default 'ringing',
  offer jsonb,
  answer jsonb,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create index if not exists calls_callee_status_idx on public.calls(callee_id,status);
create table if not exists public.call_ice_candidates (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.calls(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  side text not null,
  candidate jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists call_ice_call_idx on public.call_ice_candidates(call_id,created_at);

create table if not exists public.limo_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.limo_group_invites (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  invite_code text not null unique default encode(gen_random_bytes(12),'hex'),
  created_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

-- Username is generated from the signup metadata supplied by index.html.
create or replace function public.limo_handle_new_user()
returns trigger language plpgsql security definer set search_path=public,auth
as $$
declare
  v_username text;
begin
  v_username := lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));
  v_username := regexp_replace(v_username,'[^a-z0-9_.]','','g');
  if length(v_username) < 3 then v_username := 'user_' || substr(replace(new.id::text,'-',''),1,12); end if;
  insert into public.profiles(id,username,display_name)
  values(new.id,v_username,coalesce(new.raw_user_meta_data->>'display_name',v_username))
  on conflict(id) do nothing;
  return new;
end $$;

drop trigger if exists limo_auth_user_created on auth.users;
create trigger limo_auth_user_created after insert on auth.users
for each row execute procedure public.limo_handle_new_user();

create or replace function public.ensure_limo_profile()
returns public.profiles language plpgsql security definer set search_path=public,auth
as $$
declare
  p public.profiles;
  u auth.users;
  v_username text;
begin
  select * into u from auth.users where id=auth.uid();
  if u.id is null then raise exception 'Not authenticated'; end if;
  select * into p from public.profiles where id=u.id;
  if p.id is null then
    v_username := lower(coalesce(u.raw_user_meta_data->>'username',split_part(u.email,'@',1)));
    v_username := regexp_replace(v_username,'[^a-z0-9_.]','','g');
    if length(v_username)<3 then v_username := 'user_'||substr(replace(u.id::text,'-',''),1,12); end if;
    insert into public.profiles(id,username,display_name)
    values(u.id,v_username,coalesce(u.raw_user_meta_data->>'display_name',v_username))
    on conflict(id) do update set username=excluded.username
    returning * into p;
  end if;
  return p;
end $$;

create or replace function public.limo_is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.limo_admins where user_id=auth.uid()) $$;

-- SECURITY DEFINER membership helpers prevent recursive RLS evaluation on chat_members.
create or replace function public.limo_is_chat_member(target_chat uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.chat_members where chat_id=target_chat and user_id=auth.uid()) $$;
create or replace function public.limo_can_manage_chat(target_chat uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.chat_members where chat_id=target_chat and user_id=auth.uid() and role in ('owner','admin')) $$;

create or replace function public.create_direct_chat(target_user uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_chat uuid;
begin
  if auth.uid() is null or target_user is null or target_user=auth.uid() then raise exception 'Invalid participant'; end if;
  if exists(select 1 from public.profiles where id in (auth.uid(),target_user) and is_suspended) then raise exception 'Account suspended'; end if;
  select c.id into v_chat
  from public.chats c
  join public.chat_members a on a.chat_id=c.id and a.user_id=auth.uid()
  join public.chat_members b on b.chat_id=c.id and b.user_id=target_user
  where c.chat_type='private'
    and (select count(*) from public.chat_members m where m.chat_id=c.id)=2
  limit 1;
  if v_chat is not null then return v_chat; end if;
  insert into public.chats(chat_type,created_by) values('private',auth.uid()) returning id into v_chat;
  insert into public.chat_members(chat_id,user_id,role) values(v_chat,auth.uid(),'owner'),(v_chat,target_user,'member');
  return v_chat;
end $$;

create or replace function public.create_limo_group(group_name text, member_ids uuid[] default '{}', make_channel boolean default false)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_chat uuid; v_member uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if length(trim(coalesce(group_name,'')))<2 or length(group_name)>70 then raise exception 'Invalid name'; end if;
  insert into public.chats(name,chat_type,created_by) values(trim(group_name),case when make_channel then 'channel' else 'group' end,auth.uid()) returning id into v_chat;
  insert into public.chat_members(chat_id,user_id,role) values(v_chat,auth.uid(),'owner');
  foreach v_member in array coalesce(member_ids,'{}'::uuid[]) loop
    if v_member<>auth.uid() and exists(select 1 from public.profiles where id=v_member and not is_suspended) then
      insert into public.chat_members(chat_id,user_id,role) values(v_chat,v_member,case when make_channel then 'subscriber' else 'member' end) on conflict do nothing;
    end if;
  end loop;
  return v_chat;
end $$;

create or replace function public.mark_chat_messages_read(target_chat uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not exists(select 1 from public.chat_members where chat_id=target_chat and user_id=auth.uid()) then return; end if;
  update public.messages set status='read'
  where chat_id=target_chat and sender_id<>auth.uid() and status<>'read';
end $$;

-- Enforce media rules on the database side: Premium only, max 500 KB, max 2 images/day.
create or replace function public.limo_guard_media_message()
returns trigger language plpgsql security definer set search_path=public
as $$
declare v_premium boolean; v_count integer;
begin
  if new.image_path is not null then
    select is_premium into v_premium from public.profiles where id=auth.uid();
    if not coalesce(v_premium,false) and not public.limo_is_admin() then
      raise exception 'MEDIA_PREMIUM_REQUIRED' using errcode='42501';
    end if;
    if coalesce(new.image_size,0)>512000 then raise exception 'MEDIA_LIMIT_500KB'; end if;
    if tg_table_name='messages' then
      select count(*) into v_count from public.messages where sender_id=auth.uid() and image_path is not null and created_at>now()-interval '24 hours';
    else
      select count(*) into v_count from public.global_messages where sender_id=auth.uid() and image_path is not null and created_at>now()-interval '24 hours';
    end if;
    if v_count>=2 then raise exception 'MEDIA_DAILY_LIMIT_2'; end if;
    new.expires_at := now()+interval '72 hours';
  end if;
  if exists(select 1 from public.profiles where id=auth.uid() and is_suspended) and not public.limo_is_admin() then
    raise exception 'ACCOUNT_SUSPENDED' using errcode='42501';
  end if;
  return new;
end $$;
drop trigger if exists limo_guard_private_media on public.messages;
create trigger limo_guard_private_media before insert on public.messages for each row execute function public.limo_guard_media_message();
drop trigger if exists limo_guard_global_media on public.global_messages;
create trigger limo_guard_global_media before insert on public.global_messages for each row execute function public.limo_guard_media_message();

-- Admin operations. Admin can manage users and remove rows but cannot decrypt E2EE because E2EE is not implemented in this release.
create or replace function public.limo_admin_set_user(target_user uuid, premium_value boolean default null, suspended_value boolean default null)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  update public.profiles set
    is_premium=coalesce(premium_value,is_premium),
    is_suspended=coalesce(suspended_value,is_suspended),
    updated_at=now()
  where id=target_user;
end $$;
create or replace function public.limo_admin_delete_message(target_message uuid, global_message boolean default false)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  if global_message then delete from public.global_messages where id=target_message;
  else delete from public.messages where id=target_message; end if;
end $$;
create or replace function public.limo_admin_update_report(target_report uuid, new_status text, note text default '')
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  if new_status not in ('new','reviewing','resolved','rejected') then raise exception 'Invalid status'; end if;
  update public.reports set status=new_status,admin_note=left(coalesce(note,''),1000) where id=target_report;
end $$;

-- RLS
alter table public.profiles enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.messages enable row level security;
alter table public.global_messages enable row level security;
alter table public.user_blocks enable row level security;
alter table public.user_settings enable row level security;
alter table public.chat_states enable row level security;
alter table public.reports enable row level security;
alter table public.bot_messages enable row level security;
alter table public.calls enable row level security;
alter table public.call_ice_candidates enable row level security;
alter table public.limo_admins enable row level security;
alter table public.limo_group_invites enable row level security;

drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated" on public.profiles for select to authenticated using (not is_suspended or id=auth.uid() or public.limo_is_admin());
drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles for update to authenticated using(id=auth.uid() or public.limo_is_admin()) with check(id=auth.uid() or public.limo_is_admin());

drop policy if exists "chats_member_read" on public.chats;
create policy "chats_member_read" on public.chats for select to authenticated using (
  public.limo_is_admin() or public.limo_is_chat_member(id)
);
drop policy if exists "chats_member_update" on public.chats;
create policy "chats_member_update" on public.chats for update to authenticated using (
  public.limo_is_admin() or public.limo_can_manage_chat(id)
) with check (public.limo_is_admin() or public.limo_can_manage_chat(id));

drop policy if exists "members_read" on public.chat_members;
create policy "members_read" on public.chat_members for select to authenticated using (
  user_id=auth.uid() or public.limo_is_admin() or public.limo_is_chat_member(chat_id)
);
drop policy if exists "members_insert" on public.chat_members;
create policy "members_insert" on public.chat_members for insert to authenticated with check (
  user_id=auth.uid() or public.limo_is_admin() or public.limo_can_manage_chat(chat_id)
);
drop policy if exists "members_delete" on public.chat_members;
create policy "members_delete" on public.chat_members for delete to authenticated using (
  user_id=auth.uid() or public.limo_is_admin() or public.limo_can_manage_chat(chat_id)
);

drop policy if exists "messages_member_read" on public.messages;
create policy "messages_member_read" on public.messages for select to authenticated using (
  public.limo_is_admin() or public.limo_is_chat_member(messages.chat_id)
);
drop policy if exists "messages_member_insert" on public.messages;
create policy "messages_member_insert" on public.messages for insert to authenticated with check (
  sender_id=auth.uid() and not exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_suspended)
  and public.limo_is_chat_member(messages.chat_id)
);
drop policy if exists "messages_update_owner" on public.messages;
create policy "messages_update_owner" on public.messages for update to authenticated using(sender_id=auth.uid() or public.limo_is_admin()) with check(sender_id=auth.uid() or public.limo_is_admin());
drop policy if exists "messages_delete_owner_admin" on public.messages;
create policy "messages_delete_owner_admin" on public.messages for delete to authenticated using(sender_id=auth.uid() or public.limo_is_admin());

drop policy if exists "global_messages_read" on public.global_messages;
create policy "global_messages_read" on public.global_messages for select to authenticated using(true);
drop policy if exists "global_messages_insert" on public.global_messages;
create policy "global_messages_insert" on public.global_messages for insert to authenticated with check(sender_id=auth.uid() and not exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_suspended));
drop policy if exists "global_messages_update" on public.global_messages;
create policy "global_messages_update" on public.global_messages for update to authenticated using(sender_id=auth.uid() or public.limo_is_admin()) with check(sender_id=auth.uid() or public.limo_is_admin());
drop policy if exists "global_messages_delete" on public.global_messages;
create policy "global_messages_delete" on public.global_messages for delete to authenticated using(sender_id=auth.uid() or public.limo_is_admin());

drop policy if exists "blocks_self" on public.user_blocks;
create policy "blocks_self" on public.user_blocks for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "settings_self" on public.user_settings;
create policy "settings_self" on public.user_settings for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "chat_states_self" on public.chat_states;
create policy "chat_states_self" on public.chat_states for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "reports_insert_self" on public.reports;
create policy "reports_insert_self" on public.reports for insert to authenticated with check(reporter_id=auth.uid());
drop policy if exists "reports_read_admin" on public.reports;
create policy "reports_read_admin" on public.reports for select to authenticated using(public.limo_is_admin());
drop policy if exists "reports_update_admin" on public.reports;
create policy "reports_update_admin" on public.reports for update to authenticated using(public.limo_is_admin()) with check(public.limo_is_admin());
drop policy if exists "bot_messages_self" on public.bot_messages;
create policy "bot_messages_self" on public.bot_messages for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "calls_participants" on public.calls;
create policy "calls_participants" on public.calls for all to authenticated using(caller_id=auth.uid() or callee_id=auth.uid() or public.limo_is_admin()) with check(caller_id=auth.uid() or callee_id=auth.uid() or public.limo_is_admin());
drop policy if exists "ice_call_participants" on public.call_ice_candidates;
create policy "ice_call_participants" on public.call_ice_candidates for all to authenticated using(
  public.limo_is_admin() or exists(select 1 from public.calls c where c.id=call_id and (c.caller_id=auth.uid() or c.callee_id=auth.uid()))
) with check(
  sender_id=auth.uid() and exists(select 1 from public.calls c where c.id=call_id and (c.caller_id=auth.uid() or c.callee_id=auth.uid()))
);
drop policy if exists "admin_self_read" on public.limo_admins;
create policy "admin_self_read" on public.limo_admins for select to authenticated using(user_id=auth.uid() or public.limo_is_admin());

-- Storage bucket: private; media is restricted to Premium by message trigger and object policies.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('chat-media','chat-media',false,512000,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=512000,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "chat_media_read_authenticated" on storage.objects;
create policy "chat_media_read_authenticated" on storage.objects for select to authenticated using(
  bucket_id='chat-media' and (
    owner_id=auth.uid()::text or public.limo_is_admin() or
    public.limo_is_chat_member((storage.foldername(name))[1]::uuid) or
    (storage.foldername(name))[1]='global'
  )
);
drop policy if exists "chat_media_insert_premium" on storage.objects;
create policy "chat_media_insert_premium" on storage.objects for insert to authenticated with check(
  bucket_id='chat-media' and owner_id=auth.uid()::text and exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_premium)
);
drop policy if exists "chat_media_delete_owner_admin" on storage.objects;
create policy "chat_media_delete_owner_admin" on storage.objects for delete to authenticated using(bucket_id='chat-media' and (owner_id=auth.uid()::text or public.limo_is_admin()));

-- 72-hour cleanup for message rows and storage objects. pg_cron is optional on some Supabase projects.
create or replace function public.limo_cleanup_expired_media()
returns integer language plpgsql security definer set search_path=public,storage
as $$
declare v_count integer:=0;
begin
  delete from storage.objects where bucket_id='chat-media' and created_at < now()-interval '72 hours';
  get diagnostics v_count = row_count;
  delete from public.messages where expires_at is not null and expires_at<=now();
  delete from public.global_messages where expires_at is not null and expires_at<=now();
  return v_count;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  if exists(select 1 from cron.job where jobname='limo-media-cleanup') then
    perform cron.unschedule((select jobid from cron.job where jobname='limo-media-cleanup' limit 1));
  end if;
  perform cron.schedule('limo-media-cleanup','15 * * * *','select public.limo_cleanup_expired_media()');
exception when others then
  raise notice 'pg_cron unavailable; scheduled media cleanup was not installed. Enable pg_cron or configure an external scheduled Edge Function.';
end $$;

-- Enable Realtime for message tables (safe to skip if already included).
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
when others then raise notice 'Could not add messages to supabase_realtime: %',sqlerrm;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.global_messages;
exception when duplicate_object then null;
when others then raise notice 'Could not add global_messages to supabase_realtime: %',sqlerrm;
end $$;

grant usage on schema public to anon,authenticated;
grant select on public.profiles to authenticated;
grant update(display_name,bio,avatar_url,username) on public.profiles to authenticated;
grant select,insert,update,delete on public.chats,public.chat_members,public.messages,public.global_messages,
 public.user_blocks,public.user_settings,public.chat_states,public.reports,public.bot_messages,
 public.calls,public.call_ice_candidates,public.limo_group_invites to authenticated;
grant select on public.limo_admins to authenticated;
grant execute on function public.ensure_limo_profile() to authenticated;
grant execute on function public.create_direct_chat(uuid) to authenticated;
grant execute on function public.create_limo_group(text,uuid[],boolean) to authenticated;
grant execute on function public.mark_chat_messages_read(uuid) to authenticated;
grant execute on function public.limo_admin_set_user(uuid,boolean,boolean) to authenticated;
grant execute on function public.limo_admin_delete_message(uuid,boolean) to authenticated;
grant execute on function public.limo_admin_update_report(uuid,text,text) to authenticated;
grant execute on function public.limo_cleanup_expired_media() to authenticated;

-- IMPORTANT: after creating your own account, promote that account once:
-- insert into public.limo_admins(user_id)
-- select id from public.profiles where username='YOUR_USERNAME'
-- on conflict do nothing;

grant execute on function public.limo_is_admin() to authenticated;
grant execute on function public.limo_is_chat_member(uuid) to authenticated;
grant execute on function public.limo_can_manage_chat(uuid) to authenticated;
