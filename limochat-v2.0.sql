-- ============================================================================
-- LIMO CHAT 2.0 — FULL INSTALL SCRIPT
-- Includes the original 1.13 schema followed by the additive 2.0 migration.
-- Run in Supabase SQL Editor after taking a database backup.
-- GitHub Pages hosts the frontend; Supabase provides Auth, Postgres, Realtime and Storage.
-- This script does NOT enable true end-to-end encryption. See SECURITY.md.
-- ============================================================================

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



-- ============================================================================
-- LIMO CHAT v2.0 ADDITIVE MIGRATION
-- GitHub Pages frontend + Supabase Auth/Postgres/Realtime/Storage.
-- Run after (or instead of, when using the full bundle) limochat-v2.0.sql.
-- This migration deliberately does NOT claim E2EE. See SECURITY.md.
-- ============================================================================

-- Profile and product preferences.
alter table public.profiles add column if not exists locale text not null default 'fa';
alter table public.profiles add column if not exists timezone text not null default 'Asia/Tehran';
alter table public.profiles add column if not exists public_profile boolean not null default true;
alter table public.profiles add column if not exists public_id text;
update public.profiles set public_id = 'limo_' || substr(replace(id::text,'-',''),1,12) where public_id is null;
create unique index if not exists profiles_public_id_uidx on public.profiles(public_id);

-- Stable public IDs are generated server-side for new profiles.
create or replace function public.limo_set_public_id()
returns trigger language plpgsql set search_path=public
as $$
begin
  if new.public_id is null or btrim(new.public_id)='' then
    new.public_id := 'limo_' || substr(replace(new.id::text,'-',''),1,12);
  end if;
  return new;
end $$;
drop trigger if exists limo_profiles_public_id on public.profiles;
create trigger limo_profiles_public_id before insert on public.profiles
  for each row execute function public.limo_set_public_id();

-- Prevent ordinary users from changing privileged profile flags through REST.
revoke update on public.profiles from public, anon, authenticated;
revoke update(username,display_name,bio,avatar_url) on public.profiles from public, anon, authenticated;
grant update(username,display_name,bio,avatar_url,locale,timezone,public_profile) on public.profiles to authenticated;

-- Fix an unsafe legacy policy: users may leave a chat, but cannot self-enrol in
-- an arbitrary private chat merely by learning/guessing its UUID.
drop policy if exists "members_insert" on public.chat_members;
create policy "members_insert_managers_only" on public.chat_members
  for insert to authenticated
  with check (public.limo_is_admin() or public.limo_can_manage_chat(chat_id));

-- A shared rate ledger protects all user-authored message tables consistently.
create table if not exists public.limo_rate_events (
  id bigserial primary key,
  user_id uuid not null,
  sent_at timestamptz not null default now()
);
create index if not exists limo_rate_events_user_time_idx on public.limo_rate_events(user_id, sent_at desc);
alter table public.limo_rate_events enable row level security;
revoke all on public.limo_rate_events from public, anon, authenticated;
revoke all on sequence public.limo_rate_events_id_seq from public, anon, authenticated;

create or replace function public.limo_enforce_message_rate()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  v_user uuid;
  v_count integer;
  v_suspended boolean;
begin
  v_user := new.sender_id;
  if v_user is null then raise exception 'MESSAGE_SENDER_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  select coalesce(is_suspended,false) into v_suspended from public.profiles where id=v_user;
  if coalesce(v_suspended,false) and not exists(select 1 from public.limo_admins where user_id=v_user) then
    raise exception 'ACCOUNT_SUSPENDED' using errcode='42501';
  end if;
  select count(*) into v_count from public.limo_rate_events
    where user_id=v_user and sent_at > now()-interval '30 seconds';
  if v_count >= 5 then
    raise exception 'LIMO_RATE_LIMIT: maximum 5 messages in 30 seconds' using errcode='P0001';
  end if;
  insert into public.limo_rate_events(user_id) values(v_user);
  delete from public.limo_rate_events where user_id=v_user and sent_at < now()-interval '1 day';
  return new;
end $$;

drop trigger if exists limo_rate_private_messages on public.messages;
create trigger limo_rate_private_messages before insert on public.messages
  for each row execute function public.limo_enforce_message_rate();
drop trigger if exists limo_rate_global_messages on public.global_messages;
create trigger limo_rate_global_messages before insert on public.global_messages
  for each row execute function public.limo_enforce_message_rate();

-- Message attachment metadata. The binary itself always remains in Supabase Storage.
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists attachment_type text;
alter table public.messages add column if not exists attachment_name text;
alter table public.messages add column if not exists attachment_size bigint not null default 0;
alter table public.global_messages add column if not exists attachment_path text;
alter table public.global_messages add column if not exists attachment_type text;
alter table public.global_messages add column if not exists attachment_name text;
alter table public.global_messages add column if not exists attachment_size bigint not null default 0;

-- Public discovery rooms. These are separate from private chats and the legacy global lobby.
create table if not exists public.limo_public_rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check(length(trim(name)) between 2 and 60),
  topic text not null default '' check(length(topic) <= 240),
  category text not null default 'general',
  language text not null default 'fa',
  room_kind text not null default 'chat' check(room_kind in ('chat','channel','voice')),
  is_public boolean not null default true,
  is_verified boolean not null default false,
  is_archived boolean not null default false,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists limo_public_rooms_discover_idx
  on public.limo_public_rooms(is_public,is_archived,category,created_at desc);
