-- Limo Chat v1.11: database-enforced rate limit (shared by private and public rooms).
-- Run once on the existing v1.10 database in Supabase SQL Editor.
begin;

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
