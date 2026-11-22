-- Limo Chat v1.11 - Supabase schema and legacy-message compatibility
-- Run this file in Supabase Dashboard > SQL Editor. Safe to rerun after successful completion.
-- Uses only the public/publishable key from the browser. Never expose service_role keys.

begin;

-- Compatibility migration for older LimoChat projects.
-- The first LimoChat schema used messages(id, content, sender, created_at).
-- The current app needs chat_id, sender_id, text and other columns. Preserve the
-- old table under a backup name rather than silently treating it as compatible.
do $$
begin
  if to_regclass('public.messages') is not null
     and exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'messages' and column_name = 'content'
     )
     and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'messages' and column_name = 'chat_id'
     ) then
    if to_regclass('public.messages_legacy_backup') is null then
      alter table public.messages rename to messages_legacy_backup;
    else
      raise exception 'Legacy public.messages exists and public.messages_legacy_backup already exists. Rename or archive the legacy table manually before rerunning this schema.';
    end if;
  end if;
end $$;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Profiles are separate from auth.users. Passwords remain exclusively in Supabase Auth.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,24}$'),
  display_name text not null default 'کاربر لیمو' check (char_length(display_name) between 1 and 40),
  bio text not null default '' check (char_length(bio) <= 120),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists profiles_username_idx on public.profiles (username);

create or replace function public.handle_new_limo_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate text;
begin
  candidate := lower(coalesce(nullif(new.raw_user_meta_data->>'username',''), split_part(coalesce(new.email, 'user@limochat.app'), '@', 1)));
  candidate := regexp_replace(candidate, '[^a-z0-9_.]', '', 'g');
  candidate := left(candidate, 24);
  if char_length(candidate) < 3 then candidate := 'user_' || left(replace(new.id::text, '-', ''), 8); end if;
  if exists (select 1 from public.profiles p where p.username = candidate) then
    candidate := left(candidate, 15) || '_' || left(replace(new.id::text, '-', ''), 8);
  end if;
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    candidate,
    left(coalesce(nullif(new.raw_user_meta_data->>'display_name',''), nullif(new.raw_user_meta_data->>'full_name',''), candidate), 40)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_limo on auth.users;
create trigger on_auth_user_created_limo
after insert on auth.users
for each row execute function public.handle_new_limo_user();


-- Repair profiles for accounts that were created before the auth trigger existed.
-- This RPC can create/read only the profile belonging to the currently authenticated user.
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

  -- on conflict do nothing handles a simultaneous sign-up trigger or username collision safely.
  for attempt in 0..8 loop
    if attempt = 0 then
      candidate := base_username;
    else
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

create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  name text not null default 'گفتگوی خصوصی',
  last_message text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists chats_updated_at_idx on public.chats (updated_at desc);

create table if not exists public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);
create index if not exists chat_members_user_id_idx on public.chat_members (user_id, chat_id);

-- Create this before helper functions that inspect block relationships.
create table if not exists public.user_blocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, blocked_user_id),
  constraint user_blocks_not_self check (user_id <> blocked_user_id)
);

-- SECURITY DEFINER helpers avoid recursive RLS when policies inspect membership tables.
create or replace function public.is_chat_member(target_chat uuid, target_user uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.chat_members cm
    where cm.chat_id = target_chat and cm.user_id = target_user
  );
$$;