create index if not exists limo_public_rooms_owner_idx on public.limo_public_rooms(owner_id);

create table if not exists public.limo_room_members (
  room_id uuid not null references public.limo_public_rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check(role in ('owner','moderator','member')),
  joined_at timestamptz not null default now(),
  primary key(room_id,user_id)
);
create index if not exists limo_room_members_user_idx on public.limo_room_members(user_id,joined_at desc);

create table if not exists public.limo_room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.limo_public_rooms(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  sender_name text not null default 'کاربر',
  text text not null default '' check(length(text) <= 10000),
  reply_to jsonb,
  reactions jsonb not null default '{}'::jsonb,
  attachment_path text,
  attachment_type text,
  attachment_name text,
  attachment_size bigint not null default 0,
  expires_at timestamptz,
  edited boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  check(length(text)>0 or attachment_path is not null)
);
create index if not exists limo_room_messages_room_time_idx on public.limo_room_messages(room_id,created_at desc);
create index if not exists limo_room_messages_sender_idx on public.limo_room_messages(sender_id,created_at desc);

drop trigger if exists limo_rate_room_messages on public.limo_room_messages;
create trigger limo_rate_room_messages before insert on public.limo_room_messages
  for each row execute function public.limo_enforce_message_rate();

create or replace function public.limo_is_room_member(target_room uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.limo_room_members where room_id=target_room and user_id=auth.uid()) $$;

create or replace function public.limo_can_manage_room(target_room uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.limo_room_members where room_id=target_room and user_id=auth.uid() and role in ('owner','moderator')) $$;

create or replace function public.limo_create_public_room(p_name text,p_topic text default '',p_category text default 'general',p_language text default 'fa',p_kind text default 'chat')
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and is_suspended) then raise exception 'ACCOUNT_SUSPENDED'; end if;
  if length(trim(coalesce(p_name,'')))<2 or length(p_name)>60 then raise exception 'Invalid room name'; end if;
  if p_kind not in ('chat','channel','voice') then raise exception 'Invalid room kind'; end if;
  insert into public.limo_public_rooms(name,topic,category,language,room_kind,owner_id)
  values(trim(p_name),left(coalesce(p_topic,''),240),left(coalesce(p_category,'general'),40),left(coalesce(p_language,'fa'),12),p_kind,auth.uid())
  returning id into v_id;
  insert into public.limo_room_members(room_id,user_id,role) values(v_id,auth.uid(),'owner');
  return v_id;
end $$;

