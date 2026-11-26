/* Limo Chat 2.02 feature module.
 * This file runs in the browser and uses only the authenticated Supabase client.
 * No service-role keys, private server secrets, eval(), or external AI API calls.
 */
(() => {
  'use strict';
  const core = window.LimoCore;
  if (!core?.supabase) throw new Error('LimoCore bridge is unavailable');
  const db = core.supabase;
  const $ = (id) => document.getElementById(id);
  const esc = (value='') => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const toast = (message) => core.showToast?.(message);
  const user = () => core.getUser?.();
  const chat = () => core.getChat?.() || {};
  const prefs = () => core.getPrefs?.() || {};
  const baseRender = window.renderSubMenu;
  let activeRoom = null;
  let roomChannel = null;
  let spaceChannel = null;
  let activeRoomRole = 'member';
  let roomRecorder = null;
  let roomRecordingStream = null;
  let mainRecorder = null;
  let mainRecordingStream = null;
  let roomMessageCache = [];
  let roomMessageCursor = null;
  let roomMessageHasMore = false;
  let roomLoadingOlder = false;
  let roomPollRefreshTimer = null;
  let roomExpiryHoldTimer = null;
  let roomExpiryHoldOpened = false;
  let skipRoomExpiryClick = false;
  let premiumStatusCache = null;
  const roomExpiryOptions = [{value:0,label:'ماندگار',icon:'fa-infinity'},{value:5,label:'۵ ثانیه',icon:'fa-hourglass-start'},{value:10,label:'۱۰ ثانیه',icon:'fa-hourglass-start'},{value:30,label:'۳۰ ثانیه',icon:'fa-clock'},{value:60,label:'۱ دقیقه',icon:'fa-clock'},{value:300,label:'۵ دقیقه',icon:'fa-clock'},{value:3600,label:'۱ ساعت',icon:'fa-clock'},{value:86400,label:'۱ روز',icon:'fa-calendar-day'},{value:604800,label:'۷ روز',icon:'fa-calendar-week'},{value:2592000,label:'۳۰ روز',icon:'fa-calendar-check'}];
  const publicProfileCache = new Map();
  const offlineKey = () => `limo_v2_outbox_${user()?.uid || 'guest'}`;

  function signedMediaLifetimeSeconds(expiresAt) {
    if (!expiresAt) return 60;
    const remaining = Date.parse(expiresAt) - Date.now();
    if (!Number.isFinite(remaining) || remaining <= 2500) return 0;
    return Math.max(1, Math.min(60, Math.floor(remaining / 1000) - 2));
  }
  async function setSignedMediaSource(element, path, expiresAt) {
    const lifetime = signedMediaLifetimeSeconds(expiresAt);
    if (!lifetime) return;
    const {data,error} = await db.storage.from('chat-media').createSignedUrl(path,lifetime);
    if (!error && data?.signedUrl && (!expiresAt || Date.parse(expiresAt) > Date.now())) element.src=data.signedUrl;
  }

  function setBody(html) {
    const body = $('submenu-body');
    if (body) body.innerHTML = html;
  }
  function featureHeader(title) {
    $('submenu-title').textContent = title;
    $('submenu').classList.add('active');
  }
  function needAuth() {
    if (user()) return false;
    toast('برای استفاده از این بخش ابتدا وارد حساب شوید.');
    window.closeSubMenu?.();
    window.navigateTo?.('auth');
    return true;
  }
  async function isPremium(force = false) {
    if (!force && premiumStatusCache !== null) return premiumStatusCache;
    if (!user()?.uid) return false;
    const { data, error } = await db.from('profiles').select('is_premium,premium_expires_at').eq('id', user().uid).single();
    if (error) throw error;
    premiumStatusCache = !!data?.is_premium && (!data?.premium_expires_at || Date.parse(data.premium_expires_at) > Date.now());
    return premiumStatusCache;
  }
  async function requirePremium(featureName = 'این قابلیت') {
    try {
      if (await isPremium(true)) return true;
      toast(`${featureName} مخصوص کاربران Limo Premium است. از تنظیمات، اشتراک Premium را درخواست کن.`);
      return false;
    } catch (error) {
      console.error('Premium check:', error);
      toast('وضعیت اشتراک از سرور دریافت نشد؛ دوباره تلاش کن.');
      return false;
    }
  }
  async function openUser(uid) {
    if (!uid) return;
    if (uid === user()?.uid) { core.openSubMenu?.('account'); return; }
    // Always re-check with RLS. A cached profile must not survive a privacy change.
    const { data: profile, error } = await db.from('profiles')
      .select('id,username,display_name,avatar_url,bio,public_profile')
      .eq('id', uid).maybeSingle();
    if (error || !profile) return toast('این پروفایل خصوصی است یا در دسترس نیست.');
    featureHeader('پروفایل عمومی');
    const body = $('submenu-body');
    if (!body) return;
    body.replaceChildren();
    const card = document.createElement('div'); card.className = 'limo-v2-card'; card.style.textAlign = 'center';
    const avatarWrap = document.createElement('div'); avatarWrap.style.cssText = 'display:flex;justify-content:center;margin:8px';
    const avatar = document.createElement('div'); avatar.className = 'avatar'; avatar.style.cssText = 'width:72px;height:72px;margin:auto;font-size:24px';
    if (profile.avatar_url && /^https:\/\//i.test(profile.avatar_url)) {
      const image = document.createElement('img'); image.src = profile.avatar_url; image.alt = ''; image.referrerPolicy = 'no-referrer'; avatar.append(image);
    } else {
      avatar.textContent = (profile.display_name || profile.username || 'ل').slice(0,1);
    }
    avatarWrap.append(avatar);
    const name = document.createElement('h2'); name.textContent = profile.display_name || profile.username || 'کاربر لیمو';
    const handle = document.createElement('p'); handle.className = 'limo-v2-muted'; handle.dir = 'ltr'; handle.textContent = '@' + (profile.username || 'user');
    const bio = document.createElement('p'); bio.textContent = profile.bio || 'بدون بیوگرافی';
    const action = document.createElement('button'); action.type = 'button'; action.className = 'limo-v2-btn'; action.style.width = '100%';
    const icon = document.createElement('i'); icon.className = 'fa-solid fa-message'; action.append(icon, document.createTextNode(' شروع گفتگوی خصوصی'));
    action.addEventListener('click', () => startPrivateChat(profile.id, profile.display_name || profile.username || 'کاربر', profile.avatar_url || ''));
    card.append(avatarWrap, name, handle, bio, action);
    const note = document.createElement('div'); note.className = 'limo-v2-note';
    note.textContent = 'فقط اطلاعات عمومی این کاربر نمایش داده می‌شود؛ اطلاعات خصوصی حساب در دسترس نیست.';
    body.append(card, note);
  }
  async function startPrivateChat(uid,name,avatar){
    if (!uid) return;
    if (!navigator.onLine) return toast('برای ساخت گفتگوی خصوصی باید آنلاین باشی.');
    if (typeof window.startPrivateChat === 'function') return window.startPrivateChat(uid,name,avatar||null);
    return toast('امکان ساخت گفتگوی خصوصی در دسترس نیست.');
  }

  function timeLocal(value) {
    try { return new Date(value).toLocaleString(prefs().locale === 'en' ? 'en-US' : 'fa-IR', { dateStyle:'short', timeStyle:'short' }); }
    catch { return ''; }
  }
  function empty(text) { return `<div class="limo-v2-note">${esc(text)}</div>`; }
  function btn(label, action, cls='') { return `<button class="limo-v2-btn ${cls}" onclick="${action}">${label}</button>`; }

  // ------------------------- LIMO WORLD -------------------------
  function renderWorld() {
    featureHeader('Limo World · جهان لیمو');
    setBody(`
      <div class="limo-v2-card">
        <h3>جهان ارتباطات لیمو</h3>
        <p class="limo-v2-muted">اتاق‌های عمومی را بر اساس موضوع، زبان و نوع گفتگو پیدا کن. عضویت در اتاق عمومی اختیاری است.</p>
        <input class="limo-v2-input" id="world-query" placeholder="جستجوی اتاق یا موضوع..." oninput="LimoV2.filterWorld()">
        <div class="limo-v2-actions">
          <button class="limo-v2-btn" onclick="LimoV2.openCreateRoom()"><i class="fa-solid fa-plus"></i> ساخت اتاق</button>
          <button class="limo-v2-btn secondary" onclick="LimoV2.loadWorld()"><i class="fa-solid fa-rotate"></i> تازه‌سازی</button>
        </div>
      </div>
      <div id="world-create" class="limo-v2-card" hidden>
        <h3>ساخت فضای عمومی</h3>
        <input id="world-name" class="limo-v2-input" maxlength="60" placeholder="نام اتاق / کانال">
        <input id="world-topic" class="limo-v2-input" maxlength="240" placeholder="توضیح کوتاه و موضوع">
        <select id="world-category" class="limo-v2-select"><option value="general">عمومی</option><option value="technology">فناوری</option><option value="education">آموزش</option><option value="games">بازی</option><option value="culture">فرهنگ و هنر</option><option value="science">علم</option><option value="support">پشتیبانی</option></select>
        <select id="world-kind" class="limo-v2-select"><option value="chat">گروه گفتگو</option><option value="channel">کانال یک‌طرفه</option><option value="voice">اتاق صوتی (فعلاً لابی متنی)</option></select>
        <div class="limo-v2-actions"><button class="limo-v2-btn" onclick="LimoV2.createRoom()">ایجاد اتاق</button><button class="limo-v2-btn secondary" onclick="LimoV2.closeCreateRoom()">انصراف</button></div>
      </div>
      <div id="world-list">${empty('در حال دریافت اتاق‌های عمومی...')}</div>
    `);
    loadWorld();
  }
  async function loadWorld() {
    const root = $('world-list');
    if (!root) return;
    root.innerHTML = empty('در حال بارگذاری...');
    try {
      const [{ data: rooms, error }, { data: memberships }] = await Promise.all([
        db.from('limo_public_rooms').select('id,name,topic,category,language,room_kind,is_verified,owner_id,created_at').eq('is_public', true).eq('is_archived', false).order('created_at',{ascending:false}).limit(100),
        db.from('limo_room_members').select('room_id').eq('user_id', user().uid)
      ]);
      if (error) throw error;
      const joined = new Set((memberships || []).map(x => x.room_id));
      root.innerHTML = '';
      if (!rooms?.length) { root.innerHTML = empty('هنوز اتاق عمومی ساخته نشده است. اولین اتاق را بساز.'); return; }
      rooms.forEach(room => {
        const el = document.createElement('div'); el.className = 'limo-v2-room';
        const icon = document.createElement('div'); icon.className='avatar'; icon.textContent = room.room_kind === 'channel' ? '▣' : room.room_kind === 'voice' ? '◉' : '🌍';
        const info = document.createElement('div'); info.className='info';
        const title = document.createElement('b'); title.textContent = room.name + (room.is_verified ? ' ✓' : '');
        const sub = document.createElement('small'); sub.textContent = `${room.topic || 'بدون توضیح'} · ${room.category || 'عمومی'} · ${room.room_kind === 'channel' ? 'کانال' : room.room_kind === 'voice' ? 'اتاق صوتی' : 'گروه'}`;
        info.append(title,sub);
        const action = document.createElement('button'); action.className='limo-v2-btn' ; action.textContent = joined.has(room.id) ? 'ورود' : 'عضویت';
        action.onclick = () => openRoom(room, joined.has(room.id));
        el.append(icon,info,action); root.append(el);
      });
      filterWorld();
    } catch (error) {
      console.error('Limo World:',error);
      root.innerHTML = empty(`دریافت اتاق‌ها ممکن نشد: ${error.message || 'خطای ارتباط'}. بررسی کن SQL نسخه ۲ اجرا شده باشد.`);
    }
  }
  function filterWorld() {
    const q = String($('world-query')?.value || '').trim().toLocaleLowerCase();
    document.querySelectorAll('#world-list .limo-v2-room').forEach(el => {
      el.hidden = q && !el.textContent.toLocaleLowerCase().includes(q);
    });
  }
  function openCreateRoom() { const x=$('world-create'); if(x) x.hidden=false; $('world-name')?.focus(); }
  function closeCreateRoom() { const x=$('world-create'); if(x) x.hidden=true; }
  async function createRoom() {
    if (needAuth()) return;
    const name=$('world-name')?.value.trim(), topic=$('world-topic')?.value.trim();
    const category=$('world-category')?.value || 'general', kind=$('world-kind')?.value || 'chat';
    if (!name || name.length<2) return toast('نام اتاق حداقل دو حرف باشد.');
    try {
      const {data,error}=await db.rpc('limo_create_public_room',{p_name:name,p_topic:topic||'',p_category:category,p_language:prefs().locale||'fa',p_kind:kind});
      if(error) throw error;
      toast('اتاق عمومی ساخته شد.');
      const {data:room}=await db.from('limo_public_rooms').select('*').eq('id',data).single();
      if(room) openRoom(room,true); else loadWorld();
    } catch(error) { console.error(error); toast(`ساخت اتاق ناموفق بود: ${error.message || ''}`); }
  }
  async function openRoom(room, alreadyJoined=false) {
    if (needAuth()) return;
    if (!alreadyJoined) {
      const {error}=await db.rpc('limo_join_public_room',{p_room_id:room.id});
      if(error) return toast(`عضویت ناموفق بود: ${error.message || ''}`);
    }
    const {data:membership,error:membershipError}=await db.from('limo_room_members').select('role').eq('room_id',room.id).eq('user_id',user().uid).maybeSingle();
    if(membershipError || !membership) return toast('عضویت اتاق تأیید نشد؛ دوباره تلاش کن.');
    activeRoomRole=membership.role||'member';
    activeRoom = room;
    roomMessageCache = []; roomMessageCursor = null; roomMessageHasMore = false; roomLoadingOlder = false;
    if(roomChannel) { await db.removeChannel(roomChannel).catch(()=>{}); roomChannel=null; }
    featureHeader(room.name);
    const mayPost=room.room_kind!=='channel'||['owner','moderator'].includes(activeRoomRole);
    setBody(`
      <div class="limo-v2-card">
        <div class="limo-v2-actions"><button class="limo-v2-btn secondary" onclick="LimoV2.renderWorld()"><i class="fa-solid fa-arrow-right"></i> بازگشت</button><button class="limo-v2-btn secondary" onclick="LimoV2.leaveRoom()">خروج از اتاق</button></div>
        <h3>${esc(room.name)}</h3><p class="limo-v2-muted">${esc(room.topic||'اتاق عمومی لیموچت')} · ${esc(room.category||'عمومی')}</p>
        ${room.room_kind==='voice' ? '<div class="limo-v2-note">این اتاق در نسخه فعلی لابی متنی است. تماس صوتی چندنفره برای انتشار عمومی به SFU و سرویس TURN پایدار نیاز دارد.</div>' : ''}
      </div>
      <div id="room-polls"></div><button id="room-load-older" class="limo-v2-btn secondary" style="display:none;margin:8px auto" onclick="LimoV2.loadOlderRoomMessages()">نمایش پیام‌های قدیمی‌تر</button><div id="room-messages" class="limo-v2-card" style="min-height:180px;max-height:45vh;overflow:auto"></div>
      ${mayPost ? `<div class="limo-v2-card"><textarea id="room-text" class="limo-v2-textarea" maxlength="10000" placeholder="پیام در اتاق عمومی..."></textarea><div class="room-expiry-popover" id="room-expiry-popover" hidden><div class="expiry-popover-head"><div><b>ماندگاری پیام</b><br><small>برای انتخاب مدت، دکمه ارسال را نگه دار</small></div><button class="icon-btn" type="button" onclick="LimoV2.closeRoomExpiryMenu()" aria-label="بستن"><i class="fa-solid fa-xmark"></i></button></div><div class="expiry-options" id="room-expiry-options"></div></div><div class="limo-v2-actions"><select id="room-expiry" class="limo-v2-select" aria-label="عمر پیام" hidden><option value="0">ماندگار</option><option value="5">۵ ثانیه</option><option value="10">۱۰ ثانیه</option><option value="30">۳۰ ثانیه</option><option value="60">۱ دقیقه</option><option value="300">۵ دقیقه</option><option value="3600">۱ ساعت</option><option value="86400">۱ روز</option><option value="604800">۷ روز</option><option value="2592000">۳۰ روز</option></select><button class="limo-v2-btn room-send-button" id="room-send-button" onclick="LimoV2.handleRoomSendClick(event)" onpointerdown="LimoV2.beginRoomExpiryHold(event)" onpointerup="LimoV2.endRoomExpiryHold(event)" onpointercancel="LimoV2.cancelRoomExpiryHold()" onpointerleave="LimoV2.cancelRoomExpiryHold()" oncontextmenu="return false"><i class="fa-solid fa-paper-plane"></i> ارسال متن <span class="room-expiry-label" id="room-expiry-label">ماندگار</span></button>${room.room_kind==='channel' ? '' : '<button class="limo-v2-btn secondary" onclick="LimoV2.toggleRoomVoice()"><i class="fa-solid fa-microphone"></i> ویس (Premium)</button>'}<button class="limo-v2-btn secondary" onclick="LimoV2.chooseRoomMedia('image')"><i class="fa-regular fa-image"></i> عکس (Premium)</button><button class="limo-v2-btn secondary" onclick="LimoV2.chooseRoomMedia('video')"><i class="fa-solid fa-video"></i> فیلم (Premium)</button><button class="limo-v2-btn secondary" onclick="LimoV2.createPoll()"><i class="fa-solid fa-square-poll-vertical"></i> نظرسنجی</button></div><input id="room-image-file" type="file" accept="image/jpeg,image/png,image/webp" hidden onchange="LimoV2.uploadRoomMedia(event,'image')"><input id="room-video-file" type="file" accept="video/mp4,video/webm,video/quicktime" hidden onchange="LimoV2.uploadRoomMedia(event,'video')"><div class="limo-v2-note">عمر پیام از گزینه ماندگار تا ۳۰ روز قابل انتخاب است؛ برای تغییر، دکمه ارسال متن را نگه دار. ارسال عکس، فیلم و ویس مخصوص Premium است.</div></div>` : '<div class="limo-v2-note">این کانال فقط برای مدیران قابل ارسال است. پیام‌ها برای اعضا قابل مشاهده‌اند.</div>'}
    `);
    await Promise.all([loadRoomMessages(),loadRoomPolls()]);
    roomChannel=db.channel(`limo-room-${room.id}-${Math.random().toString(36).slice(2,8)}`)
      .on('postgres_changes',{event:'*',schema:'public',table:'limo_room_messages',filter:`room_id=eq.${room.id}`},()=>loadRoomMessages())
      .on('postgres_changes',{event:'*',schema:'public',table:'limo_polls'},()=>loadRoomPolls())
      .subscribe();
  }
  function compareRoomMessages(a,b) {
    const time = String(a.created_at).localeCompare(String(b.created_at));
    return time || String(a.id).localeCompare(String(b.id));
  }
  async function loadRoomMessages(before = null) {
    if(!activeRoom || !$('room-messages')) return;
    const roomId = activeRoom.id;
    const root = $('room-messages');
    const wasNearBottom = root.scrollHeight - root.scrollTop - root.clientHeight < 90;
    const oldHeight = root.scrollHeight, oldTop = root.scrollTop;
    let query = db.from('limo_room_messages')
      .select('id,sender_id,sender_name,text,reactions,created_at,attachment_path,attachment_type,attachment_name,attachment_size,is_pinned,is_forwarded,expires_at')
      .eq('room_id', roomId).order('created_at',{ascending:false}).order('id',{ascending:false}).limit(100);
    if (before?.created_at && before?.id) {
      query = query.or(`created_at.lt.${before.created_at},and(created_at.eq.${before.created_at},id.lt.${before.id})`);
    }
    const {data,error}=await query;
    if (activeRoom?.id !== roomId) return;
    if(error) {root.textContent=`خطا در دریافت پیام‌ها: ${error.message}`;return;}
    const newestFirst = data || [];
    const page = newestFirst.slice().reverse();
    if (before) {
      roomMessageCache = [...page, ...roomMessageCache];
      if (newestFirst.length) roomMessageCursor = {created_at:newestFirst[newestFirst.length-1].created_at,id:newestFirst[newestFirst.length-1].id};
      roomMessageHasMore = newestFirst.length === 100;
    } else {
      if (page.length) {
        const newestBoundary = page[0];
        const retainedOlder = roomMessageCache.filter(m => compareRoomMessages(m,newestBoundary) < 0);
        roomMessageCache = [...retainedOlder, ...page];
      } else if (!roomMessageCache.length) roomMessageCache = [];
      if (!roomMessageCursor && newestFirst.length) {
        const oldest = newestFirst[newestFirst.length-1];
        roomMessageCursor = {created_at:oldest.created_at,id:oldest.id};
        roomMessageHasMore = newestFirst.length === 100;
      }
    }
    const now = Date.now();
    roomMessageCache = roomMessageCache.filter(m =>
      (!m.expires_at || Date.parse(m.expires_at) > now) &&
      (m.sender_id === user()?.uid || !core.isBlocked?.(m.sender_id))
    ).sort(compareRoomMessages);
    const olderButton = $('room-load-older');
    if (olderButton) olderButton.style.display = roomMessageHasMore ? 'block' : 'none';
    root.replaceChildren();
    if(!roomMessageCache.length) {root.append(document.createTextNode('هنوز پیامی در این اتاق نیست.'));return;}
    const ids=[...new Set(roomMessageCache.filter(m=>m.sender_name!=='کاربر ناشناس').map(m=>m.sender_id).filter(Boolean))];
    publicProfileCache.clear();
    if(ids.length){const {data:profiles,error:profileError}=await db.from('profiles').select('id,username,display_name,avatar_url').in('id',ids);if(!profileError)(profiles||[]).forEach(profile=>publicProfileCache.set(profile.id,profile));}
    if (activeRoom?.id !== roomId) return;
    roomMessageCache.forEach(m=>{
      const item=document.createElement('div'); item.className='limo-v2-message'+(m.sender_id===user().uid?' mine':'');
      const anonymous=m.sender_name==='کاربر ناشناس';
      const profile=anonymous?{}:(publicProfileCache.get(m.sender_id)||{});
      const author=document.createElement(anonymous?'div':'button');if(!anonymous){author.type='button';author.onclick=()=>openUser(m.sender_id);}author.className='limo-v2-author'+(anonymous?' anonymous':'');
      const avatar=document.createElement('div');avatar.className='avatar';avatar.textContent=anonymous?'؟':(profile.display_name||m.sender_name||'ل').slice(0,1).toUpperCase();
      if(!anonymous&&profile.avatar_url?.startsWith('http')){const img=document.createElement('img');img.src=profile.avatar_url;img.alt='';img.referrerPolicy='no-referrer';avatar.textContent='';avatar.append(img);}
      const authorInfo=document.createElement('span');const authorName=document.createElement('b');authorName.textContent=anonymous?'کاربر ناشناس':(profile.display_name||m.sender_name||'کاربر');const authorHandle=document.createElement('small');authorHandle.textContent=anonymous?'هویت پنهان · '+timeLocal(m.created_at):(profile.username?'@'+profile.username+' · '+timeLocal(m.created_at):timeLocal(m.created_at));authorInfo.append(authorName,authorHandle);
      author.append(avatar,authorInfo);if(!anonymous){const action=document.createElement('i');action.className='fa-solid '+(m.sender_id===user().uid?'fa-user-gear':'fa-paper-plane');action.style.marginRight='auto';action.style.color='var(--muted)';author.append(action);}item.append(author);
      if(m.is_forwarded){const tag=document.createElement('small');tag.textContent='↗ پیام منتقل‌شده';tag.className='limo-v2-muted';item.append(tag);}if(m.is_pinned){const tag=document.createElement('small');tag.textContent='📌 پیام سنجاق‌شده';tag.className='limo-v2-muted';item.append(tag);}const text=document.createElement('div');text.textContent=m.text||'';item.append(text);
      if(m.attachment_path){
        if(m.attachment_type==='audio'){
          const audioWrap=document.createElement('div');audioWrap.className='limo-audio-wrap';
          const audio=document.createElement('audio');audio.controls=true;audio.preload='none';audio.className='limo-v2-audio';
          const caption=document.createElement('small');caption.textContent=m.attachment_name||'پیام صوتی · مدت نامشخص';
          const speed=document.createElement('button');speed.type='button';speed.className='limo-v2-btn secondary';speed.textContent='سرعت ۱×';
          const rates=[1,1.25,1.5,2,0.75];let rateIndex=0;speed.onclick=()=>{rateIndex=(rateIndex+1)%rates.length;audio.playbackRate=rates[rateIndex];speed.textContent=`سرعت ${rates[rateIndex]}×`;};
          audio.addEventListener('loadedmetadata',()=>{if(Number.isFinite(audio.duration))caption.textContent=`${m.attachment_name||'پیام صوتی'} · ${Math.floor(audio.duration/60)}:${String(Math.floor(audio.duration%60)).padStart(2,'0')}`;});
          audioWrap.append(audio,caption,speed);item.append(audioWrap);
          setSignedMediaSource(audio,m.attachment_path,m.expires_at).catch(error=>console.warn('Room audio URL:',error));
        }
        else if(m.attachment_type==='video'){const video=document.createElement('video');video.controls=true;video.playsInline=true;video.preload='metadata';video.className='limo-v2-room-media';item.append(video);setSignedMediaSource(video,m.attachment_path,m.expires_at).catch(error=>console.warn('Room video URL:',error));}
        else if(m.attachment_type==='image'){const img=document.createElement('img');img.alt=m.attachment_name||'تصویر';img.className='limo-v2-room-media';item.append(img);setSignedMediaSource(img,m.attachment_path,m.expires_at).catch(error=>console.warn('Room image URL:',error));}
      }
      const actions=document.createElement('div');actions.className='limo-v2-actions';
      const react=document.createElement('button');react.className='limo-v2-btn secondary';react.textContent='👍 واکنش';react.onclick=()=>reactRoomMessage(m.id,'👍');
      actions.append(react);item.append(actions);root.append(item);
    });
    if (before) root.scrollTop = oldTop + (root.scrollHeight-oldHeight);
    else if (wasNearBottom) root.scrollTop = root.scrollHeight;
  }
  async function loadOlderRoomMessages() {
    if(!activeRoom || !roomMessageCursor || !roomMessageHasMore || roomLoadingOlder) return;
    roomLoadingOlder=true;const button=$('room-load-older');if(button){button.disabled=true;button.textContent='در حال دریافت…';}
    try { await loadRoomMessages(roomMessageCursor); }
    catch(error){console.error('Older room messages:',error);toast('دریافت پیام‌های قدیمی‌تر ناموفق بود.');}
    finally {roomLoadingOlder=false;if(button){button.disabled=false;button.textContent='نمایش پیام‌های قدیمی‌تر';}}
  }
  function beginRoomExpiryHold(event){if(event?.button!==undefined&&event.button!==0)return;clearTimeout(roomExpiryHoldTimer);roomExpiryHoldOpened=false;roomExpiryHoldTimer=setTimeout(()=>{roomExpiryHoldOpened=true;skipRoomExpiryClick=true;openRoomExpiryMenu();},430);}
  function endRoomExpiryHold(){clearTimeout(roomExpiryHoldTimer);roomExpiryHoldTimer=null;if(roomExpiryHoldOpened)setTimeout(()=>{skipRoomExpiryClick=false;roomExpiryHoldOpened=false;},150);}
  function cancelRoomExpiryHold(){clearTimeout(roomExpiryHoldTimer);roomExpiryHoldTimer=null;}
  document.addEventListener('pointerup',()=>{if(roomExpiryHoldOpened)setTimeout(()=>{skipRoomExpiryClick=false;roomExpiryHoldOpened=false;},180);},true);
  document.addEventListener('pointercancel',()=>{if(roomExpiryHoldOpened){skipRoomExpiryClick=false;roomExpiryHoldOpened=false;}},true);
  function handleRoomSendClick(event){if(skipRoomExpiryClick||roomExpiryHoldOpened){event?.preventDefault?.();skipRoomExpiryClick=false;roomExpiryHoldOpened=false;return;}sendRoomMessage();}
  function openRoomExpiryMenu(){const menu=$('room-expiry-popover'),root=$('room-expiry-options'),select=$('room-expiry');if(!menu||!root||!select)return;const current=Number(select.value||0);root.replaceChildren();roomExpiryOptions.forEach(option=>{const b=document.createElement('button');b.type='button';b.className='expiry-option'+(current===option.value?' selected':'');b.innerHTML=`<i class="fa-solid ${option.icon}"></i><span>${option.label}</span>`;b.onclick=()=>setRoomMessageExpiry(option.value);root.append(b);});menu.hidden=false;}
  function closeRoomExpiryMenu(){const menu=$('room-expiry-popover');if(menu)menu.hidden=true;}
  function setRoomMessageExpiry(value){const select=$('room-expiry');if(!select)return;select.value=String(value);const option=roomExpiryOptions.find(x=>x.value===Number(value));const label=$('room-expiry-label');if(label)label.textContent=option?.label||'ماندگار';const button=$('room-send-button');button?.classList.toggle('has-expiry',Number(value)>0);if(button)button.title=`ارسال · ماندگاری ${option?.label||'ماندگار'}؛ برای تغییر نگه دار`;closeRoomExpiryMenu();toast(`ماندگاری پیام: ${option?.label||'ماندگار'}`);}

  document.addEventListener('pointerdown',event=>{const menu=$('room-expiry-popover');if(menu&&!menu.hidden&&!event.target.closest('#room-expiry-popover')&&!event.target.closest('#room-send-button'))closeRoomExpiryMenu();},{passive:true});

  async function sendRoomMessage() {
    if(!activeRoom) return;
    const input=$('room-text'), text=input?.value.trim(); if(!text) return;
    const me=user();
    const payload={room_id:activeRoom.id,sender_id:me.uid,sender_name:prefs().anonymous?'کاربر ناشناس':(me.displayName||me.username),text};
    const ttl=Number($('room-expiry')?.value||0);payload.expires_in_seconds=ttl;payload.client_message_id=crypto.randomUUID();
    const {error}=await db.from('limo_room_messages').insert(payload);
    if(error) return toast(error.message.includes('LIMO_RATE_LIMIT')?'سقف ارسال ۵ پیام در ۳۰ ثانیه است.':`ارسال نشد: ${error.message}`);
    input.value=''; await loadRoomMessages();
  }
  async function chooseRoomMedia(kind) {
    if(!activeRoom) return;
    if(!await requirePremium(kind==='image'?'ارسال عکس':'ارسال ویدئو')) return;
    $(kind==='image'?'room-image-file':'room-video-file')?.click();
  }
  async function uploadRoomMedia(event, kind) {
    const file=event.target.files?.[0];event.target.value='';if(!file||!activeRoom)return;
    if(!await requirePremium(kind==='image'?'ارسال عکس':'ارسال ویدئو'))return;
    const max=kind==='image'?5*1024*1024:40*1024*1024;
    if(file.size>max)return toast(kind==='image'?'حجم تصویر حداکثر ۵ مگابایت است.':'حجم ویدئو حداکثر ۴۰ مگابایت است.');
    if(kind==='image'&&!['image/jpeg','image/png','image/webp'].includes(file.type))return toast('فرمت تصویر پشتیبانی نمی‌شود.');
    if(kind==='video'&&!['video/mp4','video/webm','video/quicktime'].includes(file.type))return toast('فرمت ویدئو پشتیبانی نمی‌شود. از MP4 یا WebM استفاده کن.');
    const me=user(),ext=kind==='image'?(file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg'):(file.type==='video/webm'?'webm':file.type==='video/quicktime'?'mov':'mp4');
    const path=`${activeRoom.id}/${me.uid}/${crypto.randomUUID()}.${ext}`;
    const upload=await db.storage.from('chat-media').upload(path,file,{contentType:file.type,upsert:false});
    if(upload.error)return toast(`آپلود فایل ناموفق بود: ${upload.error.message}`);
    const payload={room_id:activeRoom.id,sender_id:me.uid,sender_name:prefs().anonymous?'کاربر ناشناس':(me.displayName||me.username),text:'',attachment_path:path,attachment_type:kind,attachment_name:file.name||kind,attachment_size:file.size};
    const ttl=Number($('room-expiry')?.value||0);payload.expires_in_seconds=ttl;payload.client_message_id=crypto.randomUUID();
    const {error}=await db.from('limo_room_messages').insert(payload);
    if(error){await db.storage.from('chat-media').remove([path]);return toast(`ثبت فایل ناموفق بود: ${error.message}`);}
    toast(kind==='image'?'تصویر ارسال شد.':'ویدئو ارسال شد.');loadRoomMessages();
  }

  async function leaveRoom() {
    if(!activeRoom) return;
    if(!confirm('از این اتاق خارج می‌شوی؟')) return;
    const {error}=await db.rpc('limo_leave_public_room',{p_room_id:activeRoom.id});
    if(error) return toast(error.message);
    activeRoom=null; if(roomChannel) await db.removeChannel(roomChannel).catch(()=>{}); roomChannel=null;
    toast('از اتاق خارج شدی.'); renderWorld();
  }
  async function reactRoomMessage(id,emoji) {
    const {error}=await db.rpc('limo_toggle_room_reaction',{p_message_id:id,p_emoji:emoji});
    if(error) toast(error.message); else loadRoomMessages();
  }
  async function createPoll() {
    if(!activeRoom) return;
    const question=prompt('سؤال نظرسنجی را وارد کن:'); if(!question?.trim()) return;
    const raw=prompt('گزینه‌ها را با ویرگول جدا کن (حداقل ۲ و حداکثر ۸ گزینه):','گزینه اول, گزینه دوم'); if(!raw) return;
    const options=raw.split(',').map(x=>x.trim()).filter(Boolean);
    const {error}=await db.rpc('limo_create_poll',{p_room_id:activeRoom.id,p_question:question.trim(),p_options:options,p_allow_multiple:false,p_closes_at:null});
    if(error) return toast(`ساخت نظرسنجی ناموفق بود: ${error.message}`);
    toast('نظرسنجی ساخته شد.'); loadRoomPolls();
  }
  async function loadRoomPolls() {
    if(!activeRoom || !$('room-polls')) return;
    const root=$('room-polls');
    const {data:polls,error}=await db.from('limo_polls').select('id,question,allow_multiple,closes_at,created_at').eq('room_id',activeRoom.id).order('created_at',{ascending:false}).limit(10);
    if(error) {root.textContent='نظرسنجی‌ها در دسترس نیستند.';return;}
    root.replaceChildren();
    for(const poll of polls||[]) {
      const [{data:opts},{data:votes}] = await Promise.all([
        db.from('limo_poll_options').select('id,label,sort_order').eq('poll_id',poll.id).order('sort_order'),
        db.from('limo_poll_votes').select('option_id,user_id').eq('poll_id',poll.id)
      ]);
      const card=document.createElement('div');card.className='limo-v2-card';
      const heading=document.createElement('h3');heading.textContent='نظرسنجی: '+poll.question;card.append(heading);
      (opts||[]).forEach(option=>{
        const count=(votes||[]).filter(v=>v.option_id===option.id).length;
        const row=document.createElement('div');row.className='setting-line';
        const label=document.createElement('span');label.textContent=`${option.label} (${count})`;
        const vote=document.createElement('button');vote.className='limo-v2-btn secondary';vote.textContent=(votes||[]).some(v=>v.option_id===option.id&&v.user_id===user().uid)?'انتخاب‌شده':'رأی';
        vote.onclick=async()=>{const {error}=await db.rpc('limo_vote_poll',{p_poll_id:poll.id,p_option_ids:[option.id]});if(error)toast(error.message);else loadRoomPolls();};
        row.append(label,vote);card.append(row);
      });
      root.append(card);
    }
  }
  async function toggleRoomVoice() {
    if(!activeRoom) return;
    if(roomRecorder?.state==='recording'){roomRecorder.stop();return;}
    if(!await requirePremium('ارسال پیام صوتی')) return;
    if(!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) return toast('ضبط صدا در این مرورگر پشتیبانی نمی‌شود.');
    try {
      roomRecordingStream=await navigator.mediaDevices.getUserMedia({audio:true});
      const mime=['audio/webm;codecs=opus','audio/webm','audio/mp4','audio/ogg'].find(t=>MediaRecorder.isTypeSupported?.(t));
      roomRecorder=new MediaRecorder(roomRecordingStream,mime?{mimeType:mime}:undefined);
      const chunks=[];roomRecorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};
      roomRecorder.onstop=async()=>{
        roomRecordingStream?.getTracks().forEach(t=>t.stop());roomRecordingStream=null;
        const blob=new Blob(chunks,{type:roomRecorder.mimeType||'audio/webm'});
        if(blob.size>5*1024*1024) return toast('حجم پیام صوتی بیشتر از ۵ مگابایت است.');
        const me=user(), ext=(blob.type.includes('mp4')?'m4a':blob.type.includes('ogg')?'ogg':'webm');
        const path=`${activeRoom.id}/${me.uid}/${crypto.randomUUID()}.${ext}`;
        const safeMime=(blob.type||'audio/webm').split(';')[0];
        const up=await db.storage.from('chat-media').upload(path,blob,{contentType:safeMime,upsert:false});
        if(up.error) return toast(`بارگذاری صدا ناموفق بود: ${up.error.message}`);
        const payload={room_id:activeRoom.id,sender_id:me.uid,sender_name:prefs().anonymous?'کاربر ناشناس':(me.displayName||me.username),text:'',attachment_path:path,attachment_type:'audio',attachment_name:'پیام صوتی',attachment_size:blob.size};
        const ttl=Number($('room-expiry')?.value||0);payload.expires_in_seconds=ttl;payload.client_message_id=crypto.randomUUID();
        const ins=await db.from('limo_room_messages').insert(payload);
        if(ins.error){await db.storage.from('chat-media').remove([path]);return toast(`ثبت پیام صوتی ناموفق بود: ${ins.error.message}`);}
        loadRoomMessages();
      };
      roomRecorder.start();toast('در حال ضبط پیام صوتی؛ دوباره دکمه را بزن تا ارسال شود.');
      setTimeout(()=>{if(roomRecorder?.state==='recording'){roomRecorder.stop();toast('ضبط به سقف ۳ دقیقه رسید.');}},180000);
    } catch(error){console.error(error);toast('دسترسی به میکروفون ممکن نشد.');}
  }

  // ------------------------- LIMO SPACE -------------------------
  function renderSpace() {
    featureHeader('Limo Space · فضای همکاری');
    setBody(`<div class="limo-v2-card"><h3>فضاهای کاری مشترک</h3><p class="limo-v2-muted">برای پروژه، کلاس یا گروه دوستان یک فضای مشترک بساز؛ کارها و یادداشت‌ها بین اعضای فضا همگام می‌شوند.</p><input id="space-name" class="limo-v2-input" maxlength="70" placeholder="نام فضای کاری"><input id="space-desc" class="limo-v2-input" maxlength="300" placeholder="توضیح کوتاه"><button class="limo-v2-btn" onclick="LimoV2.createSpace()">ساخت فضا</button></div><div class="limo-v2-card"><h3>عضویت با کد دعوت</h3><input id="space-code" class="limo-v2-input" placeholder="کد دعوت فضا" dir="ltr"><button class="limo-v2-btn secondary" onclick="LimoV2.joinSpace()">پیوستن</button></div><div id="space-list">${empty('در حال دریافت فضاها...')}</div>`);
    loadSpaces();
  }
  async function loadSpaces() {
    const root=$('space-list');if(!root)return;
    const {data,error}=await db.from('limo_spaces').select('id,name,description,invite_code,created_at').order('updated_at',{ascending:false}).limit(100);
    if(error){root.innerHTML=empty(`فضاها در دسترس نیستند: ${error.message}. SQL نسخه ۲ را اجرا کن.`);return;}
    root.replaceChildren();
    if(!data?.length){root.innerHTML=empty('فضایی نساخته‌ای یا هنوز به فضایی نپیوسته‌ای.');return;}
    data.forEach(space=>{
      const card=document.createElement('div');card.className='limo-v2-room';
      const icon=document.createElement('div');icon.className='avatar';icon.textContent='S';
      const info=document.createElement('div');info.className='info';const title=document.createElement('b');title.textContent=space.name;const sub=document.createElement('small');sub.textContent=space.description||'فضای همکاری';info.append(title,sub);
      const open=document.createElement('button');open.className='limo-v2-btn';open.textContent='باز کردن';open.onclick=()=>openSpace(space);
      card.append(icon,info,open);root.append(card);
    });
  }
  async function createSpace() {
    const name=$('space-name')?.value.trim(),description=$('space-desc')?.value.trim()||'';
    if(!name||name.length<2)return toast('نام فضا حداقل دو حرف باشد.');
    const {data,error}=await db.rpc('limo_create_space',{p_name:name,p_description:description});
    if(error)return toast(`ساخت فضا ناموفق بود: ${error.message}`);
    toast('فضای همکاری ساخته شد.');
    const {data:space}=await db.from('limo_spaces').select('*').eq('id',data).single();if(space)openSpace(space);else loadSpaces();
  }
  async function joinSpace() {
    const code=$('space-code')?.value.trim();if(!code)return toast('کد دعوت را وارد کن.');
    const {error}=await db.rpc('limo_join_space',{p_invite_code:code});if(error)return toast(`عضویت ناموفق بود: ${error.message}`);
    toast('به فضا پیوستی.');loadSpaces();
  }
  async function openSpace(space) {
    if(spaceChannel){await db.removeChannel(spaceChannel).catch(()=>{});spaceChannel=null;}
    featureHeader('Limo Space · '+space.name);
    setBody(`<div class="limo-v2-card"><div class="limo-v2-actions"><button class="limo-v2-btn secondary" onclick="LimoV2.renderSpace()">بازگشت</button><button class="limo-v2-btn secondary" onclick="LimoV2.copySpaceInvite('${esc(space.invite_code)}')">کپی کد دعوت</button></div><h3>${esc(space.name)}</h3><p class="limo-v2-muted">${esc(space.description||'فضای همکاری تیمی')}</p><p class="limo-v2-muted">کد دعوت فقط با اعضای مورد اعتماد به اشتراک گذاشته شود.</p></div>
      <div class="limo-v2-card"><h3>وظایف مشترک</h3><input id="task-title" class="limo-v2-input" maxlength="200" placeholder="عنوان کار جدید"><textarea id="task-desc" class="limo-v2-textarea" placeholder="توضیحات (اختیاری)"></textarea><button class="limo-v2-btn" onclick="LimoV2.addTask('${space.id}')">افزودن وظیفه</button><div id="space-tasks">در حال بارگذاری...</div></div>
      <div class="limo-v2-card"><h3>یادداشت‌های مشترک</h3><input id="note-title" class="limo-v2-input" maxlength="160" placeholder="عنوان یادداشت"><textarea id="note-body" class="limo-v2-textarea" maxlength="20000" placeholder="متن یادداشت"></textarea><button class="limo-v2-btn" onclick="LimoV2.addNote('${space.id}')">ذخیره یادداشت</button><div id="space-notes"></div></div>`);
    loadSpaceTasks(space.id);loadSpaceNotes(space.id);
    spaceChannel=db.channel(`limo-space-${space.id}`)
      .on('postgres_changes',{event:'*',schema:'public',table:'limo_space_tasks',filter:`space_id=eq.${space.id}`},()=>loadSpaceTasks(space.id))
      .on('postgres_changes',{event:'*',schema:'public',table:'limo_space_notes',filter:`space_id=eq.${space.id}`},()=>loadSpaceNotes(space.id))
      .subscribe();
  }
  async function loadSpaceTasks(spaceId) {
    const root=$('space-tasks');if(!root)return;
    const {data,error}=await db.from('limo_space_tasks').select('*').eq('space_id',spaceId).order('created_at',{ascending:false}).limit(100);
    if(error){root.textContent=error.message;return;}root.replaceChildren();
    if(!data?.length){root.textContent='هنوز وظیفه‌ای ثبت نشده است.';return;}
    data.forEach(task=>{
      const row=document.createElement('div');row.className='setting-line';const label=document.createElement('span');label.textContent=`${task.status==='done'?'✓ ':''}${task.title}`;
      const sel=document.createElement('select');sel.className='limo-v2-select';['open','doing','done'].forEach(v=>{const o=document.createElement('option');o.value=v;o.textContent=({open:'باز',doing:'در حال انجام',done:'انجام‌شده'})[v];o.selected=v===task.status;sel.append(o);});
      sel.onchange=async()=>{const {error}=await db.from('limo_space_tasks').update({status:sel.value,updated_at:new Date().toISOString()}).eq('id',task.id);if(error)toast(error.message);else loadSpaceTasks(spaceId);};row.append(label,sel);root.append(row);
    });
  }
  async function addTask(spaceId) {
    const title=$('task-title')?.value.trim(),description=$('task-desc')?.value.trim()||'';if(!title)return toast('عنوان وظیفه را وارد کن.');
    const {error}=await db.from('limo_space_tasks').insert({space_id:spaceId,created_by:user().uid,title,description});if(error)return toast(error.message);
    $('task-title').value='';$('task-desc').value='';loadSpaceTasks(spaceId);
  }
  async function loadSpaceNotes(spaceId) {
    const root=$('space-notes');if(!root)return;
    const {data,error}=await db.from('limo_space_notes').select('id,title,body,created_at').eq('space_id',spaceId).order('updated_at',{ascending:false}).limit(50);
    if(error){root.textContent=error.message;return;}root.replaceChildren();
    if(!data?.length){root.textContent='هنوز یادداشتی ثبت نشده است.';return;}
    data.forEach(note=>{const card=document.createElement('div');card.className='limo-v2-note';const title=document.createElement('b');title.textContent=note.title;const body=document.createElement('p');body.textContent=note.body;card.append(title,body);root.append(card);});
  }
  async function addNote(spaceId) {
    const title=$('note-title')?.value.trim(),body=$('note-body')?.value.trim()||'';if(!title)return toast('عنوان یادداشت را وارد کن.');
    const {error}=await db.from('limo_space_notes').insert({space_id:spaceId,created_by:user().uid,title,body});if(error)return toast(error.message);
    $('note-title').value='';$('note-body').value='';loadSpaceNotes(spaceId);
  }
  async function copySpaceInvite(code) { try{await navigator.clipboard.writeText(code);toast('کد دعوت کپی شد.');}catch{toast(code);} }

  // ------------------------- LIMO AI (private, in-browser helpers) -------------------------
  function renderAI() {
    featureHeader('Limo AI · دستیار هوشمند');
    setBody(`<div class="limo-v2-card"><h3>ابزارهای هوشمند محلی</h3><p class="limo-v2-muted">این ابزارها متن گفتگو را در همین مرورگر تحلیل می‌کنند و محتوای چت را به سرویس بیرونی نمی‌فرستند. این نسخه هنوز به مدل زبانی مولد متصل نیست.</p><div class="limo-v2-actions"><button class="limo-v2-btn" onclick="LimoV2.aiSummarize()">خلاصه گفتگو</button><button class="limo-v2-btn secondary" onclick="LimoV2.aiTasks()">استخراج کارها</button><button class="limo-v2-btn secondary" onclick="LimoV2.aiLinks()">استخراج لینک‌ها</button></div></div><div class="limo-v2-card"><h3>جستجوی معنایی ساده در متن</h3><input id="ai-query" class="limo-v2-input" placeholder="واژه یا عبارت موردنظر..."><button class="limo-v2-btn" onclick="LimoV2.aiSearch()">جستجو در تاریخچه</button></div><div class="limo-v2-card"><h3>قالب‌های آماده پاسخ (بدون مدل هوش مصنوعی)</h3><div class="limo-v2-actions"><button class="limo-v2-btn secondary" onclick="LimoV2.aiReply('formal')">رسمی</button><button class="limo-v2-btn secondary" onclick="LimoV2.aiReply('friendly')">دوستانه</button><button class="limo-v2-btn secondary" onclick="LimoV2.aiReply('short')">کوتاه</button></div><textarea id="ai-result" class="limo-v2-textarea" readonly placeholder="نتیجه ابزارها اینجا نمایش داده می‌شود..."></textarea><button class="limo-v2-btn secondary" onclick="LimoV2.copyAI()">کپی نتیجه</button></div><div class="limo-v2-note">برای پاسخ‌سازی مولد، ترجمه خودکار و خلاصه‌سازی ابری باید یک Edge Function امن در Supabase و کلید ارائه‌دهنده در Secret سمت سرور نصب شود؛ قرار دادن کلید API در فایل عمومی GitHub ناامن است.</div>`);
  }
  async function getContextMessages() {
    const c=chat();
    if(c.type==='private' && c.id){const {data,error}=await db.from('messages').select('sender_name,text,created_at').eq('chat_id',c.id).order('created_at',{ascending:false}).limit(250);if(error)throw error;return (data||[]).reverse();}
    if(c.type==='global'){const {data,error}=await db.from('global_messages').select('sender_name,text,created_at').order('created_at',{ascending:false}).limit(250);if(error)throw error;return (data||[]).reverse();}
    if(activeRoom){const {data,error}=await db.from('limo_room_messages').select('sender_name,text,created_at').eq('room_id',activeRoom.id).order('created_at',{ascending:false}).limit(250);if(error)throw error;return (data||[]).reverse();}
    throw new Error('ابتدا یک گفتگوی خصوصی، عمومی یا اتاق Limo World را باز کن.');
  }
  async function aiSummarize() {
    try{const rows=await getContextMessages(),texts=rows.map(r=>String(r.text||'').trim()).filter(Boolean);if(!texts.length)return setAI('متن قابل خلاصه‌سازی پیدا نشد.');
      const last=texts.slice(-80);const links=[...new Set(last.join('\n').match(/https?:\/\/[^\s]+/g)||[])];const tasks=extractTasks(last.join('\n'));
      const longest=[...last].sort((a,b)=>b.length-a.length).slice(0,5);
      setAI(`خلاصه محلی از ${last.length} پیام اخیر:\n\n${longest.map((x,i)=>`${i+1}. ${x.slice(0,260)}`).join('\n')}\n\nلینک‌های یافت‌شده: ${links.length}\nکارهای احتمالی: ${tasks.length}\n\nاین خلاصه استخراجی است، نه خروجی یک مدل زبانی.`);
    }catch(e){setAI(e.message);}
  }
  function extractTasks(text) {
    const lines=text.split(/\n|(?<=[.!؟])\s+/).map(x=>x.trim()).filter(Boolean);
    const re=/(باید|لطفاً|لطفا|انجام بده|فراموش نکن|یادآوری|مسئولیت|todo|task|please|must|remember|need to)/i;
    return lines.filter(x=>re.test(x)).slice(-25);
  }
  async function aiTasks(){try{const rows=await getContextMessages();const tasks=extractTasks(rows.map(x=>x.text||'').join('\n'));setAI(tasks.length?'مواردی که ممکن است نیازمند پیگیری باشند:\n\n'+tasks.map((x,i)=>`${i+1}. ${x}`).join('\n'):'موردی با الگوی وظیفه پیدا نشد.');}catch(e){setAI(e.message);}}
  async function aiLinks(){try{const rows=await getContextMessages();const links=[...new Set(rows.map(x=>x.text||'').join('\n').match(/https?:\/\/[^\s<>]+/g)||[])];setAI(links.length?links.join('\n'):'لینکی در تاریخچه پیدا نشد.');}catch(e){setAI(e.message);}}
  async function aiSearch(){const q=$('ai-query')?.value.trim();if(!q)return toast('عبارت جستجو را وارد کن.');try{const rows=await getContextMessages();const found=rows.filter(r=>(r.text||'').toLocaleLowerCase().includes(q.toLocaleLowerCase())).slice(-40);setAI(found.length?found.map(r=>`${timeLocal(r.created_at)} · ${r.sender_name||'کاربر'}\n${r.text}`).join('\n\n'):'پیامی مطابق جستجو پیدا نشد.');}catch(e){setAI(e.message);}}
  function aiReply(style){const templates={formal:'سلام، ممنون از پیامتان. بررسی می‌کنم و نتیجه را اطلاع می‌دهم.',friendly:'سلام! ممنون که گفتی، حتماً بررسیش می‌کنم.',short:'حتماً، بررسی می‌کنم.'};setAI(templates[style]||templates.short);}
  function setAI(value){const el=$('ai-result');if(el)el.value=value;}
  async function copyAI(){try{await navigator.clipboard.writeText($('ai-result')?.value||'');toast('متن کپی شد.');}catch{toast('کپی در این مرورگر در دسترس نیست.');}}

  // ------------------------- LIMO MINI -------------------------
  function renderMini(){
    featureHeader('Limo Mini · ابزارهای داخلی');
    setBody(`<div class="limo-v2-grid">
      <button class="limo-v2-tile" onclick="LimoV2.miniDice()"><i class="fa-solid fa-dice"></i><b>تاس</b><small>تاس تصادفی امن</small></button>
      <button class="limo-v2-tile" onclick="LimoV2.miniCalculator()"><i class="fa-solid fa-calculator"></i><b>ماشین‌حساب</b><small>محاسبات پایه</small></button>
      <button class="limo-v2-tile" onclick="LimoV2.miniText()"><i class="fa-solid fa-align-left"></i><b>ابزار متن</b><small>شمارش حروف و کلمات</small></button>
      <button class="limo-v2-tile" onclick="LimoV2.miniPicker()"><i class="fa-solid fa-shuffle"></i><b>انتخاب‌گر</b><small>انتخاب تصادفی گزینه</small></button>
    </div><div id="mini-workspace" class="limo-v2-card">این نسخه فقط ابزارهای داخلی و ازپیش‌تعریف‌شده دارد؛ اجرای مینی‌اپ ثالث و sandbox مجوزدار هنوز پیاده‌سازی نشده است. ابزارهای داخلی در مرورگر اجرا می‌شوند و داده‌ای به سرور نمی‌فرستند.</div>`);
  }
  function miniDice(){const a=new Uint32Array(1);crypto.getRandomValues(a);const value=(a[0]%6)+1;const root=$('mini-workspace');root.innerHTML=`<h3>تاس لیمو</h3><div class="limo-v2-stat" style="font-size:58px;text-align:center">${['⚀','⚁','⚂','⚃','⚄','⚅'][value-1]}</div><p style="text-align:center">عدد ${value}</p><button class="limo-v2-btn" onclick="LimoV2.miniDice()">پرتاب دوباره</button>`;}
  function miniCalculator(){const root=$('mini-workspace');root.innerHTML=`<h3>ماشین‌حساب امن</h3><input id="mini-expression" class="limo-v2-input" dir="ltr" placeholder="مثلاً (12+8)*3/2"><button class="limo-v2-btn" onclick="LimoV2.calcRun()">محاسبه</button><p id="mini-calc-result" class="limo-v2-stat"></p><small class="limo-v2-muted">عملگرها: + − × ÷ % و پرانتز</small>`;}
  function calcRun(){const raw=$('mini-expression')?.value||'';try{const value=safeArithmetic(raw);$('mini-calc-result').textContent=String(value);}catch{$('mini-calc-result').textContent='عبارت معتبر نیست.';}}
  function safeArithmetic(input){
    const s=input.replace(/\s+/g,'');if(!s||!/^[0-9.+\-*/()%]+$/.test(s))throw new Error('invalid');let i=0;
    function expr(){let v=term();while(s[i]==='+'||s[i]==='-'){const op=s[i++],r=term();v=op==='+'?v+r:v-r;}return v;}
    function term(){let v=factor();while(s[i]==='*'||s[i]==='/'||s[i]==='%'){const op=s[i++],r=factor();if((op==='/'||op==='%')&&r===0)throw new Error('zero');v=op==='*'?v*r:op==='/'?v/r:v%r;}return v;}
    function factor(){if(s[i]==='+'){i++;return factor();}if(s[i]==='-'){i++;return -factor();}if(s[i]==='('){i++;const v=expr();if(s[i++]!==')')throw new Error('paren');return v;}const start=i;while(/[0-9.]/.test(s[i]||''))i++;if(start===i)throw new Error('number');const n=Number(s.slice(start,i));if(!Number.isFinite(n))throw new Error('nan');return n;}
    const result=expr();if(i!==s.length||!Number.isFinite(result))throw new Error('tail');return Math.round(result*1e10)/1e10;
  }
  function miniText(){const root=$('mini-workspace');root.innerHTML=`<h3>شمارش متن</h3><textarea id="mini-text-input" class="limo-v2-textarea" oninput="LimoV2.textStats()" placeholder="متن را وارد کن..."></textarea><div id="mini-text-stats" class="limo-v2-note">۰ حرف · ۰ کلمه · ۰ خط</div>`;}
  function textStats(){const v=$('mini-text-input')?.value||'';const words=v.trim()?v.trim().split(/\s+/u).length:0;const lines=v? v.split(/\r?\n/).length:0;$('mini-text-stats').textContent=`${v.length.toLocaleString()} حرف · ${words.toLocaleString()} کلمه · ${lines.toLocaleString()} خط`;}
  function miniPicker(){const root=$('mini-workspace');root.innerHTML=`<h3>انتخاب‌گر تصادفی</h3><textarea id="mini-options" class="limo-v2-textarea" placeholder="هر گزینه را در یک خط بنویس"></textarea><button class="limo-v2-btn" onclick="LimoV2.pickOption()">انتخاب کن</button><div id="mini-picked" class="limo-v2-stat"></div>`;}
  function pickOption(){const lines=($('mini-options')?.value||'').split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(!lines.length)return toast('ابتدا چند گزینه وارد کن.');const a=new Uint32Array(1);crypto.getRandomValues(a);$('mini-picked').textContent=lines[a[0]%lines.length];}

  // ------------------------- SCHEDULED MESSAGES -------------------------
  function renderSchedule(){
    featureHeader('Limo Time Capsule · پیام زمان‌دار');
    const c=chat();let targetType='global',targetId='';
    if(activeRoom?.id){targetType='room';targetId=activeRoom.id;}
    else if(c.type==='private'&&c.id){targetType='private';targetId=c.id;}
    else {targetType='global';targetId='';}
    const defaultAt=new Date(Date.now()+3600000);defaultAt.setMinutes(defaultAt.getMinutes()-defaultAt.getTimezoneOffset());
    setBody(`<div class="limo-v2-card"><h3>ارسال در آینده</h3><p class="limo-v2-muted">پیام زمان‌بندی‌شده فقط پس از فعال بودن زمان‌بند دیتابیس ارسال می‌شود. در صورت نبود pg_cron، بازشدن برنامه توسط یک کاربر واردشده می‌تواند پیام‌های سررسیدشده را پردازش کند.</p><input type="hidden" id="schedule-type" value="${targetType}"><input type="hidden" id="schedule-id" value="${targetId}"><div class="limo-v2-note">مقصد انتخاب‌شده: ${targetType==='global'?'گفتگوی عمومی':targetType==='room'?'اتاق جاری Limo World':targetType==='private'?'گفتگوی خصوصی جاری':'ابتدا یک گفتگو باز کن'}</div><textarea id="schedule-body" class="limo-v2-textarea" maxlength="10000" placeholder="متن پیام..."></textarea><label class="limo-v2-muted">تاریخ و ساعت محلی</label><input id="schedule-time" type="datetime-local" class="limo-v2-input" value="${defaultAt.toISOString().slice(0,16)}"><button class="limo-v2-btn" onclick="LimoV2.saveScheduled()">ثبت پیام زمان‌دار</button></div><div class="limo-v2-card"><h3>پیام‌های زمان‌بندی‌شده من</h3><div id="schedule-list">در حال بارگذاری...</div></div>`);
    loadScheduled();
  }
  async function saveScheduled(){
    const type=$('schedule-type')?.value,id=$('schedule-id')?.value||null,body=$('schedule-body')?.value.trim(),raw=$('schedule-time')?.value;
    if(!body)return toast('متن پیام را وارد کن.');if(type!=='global'&&!id)return toast('برای پیام زمان‌دار ابتدا یک گفتگوی خصوصی یا اتاق عمومی باز کن.');if(!raw)return toast('زمان ارسال را تعیین کن.');
    const date=new Date(raw);if(Number.isNaN(date.getTime())||date.getTime()<Date.now()+15000)return toast('زمان ارسال باید حداقل ۱۵ ثانیه بعد باشد.');
    const {error}=await db.from('limo_scheduled_messages').insert({user_id:user().uid,destination_type:type,destination_id:type==='global'?null:id,body,scheduled_at:date.toISOString()});
    if(error)return toast(`ثبت پیام زمان‌دار ناموفق بود: ${error.message}`);$('schedule-body').value='';toast('پیام برای ارسال زمان‌بندی شد.');loadScheduled();
  }
  async function loadScheduled(){const root=$('schedule-list');if(!root)return;const {data,error}=await db.from('limo_scheduled_messages').select('id,destination_type,body,scheduled_at,status,last_error').order('scheduled_at',{ascending:false}).limit(50);if(error){root.textContent=error.message;return;}root.replaceChildren();if(!data?.length){root.textContent='پیام زمان‌بندی‌شده‌ای وجود ندارد.';return;}data.forEach(row=>{const card=document.createElement('div');card.className='limo-v2-note';const text=document.createElement('div');text.textContent=`${row.body}\n${timeLocal(row.scheduled_at)} · ${row.status}`;card.append(text);if(row.status==='pending'){const cancel=document.createElement('button');cancel.className='limo-v2-btn danger';cancel.textContent='لغو';cancel.onclick=async()=>{const {error}=await db.from('limo_scheduled_messages').update({status:'cancelled'}).eq('id',row.id);if(error)toast(error.message);else loadScheduled();};card.append(cancel);}if(row.last_error){const e=document.createElement('small');e.textContent=row.last_error;card.append(e);}root.append(card);});}
  async function dispatchScheduled(){if(!user())return;try{const {error}=await db.rpc('limo_dispatch_scheduled_messages');if(error)console.warn('Schedule dispatcher:',error.message);}catch(e){console.warn(e);}}

  // ------------------------- VOICE NOTES FOR PRIVATE/GLOBAL CHAT -------------------------
  async function startMainVoiceNote(){
    const c=chat();if(!user()||!c.id||!['private','global'].includes(c.type))return toast('برای ضبط پیام صوتی، گفتگوی خصوصی یا عمومی را باز کن.');
    const button=$('voice-record-button');
    if(mainRecorder?.state==='recording'){mainRecorder.stop();button?.classList.remove('recording');button.innerHTML='<i class="fa-solid fa-microphone"></i>';return;}
    if(!await requirePremium('ارسال پیام صوتی')) return;
    if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)return toast('ضبط صدا در این مرورگر پشتیبانی نمی‌شود.');
    try{
      mainRecordingStream=await navigator.mediaDevices.getUserMedia({audio:true});
      const mime=['audio/webm;codecs=opus','audio/webm','audio/mp4','audio/ogg'].find(t=>MediaRecorder.isTypeSupported?.(t));
      mainRecorder=new MediaRecorder(mainRecordingStream,mime?{mimeType:mime}:undefined);const chunks=[];
      mainRecorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};
      mainRecorder.onstop=async()=>{
        mainRecordingStream?.getTracks().forEach(t=>t.stop());mainRecordingStream=null;
        const blob=new Blob(chunks,{type:mainRecorder.mimeType||'audio/webm'});if(blob.size>5*1024*1024)return toast('حجم ویس بیشتر از ۵ مگابایت است.');
        const me=user(),ext=blob.type.includes('mp4')?'m4a':blob.type.includes('ogg')?'ogg':'webm';
        const path=`${c.type==='global'?'global':c.id}/${me.uid}/${crypto.randomUUID()}.${ext}`;
        const safeMime=(blob.type||'audio/webm').split(';')[0];
        const upload=await db.storage.from('chat-media').upload(path,blob,{contentType:safeMime,upsert:false});if(upload.error)return toast(`آپلود ویس ناموفق بود: ${upload.error.message}`);
        const table=c.type==='global'?'global_messages':'messages';const payload={sender_id:me.uid,sender_name:prefs().anonymous?'کاربر ناشناس':(me.displayName||me.username),text:'',attachment_path:path,attachment_type:'audio',attachment_name:'پیام صوتی',attachment_size:blob.size};if(c.type==='private')payload.chat_id=c.id;
        const ttl=Number($('limo-expiry-select')?.value||0);payload.expires_in_seconds=ttl;payload.client_message_id=crypto.randomUUID();
        const {error}=await db.from(table).insert(payload);if(error){await db.storage.from('chat-media').remove([path]);return toast(`ثبت ویس ناموفق بود: ${error.message}`);}
        core.refreshMessages?.(c.id);
      };
      mainRecorder.start();button?.classList.add('recording');button.innerHTML='<i class="fa-solid fa-stop"></i>';toast('در حال ضبط ویس؛ برای پایان و ارسال دوباره دکمه میکروفون را بزن.');
      setTimeout(()=>{if(mainRecorder?.state==='recording'){mainRecorder.stop();button?.classList.remove('recording');button.innerHTML='<i class="fa-solid fa-microphone"></i>';toast('ضبط به سقف ۳ دقیقه رسید.');}},180000);
    }catch(e){console.error(e);toast('دسترسی میکروفون داده نشد.');}
  }

  // ------------------------- PREMIUM / LANGUAGE / PROFILE -------------------------
  function renderInstall(){
    featureHeader('نصب لیموچت');
    setBody(`<div class="limo-v2-card" style="text-align:center"><i class="fa-solid fa-mobile-screen-button" style="font-size:38px;color:var(--primary-dark)"></i><h2>نصب Limo Chat</h2><p class="limo-v2-muted">نسخه وب پیش‌رونده (PWA) را می‌توان در مرورگرهای پشتیبانی‌شده به صفحه اصلی افزود.</p><button class="limo-v2-btn" onclick="LimoV2.installApp()">نصب برنامه</button></div><div class="limo-v2-card"><h3>اندروید</h3><p>منوی Chrome یا مرورگر سازگار را باز کن و گزینه Install app یا Add to Home screen را انتخاب کن.</p><h3>iPhone و iPad</h3><p>در Safari گزینه Share و سپس Add to Home Screen را انتخاب کن.</p></div><div class="limo-v2-note">نصب PWA به‌تنهایی به معنی فعال بودن پیام‌رسانی در پس‌زمینه یا دریافت Push هنگام بسته بودن مرورگر نیست؛ برای آن سرویس Push سمت سرور و تنظیمات سیستم‌عامل لازم است.</div>`);
  }

  function renderPremium(){
    featureHeader('Limo Premium');
    setBody(`<div class="premium-hero"><i class="fa-solid fa-crown" style="font-size:42px;color:var(--primary-dark)"></i><h2 style="margin:8px 0">Limo Premium</h2><p class="limo-v2-muted">اشتراک ویژه لیموچت؛ پیام‌رسانی پایه و امنیت اصلی برای همه رایگان می‌ماند.</p><div id="premium-status" class="limo-v2-stat">در حال بررسی وضعیت حساب…</div></div><div class="limo-v2-card"><h3>امکانات Premium</h3><div class="premium-benefits"><div class="premium-benefit"><i class="fa-regular fa-image"></i> ارسال عکس</div><div class="premium-benefit"><i class="fa-solid fa-video"></i> ارسال ویدئو</div><div class="premium-benefit"><i class="fa-solid fa-microphone"></i> پیام صوتی</div><div class="premium-benefit"><i class="fa-solid fa-cloud-arrow-up"></i> سهمیه رسانه بیشتر</div></div><p class="limo-v2-muted">عکس، فیلم و ویس در گفتگوهای خصوصی، گفتگوی عمومی و اتاق‌های عمومی برای حساب‌های Premium فعال است. سقف حجم و فرمت فایل در برنامه و دیتابیس کنترل می‌شود.</p></div><div class="limo-v2-card"><h3>درخواست خرید یا فعال‌سازی</h3><label for="premium-plan">مدت اشتراک درخواستی</label><select id="premium-plan" class="limo-v2-select"><option value="۱ ماه">۱ ماه</option><option value="۳ ماه">۳ ماه</option><option value="۱۲ ماه">۱۲ ماه</option></select><p class="limo-v2-muted">برای خرید اشتراک، درخواست مستقیماً در گفتگوی داخلی با حساب رسمی @premium در لیموچت ارسال می‌شود.</p><button class="limo-v2-btn" style="width:100%;padding:13px" onclick="LimoV2.requestPremium()"><i class="fa-solid fa-paper-plane"></i> ارسال درخواست در لیموچت به @premium</button><button class="limo-v2-btn secondary" style="width:100%;margin-top:8px" onclick="LimoV2.copyPremiumRequest()">کپی متن درخواست</button></div><div class="limo-v2-note">پرداخت خودکار در سایت فعال نیست. پس از هماهنگی و بررسی پرداخت، مدیر حساب شما را از پنل مدیریت Premium می‌کند. ارسال درخواست به معنی پرداخت یا فعال‌شدن خودکار اشتراک نیست.</div>`);
    refreshPremiumStatus();
  }
  async function refreshPremiumStatus(){
    const el=$('premium-status');if(!el)return;
    try{premiumStatusCache=await isPremium(true);el.textContent=premiumStatusCache?'اشتراک Premium شما فعال است':'حساب شما در طرح رایگان است یا اعتبار Premium پایان یافته است';el.style.color=premiumStatusCache?'var(--primary-dark)':'var(--muted)';}
    catch(error){el.textContent='وضعیت اشتراک دریافت نشد';console.warn(error);}
  }
  function premiumRequestText(){const me=user()||{};const plan=$('premium-plan')?.value||'۱ ماه';return `سلام، برای خرید یا فعال‌سازی اشتراک Limo Premium درخواست دارم.
مدت اشتراک درخواستی: ${plan}
آیدی لیموچت: @${me.username||'نامشخص'}
نام نمایشی: ${me.displayName||'نامشخص'}
شناسه حساب: ${me.uid||'نامشخص'}
لطفاً قیمت، مدت اشتراک و روش پرداخت را اعلام کنید.

لینک لیموچت: https://xdevelopre.github.io/limochat/`;}
  async function requestPremium(){
    const request=premiumRequestText();
    try {
      const {data:target,error}=await db.from('profiles').select('id,username,display_name,avatar_url').eq('username','premium').maybeSingle();
      if(error)throw error;
      if(!target){toast('حساب رسمی @premium هنوز در لیموچت ثبت نشده است؛ درخواست ارسال نشد.');return;}
      await startPrivateChat(target.id,target.display_name||'Limo Premium',target.avatar_url||'');
      const input=$('message-input');
      if(!input){toast('گفتگوی @premium باز شد؛ متن درخواست را کپی و ارسال کن.');await navigator.clipboard?.writeText(request);return;}
      input.value=request;input.dispatchEvent(new Event('input',{bubbles:true}));
      await window.sendMessage();
      toast('درخواست Premium در گفتگوی داخلی @premium ارسال شد.');
    } catch(error){console.error('Premium in-app request:',error);toast('بازکردن گفتگوی @premium ناموفق بود: '+(error.message||'خطای سرور'));}
  }
  async function copyPremiumRequest(){try{await navigator.clipboard.writeText(premiumRequestText());toast('متن درخواست Premium کپی شد.');}catch{toast(premiumRequestText());}}

  function renderLanguage(){
    featureHeader('زبان و جهت نمایش');
    const locale=prefs().locale==='en'?'en':'fa';
    const direction=prefs().direction==='ltr'?'ltr':'rtl';
    setBody(`<div class="limo-v2-card"><h3>Language / زبان برنامه</h3><label>زبان رابط</label><select id="limo-locale" class="limo-v2-select"><option value="fa" ${locale==='fa'?'selected':''}>فارسی</option><option value="en" ${locale==='en'?'selected':''}>English</option></select><label>جهت نمایش مستقل از زبان</label><select id="limo-direction" class="limo-v2-select"><option value="rtl" ${direction==='rtl'?'selected':''}>راست به چپ (RTL)</option><option value="ltr" ${direction==='ltr'?'selected':''}>چپ به راست (LTR)</option></select><button class="limo-v2-btn" onclick="LimoV2.saveLanguage()">ذخیره زبان و جهت</button><p class="limo-v2-muted">تغییر زبان روی برچسب‌های ترجمه‌شده و جهت سند اعمال می‌شود. بخش‌هایی که هنوز ترجمه نشده‌اند با زبان اصلی باقی می‌مانند.</p></div>`);
  }
  async function saveLanguage(){
    const locale=$('limo-locale')?.value==='en'?'en':'fa';
    const direction=$('limo-direction')?.value==='ltr'?'ltr':'rtl';
    try{await core.setPref('locale',locale);await core.setPref('direction',direction);document.documentElement.lang=locale;document.documentElement.dir=direction;applyBasicLocale(locale);toast('زبان و جهت نمایش ذخیره شد.');}
    catch(error){toast('ذخیره تنظیمات زبان ناموفق بود: '+(error.message||''));}
  }
  const basicTranslations={
    'چت‌ها':'Chats','تماس‌ها':'Calls','برنامه‌ها':'Apps','تنظیمات':'Settings','همه':'All','خصوصی':'Private','عمومی':'Public','دستیار':'Assistant','لیمو چت':'Limo Chat','شروع گفتگو':'New chat','جستجوی کاربر':'Search users','زبان برنامه':'App language','حساب و حریم خصوصی':'Account & privacy','حساب کاربری، آیدی و رمز عبور':'Account, username & password','حریم خصوصی و چت ایمن':'Privacy & chat security','کاربران مسدودشده':'Blocked users','جهان لیمو و اتاق‌های عمومی':'Limo World & public rooms','دستیار هوشمند Limo AI':'Limo AI assistant','فضاهای همکاری Limo Space':'Limo Space collaboration','مینی‌اپ‌های لیمو':'Limo Mini apps','پیام‌های زمان‌دار':'Scheduled messages','اشتراک Limo Premium':'Limo Premium subscription','زبان و منطقه':'Language & region','تم مات Aero و ظاهر':'Themes & appearance','اعلان‌ها':'Notifications','جستجوی کاربران و دعوت دوستان':'Find users & invite friends','داده‌ها و ذخیره‌سازی':'Data & storage','درباره لیمو چت':'About Limo Chat','بررسی اتصال و عیب‌یابی':'Connection diagnostics','خروج از حساب':'Sign out','حساب ندارید؟':'No account?','ورود':'Sign in','ثبت‌نام کنید':'Sign up','نام نمایشی':'Display name','بیوگرافی':'Bio','ذخیره نمایه':'Save profile','جستجو':'Search','پیام':'Message','ارسال':'Send','بستن':'Close','ذخیره':'Save','بازگشت':'Back','لغو':'Cancel','تماس':'Call','حذف':'Delete','گزارش':'Report','پروفایل عمومی':'Public profile','شروع گفتگوی خصوصی':'Start private chat','مخاطبان':'Contacts','ساخت گروه':'Create group','ساخت کانال':'Create channel','مدیریت کاربران':'User management','مدیریت گزارش‌ها':'Report management'
  };
  function applyBasicLocale(locale){
    if(locale!=='en')return;
    const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())){const raw=node.nodeValue;const key=raw.trim();if(basicTranslations[key])node.nodeValue=raw.replace(key,basicTranslations[key]);}
    document.querySelectorAll('input[placeholder],textarea[placeholder],button[aria-label]').forEach(el=>{const attr=el.hasAttribute('placeholder')?'placeholder':'aria-label';if(basicTranslations[el.getAttribute(attr)])el.setAttribute(attr,basicTranslations[el.getAttribute(attr)]);});
  }
  function renderProfileId(){
    const me=user();if(!me)return;const publicId=`limo_${me.uid.replaceAll('-','').slice(0,12)}`;const profileUrl=core.getBaseUrl()+`?user=${encodeURIComponent(me.username)}`;
    featureHeader('Limo ID · هویت دیجیتال');
    setBody(`<div class="limo-v2-card" style="text-align:center"><div class="limo-v2-stat">${esc(publicId)}</div><p class="limo-v2-muted">شناسه پایدار حساب؛ برای جستجوی کاربر همچنان از @نام‌کاربری استفاده کن.</p><button class="limo-v2-btn" onclick="LimoV2.copyText('${publicId}')">کپی Limo ID</button><button class="limo-v2-btn secondary" onclick="LimoV2.copyText('${esc(profileUrl)}')">کپی لینک پروفایل</button></div><div class="limo-v2-note">این شناسه از UUID حساب ساخته شده و برای کپی و شناسایی پایدار است. لینک نمایه برای اشتراک‌گذاری آیدی کاربری است؛ گفتگوی مستقیم از جستجوی @نام‌کاربری در برنامه باز می‌شود.</div>`);
  }
  async function copyText(value){try{await navigator.clipboard.writeText(value);toast('کپی شد.');}catch{toast(value);}}

  // ------------------------- OFFLINE OUTBOX -------------------------
  function readOutbox(){try{return JSON.parse(localStorage.getItem(offlineKey())||'[]');}catch{return[];}}
  function writeOutbox(items){localStorage.setItem(offlineKey(),JSON.stringify(items.slice(-100)));}
  const baseSend=window.sendMessage;
  window.sendMessage=async()=>{
    if(navigator.onLine)return baseSend();
    const c=chat(),me=user(),input=$('message-input'),text=input?.value.trim();
    if(!me||!text||!['private','global'].includes(c.type)||!c.id)return toast('صف آفلاین فقط برای گفتگوی خصوصی و عمومی فعال است.');
    const ttl=Number($('limo-expiry-select')?.value||0);
    const queue=readOutbox();queue.push({id:crypto.randomUUID(),type:c.type,chatId:c.id,text,ttl,createdAt:new Date().toISOString()});writeOutbox(queue);input.value='';toast('اینترنت قطع است؛ پیام در صف محلی ذخیره شد و پس از اتصال ارسال می‌شود.');
  };
  async function flushOutbox(){
    if(!navigator.onLine||!user())return;const queue=readOutbox();if(!queue.length)return;
    const remaining=[];
    for(let i=0;i<queue.length;i++){
      const item=queue[i],me=user();let table=item.type==='global'?'global_messages':'messages';const payload={sender_id:me.uid,sender_name:me.displayName||me.username,text:item.text,client_message_id:item.id,expires_in_seconds:Number(item.ttl)||0};if(item.type==='private')payload.chat_id=item.chatId;
      const {error}=await db.from(table).insert(payload);
      if(error && error.code==='23505'){const {data:existing,error:lookupError}=await db.from(table).select('id').eq('sender_id',me.uid).eq('client_message_id',item.id).maybeSingle();if(lookupError||!existing){remaining.push(item,...queue.slice(i+1));toast('بررسی ارسال قبلی پیام ناموفق بود؛ پیام در صف حفظ شد.');break;}}
      else if(error){remaining.push(item,...queue.slice(i+1));toast('بعضی پیام‌های صف آفلاین هنوز ارسال نشدند؛ دوباره تلاش می‌شود.');break;}
    }
    writeOutbox(remaining);if(!remaining.length&&queue.length)toast(`${queue.length} پیام آفلاین ارسال شد.`);
    const c=chat();if(c.id)core.refreshMessages?.(c.id);
  }
  window.addEventListener('online',()=>{toast('اتصال اینترنت برقرار شد.');flushOutbox();dispatchScheduled();});
  window.addEventListener('offline',()=>toast('اینترنت قطع شد؛ پیام‌های متنی قابل صف‌بندی هستند.'));

  // ------------------------- SETTINGS DIAGNOSTICS -------------------------
  function renderDiagnostics(){
    featureHeader('بررسی اتصال و عیب‌یابی');
    setBody(`<div class="limo-v2-card"><h3>وضعیت سرویس‌های لیمو</h3><p class="limo-v2-muted">این صفحه وضعیت نشست و دسترسی واقعی به بخش‌های اصلی Supabase را می‌سنجد. هیچ اطلاعات محرمانه یا کلید مدیریتی نمایش داده نمی‌شود.</p><button class="limo-v2-btn" onclick="LimoV2.runDiagnostics()"><i class="fa-solid fa-rotate"></i> اجرای دوباره آزمایش‌ها</button></div><div id="diagnostic-results" class="limo-v2-card">در حال بررسی…</div><div class="limo-v2-note">نتیجه موفق یعنی درخواست از همین مرورگر پاسخ گرفته است؛ این آزمایش جای تست بار، ممیزی امنیتی یا بررسی تنظیمات داشبورد Supabase را نمی‌گیرد.</div>`);
    runDiagnostics();
  }
  async function runDiagnostics(){
    const root=$('diagnostic-results');if(!root)return;root.textContent='در حال اجرای آزمایش‌ها…';
    const results=[];const add=(name,ok,detail)=>results.push({name,ok,detail:String(detail||'')});
    add('اتصال اینترنت',navigator.onLine,navigator.onLine?'مرورگر آنلاین است.':'مرورگر حالت آفلاین را گزارش می‌کند.');
    const me=user();add('نشست کاربر',!!me?.uid,me?.username?`واردشده با @${me.username}`:'نشست فعال کاربری پیدا نشد.');
    if(me?.uid){
      const tests=[
        ['پروفایل کاربر',()=>db.from('profiles').select('id,username,is_premium,premium_expires_at,is_suspended').eq('id',me.uid).single(),d=>`@${d.username||me.username} · ${d.is_premium&&(!d.premium_expires_at||Date.parse(d.premium_expires_at)>Date.now())?'Premium':'Free'} · ${d.is_suspended?'تعلیق‌شده':'فعال'}`],
        ['تنظیمات ذخیره‌شده',()=>db.from('user_settings').select('user_id').eq('user_id',me.uid).maybeSingle(),d=>d?'رکورد تنظیمات در دیتابیس موجود است.':'رکوردی هنوز ساخته نشده؛ اولین تغییر تنظیمات آن را ایجاد می‌کند.'],
        ['جدول گفتگوی عمومی',()=>db.from('global_messages').select('id',{count:'exact',head:true}),d=>`دسترسی خواندن موفق · ${d.count??'تعداد نامشخص'} پیام`],
        ['فهرست اتاق‌های World',()=>db.from('limo_public_rooms').select('id',{count:'exact',head:true}).eq('is_public',true).eq('is_archived',false),d=>`دسترسی خواندن موفق · ${d.count??'تعداد نامشخص'} اتاق`],
        ['فضاهای همکاری',()=>db.from('limo_spaces').select('id',{count:'exact',head:true}),d=>`دسترسی خواندن موفق · ${d.count??'تعداد نامشخص'} فضا`]
      ];
      for(const [name,call,format] of tests){try{const {data,error,count}=await call();if(error)throw error;add(name,true,format({data,count}));}catch(error){add(name,false,error.message||'درخواست ناموفق بود.');}}
    }else add('دیتابیس کاربر',false,'برای آزمایش جدول‌ها ابتدا وارد حساب شوید.');
    add('Service Worker',!!navigator.serviceWorker?.controller,navigator.serviceWorker?.controller?'پوسته برنامه تحت کنترل Service Worker است.':'هنوز کنترل فعال ندارد؛ صفحه را پس از انتشار با HTTPS دوباره باز کن.');
    add('اعلان مرورگر','Notification' in window,('Notification' in window)?`مجوز مرورگر: ${Notification.permission}`:'این مرورگر API اعلان را پشتیبانی نمی‌کند.');
    root.replaceChildren();const summary=document.createElement('div');summary.className='limo-v2-stat';const passed=results.filter(x=>x.ok).length;summary.textContent=`${passed} از ${results.length} آزمایش موفق`;root.append(summary);
    results.forEach(result=>{const row=document.createElement('div');row.className='setting-line';const left=document.createElement('span');left.textContent=result.name;const badge=document.createElement('b');badge.textContent=result.ok?'موفق':'ناموفق';badge.style.color=result.ok?'#278a39':'#c43a3a';row.append(left,badge);const detail=document.createElement('small');detail.className='limo-v2-muted';detail.style.display='block';detail.style.width='100%';detail.textContent=result.detail;root.append(row,detail);});
  }

  // ------------------------- APP INSTALL / STATUS -------------------------
  let installPrompt=null;
  window.addEventListener('beforeinstallprompt',event=>{event.preventDefault();installPrompt=event;});
  async function installApp(){if(!installPrompt)return toast('برای نصب، از منوی مرورگر گزینه Add to Home Screen را انتخاب کن.');installPrompt.prompt();await installPrompt.userChoice;installPrompt=null;}

  // Expose a very small, explicit feature API for static HTML handlers.
  window.LimoV2={
    renderWorld,loadWorld,filterWorld,openCreateRoom,closeCreateRoom,createRoom,openRoom,sendRoomMessage,leaveRoom,createPoll,toggleRoomVoice,beginRoomExpiryHold,endRoomExpiryHold,cancelRoomExpiryHold,handleRoomSendClick,openRoomExpiryMenu,closeRoomExpiryMenu,setRoomMessageExpiry,
    renderSpace,createSpace,joinSpace,copySpaceInvite,addTask,addNote,renderAI,aiSummarize,aiTasks,aiLinks,aiSearch,aiReply,copyAI,
    renderMini,miniDice,miniCalculator,calcRun,miniText,textStats,miniPicker,pickOption,
    renderSchedule,saveScheduled,renderPremium,renderLanguage,saveLanguage,renderProfileId,renderInstall,renderDiagnostics,runDiagnostics,copyText,startMainVoiceNote,applyBasicLocale,openUser,chooseRoomMedia,uploadRoomMedia,requestPremium,copyPremiumRequest,startPrivateChat,loadOlderRoomMessages,
    installApp,flushOutbox,loadRoomMessages
  };

  const featureRender=(key)=>{
    if(needAuth())return true;
    const pages={world:renderWorld,space:renderSpace,ai:renderAI,mini:renderMini,schedule:renderSchedule,premium:renderPremium,language:renderLanguage,limoid:renderProfileId,install:renderInstall,diagnostics:renderDiagnostics};
    if(pages[key]){pages[key]();return true;}return false;
  };
  window.renderSubMenu=(key)=>{try{if(featureRender(key))return;baseRender(key);}catch(error){console.error('Settings page failed:',key,error);featureHeader('خطا در بارگذاری تنظیمات');setBody(`<div class="limo-v2-card"><h3>این بخش بارگذاری نشد</h3><p class="limo-v2-muted">${esc(error?.message||'خطای نامشخص')}</p><button class="limo-v2-btn secondary" onclick="LimoV2.renderWorld()">بازگشت به جهان لیمو</button></div>`);}};
  window.startLimoVoiceNote=startMainVoiceNote;

  document.documentElement.lang=prefs().locale==='en'?'en':'fa';document.documentElement.dir=prefs().direction==='ltr'?'ltr':'rtl';if(prefs().locale==='en')applyBasicLocale('en');const localeObserver=new MutationObserver(()=>{if(prefs().locale==='en')applyBasicLocale('en');});localeObserver.observe(document.body,{childList:true,subtree:true,characterData:true});

  // On sign-in, attempt due scheduled messages and queued text. This is not a push daemon:
  // the client must be open unless pg_cron is enabled in the Supabase project.
  setTimeout(()=>{if(user()){dispatchScheduled();flushOutbox();}},1200);
  let userShortcutHandled=false;
  const openShortcut=async()=>{
    if(!user())return;
    const params=new URLSearchParams(location.search);
    if(params.get('open')==='world'){window.openSubMenu?.('world');return;}
    const username=String(params.get('user')||'').replace(/^@/,'').trim().toLowerCase();
    if(!username||userShortcutHandled)return;
    userShortcutHandled=true;
    try{
      const {data,error}=await db.from('profiles').select('id,username,display_name,avatar_url').eq('username',username).maybeSingle();
      if(error)throw error;
      if(!data){toast('این پروفایل پیدا نشد یا نمایش عمومی آن غیرفعال است.');return;}
      if(data.id===user().uid)core.openSubMenu?.('account');
      else if(typeof window.startPrivateChat==='function')await window.startPrivateChat(data.id,data.display_name||data.username,data.avatar_url);
      else toast('امکان بازکردن گفتگوی خصوصی فراهم نشد.');
    }catch(error){console.warn('Profile shortcut:',error);toast('بازکردن پروفایل ناموفق بود؛ دوباره تلاش کن.');}
    finally{history.replaceState({},'',location.pathname+location.hash);}
  };
  window.addEventListener('limo:session-ready',openShortcut);
  setTimeout(openShortcut,1800);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&user()){dispatchScheduled();flushOutbox();}});
})();