create or replace function public.can_send_to_chat(target_chat uuid, sender uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_chat_member(target_chat, sender)
    and not exists (
      select 1
      from public.chat_members recipient
      join public.user_blocks blocked
        on blocked.user_id = recipient.user_id
       and blocked.blocked_user_id = sender
      where recipient.chat_id = target_chat and recipient.user_id <> sender
    );
$$;

create or replace function public.create_direct_chat(target_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  result_id uuid;
begin
  if me is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if target_user is null or target_user = me then raise exception 'INVALID_TARGET'; end if;
  if not exists (select 1 from public.profiles p where p.id = target_user) then raise exception 'USER_NOT_FOUND'; end if;
  if exists (
    select 1 from public.user_blocks b
    where (b.user_id = me and b.blocked_user_id = target_user)
       or (b.user_id = target_user and b.blocked_user_id = me)
  ) then raise exception 'USER_BLOCKED'; end if;

  -- Stable lock key for the ordered pair; concurrent requests cannot create duplicate DMs.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      LEAST(me::text, target_user::text) || ':' ||
      GREATEST(me::text, target_user::text), 0
    )
  );

  select c.id into result_id
  from public.chats c
  where public.is_chat_member(c.id, me)
    and public.is_chat_member(c.id, target_user)
    and (select count(*) from public.chat_members cm where cm.chat_id = c.id) = 2
  order by c.updated_at desc
  limit 1;

  if result_id is not null then return result_id; end if;

  insert into public.chats (created_by, name)
  values (me, 'گفتگوی خصوصی')
  returning id into result_id;

  insert into public.chat_members (chat_id, user_id)
  values (result_id, me), (result_id, target_user);

  return result_id;
end;
$$;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null default 'کاربر',
  text text not null default '' check (char_length(text) <= 10000),
  image_path text,
  image_name text,
  image_size bigint check (image_size is null or image_size <= 2097152),
  reply_to jsonb,
  reactions jsonb not null default '{}'::jsonb,
  status text not null default 'sent' check (status in ('sent','delivered','read')),
  edited boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  constraint messages_have_content check (char_length(text) > 0 or image_path is not null)
);
create index if not exists messages_chat_created_idx on public.messages (chat_id, created_at);
create index if not exists messages_sender_idx on public.messages (sender_id);

create table if not exists public.global_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null default 'کاربر',
  text text not null default '' check (char_length(text) <= 10000),
  image_path text,
  image_name text,
  image_size bigint check (image_size is null or image_size <= 2097152),
  reply_to jsonb,
  reactions jsonb not null default '{}'::jsonb,
  status text not null default 'sent' check (status in ('sent','delivered','read')),
  edited boolean not null default false,
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  constraint global_messages_have_content check (char_length(text) > 0 or image_path is not null)
);
create index if not exists global_messages_created_idx on public.global_messages (created_at);

create or replace function public.react_to_message(target_message uuid, target_global boolean, reaction text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if reaction not in ('❤️','😂','👍','😮','😢','🔥','👏','🙏') then raise exception 'INVALID_REACTION'; end if;
  if target_global then
    update public.global_messages
      set reactions = coalesce(reactions, '{}'::jsonb) || jsonb_build_object(auth.uid()::text, reaction)
      where id = target_message;
  else
    update public.messages
      set reactions = coalesce(reactions, '{}'::jsonb) || jsonb_build_object(auth.uid()::text, reaction)
      where id = target_message and public.is_chat_member(chat_id, auth.uid());
  end if;
  get diagnostics changed = row_count;
  if changed = 0 then raise exception 'MESSAGE_NOT_FOUND_OR_FORBIDDEN'; end if;
end;
$$;

create or replace function public.mark_chat_messages_read(target_chat uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_chat_member(target_chat, auth.uid()) then
    raise exception 'NOT_CHAT_MEMBER';
  end if;
  update public.messages
  set status = 'read'
  where chat_id = target_chat and sender_id <> auth.uid() and status <> 'read';
end;
$$;

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reporter_username text not null,
  type text not null check (type in ('user','message')),
  target_uid uuid references auth.users(id) on delete set null,
  target_name text,
  message_id uuid,
  chat_id uuid references public.chats(id) on delete set null,
  reason text not null check (char_length(reason) between 1 and 500),
  content text not null default '' check (char_length(content) <= 500),
  destination text not null default '@Report',
  status text not null default 'new' check (status in ('new','reviewed','closed')),
  created_at timestamptz not null default now()
);
create index if not exists reports_reporter_idx on public.reports (reporter_id, created_at desc);

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  preferences jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.chat_states (
  user_id uuid not null references auth.users(id) on delete cascade,
  chat_key text not null,
  pinned boolean not null default false,
  hidden boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, chat_key)
);