create or replace function public.limo_join_public_room(p_room_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if exists(select 1 from public.profiles where id=auth.uid() and is_suspended) then raise exception 'ACCOUNT_SUSPENDED'; end if;
  if not exists(select 1 from public.limo_public_rooms where id=p_room_id and is_public and not is_archived) then raise exception 'ROOM_NOT_AVAILABLE'; end if;
  insert into public.limo_room_members(room_id,user_id,role) values(p_room_id,auth.uid(),'member') on conflict do nothing;
end $$;

create or replace function public.limo_leave_public_room(p_room_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if exists(select 1 from public.limo_room_members where room_id=p_room_id and user_id=auth.uid() and role='owner') then
    raise exception 'ROOM_OWNER_CANNOT_LEAVE';
  end if;
  delete from public.limo_room_members where room_id=p_room_id and user_id=auth.uid();
end $$;

create or replace function public.limo_toggle_room_reaction(p_message_id uuid,p_emoji text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_room uuid; v_reactions jsonb; v_key text;
begin
  if p_emoji not in ('👍','❤️','😂','😮','😢','👏','🔥','🎉') then raise exception 'REACTION_NOT_ALLOWED'; end if;
  select room_id,reactions into v_room,v_reactions from public.limo_room_messages where id=p_message_id;
  if v_room is null or not public.limo_is_room_member(v_room) then raise exception 'Not allowed' using errcode='42501'; end if;
  v_key := auth.uid()::text;
  if v_reactions ? v_key and v_reactions->>v_key=p_emoji then v_reactions := v_reactions - v_key;
  else v_reactions := jsonb_set(coalesce(v_reactions,'{}'::jsonb),array[v_key],to_jsonb(p_emoji),true); end if;
  update public.limo_room_messages set reactions=v_reactions where id=p_message_id;
  return v_reactions;
end $$;

-- Polls are room-scoped. Voting is handled through RPCs to enforce single/multiple choice rules.
create table if not exists public.limo_polls (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.limo_public_rooms(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  question text not null check(length(trim(question)) between 3 and 300),
  allow_multiple boolean not null default false,
  closes_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.limo_poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.limo_polls(id) on delete cascade,
  label text not null check(length(trim(label)) between 1 and 120),
  sort_order integer not null default 0
);
create table if not exists public.limo_poll_votes (
  poll_id uuid not null references public.limo_polls(id) on delete cascade,
  option_id uuid not null references public.limo_poll_options(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(poll_id,option_id,user_id)
);
create index if not exists limo_poll_votes_poll_idx on public.limo_poll_votes(poll_id);

create or replace function public.limo_create_poll(p_room_id uuid,p_question text,p_options text[],p_allow_multiple boolean default false,p_closes_at timestamptz default null)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_poll uuid; v_option text; v_order integer:=0;
begin
  if not public.limo_is_room_member(p_room_id) then raise exception 'Not allowed' using errcode='42501'; end if;
  if length(trim(coalesce(p_question,'')))<3 or length(p_question)>300 then raise exception 'Invalid question'; end if;
  if coalesce(array_length(p_options,1),0)<2 or array_length(p_options,1)>8 then raise exception 'Poll needs 2 to 8 options'; end if;
  insert into public.limo_polls(room_id,created_by,question,allow_multiple,closes_at)
    values(p_room_id,auth.uid(),trim(p_question),coalesce(p_allow_multiple,false),p_closes_at) returning id into v_poll;
  foreach v_option in array p_options loop
    if length(trim(coalesce(v_option,'')))=0 or length(v_option)>120 then raise exception 'Invalid poll option'; end if;
    insert into public.limo_poll_options(poll_id,label,sort_order) values(v_poll,trim(v_option),v_order);
    v_order:=v_order+1;
  end loop;
  return v_poll;
end $$;

create or replace function public.limo_vote_poll(p_poll_id uuid,p_option_ids uuid[])
returns void language plpgsql security definer set search_path=public
as $$
declare v_room uuid; v_multiple boolean; v_closes timestamptz; v_option uuid;
begin
  select room_id,allow_multiple,closes_at into v_room,v_multiple,v_closes from public.limo_polls where id=p_poll_id;
  if v_room is null or not public.limo_is_room_member(v_room) then raise exception 'Not allowed' using errcode='42501'; end if;
  if v_closes is not null and v_closes<=now() then raise exception 'POLL_CLOSED'; end if;
  if coalesce(array_length(p_option_ids,1),0)<1 or array_length(p_option_ids,1)>8 then raise exception 'Invalid vote'; end if;
  if not v_multiple and array_length(p_option_ids,1)<>1 then raise exception 'SINGLE_CHOICE_ONLY'; end if;
  foreach v_option in array p_option_ids loop
    if not exists(select 1 from public.limo_poll_options where id=v_option and poll_id=p_poll_id) then raise exception 'INVALID_OPTION'; end if;
  end loop;
  delete from public.limo_poll_votes where poll_id=p_poll_id and user_id=auth.uid();
  foreach v_option in array p_option_ids loop
    insert into public.limo_poll_votes(poll_id,option_id,user_id) values(p_poll_id,v_option,auth.uid());
  end loop;
end $$;

-- Limo Space: shared boards with notes and tasks.
create table if not exists public.limo_spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check(length(trim(name)) between 2 and 70),
  description text not null default '' check(length(description)<=300),
  invite_code text not null unique default encode(gen_random_bytes(10),'hex'),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.limo_space_members (
  space_id uuid not null references public.limo_spaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check(role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  primary key(space_id,user_id)
);
create table if not exists public.limo_space_tasks (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.limo_spaces(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  assigned_to uuid references public.profiles(id) on delete set null,
  title text not null check(length(trim(title)) between 2 and 200),
  description text not null default '' check(length(description)<=2000),
  status text not null default 'open' check(status in ('open','doing','done')),
  due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists limo_space_tasks_space_idx on public.limo_space_tasks(space_id,status,created_at desc);
create table if not exists public.limo_space_notes (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.limo_spaces(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  title text not null check(length(trim(title)) between 2 and 160),
  body text not null default '' check(length(body)<=20000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.limo_is_space_member(target_space uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.limo_space_members where space_id=target_space and user_id=auth.uid()) $$;

create or replace function public.limo_create_space(p_name text,p_description text default '')
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if length(trim(coalesce(p_name,'')))<2 or length(p_name)>70 then raise exception 'Invalid space name'; end if;
  insert into public.limo_spaces(name,description,owner_id) values(trim(p_name),left(coalesce(p_description,''),300),auth.uid()) returning id into v_id;
  insert into public.limo_space_members(space_id,user_id,role) values(v_id,auth.uid(),'owner');
  return v_id;
end $$;

create or replace function public.limo_join_space(p_invite_code text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  select id into v_id from public.limo_spaces where invite_code=p_invite_code;
  if v_id is null then raise exception 'SPACE_INVITE_INVALID'; end if;
  insert into public.limo_space_members(space_id,user_id,role) values(v_id,auth.uid(),'member') on conflict do nothing;
  return v_id;
end $$;

-- Scheduled messages. A client may create/cancel its own scheduled item; only the
-- database dispatcher publishes due messages. pg_cron is optional; the client
-- also calls the dispatcher on sign-in/return-to-online as a fallback.
create table if not exists public.limo_scheduled_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  destination_type text not null check(destination_type in ('private','global','room')),
  destination_id uuid,
  body text not null check(length(trim(body)) between 1 and 10000),
  scheduled_at timestamptz not null,
  status text not null default 'pending' check(status in ('pending','sent','failed','cancelled')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  check((destination_type='global' and destination_id is null) or (destination_type<>'global' and destination_id is not null))
);
create index if not exists limo_scheduled_pending_idx on public.limo_scheduled_messages(status,scheduled_at) where status='pending';

create or replace function public.limo_dispatch_scheduled_messages()
returns integer language plpgsql security definer set search_path=public
as $$
declare
  r public.limo_scheduled_messages%rowtype;
  v_name text;
  v_count integer:=0;
begin
  for r in select * from public.limo_scheduled_messages
    where status='pending' and scheduled_at<=now()
    order by scheduled_at limit 30 for update skip locked
  loop
    begin
      select coalesce(display_name,username,'کاربر') into v_name from public.profiles where id=r.user_id;
      if r.destination_type='private' then
        if not exists(select 1 from public.chat_members where chat_id=r.destination_id and user_id=r.user_id) then raise exception 'CHAT_MEMBERSHIP_LOST'; end if;
        insert into public.messages(chat_id,sender_id,sender_name,text) values(r.destination_id,r.user_id,v_name,r.body);
        update public.chats set last_message=left(r.body,120),updated_at=now() where id=r.destination_id;
      elsif r.destination_type='room' then
        if not exists(select 1 from public.limo_room_members where room_id=r.destination_id and user_id=r.user_id) then raise exception 'ROOM_MEMBERSHIP_LOST'; end if;
        if exists(select 1 from public.limo_public_rooms where id=r.destination_id and room_kind='channel')
          and not exists(select 1 from public.limo_room_members where room_id=r.destination_id and user_id=r.user_id and role in ('owner','moderator')) then
          raise exception 'CHANNEL_POSTING_REQUIRES_MODERATOR';
        end if;
        insert into public.limo_room_messages(room_id,sender_id,sender_name,text) values(r.destination_id,r.user_id,v_name,r.body);
      else
        insert into public.global_messages(sender_id,sender_name,text) values(r.user_id,v_name,r.body);
      end if;
      update public.limo_scheduled_messages set status='sent',sent_at=now(),attempts=attempts+1,last_error=null where id=r.id;
      v_count:=v_count+1;
    exception when others then
      update public.limo_scheduled_messages set attempts=attempts+1,
        last_error=left(sqlerrm,500),
        status=case when attempts+1>=5 then 'failed' else 'pending' end,
        scheduled_at=case when attempts+1>=5 then scheduled_at else now()+interval '45 seconds' end
      where id=r.id;
    end;
  end loop;
  return v_count;
end $$;

-- Public app catalogue for the Mini section (actual built-ins run locally in the PWA).
create table if not exists public.limo_mini_apps (
  slug text primary key,
  title text not null,
  description text not null default '',
  category text not null default 'utility',
  is_enabled boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.limo_mini_apps(slug,title,description,category) values
 ('dice','تاس آنلاین','تاس تصادفی برای بازی‌های گروهی','game'),
 ('calculator','ماشین‌حساب','محاسبه‌گر ساده و امن','utility'),
 ('poll','نظرسنجی گروهی','ساخت نظرسنجی در اتاق عمومی','social'),
 ('picker','انتخاب‌گر تصادفی','انتخاب تصادفی از فهرست اعضا یا گزینه‌ها','utility'),
 ('text-tools','ابزار متن','شمارش کلمات و حروف','utility')
on conflict(slug) do update set title=excluded.title,description=excluded.description,category=excluded.category;

-- Device public-key directory is groundwork only: it does NOT enable E2EE by itself.
create table if not exists public.limo_device_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_label text not null default 'دستگاه',
  public_key jsonb not null,
  key_version integer not null default 1,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index if not exists limo_device_keys_user_idx on public.limo_device_keys(user_id,last_seen_at desc) where revoked_at is null;

-- RLS for all new tables.
alter table public.limo_public_rooms enable row level security;
alter table public.limo_room_members enable row level security;
alter table public.limo_room_messages enable row level security;
alter table public.limo_polls enable row level security;
alter table public.limo_poll_options enable row level security;
alter table public.limo_poll_votes enable row level security;
alter table public.limo_spaces enable row level security;
alter table public.limo_space_members enable row level security;
alter table public.limo_space_tasks enable row level security;
alter table public.limo_space_notes enable row level security;
alter table public.limo_scheduled_messages enable row level security;
alter table public.limo_mini_apps enable row level security;
alter table public.limo_device_keys enable row level security;

-- Public rooms
drop policy if exists limo_rooms_read on public.limo_public_rooms;
create policy limo_rooms_read on public.limo_public_rooms for select to authenticated
  using((is_public and not is_archived) or owner_id=auth.uid() or public.limo_is_room_member(id) or public.limo_is_admin());
drop policy if exists limo_rooms_insert on public.limo_public_rooms;
create policy limo_rooms_insert on public.limo_public_rooms for insert to authenticated
  with check(owner_id=auth.uid() and not exists(select 1 from public.profiles where id=auth.uid() and is_suspended));
drop policy if exists limo_rooms_update on public.limo_public_rooms;
create policy limo_rooms_update on public.limo_public_rooms for update to authenticated
  using(owner_id=auth.uid() or public.limo_can_manage_room(id) or public.limo_is_admin())
  with check(owner_id=auth.uid() or public.limo_can_manage_room(id) or public.limo_is_admin());
drop policy if exists limo_rooms_delete on public.limo_public_rooms;
create policy limo_rooms_delete on public.limo_public_rooms for delete to authenticated
  using(owner_id=auth.uid() or public.limo_is_admin());

drop policy if exists limo_room_members_read on public.limo_room_members;
create policy limo_room_members_read on public.limo_room_members for select to authenticated
  using(user_id=auth.uid() or public.limo_is_room_member(room_id) or public.limo_can_manage_room(room_id) or public.limo_is_admin());
drop policy if exists limo_room_members_insert on public.limo_room_members;
create policy limo_room_members_insert on public.limo_room_members for insert to authenticated
  with check(
    public.limo_is_admin()
    or public.limo_can_manage_room(room_id)
    or (user_id=auth.uid() and role='member' and exists(
      select 1 from public.limo_public_rooms r where r.id=room_id and r.is_public and not r.is_archived
    ))
  );
drop policy if exists limo_room_members_delete on public.limo_room_members;
create policy limo_room_members_delete on public.limo_room_members for delete to authenticated
  using((user_id=auth.uid() and role<>'owner') or public.limo_can_manage_room(room_id) or public.limo_is_admin());

drop policy if exists limo_room_messages_read on public.limo_room_messages;
create policy limo_room_messages_read on public.limo_room_messages for select to authenticated
  using(public.limo_is_room_member(room_id) or public.limo_is_admin());
drop policy if exists limo_room_messages_insert on public.limo_room_messages;
create policy limo_room_messages_insert on public.limo_room_messages for insert to authenticated
  with check(sender_id=auth.uid() and public.limo_is_room_member(room_id)
    and not exists(select 1 from public.profiles where id=auth.uid() and is_suspended)
    and (not exists(select 1 from public.limo_public_rooms r where r.id=room_id and r.room_kind='channel') or public.limo_can_manage_room(room_id)));
drop policy if exists limo_room_messages_update on public.limo_room_messages;
create policy limo_room_messages_update on public.limo_room_messages for update to authenticated
  using(sender_id=auth.uid() or public.limo_can_manage_room(room_id) or public.limo_is_admin())
  with check(sender_id=auth.uid() or public.limo_can_manage_room(room_id) or public.limo_is_admin());
drop policy if exists limo_room_messages_delete on public.limo_room_messages;
create policy limo_room_messages_delete on public.limo_room_messages for delete to authenticated
  using(sender_id=auth.uid() or public.limo_can_manage_room(room_id) or public.limo_is_admin());

-- Polls
drop policy if exists limo_polls_read on public.limo_polls;
create policy limo_polls_read on public.limo_polls for select to authenticated using(public.limo_is_room_member(room_id) or public.limo_is_admin());
drop policy if exists limo_poll_options_read on public.limo_poll_options;
create policy limo_poll_options_read on public.limo_poll_options for select to authenticated
  using(exists(select 1 from public.limo_polls p where p.id=poll_id and (public.limo_is_room_member(p.room_id) or public.limo_is_admin())));
drop policy if exists limo_poll_votes_read on public.limo_poll_votes;
create policy limo_poll_votes_read on public.limo_poll_votes for select to authenticated
  using(user_id=auth.uid() or exists(select 1 from public.limo_polls p where p.id=poll_id and (public.limo_is_room_member(p.room_id) or public.limo_is_admin())));

-- Spaces
drop policy if exists limo_spaces_read on public.limo_spaces;
create policy limo_spaces_read on public.limo_spaces for select to authenticated using(public.limo_is_space_member(id) or owner_id=auth.uid() or public.limo_is_admin());
drop policy if exists limo_spaces_insert on public.limo_spaces;
create policy limo_spaces_insert on public.limo_spaces for insert to authenticated with check(owner_id=auth.uid());
drop policy if exists limo_spaces_update on public.limo_spaces;
create policy limo_spaces_update on public.limo_spaces for update to authenticated
  using(owner_id=auth.uid() or public.limo_is_admin()) with check(owner_id=auth.uid() or public.limo_is_admin());
drop policy if exists limo_spaces_delete on public.limo_spaces;
create policy limo_spaces_delete on public.limo_spaces for delete to authenticated using(owner_id=auth.uid() or public.limo_is_admin());
drop policy if exists limo_space_members_read on public.limo_space_members;
create policy limo_space_members_read on public.limo_space_members for select to authenticated
  using(user_id=auth.uid() or public.limo_is_space_member(space_id) or public.limo_is_admin());
drop policy if exists limo_space_members_insert on public.limo_space_members;
create policy limo_space_members_insert on public.limo_space_members for insert to authenticated
  with check(public.limo_is_admin() or exists(select 1 from public.limo_spaces s where s.id=space_id and s.owner_id=auth.uid()));
drop policy if exists limo_space_members_delete on public.limo_space_members;
create policy limo_space_members_delete on public.limo_space_members for delete to authenticated
  using(user_id=auth.uid() or exists(select 1 from public.limo_spaces s where s.id=space_id and s.owner_id=auth.uid()) or public.limo_is_admin());
drop policy if exists limo_space_tasks_read on public.limo_space_tasks;
create policy limo_space_tasks_read on public.limo_space_tasks for select to authenticated using(public.limo_is_space_member(space_id) or public.limo_is_admin());
drop policy if exists limo_space_tasks_insert on public.limo_space_tasks;
create policy limo_space_tasks_insert on public.limo_space_tasks for insert to authenticated with check(created_by=auth.uid() and public.limo_is_space_member(space_id));
drop policy if exists limo_space_tasks_update on public.limo_space_tasks;
create policy limo_space_tasks_update on public.limo_space_tasks for update to authenticated using(public.limo_is_space_member(space_id) or public.limo_is_admin()) with check(public.limo_is_space_member(space_id) or public.limo_is_admin());
drop policy if exists limo_space_tasks_delete on public.limo_space_tasks;
create policy limo_space_tasks_delete on public.limo_space_tasks for delete to authenticated using(created_by=auth.uid() or public.limo_is_admin());
drop policy if exists limo_space_notes_read on public.limo_space_notes;
create policy limo_space_notes_read on public.limo_space_notes for select to authenticated using(public.limo_is_space_member(space_id) or public.limo_is_admin());
drop policy if exists limo_space_notes_insert on public.limo_space_notes;
create policy limo_space_notes_insert on public.limo_space_notes for insert to authenticated with check(created_by=auth.uid() and public.limo_is_space_member(space_id));
drop policy if exists limo_space_notes_update on public.limo_space_notes;
create policy limo_space_notes_update on public.limo_space_notes for update to authenticated using(public.limo_is_space_member(space_id) or public.limo_is_admin()) with check(public.limo_is_space_member(space_id) or public.limo_is_admin());
drop policy if exists limo_space_notes_delete on public.limo_space_notes;
create policy limo_space_notes_delete on public.limo_space_notes for delete to authenticated using(created_by=auth.uid() or public.limo_is_admin());

-- Scheduled messages
drop policy if exists limo_schedule_read on public.limo_scheduled_messages;
create policy limo_schedule_read on public.limo_scheduled_messages for select to authenticated using(user_id=auth.uid() or public.limo_is_admin());
drop policy if exists limo_schedule_insert on public.limo_scheduled_messages;
create policy limo_schedule_insert on public.limo_scheduled_messages for insert to authenticated
  with check(user_id=auth.uid() and scheduled_at>now()+interval '10 seconds' and scheduled_at<now()+interval '1 year'
    and ((destination_type='global' and destination_id is null)
      or (destination_type='private' and exists(select 1 from public.chat_members where chat_id=destination_id and user_id=auth.uid()))
      or (destination_type='room' and public.limo_is_room_member(destination_id)
      and (not exists(select 1 from public.limo_public_rooms r where r.id=destination_id and r.room_kind='channel')
        or public.limo_can_manage_room(destination_id)))));
drop policy if exists limo_schedule_update on public.limo_scheduled_messages;
create policy limo_schedule_update on public.limo_scheduled_messages for update to authenticated
  using(user_id=auth.uid() and status='pending') with check(user_id=auth.uid() and status in ('pending','cancelled'));
drop policy if exists limo_schedule_delete on public.limo_scheduled_messages;
create policy limo_schedule_delete on public.limo_scheduled_messages for delete to authenticated using(user_id=auth.uid() and status in ('pending','failed'));

-- Mini catalogue and public device-key directory.
drop policy if exists limo_mini_apps_read on public.limo_mini_apps;
create policy limo_mini_apps_read on public.limo_mini_apps for select to authenticated using(is_enabled);
drop policy if exists limo_device_keys_read on public.limo_device_keys;
create policy limo_device_keys_read on public.limo_device_keys for select to authenticated using(user_id=auth.uid() or public.limo_is_admin());
drop policy if exists limo_device_keys_insert on public.limo_device_keys;
create policy limo_device_keys_insert on public.limo_device_keys for insert to authenticated with check(user_id=auth.uid());
drop policy if exists limo_device_keys_update on public.limo_device_keys;
create policy limo_device_keys_update on public.limo_device_keys for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

-- Storage: keep the existing chat-media bucket private; add audio formats for voice notes.
update storage.buckets set public=false,file_size_limit=5242880,
  allowed_mime_types=array['image/jpeg','image/png','image/webp','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/aac']
where id='chat-media';
drop policy if exists chat_media_insert_audio on storage.objects;
create policy chat_media_insert_audio on storage.objects for insert to authenticated
  with check(bucket_id='chat-media' and owner_id=auth.uid()::text
    and coalesce(metadata->>'mimetype','') like 'audio/%'
    and (storage.foldername(name))[2]=auth.uid()::text);

-- Realtime subscriptions for new tables.
do $$ begin
  alter publication supabase_realtime add table public.limo_room_messages;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_room_messages to supabase_realtime: %',sqlerrm; end $$;
do $$ begin
  alter publication supabase_realtime add table public.limo_public_rooms;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_public_rooms to supabase_realtime: %',sqlerrm; end $$;
do $$ begin
  alter publication supabase_realtime add table public.limo_space_tasks;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_space_tasks to supabase_realtime: %',sqlerrm; end $$;

-- Function access. SECURITY DEFINER functions perform their own membership checks.
grant execute on function public.limo_create_public_room(text,text,text,text,text) to authenticated;
grant execute on function public.limo_join_public_room(uuid) to authenticated;
grant execute on function public.limo_leave_public_room(uuid) to authenticated;
grant execute on function public.limo_toggle_room_reaction(uuid,text) to authenticated;
grant execute on function public.limo_create_poll(uuid,text,text[],boolean,timestamptz) to authenticated;
grant execute on function public.limo_vote_poll(uuid,uuid[]) to authenticated;
grant execute on function public.limo_create_space(text,text) to authenticated;
grant execute on function public.limo_join_space(text) to authenticated;
grant execute on function public.limo_dispatch_scheduled_messages() to authenticated;

grant select on public.limo_public_rooms,public.limo_room_members,public.limo_room_messages,
  public.limo_polls,public.limo_poll_options,public.limo_poll_votes,
  public.limo_spaces,public.limo_space_members,public.limo_space_tasks,public.limo_space_notes,
  public.limo_scheduled_messages,public.limo_mini_apps,public.limo_device_keys to authenticated;
grant insert,update,delete on public.limo_room_messages to authenticated;
grant insert,update,delete on public.limo_space_tasks,public.limo_space_notes to authenticated;
grant insert,update,delete on public.limo_scheduled_messages to authenticated;
grant update,delete on public.limo_public_rooms to authenticated;
-- Room and space membership is mutated only through checked SECURITY DEFINER RPCs.
revoke insert,update,delete on public.limo_room_members,public.limo_space_members from public,anon,authenticated;
revoke insert on public.limo_public_rooms,public.limo_spaces from public,anon,authenticated;
grant update,delete on public.limo_spaces to authenticated;

-- The legacy cleanup RPC should not be manually callable by every normal user.
revoke all on function public.limo_cleanup_expired_media() from public,anon,authenticated;

-- Optional automatic dispatch: if pg_cron is available, due messages are sent every minute.
do $$
begin
  create extension if not exists pg_cron;
  if exists(select 1 from cron.job where jobname='limo-scheduled-dispatch') then
    perform cron.unschedule((select jobid from cron.job where jobname='limo-scheduled-dispatch' limit 1));
  end if;
  perform cron.schedule('limo-scheduled-dispatch','* * * * *','select public.limo_dispatch_scheduled_messages()');
exception when others then
  raise notice 'pg_cron unavailable; scheduled messages will be dispatched when an authenticated user opens the app. Error: %',sqlerrm;
end $$;

-- Helpful indexes for the current client queries.
create index if not exists messages_chat_latest_idx on public.messages(chat_id,created_at desc);
create index if not exists global_messages_latest_idx on public.global_messages(created_at desc);

-- End of Limo Chat v2.0 migration.

-- Tighten attachment access: membership is required for private/group chats and rooms.
drop policy if exists "chat_media_read_authenticated" on storage.objects;
create policy chat_media_read_authenticated on storage.objects for select to authenticated
using(bucket_id='chat-media' and case
  when (storage.foldername(name))[1]='global' then true
  when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    public.limo_is_chat_member(((storage.foldername(name))[1])::uuid)
    or public.limo_is_room_member(((storage.foldername(name))[1])::uuid)
  else owner_id=auth.uid()::text or public.limo_is_admin()
end);

drop policy if exists chat_media_insert_audio on storage.objects;
create policy chat_media_insert_audio on storage.objects for insert to authenticated
with check(bucket_id='chat-media' and owner_id=auth.uid()::text
  and coalesce(metadata->>'mimetype','') like 'audio/%'
  and (storage.foldername(name))[2]=auth.uid()::text
  and case
    when (storage.foldername(name))[1]='global' then true
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      public.limo_is_chat_member(((storage.foldername(name))[1])::uuid)
      or public.limo_is_room_member(((storage.foldername(name))[1])::uuid)
    else false
  end);

-- Correct the update check so a user cannot move a message into a room they do not belong to.
drop policy if exists limo_room_messages_update on public.limo_room_messages;
create policy limo_room_messages_update on public.limo_room_messages for update to authenticated
  using(sender_id=auth.uid() or public.limo_can_manage_room(room_id) or public.limo_is_admin())
  with check((sender_id=auth.uid() and public.limo_is_room_member(room_id)) or public.limo_can_manage_room(room_id) or public.limo_is_admin());

alter table public.calls add column if not exists call_mode text not null default 'audio';

-- Administrative cancellation of scheduled messages owned by other users.
drop policy if exists limo_schedule_update on public.limo_scheduled_messages;
create policy limo_schedule_update on public.limo_scheduled_messages for update to authenticated
  using((user_id=auth.uid() and status='pending') or public.limo_is_admin())
  with check((user_id=auth.uid() and status in ('pending','cancelled')) or public.limo_is_admin());

do $$ begin
  alter publication supabase_realtime add table public.limo_polls;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_polls to supabase_realtime: %',sqlerrm; end $$;
do $$ begin
  alter publication supabase_realtime add table public.limo_poll_votes;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_poll_votes to supabase_realtime: %',sqlerrm; end $$;


-- Ghost messages: rows become invisible to ordinary users as soon as expires_at passes.
alter table public.messages add column if not exists expires_at timestamptz;
alter table public.global_messages add column if not exists expires_at timestamptz;
alter table public.limo_room_messages add column if not exists expires_at timestamptz;
create index if not exists messages_expiry_idx on public.messages(expires_at) where expires_at is not null;
create index if not exists global_messages_expiry_idx on public.global_messages(expires_at) where expires_at is not null;
create index if not exists limo_room_messages_expiry_idx on public.limo_room_messages(expires_at) where expires_at is not null;

drop policy if exists messages_member_read on public.messages;
create policy messages_member_read on public.messages for select to authenticated
  using((expires_at is null or expires_at>now()) and (public.limo_is_admin() or public.limo_is_chat_member(chat_id)));
drop policy if exists global_messages_read on public.global_messages;
create policy global_messages_read on public.global_messages for select to authenticated
  using(expires_at is null or expires_at>now());
drop policy if exists limo_room_messages_read on public.limo_room_messages;
create policy limo_room_messages_read on public.limo_room_messages for select to authenticated
  using((expires_at is null or expires_at>now()) and (public.limo_is_room_member(room_id) or public.limo_is_admin()));

-- Cleanup also removes expired room messages and their stored attachments.
create or replace function public.limo_cleanup_expired_media()
returns integer language plpgsql security definer set search_path=public,storage
as $$
declare v_count integer:=0;
begin
  delete from storage.objects o
  using (
    select image_path as path from public.messages where expires_at is not null and expires_at<=now() and image_path is not null
    union all select attachment_path from public.messages where expires_at is not null and expires_at<=now() and attachment_path is not null
    union all select image_path from public.global_messages where expires_at is not null and expires_at<=now() and image_path is not null
    union all select attachment_path from public.global_messages where expires_at is not null and expires_at<=now() and attachment_path is not null
    union all select attachment_path from public.limo_room_messages where expires_at is not null and expires_at<=now() and attachment_path is not null
  ) expired
  where o.bucket_id='chat-media' and o.name=expired.path;
  get diagnostics v_count = row_count;
  delete from public.messages where expires_at is not null and expires_at<=now();
  delete from public.global_messages where expires_at is not null and expires_at<=now();
  delete from public.limo_room_messages where expires_at is not null and expires_at<=now();
  -- Remove only old orphan files; never delete media still referenced by an active message.
  delete from storage.objects o
  where o.bucket_id='chat-media' and o.created_at < now()-interval '72 hours'
    and not exists(select 1 from public.messages m where m.image_path=o.name or m.attachment_path=o.name)
    and not exists(select 1 from public.global_messages m where m.image_path=o.name or m.attachment_path=o.name)
    and not exists(select 1 from public.limo_room_messages m where m.image_path=o.name or m.attachment_path=o.name);
  return v_count;
end $$;

-- Least-privilege RPC grants. Trigger-only functions are not callable through the API.
revoke all on function public.limo_set_public_id() from public,anon,authenticated;
revoke all on function public.limo_enforce_message_rate() from public,anon,authenticated;
revoke all on function public.limo_cleanup_expired_media() from public,anon,authenticated;
revoke all on function public.limo_is_room_member(uuid) from public,anon;
revoke all on function public.limo_can_manage_room(uuid) from public,anon;
revoke all on function public.limo_is_space_member(uuid) from public,anon;
revoke all on function public.limo_dispatch_scheduled_messages() from public,anon;
grant execute on function public.limo_is_room_member(uuid) to authenticated;
grant execute on function public.limo_can_manage_room(uuid) to authenticated;
grant execute on function public.limo_is_space_member(uuid) to authenticated;
grant execute on function public.limo_dispatch_scheduled_messages() to authenticated;

-- Additional realtime feeds for shared workspaces and notes.
do $$ begin
  alter publication supabase_realtime add table public.limo_spaces;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_spaces to supabase_realtime: %',sqlerrm; end $$;
do $$ begin
  alter publication supabase_realtime add table public.limo_space_notes;
exception when duplicate_object then null; when others then raise notice 'Could not add limo_space_notes to supabase_realtime: %',sqlerrm; end $$;


-- Keep SECURITY DEFINER feature RPCs unavailable to anonymous clients.
revoke all on function public.limo_create_public_room(text,text,text,text,text) from public,anon;
revoke all on function public.limo_join_public_room(uuid) from public,anon;
revoke all on function public.limo_leave_public_room(uuid) from public,anon;
revoke all on function public.limo_toggle_room_reaction(uuid,text) from public,anon;
revoke all on function public.limo_create_poll(uuid,text,text[],boolean,timestamptz) from public,anon;
revoke all on function public.limo_vote_poll(uuid,uuid[]) from public,anon;
revoke all on function public.limo_create_space(text,text) from public,anon;
revoke all on function public.limo_join_space(text) from public,anon;
grant execute on function public.limo_create_public_room(text,text,text,text,text) to authenticated;
grant execute on function public.limo_join_public_room(uuid) to authenticated;
grant execute on function public.limo_leave_public_room(uuid) to authenticated;
grant execute on function public.limo_toggle_room_reaction(uuid,text) to authenticated;
grant execute on function public.limo_create_poll(uuid,text,text[],boolean,timestamptz) to authenticated;
grant execute on function public.limo_vote_poll(uuid,uuid[]) to authenticated;
grant execute on function public.limo_create_space(text,text) to authenticated;
grant execute on function public.limo_join_space(text) to authenticated;
