-- Limo Chat v1.11: single incremental update for an existing v1.10 database.
-- Backup first. This migration preserves users, conversations and messages.
begin;


do $$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.chats') is null
     or to_regclass('public.chat_members') is null
     or to_regclass('public.messages') is null
     or to_regclass('public.global_messages') is null
     or to_regclass('public.user_blocks') is null then
    raise exception 'LIMO_BASE_SCHEMA_MISSING: run supabase-schema.sql on a new database or restore the missing base tables first';
  end if;
end;
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

revoke all on function public.create_direct_chat(uuid) from public, anon;
grant execute on function public.create_direct_chat(uuid) to authenticated;

-- Required by the RPC and message client. Reassert the intended minimum table grants.
grant select on public.chat_members to authenticated;
grant select, insert, update on public.chats to authenticated;
grant select, insert, update, delete on public.messages, public.global_messages to authenticated;



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