create table if not exists public.bot_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null check (sender_role in ('user','bot')),
  text text not null check (char_length(text) between 1 and 10000),
  created_at timestamptz not null default now()
);
create index if not exists bot_messages_user_created_idx on public.bot_messages (user_id, created_at);

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references auth.users(id) on delete cascade,
  caller_name text not null default 'کاربر',
  callee_id uuid not null references auth.users(id) on delete cascade,
  chat_id uuid not null references public.chats(id) on delete cascade,
  status text not null default 'ringing' check (status in ('ringing','active','ended','declined')),
  offer jsonb,
  answer jsonb,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint calls_not_self check (caller_id <> callee_id)
);
create index if not exists calls_callee_status_idx on public.calls (callee_id, status, created_at desc);
create index if not exists calls_caller_idx on public.calls (caller_id, created_at desc);

create or replace function public.is_call_participant(target_call uuid, target_user uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.calls c
    where c.id = target_call and target_user in (c.caller_id, c.callee_id)
  );
$$;

create table if not exists public.call_ice_candidates (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.calls(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  side text not null check (side in ('caller','callee')),
  candidate jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists call_ice_call_side_idx on public.call_ice_candidates (call_id, side, created_at);

-- Enable Row Level Security on every exposed application table.
alter table public.profiles enable row level security;
alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.messages enable row level security;
alter table public.global_messages enable row level security;
alter table public.user_blocks enable row level security;
alter table public.reports enable row level security;
alter table public.user_settings enable row level security;
alter table public.chat_states enable row level security;
alter table public.bot_messages enable row level security;
alter table public.calls enable row level security;
alter table public.call_ice_candidates enable row level security;

-- Remove broad anonymous access; authenticated users receive only explicit app-level grants.
revoke all on public.profiles, public.chats, public.chat_members, public.messages, public.global_messages,
  public.user_blocks, public.reports, public.user_settings, public.chat_states, public.bot_messages,
  public.calls, public.call_ice_candidates from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update on public.chats to authenticated;
grant select on public.chat_members to authenticated;
grant select, insert, update, delete on public.messages, public.global_messages to authenticated;
grant select, insert, delete on public.user_blocks to authenticated;
grant select, insert on public.reports to authenticated;
grant select, insert, update on public.user_settings, public.chat_states to authenticated;
grant select, insert on public.bot_messages to authenticated;
grant select, insert on public.calls to authenticated;
grant update (offer, answer, status, ended_at) on public.calls to authenticated;
grant select, insert on public.call_ice_candidates to authenticated;

-- Drop/re-create policies so rerunning this script is safe.
do $$ declare p record; begin
  for p in select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public' and tablename = any(array['profiles','chats','chat_members','messages','global_messages','user_blocks','reports','user_settings','chat_states','bot_messages','calls','call_ice_candidates'])
  loop execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename); end loop;
end $$;

drop policy if exists profiles_read_authenticated on public.profiles;
create policy profiles_read_authenticated on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists chats_read_members on public.chats;
create policy chats_read_members on public.chats for select to authenticated using (public.is_chat_member(id));
drop policy if exists chats_insert_creator on public.chats;
create policy chats_insert_creator on public.chats for insert to authenticated with check (created_by = (select auth.uid()));
drop policy if exists chats_update_members on public.chats;
create policy chats_update_members on public.chats for update to authenticated using (public.is_chat_member(id)) with check (public.is_chat_member(id));

drop policy if exists chat_members_read_members on public.chat_members;
create policy chat_members_read_members on public.chat_members for select to authenticated using (public.is_chat_member(chat_id));
-- Membership rows are inserted only through the SECURITY DEFINER create_direct_chat RPC.

drop policy if exists messages_read_members on public.messages;
create policy messages_read_members on public.messages for select to authenticated using (public.is_chat_member(chat_id));
drop policy if exists messages_insert_members on public.messages;
create policy messages_insert_members on public.messages for insert to authenticated with check (sender_id = (select auth.uid()) and public.can_send_to_chat(chat_id, (select auth.uid())));
drop policy if exists messages_update_own on public.messages;
create policy messages_update_own on public.messages for update to authenticated using (sender_id = (select auth.uid())) with check (sender_id = (select auth.uid()) and public.is_chat_member(chat_id));
drop policy if exists messages_delete_own on public.messages;
create policy messages_delete_own on public.messages for delete to authenticated using (sender_id = (select auth.uid()) and public.is_chat_member(chat_id));

drop policy if exists global_messages_read_authenticated on public.global_messages;
create policy global_messages_read_authenticated on public.global_messages for select to authenticated using (true);
drop policy if exists global_messages_insert_own on public.global_messages;
create policy global_messages_insert_own on public.global_messages for insert to authenticated with check (sender_id = (select auth.uid()));
drop policy if exists global_messages_update_own on public.global_messages;
create policy global_messages_update_own on public.global_messages for update to authenticated using (sender_id = (select auth.uid())) with check (sender_id = (select auth.uid()));
drop policy if exists global_messages_delete_own on public.global_messages;
create policy global_messages_delete_own on public.global_messages for delete to authenticated using (sender_id = (select auth.uid()));

drop policy if exists user_blocks_read_own on public.user_blocks;
create policy user_blocks_read_own on public.user_blocks for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists user_blocks_insert_own on public.user_blocks;
create policy user_blocks_insert_own on public.user_blocks for insert to authenticated with check (user_id = (select auth.uid()) and blocked_user_id <> (select auth.uid()));
drop policy if exists user_blocks_delete_own on public.user_blocks;
create policy user_blocks_delete_own on public.user_blocks for delete to authenticated using (user_id = (select auth.uid()));

drop policy if exists reports_insert_own on public.reports;
create policy reports_insert_own on public.reports for insert to authenticated with check (reporter_id = (select auth.uid()));
drop policy if exists reports_read_own on public.reports;
create policy reports_read_own on public.reports for select to authenticated using (reporter_id = (select auth.uid()));

drop policy if exists user_settings_read_own on public.user_settings;
create policy user_settings_read_own on public.user_settings for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists user_settings_insert_own on public.user_settings;
create policy user_settings_insert_own on public.user_settings for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists user_settings_update_own on public.user_settings;
create policy user_settings_update_own on public.user_settings for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists chat_states_read_own on public.chat_states;
create policy chat_states_read_own on public.chat_states for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists chat_states_insert_own on public.chat_states;
create policy chat_states_insert_own on public.chat_states for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists chat_states_update_own on public.chat_states;
create policy chat_states_update_own on public.chat_states for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists bot_messages_read_own on public.bot_messages;
create policy bot_messages_read_own on public.bot_messages for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists bot_messages_insert_own on public.bot_messages;
create policy bot_messages_insert_own on public.bot_messages for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists calls_read_participants on public.calls;
create policy calls_read_participants on public.calls for select to authenticated using ((select auth.uid()) in (caller_id, callee_id));
drop policy if exists calls_insert_caller on public.calls;
create policy calls_insert_caller on public.calls for insert to authenticated with check (caller_id = (select auth.uid()) and public.is_chat_member(chat_id) and public.is_chat_member(chat_id, callee_id));
drop policy if exists calls_update_participants on public.calls;
create policy calls_update_participants on public.calls for update to authenticated using ((select auth.uid()) in (caller_id, callee_id)) with check ((select auth.uid()) in (caller_id, callee_id));

drop policy if exists call_ice_read_participants on public.call_ice_candidates;
create policy call_ice_read_participants on public.call_ice_candidates for select to authenticated using (public.is_call_participant(call_id));
drop policy if exists call_ice_insert_participants on public.call_ice_candidates;
create policy call_ice_insert_participants on public.call_ice_candidates for insert to authenticated with check (sender_id = (select auth.uid()) and public.is_call_participant(call_id) and exists (select 1 from public.calls c where c.id = call_id and ((side = 'caller' and c.caller_id = (select auth.uid())) or (side = 'callee' and c.callee_id = (select auth.uid())))));

-- RPC permissions.
revoke all on function public.handle_new_limo_user() from public, anon, authenticated;
revoke all on function public.ensure_limo_profile() from public, anon;
revoke all on function public.is_chat_member(uuid, uuid) from public, anon;
revoke all on function public.can_send_to_chat(uuid, uuid) from public, anon;
revoke all on function public.create_direct_chat(uuid) from public, anon;
revoke all on function public.react_to_message(uuid, boolean, text) from public, anon;
revoke all on function public.mark_chat_messages_read(uuid) from public, anon;
revoke all on function public.is_call_participant(uuid, uuid) from public, anon;
grant execute on function public.ensure_limo_profile() to authenticated;
grant execute on function public.is_chat_member(uuid, uuid) to authenticated;
grant execute on function public.can_send_to_chat(uuid, uuid) to authenticated;
grant execute on function public.create_direct_chat(uuid) to authenticated;
grant execute on function public.react_to_message(uuid, boolean, text) to authenticated;
grant execute on function public.mark_chat_messages_read(uuid) to authenticated;
grant execute on function public.is_call_participant(uuid, uuid) to authenticated;

-- Private media bucket; uploaded image paths are signed when read by the client.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 2097152, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public = false, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists limo_chat_media_read on storage.objects;
drop policy if exists limo_chat_media_insert on storage.objects;
drop policy if exists limo_chat_media_delete on storage.objects;
drop policy if exists limo_chat_media_read on storage.objects;
create policy limo_chat_media_read on storage.objects for select to authenticated
using (
  bucket_id = 'chat-media' and (
    split_part(name, '/', 1) = 'global'
    or (split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_chat_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end))
  )
);
drop policy if exists limo_chat_media_insert on storage.objects;
create policy limo_chat_media_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and split_part(name, '/', 2) = (select auth.uid())::text
  and (
    split_part(name, '/', 1) = 'global'
    or (split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and public.is_chat_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end))
  )
);
drop policy if exists limo_chat_media_delete on storage.objects;
create policy limo_chat_media_delete on storage.objects for delete to authenticated
using (bucket_id = 'chat-media' and split_part(name, '/', 2) = (select auth.uid())::text);

