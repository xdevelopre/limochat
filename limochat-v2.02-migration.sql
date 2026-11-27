-- ============================================================================
-- LIMO CHAT 2.02 — ADDITIVE, IDEMPOTENT SUPABASE MIGRATION
-- Apply AFTER the existing 2.0 installation and 2.01 migration.
-- GitHub Pages frontend + Supabase Auth / PostgreSQL / Realtime / Storage.
--
-- Data safety:
--   * No existing user, chat, message, or storage row is dropped/truncated.
--   * Existing Premium users remain active. NULL premium_expires_at means the
--     existing admin-granted entitlement has no scheduled expiry.
--   * Existing message expires_at values are preserved. New writes calculate
--     expiry on the database clock from an allow-listed duration.
--   * Back up the project before running this script.
-- ============================================================================

begin;

create table if not exists public.limo_schema_migrations (
  version text primary key,
  applied_at timestamptz not null default now(),
  notes text not null default ''
);
revoke all on public.limo_schema_migrations from public, anon, authenticated;
insert into public.limo_schema_migrations(version,notes)
values('2.02','Server-enforced message TTL, Premium expiry, RLS and message idempotency')
on conflict(version) do update set notes=excluded.notes;

-- 1. Versioned metadata and server-controlled entitlement fields.
alter table public.profiles
  add column if not exists premium_expires_at timestamptz;

alter table public.messages
  add column if not exists expires_in_seconds integer not null default 0
    check (expires_in_seconds in (0,5,10,30,60,300,3600,86400,604800,2592000)),
  add column if not exists client_message_id uuid,
  add column if not exists is_forwarded boolean not null default false,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists pinned_by uuid references public.profiles(id) on delete set null,
  add column if not exists pinned_at timestamptz;

alter table public.global_messages
  add column if not exists expires_in_seconds integer not null default 0
    check (expires_in_seconds in (0,5,10,30,60,300,3600,86400,604800,2592000)),
  add column if not exists client_message_id uuid,
  add column if not exists is_forwarded boolean not null default false,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists pinned_by uuid references public.profiles(id) on delete set null,
  add column if not exists pinned_at timestamptz;

alter table public.limo_room_messages
  add column if not exists expires_in_seconds integer not null default 0
    check (expires_in_seconds in (0,5,10,30,60,300,3600,86400,604800,2592000)),
  add column if not exists client_message_id uuid,
  add column if not exists is_forwarded boolean not null default false,
  add column if not exists is_pinned boolean not null default false,
  add column if not exists pinned_by uuid references public.profiles(id) on delete set null,
  add column if not exists pinned_at timestamptz;

create unique index if not exists messages_sender_client_id_uidx
  on public.messages(sender_id,client_message_id) where client_message_id is not null;
create unique index if not exists global_messages_sender_client_id_uidx
  on public.global_messages(sender_id,client_message_id) where client_message_id is not null;
create unique index if not exists limo_room_messages_sender_client_id_uidx
  on public.limo_room_messages(sender_id,client_message_id) where client_message_id is not null;
create index if not exists messages_expiry_v202_idx on public.messages(expires_at) where expires_at is not null;
create index if not exists global_messages_expiry_v202_idx on public.global_messages(expires_at) where expires_at is not null;
create index if not exists limo_room_messages_expiry_v202_idx on public.limo_room_messages(expires_at) where expires_at is not null;
create index if not exists profiles_premium_expiry_idx on public.profiles(premium_expires_at) where is_premium=true and premium_expires_at is not null;

-- Scheduled text messages may opt into the same server-calculated TTL.
alter table public.limo_scheduled_messages
  add column if not exists expires_in_seconds integer not null default 0
    check (expires_in_seconds in (0,5,10,30,60,300,3600,86400,604800,2592000));

