-- Limo Chat v1.11: direct-chat RPC repair for an existing v1.10 database.
-- This migration is intentionally non-destructive and does not delete existing accounts or messages.
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

commit;
