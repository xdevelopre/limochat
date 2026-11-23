-- ============================================================================
-- LIMO CHAT 2.01 — ADDITIVE MIGRATION
-- Execute this file ONCE after the already-installed Limo Chat 2.0 SQL.
-- GitHub Pages + Supabase Auth / PostgreSQL / Realtime / Storage.
-- No service_role key is needed in the browser.
-- ============================================================================

begin;

-- 1) Keep message TTL exactly as selected by the sender. Enforce Premium media
--    on the database side for private chats, the public lobby and World rooms.
--    This replaces the 2.0 trigger which forced every image to expire in 72h
--    and only checked image_path (not voice/video attachments).
create or replace function public.limo_guard_media_message()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_sender uuid;
  v_is_premium boolean := false;
  v_image_path text;
  v_attachment_path text;
  v_attachment_type text;
  v_image_size bigint := 0;
  v_attachment_size bigint := 0;
  v_old_image_path text;
  v_old_attachment_path text;
  v_media_changed boolean := true;
begin
  v_sender := nullif(v_row->>'sender_id','')::uuid;
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode='42501';
  end if;
  if v_sender is distinct from auth.uid() and not public.limo_is_admin() then
    raise exception 'MESSAGE_SENDER_MISMATCH' using errcode='42501';
  end if;
  if exists(select 1 from public.profiles p where p.id=auth.uid() and p.is_suspended) and not public.limo_is_admin() then
    raise exception 'ACCOUNT_SUSPENDED' using errcode='42501';
  end if;

  v_image_path := nullif(v_row->>'image_path','');
  v_attachment_path := nullif(v_row->>'attachment_path','');
  v_attachment_type := nullif(v_row->>'attachment_type','');
  if tg_op = 'UPDATE' then
    v_old_image_path := nullif(to_jsonb(old)->>'image_path','');
    v_old_attachment_path := nullif(to_jsonb(old)->>'attachment_path','');
    v_media_changed := v_image_path is distinct from v_old_image_path or v_attachment_path is distinct from v_old_attachment_path;
  end if;
  v_image_size := coalesce(nullif(v_row->>'image_size','')::bigint,0);
  v_attachment_size := coalesce(nullif(v_row->>'attachment_size','')::bigint,0);

  if (v_image_path is not null or v_attachment_path is not null) and v_media_changed then
    select coalesce(p.is_premium,false) and not coalesce(p.is_suspended,false) into v_is_premium
      from public.profiles p where p.id = auth.uid();
    if not coalesce(v_is_premium,false) and not public.limo_is_admin() then
      raise exception 'MEDIA_PREMIUM_REQUIRED' using errcode='42501';
    end if;
  end if;

  if v_image_path is not null and v_image_size > 5242880 then
    raise exception 'IMAGE_LIMIT_5MB' using errcode='22023';
  end if;

  if v_attachment_path is not null then
    if coalesce(v_attachment_type,'') not in ('image','audio','video') then
      raise exception 'INVALID_ATTACHMENT_TYPE' using errcode='22023';
    end if;
    if v_attachment_type = 'image' and v_attachment_size > 5242880 then
      raise exception 'IMAGE_LIMIT_5MB' using errcode='22023';
    elsif v_attachment_type = 'audio' and v_attachment_size > 5242880 then
      raise exception 'AUDIO_LIMIT_5MB' using errcode='22023';
    elsif v_attachment_type = 'video' and v_attachment_size > 41943040 then
      raise exception 'VIDEO_LIMIT_40MB' using errcode='22023';
    end if;
  elsif v_attachment_type is not null then
    raise exception 'ATTACHMENT_PATH_REQUIRED' using errcode='22023';
  end if;

  -- Do not modify expires_at: NULL means permanent, otherwise the client-selected
  -- lifetime remains authoritative and is enforced by the read RLS policies.
  return new;
end;
$$;

drop trigger if exists limo_guard_private_media on public.messages;
create trigger limo_guard_private_media
before insert or update on public.messages
for each row execute function public.limo_guard_media_message();