-- Realtime publication for messages, chat list and voice-call signaling.
do $$
declare table_name text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    execute 'create publication supabase_realtime';
  end if;
  foreach table_name in array array['chat_members','chats','messages','global_messages','calls','call_ice_candidates'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end $$;

alter table public.messages replica identity full;
alter table public.global_messages replica identity full;
alter table public.calls replica identity full;
alter table public.call_ice_candidates replica identity full;


-- Limo Chat v1.11: database-enforced rate limit (shared by private and public rooms).

create index if not exists messages_sender_created_at_rate_idx
  on public.messages (sender_id, created_at desc);
create index if not exists global_messages_sender_created_at_rate_idx
  on public.global_messages (sender_id, created_at desc);

create or replace function public.enforce_limo_message_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recent_count integer;
begin
  if auth.uid() is null or new.sender_id is distinct from auth.uid() then
    raise exception 'LIMO_SENDER_MISMATCH' using errcode = '42501';
  end if;

  -- Serialize inserts per account. This prevents simultaneous requests racing past the count.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.sender_id::text, 0)
  );

  select
    (select count(*) from public.messages m
      where m.sender_id = new.sender_id
        and m.created_at > pg_catalog.now() - interval '30 seconds')
    +
    (select count(*) from public.global_messages gm
      where gm.sender_id = new.sender_id
        and gm.created_at > pg_catalog.now() - interval '30 seconds')
  into recent_count;

  if recent_count >= 5 then
    raise exception 'LIMO_RATE_LIMIT: maximum 5 messages per 30 seconds'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_limo_message_rate_limit() from public, anon, authenticated;

drop trigger if exists limo_rate_limit_private_messages on public.messages;
create trigger limo_rate_limit_private_messages
before insert on public.messages
for each row execute function public.enforce_limo_message_rate_limit();

drop trigger if exists limo_rate_limit_global_messages on public.global_messages;
create trigger limo_rate_limit_global_messages
before insert on public.global_messages
for each row execute function public.enforce_limo_message_rate_limit();


commit;

-- NOTE: Supabase Auth > Providers > Email: turn OFF "Confirm email" for this app's
-- username-based accounts. The app maps usernames to internal addresses at
-- @limochat.app; those are not mailboxes. Enable Google provider separately if needed.