-- 2. Small security-definer helpers. These read protected tables without exposing
--    them and are deliberately not directly callable by anonymous clients.
create or replace function public.limo_has_premium(target_user uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path = public, auth
as $$
  select case
    when target_user is null then false
    when target_user <> auth.uid() and not public.limo_is_admin() then false
    else coalesce((
      select p.is_premium
         and not p.is_suspended
         and (p.premium_expires_at is null or p.premium_expires_at > now())
      from public.profiles p where p.id = target_user
    ), false)
  end
$$;

create or replace function public.limo_is_blocked_pair(user_a uuid, user_b uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks b
    where (b.user_id=user_a and b.blocked_user_id=user_b)
       or (b.user_id=user_b and b.blocked_user_id=user_a)
  )
$$;

create or replace function public.limo_can_view_profile(target_uid uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select target_uid = auth.uid()
      or public.limo_is_admin()
      or (
        not public.limo_is_blocked_pair(auth.uid(),target_uid)
        and (
          exists (
            select 1 from public.profiles p
            where p.id=target_uid and p.public_profile=true and p.is_suspended=false
          )
          or exists (
            select 1
            from public.chat_members mine
            join public.chat_members theirs on theirs.chat_id=mine.chat_id
            join public.chats c on c.id=mine.chat_id
            where mine.user_id=auth.uid()
              and theirs.user_id=target_uid
              and c.chat_type in ('private','group','channel')
          )
        )
      )
$$;

revoke all on function public.limo_has_premium(uuid) from public, anon;
revoke all on function public.limo_is_blocked_pair(uuid,uuid) from public, anon, authenticated;
revoke all on function public.limo_can_view_profile(uuid) from public, anon;
grant execute on function public.limo_has_premium(uuid) to authenticated;
grant execute on function public.limo_can_view_profile(uuid) to authenticated;

-- Restrict profile reads to public profiles, shared chat participants, self or admin.
drop policy if exists profiles_read_authenticated on public.profiles;
create policy profiles_read_authenticated on public.profiles
  for select to authenticated using (public.limo_can_view_profile(id));

-- 3. Prevent blocked pairs from opening or sending direct messages. A transaction
--    advisory lock serializes simultaneous create_direct_chat calls for a pair.
create or replace function public.create_direct_chat(target_user uuid)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_chat uuid;
  v_pair_key text;
begin
  if v_me is null or target_user is null or target_user=v_me then
    raise exception 'Invalid participant' using errcode='22023';
  end if;
  if not exists(select 1 from public.profiles where id=v_me and not is_suspended)
     or not exists(select 1 from public.profiles where id=target_user and not is_suspended) then
    raise exception 'ACCOUNT_UNAVAILABLE' using errcode='42501';
  end if;
  if public.limo_is_blocked_pair(v_me,target_user) then
    raise exception 'USER_BLOCKED' using errcode='42501';
  end if;

  v_pair_key := least(v_me::text,target_user::text)||':'||greatest(v_me::text,target_user::text);
  perform pg_advisory_xact_lock(hashtextextended(v_pair_key,0));

  select c.id into v_chat
  from public.chats c
  where c.chat_type='private'
    and exists(select 1 from public.chat_members a where a.chat_id=c.id and a.user_id=v_me)
    and exists(select 1 from public.chat_members b where b.chat_id=c.id and b.user_id=target_user)
    and (select count(*) from public.chat_members m where m.chat_id=c.id)=2
  order by c.created_at asc
  limit 1;
  if v_chat is not null then return v_chat; end if;

  insert into public.chats(chat_type,created_by) values('private',v_me) returning id into v_chat;
  insert into public.chat_members(chat_id,user_id,role)
    values(v_chat,v_me,'owner'),(v_chat,target_user,'member');
  return v_chat;
end;
$$;

-- 4. Server-side message guard. The browser may select only an allow-listed
--    lifetime; the database derives expires_at from clock_timestamp(). Old 2.01
--    clients which only send expires_at are accepted only when the duration is
--    one of the same allow-listed values. Message ownership/destination is
--    immutable after insert. Scheduled cron inserts are accepted only from a
--    PostgreSQL-owned session (session_user), never from a browser JWT.
create or replace function public.limo_guard_media_message()
returns trigger
language plpgsql security definer
set search_path = public, auth
as $$
declare
  v_sender uuid;
  v_uid uuid := auth.uid();
  v_actor uuid;
  v_scheduler boolean := (auth.uid() is null and session_user in ('postgres','supabase_admin'));
  v_media_changed boolean := true;
  v_ttl integer := 0;
  v_requested timestamptz;
  v_image_path text;
  v_attachment_path text;
  v_attachment_type text;
  v_image_size bigint := 0;
  v_attachment_size bigint := 0;
  v_first_folder text;
  v_second_folder text;
  v_chat_type text;
  v_other uuid;
  v_room_kind text;
begin
  v_sender := new.sender_id;
  if v_sender is null then raise exception 'MESSAGE_SENDER_REQUIRED' using errcode='22023'; end if;

  if tg_op='UPDATE' then
    v_actor := coalesce(v_uid,v_sender);
    v_media_changed := (to_jsonb(new)->>'image_path') is distinct from (to_jsonb(old)->>'image_path')
      or (to_jsonb(new)->>'attachment_path') is distinct from (to_jsonb(old)->>'attachment_path');
    if new.sender_id is distinct from old.sender_id then raise exception 'MESSAGE_SENDER_IMMUTABLE' using errcode='42501'; end if;
    if tg_table_name='messages' and (to_jsonb(new)->>'chat_id') is distinct from (to_jsonb(old)->>'chat_id') then raise exception 'MESSAGE_DESTINATION_IMMUTABLE' using errcode='42501'; end if;
    if tg_table_name='limo_room_messages' and (to_jsonb(new)->>'room_id') is distinct from (to_jsonb(old)->>'room_id') then raise exception 'MESSAGE_DESTINATION_IMMUTABLE' using errcode='42501'; end if;
    if new.created_at is distinct from old.created_at then raise exception 'MESSAGE_TIMESTAMP_IMMUTABLE' using errcode='42501'; end if;
    if new.expires_at is distinct from old.expires_at or new.expires_in_seconds is distinct from old.expires_in_seconds then
      raise exception 'MESSAGE_EXPIRY_IMMUTABLE' using errcode='42501';
    end if;
    if new.client_message_id is distinct from old.client_message_id then raise exception 'MESSAGE_IDEMPOTENCY_KEY_IMMUTABLE' using errcode='42501'; end if;
  else
    v_actor := v_sender;
    if not v_scheduler and (v_uid is null or v_sender is distinct from v_uid) then
      raise exception 'MESSAGE_SENDER_MISMATCH' using errcode='42501';
    end if;
    if v_scheduler and not exists(select 1 from public.profiles p where p.id=v_sender and not p.is_suspended) then
      raise exception 'ACCOUNT_SUSPENDED' using errcode='42501';
    end if;

    -- Determine an allow-listed lifetime. For legacy callers derive only the
    -- duration from their expiry hint, never trust the supplied absolute time.
    v_ttl := coalesce(new.expires_in_seconds,0);
    if v_ttl=0 and new.expires_at is not null then
      v_requested := new.expires_at;
      select options.candidate into v_ttl
      from unnest(array[5,10,30,60,300,3600,86400,604800,2592000]) as options(candidate)
      where abs(extract(epoch from (v_requested-clock_timestamp()))-options.candidate) <= 2
      order by abs(extract(epoch from (v_requested-clock_timestamp()))-options.candidate)
      limit 1;
      if v_ttl is null then
        raise exception 'INVALID_MESSAGE_EXPIRY' using errcode='22023';
      end if;
    end if;
    if v_ttl not in (0,5,10,30,60,300,3600,86400,604800,2592000) then
      raise exception 'INVALID_MESSAGE_EXPIRY' using errcode='22023';
    end if;
    new.expires_at := case when v_ttl=0 then null else clock_timestamp()+make_interval(secs=>v_ttl) end;
    new.expires_in_seconds := v_ttl;
    new.created_at := clock_timestamp();
  end if;

  if exists(select 1 from public.profiles p where p.id=coalesce(v_uid,v_sender) and p.is_suspended) and not public.limo_is_admin() then
    raise exception 'ACCOUNT_SUSPENDED' using errcode='42501';
  end if;

  if tg_table_name='messages' then
    if not public.limo_is_admin() and not exists(select 1 from public.chat_members m where m.chat_id=(to_jsonb(new)->>'chat_id')::uuid and m.user_id=v_actor) then
      raise exception 'CHAT_MEMBERSHIP_REQUIRED' using errcode='42501';
    end if;
    select c.chat_type into v_chat_type from public.chats c where c.id=(to_jsonb(new)->>'chat_id')::uuid;
    if v_chat_type='private' and v_actor is distinct from v_sender then
      if public.limo_is_blocked_pair(v_actor,v_sender) then raise exception 'USER_BLOCKED' using errcode='42501'; end if;
    elsif v_chat_type='private' and tg_op='INSERT' then
      select m.user_id into v_other from public.chat_members m where m.chat_id=(to_jsonb(new)->>'chat_id')::uuid and m.user_id<>v_sender limit 1;
      if v_other is null or public.limo_is_blocked_pair(v_sender,v_other) then
        raise exception 'USER_BLOCKED_OR_NOT_AVAILABLE' using errcode='42501';
      end if;
    end if;
  elsif tg_table_name='limo_room_messages' then
    if not public.limo_is_admin() and not exists(select 1 from public.limo_room_members m where m.room_id=(to_jsonb(new)->>'room_id')::uuid and m.user_id=v_actor) then
      raise exception 'ROOM_MEMBERSHIP_REQUIRED' using errcode='42501';
    end if;
    select room_kind into v_room_kind from public.limo_public_rooms where id=(to_jsonb(new)->>'room_id')::uuid;
    if v_room_kind='channel' and tg_op='INSERT' and not exists(
      select 1 from public.limo_room_members m where m.room_id=(to_jsonb(new)->>'room_id')::uuid and m.user_id=v_sender and m.role in ('owner','moderator')
    ) then raise exception 'CHANNEL_POSTING_REQUIRES_MODERATOR' using errcode='42501'; end if;
  elsif tg_table_name not in ('global_messages') then
    raise exception 'UNSUPPORTED_MESSAGE_TABLE';
  end if;

  v_image_path := nullif(to_jsonb(new)->>'image_path','');
  v_attachment_path := nullif(to_jsonb(new)->>'attachment_path','');
  v_attachment_type := nullif(to_jsonb(new)->>'attachment_type','');
  v_image_size := coalesce(nullif(to_jsonb(new)->>'image_size','')::bigint,0);
  v_attachment_size := coalesce(nullif(to_jsonb(new)->>'attachment_size','')::bigint,0);

  if (v_image_path is not null or v_attachment_path is not null) and (tg_op='INSERT' or v_media_changed) then
    if not public.limo_has_premium(v_sender) and not public.limo_is_admin() then
      raise exception 'MEDIA_PREMIUM_REQUIRED' using errcode='42501';
    end if;
  end if;
  if v_image_path is not null and (v_image_size<=0 or v_image_size>5242880) then
    raise exception 'IMAGE_LIMIT_5MB' using errcode='22023';
  end if;
  if v_attachment_path is not null then
    if v_attachment_type not in ('image','audio','video') then raise exception 'INVALID_ATTACHMENT_TYPE' using errcode='22023'; end if;
    if v_attachment_type in ('image','audio') and (v_attachment_size<=0 or v_attachment_size>5242880) then raise exception 'MEDIA_LIMIT_5MB' using errcode='22023'; end if;
    if v_attachment_type='video' and (v_attachment_size<=0 or v_attachment_size>41943040) then raise exception 'VIDEO_LIMIT_40MB' using errcode='22023'; end if;
  elsif v_attachment_type is not null then
    raise exception 'ATTACHMENT_PATH_REQUIRED' using errcode='22023';
  end if;

  if v_image_path is not null and (tg_op='INSERT' or v_media_changed) then
    v_first_folder := split_part(v_image_path,'/',1);
    v_second_folder := split_part(v_image_path,'/',2);
    if v_second_folder<>v_sender::text then raise exception 'MEDIA_PATH_OWNER_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='messages' and v_first_folder<>(to_jsonb(new)->>'chat_id') then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='global_messages' and v_first_folder<>'global' then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='limo_room_messages' and v_first_folder<>(to_jsonb(new)->>'room_id') then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
  end if;
  if v_attachment_path is not null and (tg_op='INSERT' or v_media_changed) then
    v_first_folder := split_part(v_attachment_path,'/',1);
    v_second_folder := split_part(v_attachment_path,'/',2);
    if v_second_folder<>v_sender::text then raise exception 'MEDIA_PATH_OWNER_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='messages' and v_first_folder<>(to_jsonb(new)->>'chat_id') then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='global_messages' and v_first_folder<>'global' then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
    if tg_table_name='limo_room_messages' and v_first_folder<>(to_jsonb(new)->>'room_id') then raise exception 'MEDIA_PATH_DESTINATION_MISMATCH' using errcode='42501'; end if;
  end if;
  return new;
end;
$$;

-- Existing trigger names are preserved so deployments do not accumulate duplicates.
drop trigger if exists limo_guard_private_media on public.messages;
create trigger limo_guard_private_media before insert or update on public.messages
  for each row execute function public.limo_guard_media_message();
drop trigger if exists limo_guard_global_media on public.global_messages;
create trigger limo_guard_global_media before insert or update on public.global_messages
  for each row execute function public.limo_guard_media_message();
drop trigger if exists limo_guard_room_media on public.limo_room_messages;
create trigger limo_guard_room_media before insert or update on public.limo_room_messages
  for each row execute function public.limo_guard_media_message();
revoke all on function public.limo_guard_media_message() from public,anon,authenticated;

-- Protect reaction identity and pin permissions against direct PostgREST UPDATE
-- calls. The SECURITY DEFINER reaction/pin RPCs perform the same role checks;
-- this trigger prevents a row owner from forging another user's reaction or
-- bypassing the global-admin / room-moderator pin restrictions.
create or replace function public.limo_guard_message_mutations()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_pin_changed boolean := false;
  v_chat uuid;
  v_room uuid;
  v_reaction text;
begin
  if tg_op='INSERT' then
    if coalesce(new.reactions,'{}'::jsonb) <> '{}'::jsonb then
      raise exception 'INITIAL_REACTIONS_NOT_ALLOWED' using errcode='42501';
    end if;
    if coalesce(new.is_pinned,false) or new.pinned_by is not null or new.pinned_at is not null then
      raise exception 'INITIAL_PIN_METADATA_NOT_ALLOWED' using errcode='42501';
    end if;
    return new;
  end if;

  if new.reactions is distinct from old.reactions then
    if v_uid is null then raise exception 'REACTION_AUTH_REQUIRED' using errcode='42501'; end if;
    if jsonb_typeof(coalesce(new.reactions,'{}'::jsonb)) <> 'object'
       or jsonb_typeof(coalesce(old.reactions,'{}'::jsonb)) <> 'object' then
      raise exception 'REACTIONS_MUST_BE_OBJECT' using errcode='22023';
    end if;
    if (coalesce(new.reactions,'{}'::jsonb) - v_uid::text)
       is distinct from (coalesce(old.reactions,'{}'::jsonb) - v_uid::text) then
      raise exception 'REACTION_IDENTITY_IMMUTABLE' using errcode='42501';
    end if;
    if new.reactions ? v_uid::text then
      v_reaction := new.reactions->>v_uid::text;
      if v_reaction not in ('❤️','😂','👍','😮','😢','🔥','👏','🙏','🎉') then
        raise exception 'REACTION_NOT_ALLOWED' using errcode='22023';
      end if;
    end if;
  end if;

  v_pin_changed := new.is_pinned is distinct from old.is_pinned
    or new.pinned_by is distinct from old.pinned_by
    or new.pinned_at is distinct from old.pinned_at;
  if v_pin_changed then
    if tg_table_name='messages' then
      v_chat := (to_jsonb(new)->>'chat_id')::uuid;
      if not public.limo_is_admin() and not public.limo_is_chat_member(v_chat) then
        raise exception 'PRIVATE_PIN_REQUIRES_CHAT_MEMBERSHIP' using errcode='42501';
      end if;
    elsif tg_table_name='global_messages' then
      if not public.limo_is_admin() then
        raise exception 'GLOBAL_PIN_ADMIN_ONLY' using errcode='42501';
      end if;
    elsif tg_table_name='limo_room_messages' then
      v_room := (to_jsonb(new)->>'room_id')::uuid;
      if not public.limo_is_admin() and not public.limo_can_manage_room(v_room) then
        raise exception 'ROOM_PIN_REQUIRES_OWNER_OR_MODERATOR' using errcode='42501';
      end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.limo_guard_message_mutations() from public,anon,authenticated;

drop trigger if exists limo_guard_private_mutations on public.messages;
create trigger limo_guard_private_mutations before insert or update on public.messages
  for each row execute function public.limo_guard_message_mutations();
drop trigger if exists limo_guard_global_mutations on public.global_messages;
create trigger limo_guard_global_mutations before insert or update on public.global_messages
  for each row execute function public.limo_guard_message_mutations();
drop trigger if exists limo_guard_room_mutations on public.limo_room_messages;
create trigger limo_guard_room_mutations before insert or update on public.limo_room_messages
  for each row execute function public.limo_guard_message_mutations();

-- Room-reaction RPC: only the current authenticated user's reaction key changes.
create or replace function public.limo_toggle_room_reaction(p_message_id uuid,p_emoji text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_room uuid; v_sender uuid; v_reactions jsonb; v_key text:=auth.uid()::text;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode='42501'; end if;
  if p_emoji not in ('👍','❤️','😂','😮','😢','👏','🔥','🎉') then raise exception 'REACTION_NOT_ALLOWED' using errcode='22023'; end if;
  select room_id,sender_id,reactions into v_room,v_sender,v_reactions
    from public.limo_room_messages
    where id=p_message_id and (expires_at is null or expires_at>now()) for update;
  if v_room is null or not public.limo_is_room_member(v_room) then raise exception 'Not allowed' using errcode='42501'; end if;
  if public.limo_is_blocked_pair(auth.uid(),v_sender) then raise exception 'USER_BLOCKED' using errcode='42501'; end if;
  if v_reactions ? v_key and v_reactions->>v_key=p_emoji then v_reactions:=v_reactions-v_key;
  else v_reactions:=jsonb_set(coalesce(v_reactions,'{}'::jsonb),array[v_key],to_jsonb(p_emoji),true); end if;
  update public.limo_room_messages set reactions=v_reactions where id=p_message_id;
  return v_reactions;
end;
$$;
revoke all on function public.limo_toggle_room_reaction(uuid,text) from public,anon;
grant execute on function public.limo_toggle_room_reaction(uuid,text) to authenticated;

-- 5. Close the private-message UPDATE IDOR and make insert-time block checks
--    database-enforced. Room/global policies also keep sender and destination.
drop policy if exists messages_update_owner on public.messages;
create policy messages_update_owner on public.messages
  for update to authenticated
  using (
    (sender_id=auth.uid() and public.limo_is_chat_member(chat_id))
    or public.limo_is_admin()
  )
  with check (
    (sender_id=auth.uid() and public.limo_is_chat_member(chat_id))
    or public.limo_is_admin()
  );

drop policy if exists messages_member_insert on public.messages;
create policy messages_member_insert on public.messages
  for insert to authenticated with check (
    sender_id=auth.uid()
    and public.limo_is_chat_member(chat_id)
    and not exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_suspended)
  );

drop policy if exists global_messages_update on public.global_messages;
create policy global_messages_update on public.global_messages
  for update to authenticated
  using(sender_id=auth.uid() or public.limo_is_admin())
  with check(sender_id=auth.uid() or public.limo_is_admin());

drop policy if exists limo_room_messages_update on public.limo_room_messages;
create policy limo_room_messages_update on public.limo_room_messages
  for update to authenticated
  using((sender_id=auth.uid() and public.limo_is_room_member(room_id)) or public.limo_can_manage_room(room_id) or public.limo_is_admin())
  with check((sender_id=auth.uid() and public.limo_is_room_member(room_id)) or public.limo_can_manage_room(room_id) or public.limo_is_admin());

-- 6. Reliable reaction RPC that the existing main chat calls. The JSON key is
--    the reacting user's UUID; a repeat of the same emoji removes that reaction.
create or replace function public.react_to_message(target_message uuid,target_global boolean,reaction text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_sender uuid; v_chat uuid; v_reactions jsonb; v_key text := auth.uid()::text;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode='42501'; end if;
  if reaction not in ('❤️','😂','👍','😮','😢','🔥','👏','🙏','🎉') then raise exception 'REACTION_NOT_ALLOWED' using errcode='22023'; end if;
  if target_global then
    select sender_id,reactions into v_sender,v_reactions from public.global_messages where id=target_message and (expires_at is null or expires_at>now()) for update;
    if v_sender is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
    if public.limo_is_blocked_pair(auth.uid(),v_sender) then raise exception 'USER_BLOCKED' using errcode='42501'; end if;
    if v_reactions ? v_key and v_reactions->>v_key=reaction then v_reactions:=v_reactions-v_key;
    else v_reactions:=jsonb_set(coalesce(v_reactions,'{}'::jsonb),array[v_key],to_jsonb(reaction),true); end if;
    update public.global_messages set reactions=v_reactions where id=target_message;
  else
    select sender_id,chat_id,reactions into v_sender,v_chat,v_reactions from public.messages where id=target_message and (expires_at is null or expires_at>now()) for update;
    if v_sender is null or not public.limo_is_chat_member(v_chat) then raise exception 'MESSAGE_NOT_FOUND_OR_FORBIDDEN' using errcode='42501'; end if;
    if public.limo_is_blocked_pair(auth.uid(),v_sender) then raise exception 'USER_BLOCKED' using errcode='42501'; end if;
    if v_reactions ? v_key and v_reactions->>v_key=reaction then v_reactions:=v_reactions-v_key;
    else v_reactions:=jsonb_set(coalesce(v_reactions,'{}'::jsonb),array[v_key],to_jsonb(reaction),true); end if;
    update public.messages set reactions=v_reactions where id=target_message;
  end if;
  return v_reactions;
end;
$$;
revoke all on function public.react_to_message(uuid,boolean,text) from public,anon;
grant execute on function public.react_to_message(uuid,boolean,text) to authenticated;

create or replace function public.limo_toggle_message_pin(target_message uuid,target_scope text)
returns boolean language plpgsql security definer set search_path=public
as $$
declare v_user uuid:=auth.uid(); v_is_pinned boolean; v_chat uuid; v_room uuid; v_sender uuid;
begin
  if v_user is null then raise exception 'Not authenticated' using errcode='42501'; end if;
  if target_scope='private' then
    select chat_id,sender_id,is_pinned into v_chat,v_sender,v_is_pinned from public.messages where id=target_message for update;
    if v_chat is null or not public.limo_is_chat_member(v_chat) then raise exception 'Not a chat member' using errcode='42501'; end if;
    update public.messages set is_pinned=not coalesce(v_is_pinned,false),pinned_by=case when not coalesce(v_is_pinned,false) then v_user else null end,pinned_at=case when not coalesce(v_is_pinned,false) then now() else null end where id=target_message;
  elsif target_scope='global' then
    if not public.limo_is_admin() then raise exception 'Only administrators can pin global messages' using errcode='42501'; end if;
    select sender_id,is_pinned into v_sender,v_is_pinned from public.global_messages where id=target_message for update;
    if v_sender is null then raise exception 'Message not found'; end if;
    update public.global_messages set is_pinned=not coalesce(v_is_pinned,false),pinned_by=case when not coalesce(v_is_pinned,false) then v_user else null end,pinned_at=case when not coalesce(v_is_pinned,false) then now() else null end where id=target_message;
  elsif target_scope='room' then
    select room_id,sender_id,is_pinned into v_room,v_sender,v_is_pinned from public.limo_room_messages where id=target_message for update;
    if v_room is null or not public.limo_can_manage_room(v_room) then raise exception 'Only room owners or moderators can pin messages' using errcode='42501'; end if;
    update public.limo_room_messages set is_pinned=not coalesce(v_is_pinned,false),pinned_by=case when not coalesce(v_is_pinned,false) then v_user else null end,pinned_at=case when not coalesce(v_is_pinned,false) then now() else null end where id=target_message;
  else raise exception 'Invalid message scope' using errcode='22023'; end if;
  return not coalesce(v_is_pinned,false);
end;
$$;
revoke all on function public.limo_toggle_message_pin(uuid,text) from public,anon;
grant execute on function public.limo_toggle_message_pin(uuid,text) to authenticated;

-- 7. Premium is time-bounded and changed only through admin RPCs. A NULL expiry
--    is retained for existing lifetime grants and legacy admin decisions.
create or replace function public.limo_admin_grant_premium(target_user uuid,valid_until timestamptz)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  if target_user is null or valid_until is null or valid_until<=now() or valid_until>now()+interval '2 years' then
    raise exception 'Invalid Premium expiry; choose a future date within two years' using errcode='22023';
  end if;
  update public.profiles set is_premium=true,premium_expires_at=valid_until,updated_at=now() where id=target_user;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
end;
$$;

create or replace function public.limo_admin_revoke_premium(target_user uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  update public.profiles set is_premium=false,premium_expires_at=null,updated_at=now() where id=target_user;
end;
$$;
revoke all on function public.limo_admin_grant_premium(uuid,timestamptz) from public,anon;
revoke all on function public.limo_admin_revoke_premium(uuid) from public,anon;
grant execute on function public.limo_admin_grant_premium(uuid,timestamptz) to authenticated;
grant execute on function public.limo_admin_revoke_premium(uuid) to authenticated;

-- Keep the legacy admin action for suspension only. Premium changes must use
-- the time-bounded RPCs above; accepting a boolean here could create new
-- accidental non-expiring subscriptions.
create or replace function public.limo_admin_set_user(
  target_user uuid,
  premium_value boolean default null,
  suspended_value boolean default null
)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.limo_is_admin() then raise exception 'Admin only' using errcode='42501'; end if;
  if premium_value is not null then
    raise exception 'Use limo_admin_grant_premium or limo_admin_revoke_premium for subscription changes' using errcode='22023';
  end if;
  if suspended_value is null then return; end if;
  update public.profiles set is_suspended=suspended_value,updated_at=now() where id=target_user;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
end;
$$;
revoke all on function public.limo_admin_set_user(uuid,boolean,boolean) from public,anon;
grant execute on function public.limo_admin_set_user(uuid,boolean,boolean) to authenticated;

-- 8. A media URL can be issued only for an unexpired message visible to the
--    authenticated requester. The owner_id shortcut from 2.01 is intentionally
--    removed: uploads not referenced by a message are not downloadable.
create or replace function public.limo_can_read_media_path(p_path text)
returns boolean language sql stable security definer
set search_path=public,storage
as $$
  select auth.uid() is not null and (
    public.limo_is_admin()
    or exists(
      select 1 from public.global_messages m
      where (m.image_path=p_path or m.attachment_path=p_path)
        and (m.expires_at is null or m.expires_at>now())
    )
    or exists(
      select 1 from public.messages m
      join public.chat_members cm on cm.chat_id=m.chat_id and cm.user_id=auth.uid()
      where (m.image_path=p_path or m.attachment_path=p_path)
        and (m.expires_at is null or m.expires_at>now())
    )
    or exists(
      select 1 from public.limo_room_messages m
      join public.limo_room_members rm on rm.room_id=m.room_id and rm.user_id=auth.uid()
      where m.attachment_path=p_path
        and (m.expires_at is null or m.expires_at>now())
    )
  )
$$;
revoke all on function public.limo_can_read_media_path(text) from public,anon;
grant execute on function public.limo_can_read_media_path(text) to authenticated;

drop policy if exists chat_media_read_authenticated on storage.objects;
create policy chat_media_read_authenticated on storage.objects
  for select to authenticated using (
    bucket_id='chat-media' and public.limo_can_read_media_path(name)
  );

drop policy if exists chat_media_insert_premium on storage.objects;
drop policy if exists chat_media_insert_audio on storage.objects;
create policy chat_media_insert_premium on storage.objects
  for insert to authenticated with check (
    bucket_id='chat-media'
    and owner_id=auth.uid()::text
    and (storage.foldername(name))[2]=auth.uid()::text
    and public.limo_has_premium(auth.uid())
    and (
      (storage.foldername(name))[1]='global'
      or (
        (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and (
          public.limo_is_chat_member(((storage.foldername(name))[1])::uuid)
          or public.limo_is_room_member(((storage.foldername(name))[1])::uuid)
        )
      )
    )
  );

-- Keep the bucket private and constrain uploads to MIME types used by this client.
update storage.buckets set
  public=false,
  file_size_limit=41943040,
  allowed_mime_types=array[
    'image/jpeg','image/png','image/webp',
    'audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/aac',
    'video/mp4','video/webm','video/quicktime'
  ]
where id='chat-media';

-- 9. Scheduled messages: authenticated fallbacks process only their own rows;
--    pg_cron (postgres session) can process all due rows. The server-side
--    message trigger still validates destination membership and Premium media.
create or replace function public.limo_dispatch_scheduled_messages()
returns integer language plpgsql security definer set search_path=public
as $$
declare
  r public.limo_scheduled_messages%rowtype;
  v_name text;
  v_count integer:=0;
  v_cron boolean := (auth.uid() is null and session_user in ('postgres','supabase_admin'));
begin
  if auth.uid() is null and not v_cron then raise exception 'Not authenticated' using errcode='42501'; end if;
  for r in
    select * from public.limo_scheduled_messages
    where status='pending' and scheduled_at<=now()
      and (v_cron or user_id=auth.uid())
    order by scheduled_at limit 30 for update skip locked
  loop
    begin
      select coalesce(display_name,username,'کاربر') into v_name from public.profiles where id=r.user_id;
      if r.destination_type='private' then
        if not exists(select 1 from public.chat_members where chat_id=r.destination_id and user_id=r.user_id) then raise exception 'CHAT_MEMBERSHIP_LOST'; end if;
        if exists(select 1 from public.chat_members m where m.chat_id=r.destination_id and m.user_id<>r.user_id and public.limo_is_blocked_pair(r.user_id,m.user_id)) then raise exception 'USER_BLOCKED'; end if;
        insert into public.messages(chat_id,sender_id,sender_name,text,expires_in_seconds)
          values(r.destination_id,r.user_id,v_name,r.body,r.expires_in_seconds);
        update public.chats set last_message=left(r.body,120),updated_at=now() where id=r.destination_id;
      elsif r.destination_type='room' then
        if not exists(select 1 from public.limo_room_members where room_id=r.destination_id and user_id=r.user_id) then raise exception 'ROOM_MEMBERSHIP_LOST'; end if;
        if exists(select 1 from public.limo_public_rooms where id=r.destination_id and room_kind='channel')
          and not exists(select 1 from public.limo_room_members where room_id=r.destination_id and user_id=r.user_id and role in ('owner','moderator')) then
          raise exception 'CHANNEL_POSTING_REQUIRES_MODERATOR';
        end if;
        insert into public.limo_room_messages(room_id,sender_id,sender_name,text,expires_in_seconds)
          values(r.destination_id,r.user_id,v_name,r.body,r.expires_in_seconds);
      else
        insert into public.global_messages(sender_id,sender_name,text,expires_in_seconds)
          values(r.user_id,v_name,r.body,r.expires_in_seconds);
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
end;
$$;
revoke all on function public.limo_dispatch_scheduled_messages() from public,anon;
grant execute on function public.limo_dispatch_scheduled_messages() to authenticated;

-- 10. Automatic cleanup: read policies hide expired rows immediately; pg_cron
--     physically removes rows and stored objects. If pg_cron is unavailable,
--     run this function from a trusted scheduled task after configuring it.
do $$
begin
  create extension if not exists pg_cron;
  if exists(select 1 from cron.job where jobname='limo-media-cleanup') then
    perform cron.unschedule((select jobid from cron.job where jobname='limo-media-cleanup' limit 1));
  end if;
  if exists(select 1 from cron.job where jobname='limo-scheduled-dispatch') then
    perform cron.unschedule((select jobid from cron.job where jobname='limo-scheduled-dispatch' limit 1));
  end if;
  perform cron.schedule('limo-media-cleanup','* * * * *','select public.limo_cleanup_expired_media()');
  perform cron.schedule('limo-scheduled-dispatch','* * * * *','select public.limo_dispatch_scheduled_messages()');
exception when others then
  raise notice 'pg_cron unavailable or insufficient privileges; configure a trusted cleanup job. Expired messages remain hidden by RLS. Details: %',sqlerrm;
end $$;

-- Ensure existing expiry read policies remain in force and room messages cannot
-- be fetched after their server-calculated expires_at.
drop policy if exists messages_member_read on public.messages;
create policy messages_member_read on public.messages for select to authenticated
  using((expires_at is null or expires_at>now()) and (public.limo_is_admin() or public.limo_is_chat_member(chat_id)));
drop policy if exists global_messages_read on public.global_messages;
create policy global_messages_read on public.global_messages for select to authenticated
  using(expires_at is null or expires_at>now());
drop policy if exists limo_room_messages_read on public.limo_room_messages;
create policy limo_room_messages_read on public.limo_room_messages for select to authenticated
  using((expires_at is null or expires_at>now()) and (public.limo_is_room_member(room_id) or public.limo_is_admin()));

-- Realtime is already enabled for the three message tables in the 2.0 schema.
-- The following grants are additive; no frontend role receives entitlement fields.
revoke update on public.profiles from public,anon,authenticated;
revoke update(is_premium,premium_expires_at,is_suspended) on public.profiles from public,anon,authenticated;
grant update(username,display_name,bio,avatar_url,locale,timezone,public_profile) on public.profiles to authenticated;

commit;

-- ==========================================================================
-- OPERATOR CHECKLIST
-- 1) Run after 2.0 full schema and 2.01 migration; take a backup first.
-- 2) Verify the existing admin is still present in public.limo_admins.
-- 3) Storage bucket `chat-media` must remain PRIVATE. Confirm global file-size
--    limit >= 40 MB in Storage settings; the SQL updates the bucket row but not
--    every project's global upload limit.
-- 4) Check pg_cron jobs `limo-media-cleanup` and `limo-scheduled-dispatch`.
--    If pg_cron is unavailable, configure trusted cleanup and dispatch jobs.
--    Message visibility expiry is still enforced by RLS even without cleanup.
-- 5) Signed URLs already issued may remain usable until their short expiry.
-- 6) Do not expose service_role or private AI provider keys in GitHub Pages.
-- ==========================================================================