drop trigger if exists limo_guard_global_media on public.global_messages;
create trigger limo_guard_global_media
before insert or update on public.global_messages
for each row execute function public.limo_guard_media_message();

drop trigger if exists limo_guard_room_media on public.limo_room_messages;
create trigger limo_guard_room_media
before insert or update on public.limo_room_messages
for each row execute function public.limo_guard_media_message();

-- 2) Allow image, audio and video content in the same private bucket.
--    Supabase Free global file-size limit cannot exceed 50 MB; set the project's
--    global limit to at least 40 MB in Storage settings before testing videos.
update storage.buckets
set public = false,
    file_size_limit = 41943040,
    allowed_mime_types = array[
      'image/jpeg','image/png','image/webp',
      'audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/aac',
      'video/mp4','video/webm','video/quicktime'
    ]
where id = 'chat-media';

-- 3) Make media reads safe for both UUID chat/room folders and the literal
--    'global' folder. The previous 2.0 policy cast every first folder to UUID
--    before checking whether it was 'global', which could fail on global media.
drop policy if exists "chat_media_read_authenticated" on storage.objects;
create policy "chat_media_read_authenticated"
on storage.objects for select to authenticated
using (
  bucket_id = 'chat-media'
  and (
    owner_id = auth.uid()::text
    or public.limo_is_admin()
    or case
      when (storage.foldername(name))[1] = 'global' then true
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        public.limo_is_chat_member(((storage.foldername(name))[1])::uuid)
        or public.limo_is_room_member(((storage.foldername(name))[1])::uuid)
      else false
    end
  )
);

-- 4) Remove the old audio-only policy. It did not check Premium and could
--    accidentally allow Free users to upload audio. One policy now guards every
--    media upload and requires both Premium entitlement and correct ownership
--    of the chat/room path.
drop policy if exists "chat_media_insert_premium" on storage.objects;
drop policy if exists chat_media_insert_audio on storage.objects;
create policy chat_media_insert_premium
on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and owner_id = auth.uid()::text
  and (storage.foldername(name))[2] = auth.uid()::text
  and (public.limo_is_admin() or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_premium = true and not p.is_suspended
  ))
  and case
    when (storage.foldername(name))[1] = 'global' then true
    when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      public.limo_is_chat_member(((storage.foldername(name))[1])::uuid)
      or public.limo_is_room_member(((storage.foldername(name))[1])::uuid)
    else false
  end
);

-- 5) Keep media deletion restricted to the file owner or an administrator.
drop policy if exists "chat_media_delete_owner_admin" on storage.objects;
create policy chat_media_delete_owner_admin
on storage.objects for delete to authenticated
using (bucket_id='chat-media' and (owner_id=auth.uid()::text or public.limo_is_admin()));

-- 6) Realtime sender profile display uses profiles(id, username, display_name,
--    avatar_url); retain authenticated profile reads (already granted in 2.0).
--    No public/anonymous access is enabled here.

-- 7) Make expired content cleanup run every minute when pg_cron is available.
--    The read policies already hide expired messages immediately; this job
--    physically removes expired rows and their stored media soon afterwards.
do $$
begin
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname='limo-media-cleanup') then
    perform cron.unschedule((select jobid from cron.job where jobname='limo-media-cleanup' limit 1));
  end if;
  perform cron.schedule('limo-media-cleanup','* * * * *','select public.limo_cleanup_expired_media()');
exception when others then
  raise notice 'pg_cron is unavailable or not permitted. Expired messages are hidden by RLS, but configure a scheduled cleanup job for physical deletion. Details: %', sqlerrm;
end $$;

revoke all on function public.limo_guard_media_message() from public, anon, authenticated;

commit;

-- AFTER RUNNING THIS MIGRATION:
-- Supabase Dashboard > Storage > Settings > Global file size limit must be >= 40 MB.
-- Keep the chat-media bucket PRIVATE. Never publish service_role keys in GitHub.
