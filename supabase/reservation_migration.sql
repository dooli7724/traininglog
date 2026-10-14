-- 예약·대기만 추가하는 마이그레이션
-- schema.sql 전체는 실행하지 마세요. 이 파일만 SQL Editor에 붙여 Run 하면 됩니다.
-- 기존 gyms, gym_state, member_logs 는 그대로 둡니다.
-- 여러 번 실행해도 됩니다.
-- 함수 본문은 이름 있는 달러 인용입니다. 본문 안에는 달러 기호가 없습니다.

-- 1:1 수업 오픈 · 예약 · 대기
-- 회원은 로그인 계정이 없고 공유 링크로 들어오므로 client_id 는 auth.users 가 아니라 회원 id(text) 입니다.
-- 확정/대기/취소 승계는 RPC 한 트랜잭션에서만 바뀝니다.
-- 알림은 booking_notices 에 쌓입니다. 화면 배지는 unread, 이후 푸시는 이 테이블을 구독하면 됩니다.

create table if not exists public.schedules (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references auth.users(id) on delete cascade,
  start_time timestamptz not null,
  end_time timestamptz not null,
  status text not null default 'available' check (status in ('available', 'booked', 'closed')),
  cancel_hours int not null default 6 check (cancel_hours >= 0 and cancel_hours <= 72),
  created_at timestamptz not null default timezone('utc'::text, now())
);

alter table public.schedules add column if not exists cancel_hours int not null default 6;

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  client_id text not null,
  member_share text not null default '',
  member_name text not null default '',
  status text not null check (status in ('confirmed', 'waiting', 'cancelled')),
  waiting_order int not null default 0,
  created_at timestamptz not null default timezone('utc'::text, now()),
  cancelled_at timestamptz
);

alter table public.reservations add column if not exists member_share text not null default '';
alter table public.reservations add column if not exists member_name text not null default '';
alter table public.reservations add column if not exists contact text not null default '';
alter table public.reservations add column if not exists cancel_token text;
alter table public.reservations add column if not exists cancelled_at timestamptz;

create table if not exists public.booking_notices (
  id uuid primary key default gen_random_uuid(),
  audience text not null check (audience in ('coach', 'member')),
  coach_id uuid not null references auth.users(id) on delete cascade,
  member_id text,
  member_share text,
  schedule_id uuid references public.schedules(id) on delete cascade,
  reservation_id uuid references public.reservations(id) on delete set null,
  kind text not null check (kind in ('booked', 'waiting', 'cancelled', 'promoted', 'closed')),
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default timezone('utc'::text, now())
);

create index if not exists schedules_coach_time_idx on public.schedules (coach_id, start_time);
create index if not exists reservations_slot_idx on public.reservations (schedule_id, status, waiting_order);
create unique index if not exists reservations_one_active_per_client
  on public.reservations (schedule_id, client_id)
  where status in ('confirmed', 'waiting');
create index if not exists booking_notices_coach_idx on public.booking_notices (coach_id, created_at desc);
create unique index if not exists reservations_cancel_token_idx
  on public.reservations (cancel_token)
  where cancel_token is not null;
create index if not exists booking_notices_member_idx on public.booking_notices (member_share, created_at desc);

alter table public.schedules enable row level security;
alter table public.reservations enable row level security;
alter table public.booking_notices enable row level security;

do $mig$
declare pol record;
begin
  for pol in
    select policyname, tablename
    from pg_policies
    where schemaname = 'public'
      and tablename in ('schedules', 'reservations', 'booking_notices')
  loop
    execute format('drop policy if exists %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end $mig$;

create policy schedules_coach_select on public.schedules
  for select to authenticated
  using (coach_id = auth.uid());
create policy schedules_coach_insert on public.schedules
  for insert to authenticated
  with check (coach_id = auth.uid());
create policy schedules_coach_update on public.schedules
  for update to authenticated
  using (coach_id = auth.uid())
  with check (coach_id = auth.uid());
create policy schedules_coach_delete on public.schedules
  for delete to authenticated
  using (coach_id = auth.uid());

create policy reservations_coach_select on public.reservations
  for select to authenticated
  using (
    exists (
      select 1 from public.schedules s
      where s.id = schedule_id and s.coach_id = auth.uid()
    )
  );

create policy booking_notices_coach_select on public.booking_notices
  for select to authenticated
  using (audience = 'coach' and coach_id = auth.uid());
create policy booking_notices_coach_update on public.booking_notices
  for update to authenticated
  using (audience = 'coach' and coach_id = auth.uid())
  with check (audience = 'coach' and coach_id = auth.uid());

create or replace function public._booking_member(p_ref text)
returns table (
  member_id text,
  member_name text,
  member_share text,
  coach_id uuid,
  gym_id uuid
)
language sql
stable
security definer
set search_path = public
as $mig$
  select
    e->>'id',
    coalesce(nullif(e->>'name', ''), '회원'),
    e->>'share',
    coalesce(s.user_id, g.owner_id),
    g.id
  from public.gym_state s
  join public.gyms g on g.id = s.gym_id,
       jsonb_array_elements(coalesce(s.data->'members', '[]'::jsonb)) e
  where (e->>'share' = btrim(p_ref) or e->>'id' = btrim(p_ref))
    and coalesce(e->>'id', '') <> ''
    and coalesce(e->>'share', '') <> ''
  limit 1;
$mig$;

create or replace function public._booking_notice(
  p_audience text,
  p_coach uuid,
  p_member_id text,
  p_share text,
  p_schedule uuid,
  p_reservation uuid,
  p_kind text,
  p_title text,
  p_body text
)
returns void
language sql
security definer
set search_path = public
as $mig$
  insert into public.booking_notices (
    audience, coach_id, member_id, member_share, schedule_id, reservation_id, kind, title, body
  ) values (
    p_audience, p_coach, p_member_id, p_share, p_schedule, p_reservation, p_kind, p_title, coalesce(p_body, '')
  );
$mig$;

create or replace function public._renumber_waitlist(p_schedule uuid)
returns void
language plpgsql
security definer
set search_path = public
as $mig$
begin
  with ranked as (
    select id, row_number() over (order by waiting_order, created_at) as n
    from public.reservations
    where schedule_id = p_schedule and status = 'waiting'
  )
  update public.reservations r
  set waiting_order = ranked.n
  from ranked
  where r.id = ranked.id
    and r.waiting_order is distinct from ranked.n;
end;
$mig$;

create or replace function public._slot_label(p_start timestamptz)
returns text
language sql
stable
as $mig$
  select to_char(p_start at time zone 'Asia/Seoul', 'FMMM/FMDD HH24:MI');
$mig$;

create or replace function public.open_schedule(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  sid uuid;
  local_start timestamp;
  local_end timestamp;
  piece record;
  created int := 0;
  skipped_past int := 0;
  skipped_overlap int := 0;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception '종료 시간은 시작 시간보다 뒤여야 합니다';
  end if;
  if p_end - p_start < interval '15 minutes' then
    raise exception '수업은 15분 이상이어야 합니다';
  end if;
  if p_end - p_start <= interval '90 minutes' then
    if p_start <= now() then
      raise exception '이미 지난 시간은 오픈할 수 없습니다';
    end if;
    if exists (
      select 1 from public.schedules s
      where s.coach_id = uid
        and s.status <> 'closed'
        and s.start_time < p_end
        and s.end_time > p_start
    ) then
      raise exception '이미 겹치는 오픈 시간이 있습니다';
    end if;
    insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
    values (uid, p_start, p_end, 'available', 6)
    returning id into sid;
    return jsonb_build_object('id', sid, 'status', 'available', 'created', 1);
  end if;

  local_start := p_start at time zone 'Asia/Seoul';
  local_end := p_end at time zone 'Asia/Seoul';
  if local_start::date <> local_end::date then
    raise exception '하루 안에서만 열 수 있습니다';
  end if;
  for piece in
    select * from public._slot_grid(local_start::date, local_start::time, local_end::time, 60)
  loop
    if piece.is_past then
      skipped_past := skipped_past + 1;
    elsif exists (
      select 1 from public.schedules s
      where s.coach_id = uid
        and s.status <> 'closed'
        and s.start_time < piece.slot_end
        and s.end_time > piece.slot_start
    ) then
      skipped_overlap := skipped_overlap + 1;
    else
      insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
      values (uid, piece.slot_start, piece.slot_end, 'available', 6);
      created := created + 1;
    end if;
  end loop;
  if created = 0 then
    raise exception '나눌 수 있는 시간이 없습니다';
  end if;
  return jsonb_build_object(
    'created', created,
    'skipped_past', skipped_past,
    'skipped_overlap', skipped_overlap,
    'status', 'available'
  );
end;
$mig$;

create or replace function public._close_coach_slot(p_schedule_id uuid, p_quiet boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  n int := 0;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.coach_id <> uid then
    raise exception '본인이 연 시간만 마감할 수 있습니다';
  end if;
  if slot.status = 'closed' then
    return;
  end if;
  update public.schedules set status = 'closed' where id = slot.id;
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in ('confirmed', 'waiting')
    for update
  loop
    n := n + 1;
    update public.reservations
    set status = 'cancelled', waiting_order = 0, cancelled_at = now()
    where id = rec.id;
    perform public._booking_notice(
      'member', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      'closed', '수업 시간이 마감되었습니다',
      public._slot_label(slot.start_time) || ' 수업이 마감되어 예약이 취소되었습니다.'
    );
  end loop;
  if n > 0 or not coalesce(p_quiet, false) then
    perform public._booking_notice(
      'coach', slot.coach_id, null, null, slot.id, null,
      'closed', '시간을 마감했습니다',
      public._slot_label(slot.start_time) || ' 시간을 마감했습니다.'
    );
  end if;
end;
$mig$;

create or replace function public.close_schedule(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
begin
  perform public._close_coach_slot(p_schedule_id, false);
  return jsonb_build_object('id', p_schedule_id, 'status', 'closed');
end;
$mig$;

-- 한국 시간 기준. 수업 길이만큼 잘라 미래 슬롯만 후보로 돌려줍니다.
create or replace function public._slot_grid(p_date date, p_start time, p_end time, p_minutes int)
returns table(slot_start timestamptz, slot_end timestamptz, is_past boolean)
language plpgsql
stable
set search_path = public
as $mig$
declare
  cursor_ts timestamp;
  day_end timestamp;
  s timestamptz;
  e timestamptz;
  lesson_minutes int;
  step_minutes int;
begin
  if p_minutes not in (30, 50, 60, 90) then
    raise exception '수업 길이는 30, 50, 60, 90분 중에서 고르세요';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception '종료 시간은 시작 시간보다 뒤여야 합니다';
  end if;
  lesson_minutes := p_minutes;
  step_minutes := case when p_minutes = 50 then 60 else p_minutes end;
  if (p_end - p_start) < make_interval(mins => lesson_minutes) then
    raise exception '시간 범위가 수업 길이보다 짧습니다';
  end if;
  cursor_ts := p_date + p_start;
  day_end := p_date + p_end;
  while cursor_ts + make_interval(mins => lesson_minutes) <= day_end loop
    s := cursor_ts at time zone 'Asia/Seoul';
    e := (cursor_ts + make_interval(mins => lesson_minutes)) at time zone 'Asia/Seoul';
    slot_start := s;
    slot_end := e;
    is_past := s <= now();
    return next;
    cursor_ts := cursor_ts + make_interval(mins => step_minutes);
  end loop;
end;
$mig$;

create or replace function public.open_schedule_range(
  p_from date,
  p_to date,
  p_weekdays int[],
  p_start time,
  p_end time,
  p_minutes int
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  d date;
  dow int;
  slot record;
  created int := 0;
  skipped_past int := 0;
  skipped_overlap int := 0;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception '종료일은 시작일보다 뒤여야 합니다';
  end if;
  if (p_to - p_from) > 92 then
    raise exception '한 번에 최대 3개월까지 열 수 있습니다';
  end if;
  if p_weekdays is null or cardinality(p_weekdays) = 0 then
    raise exception '요일을 선택해 주세요';
  end if;
  if exists (select 1 from unnest(p_weekdays) w where w < 0 or w > 6) then
    raise exception '요일 값이 올바르지 않습니다';
  end if;

  d := p_from;
  while d <= p_to loop
    dow := extract(dow from d)::int;
    if dow = any (p_weekdays) then
      for slot in
        select * from public._slot_grid(d, p_start, p_end, p_minutes)
      loop
        if slot.is_past then
          skipped_past := skipped_past + 1;
        elsif exists (
          select 1 from public.schedules s
          where s.coach_id = uid
            and s.status <> 'closed'
            and s.start_time < slot.slot_end
            and s.end_time > slot.slot_start
        ) then
          skipped_overlap := skipped_overlap + 1;
        else
          if created >= 800 then
            raise exception '한 번에 800개까지만 열 수 있습니다. 기간을 나눠 주세요';
          end if;
          insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
          values (uid, slot.slot_start, slot.slot_end, 'available', 6);
          created := created + 1;
        end if;
      end loop;
    end if;
    d := d + 1;
  end loop;

  if created = 0 and skipped_past = 0 and skipped_overlap = 0 then
    raise exception '선택한 요일에 해당하는 날이 없습니다';
  end if;

  return jsonb_build_object(
    'created', created,
    'skipped_past', skipped_past,
    'skipped_overlap', skipped_overlap
  );
end;
$mig$;

create or replace function public.override_schedule_day(
  p_date date,
  p_mode text,
  p_start time,
  p_end time,
  p_minutes int,
  p_cancel_booked boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  booked_hit int := 0;
  closed_n int := 0;
  created_n int := 0;
  skipped_overlap int := 0;
  rec record;
  slot record;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if p_date is null then
    raise exception '날짜를 선택해 주세요';
  end if;
  if p_mode not in ('closed', 'hours') then
    raise exception '처리할 수 없는 예외입니다';
  end if;

  perform 1
  from public.schedules s
  where s.coach_id = uid
    and s.status <> 'closed'
    and (s.start_time at time zone 'Asia/Seoul')::date = p_date
  for update;

  if p_mode = 'closed' then
    select count(*) into booked_hit
    from public.reservations r
    join public.schedules s on s.id = r.schedule_id
    where s.coach_id = uid
      and s.status <> 'closed'
      and s.start_time > now()
      and (s.start_time at time zone 'Asia/Seoul')::date = p_date
      and r.status in ('confirmed', 'waiting');
    if booked_hit > 0 and not coalesce(p_cancel_booked, false) then
      raise exception '%', format('이 날짜에 예약 %s건이 있습니다', booked_hit);
    end if;
    for rec in
      select s.id
      from public.schedules s
      where s.coach_id = uid
        and s.status <> 'closed'
        and s.start_time > now()
        and (s.start_time at time zone 'Asia/Seoul')::date = p_date
    loop
      perform public._close_coach_slot(rec.id, true);
      closed_n := closed_n + 1;
    end loop;
    if closed_n = 0 then
      raise exception '그 날짜에 마감할 열린 시간이 없습니다';
    end if;
    return jsonb_build_object('closed', closed_n, 'created', 0, 'cancelled_bookings', booked_hit);
  end if;

  if p_minutes is null then
    p_minutes := 60;
  end if;

  select count(*) into booked_hit
  from public.reservations r
  join public.schedules s on s.id = r.schedule_id
  where s.coach_id = uid
    and s.status <> 'closed'
    and s.start_time > now()
    and (s.start_time at time zone 'Asia/Seoul')::date = p_date
    and r.status in ('confirmed', 'waiting')
    and not exists (
      select 1 from public._slot_grid(p_date, p_start, p_end, p_minutes) g
      where g.is_past = false
        and g.slot_start = s.start_time
        and g.slot_end = s.end_time
    );
  if booked_hit > 0 and not coalesce(p_cancel_booked, false) then
    raise exception '%', format('이 날짜에 예약 %s건이 있습니다', booked_hit);
  end if;

  for rec in
    select s.id
    from public.schedules s
    where s.coach_id = uid
      and s.status <> 'closed'
      and s.start_time > now()
      and (s.start_time at time zone 'Asia/Seoul')::date = p_date
      and not exists (
        select 1 from public._slot_grid(p_date, p_start, p_end, p_minutes) g
        where g.is_past = false
          and g.slot_start = s.start_time
          and g.slot_end = s.end_time
      )
  loop
    perform public._close_coach_slot(rec.id, true);
    closed_n := closed_n + 1;
  end loop;

  for slot in
    select * from public._slot_grid(p_date, p_start, p_end, p_minutes)
    where is_past = false
  loop
    if exists (
      select 1 from public.schedules s
      where s.coach_id = uid
        and s.status <> 'closed'
        and s.start_time < slot.slot_end
        and s.end_time > slot.slot_start
    ) then
      skipped_overlap := skipped_overlap + 1;
    else
      insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
      values (uid, slot.slot_start, slot.slot_end, 'available', 6);
      created_n := created_n + 1;
    end if;
  end loop;

  if closed_n = 0 and created_n = 0 and skipped_overlap = 0 then
    raise exception '바꿀 시간이 없습니다. 지난 시간이거나 범위가 너무 짧습니다';
  end if;

  return jsonb_build_object(
    'closed', closed_n,
    'created', created_n,
    'skipped_overlap', skipped_overlap,
    'cancelled_bookings', booked_hit
  );
end;
$mig$;

create or replace function public.book_slot(p_share text, p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  mem record;
  slot public.schedules%rowtype;
  has_confirmed boolean;
  next_order int;
  rid uuid;
  new_status text;
  label text;
begin
  select * into mem from public._booking_member(p_share);
  if mem.member_id is null then
    raise exception '회원 정보를 찾을 수 없습니다';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.coach_id is distinct from mem.coach_id then
    raise exception '이 트레이너의 시간이 아닙니다';
  end if;
  if slot.status = 'closed' then
    raise exception '마감된 시간입니다';
  end if;
  if slot.start_time <= now() then
    raise exception '이미 시작된 수업은 예약할 수 없습니다';
  end if;
  if exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id
      and r.client_id = mem.member_id
      and r.status in ('confirmed', 'waiting')
  ) then
    raise exception '이미 이 시간을 예약했거나 대기 중입니다';
  end if;

  select exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = 'confirmed'
  ) into has_confirmed;

  label := public._slot_label(slot.start_time);
  if not has_confirmed then
    new_status := 'confirmed';
    next_order := 0;
    update public.schedules set status = 'booked' where id = slot.id;
  else
    new_status := 'waiting';
    select coalesce(max(r.waiting_order), 0) + 1 into next_order
    from public.reservations r
    where r.schedule_id = slot.id and r.status = 'waiting';
  end if;

  insert into public.reservations (
    schedule_id, client_id, member_share, member_name, status, waiting_order
  ) values (
    slot.id, mem.member_id, mem.member_share, mem.member_name, new_status, next_order
  ) returning id into rid;

  if new_status = 'confirmed' then
    perform public._booking_notice(
      'member', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      'booked', '예약이 확정되었습니다', label || ' 수업이 확정되었습니다.'
    );
    perform public._booking_notice(
      'coach', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      'booked', mem.member_name || ' 님 예약', label || ' 수업이 확정되었습니다.'
    );
  else
    perform public._booking_notice(
      'member', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      'waiting', '대기 ' || next_order || '순위로 신청되었습니다',
      label || ' 수업은 이미 예약되어 대기 ' || next_order || '순위입니다. 앞 순번이 취소되면 자동으로 확정됩니다.'
    );
    perform public._booking_notice(
      'coach', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      'waiting', mem.member_name || ' 님 대기 ' || next_order || '순위',
      label || ' 수업에 대기가 추가되었습니다.'
    );
  end if;

  return jsonb_build_object('id', rid, 'status', new_status, 'waiting_order', next_order);
end;
$mig$;

create or replace function public.cancel_reservation(p_share text, p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  mem record;
  sid uuid;
  slot public.schedules%rowtype;
  res public.reservations%rowtype;
  promoted_id uuid;
  promoted_name text;
  promoted_share text;
  promoted_member text;
  label text;
  is_coach boolean := false;
begin
  select r.schedule_id into sid
  from public.reservations r
  where r.id = p_reservation_id;
  if sid is null then
    raise exception '예약을 찾을 수 없습니다';
  end if;

  select * into slot from public.schedules where id = sid for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  select * into res from public.reservations where id = p_reservation_id for update;
  if not found or res.status = 'cancelled' then
    raise exception '이미 취소된 예약입니다';
  end if;

  if p_share is not null and length(btrim(p_share)) >= 4 then
    select * into mem from public._booking_member(p_share);
    if mem.member_id is null or mem.member_id <> res.client_id then
      raise exception '본인 예약만 취소할 수 있습니다';
    end if;
    if slot.start_time <= now() then
      raise exception '이미 시작된 수업은 취소할 수 없습니다';
    end if;
    if res.status = 'confirmed'
       and slot.start_time - make_interval(hours => coalesce(slot.cancel_hours, 6)) <= now() then
      raise exception '%', format('수업 시작 %s시간 전까지만 취소할 수 있습니다', coalesce(slot.cancel_hours, 6));
    end if;
  elsif uid is not null and uid = slot.coach_id then
    is_coach := true;
  else
    raise exception '취소 권한이 없습니다';
  end if;

  update public.reservations
  set status = 'cancelled', waiting_order = 0, cancelled_at = now()
  where id = res.id;

  label := public._slot_label(slot.start_time);

  if res.status = 'confirmed' and slot.status <> 'closed' and slot.start_time > now() then
    select r.id, r.member_name, r.member_share, r.client_id
      into promoted_id, promoted_name, promoted_share, promoted_member
    from public.reservations r
    where r.schedule_id = slot.id
      and r.status = 'waiting'
    order by r.waiting_order asc, r.created_at asc
    limit 1
    for update;

    if promoted_id is not null then
      update public.reservations
      set status = 'confirmed', waiting_order = 0
      where id = promoted_id;
      perform public._booking_notice(
        'member', slot.coach_id, promoted_member, promoted_share, slot.id, promoted_id,
        'promoted', '대기에서 예약이 확정되었습니다',
        label || ' 수업이 확정되었습니다. 앞 순번 취소로 자동 승계되었습니다.'
      );
      perform public._booking_notice(
        'coach', slot.coach_id, promoted_member, promoted_share, slot.id, promoted_id,
        'promoted', promoted_name || ' 님 자동 확정',
        label || ' 빈자리로 ' || promoted_name || ' 님이 확정되었습니다.'
      );
    end if;
  end if;

  perform public._renumber_waitlist(slot.id);

  if not exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = 'confirmed'
  ) and slot.status = 'booked' then
    update public.schedules set status = 'available' where id = slot.id;
  end if;

  perform public._booking_notice(
    'member', slot.coach_id, res.client_id, res.member_share, slot.id, res.id,
    'cancelled', '예약이 취소되었습니다',
    label || ' 예약이 취소되었습니다.'
  );
  perform public._booking_notice(
    'coach', slot.coach_id, res.client_id, res.member_share, slot.id, res.id,
    'cancelled', res.member_name || ' 님 취소',
    label || ' 예약이 취소되었습니다.' ||
    case when promoted_id is not null then ' ' || promoted_name || ' 님이 확정으로 올라갔습니다.' else '' end
  );

  return jsonb_build_object(
    'cancelled_id', res.id,
    'promoted', case
      when promoted_id is null then null
      when is_coach then jsonb_build_object('id', promoted_id, 'name', promoted_name)
      else jsonb_build_object('ok', true)
    end
  );
end;
$mig$;

create or replace function public.booking_board(p_share text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  mem record;
  slots jsonb;
  notes jsonb;
  unread int;
begin
  if p_share is not null and length(btrim(p_share)) >= 4 then
    select * into mem from public._booking_member(p_share);
    if mem.member_id is null then
      raise exception '회원 정보를 찾을 수 없습니다';
    end if;

    select coalesce(jsonb_agg(x.slot order by x.start_time), '[]'::jsonb)
      into slots
    from (
      select s.start_time,
        jsonb_build_object(
          'id', s.id,
          'start_time', s.start_time,
          'end_time', s.end_time,
          'status', s.status,
          'cancel_hours', s.cancel_hours,
          'has_confirmed', exists (
            select 1 from public.reservations r
            where r.schedule_id = s.id and r.status = 'confirmed'
          ),
          'wait_count', (
            select count(*) from public.reservations r
            where r.schedule_id = s.id and r.status = 'waiting'
          ),
          'mine', (
            select jsonb_build_object(
              'id', r.id,
              'status', r.status,
              'waiting_order', r.waiting_order
            )
            from public.reservations r
            where r.schedule_id = s.id
              and r.client_id = mem.member_id
              and r.status in ('confirmed', 'waiting')
            limit 1
          )
        ) as slot
      from public.schedules s
      where s.coach_id = mem.coach_id
        and s.status <> 'closed'
        and s.end_time > now()
    ) x;

    select count(*) into unread
    from public.booking_notices n
    where n.audience = 'member'
      and n.member_share = mem.member_share
      and n.read_at is null;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body,
      'created_at', n.created_at, 'read_at', n.read_at
    ) order by n.created_at desc), '[]'::jsonb)
      into notes
    from (
      select * from public.booking_notices
      where audience = 'member' and member_share = mem.member_share
      order by created_at desc
      limit 20
    ) n;

    return jsonb_build_object('role', 'member', 'unread', unread, 'notices', notes, 'slots', slots);
  end if;

  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;

  select coalesce(jsonb_agg(x.slot order by x.start_time), '[]'::jsonb)
    into slots
  from (
    select s.start_time,
      jsonb_build_object(
        'id', s.id,
        'start_time', s.start_time,
        'end_time', s.end_time,
        'status', s.status,
        'cancel_hours', s.cancel_hours,
        'reservations', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', r.id,
            'client_id', r.client_id,
            'name', r.member_name,
            'contact', r.contact,
            'status', r.status,
            'waiting_order', r.waiting_order
          ) order by case r.status when 'confirmed' then 0 when 'waiting' then 1 else 2 end, r.waiting_order, r.created_at)
          from public.reservations r
          where r.schedule_id = s.id and r.status <> 'cancelled'
        ), '[]'::jsonb),
        'completed', s.end_time <= now() and exists (
          select 1 from public.reservations r
          where r.schedule_id = s.id and r.status = 'confirmed'
        ),
        'missed', s.end_time <= now() and s.status <> 'closed' and not exists (
          select 1 from public.reservations r
          where r.schedule_id = s.id and r.status = 'confirmed'
        )
      ) as slot
    from public.schedules s
    where s.coach_id = uid
      and s.end_time > now() - interval '400 days'
  ) x;

  select count(*) into unread
  from public.booking_notices n
  where n.audience = 'coach' and n.coach_id = uid and n.read_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body,
    'created_at', n.created_at, 'read_at', n.read_at
  ) order by n.created_at desc), '[]'::jsonb)
    into notes
  from (
    select * from public.booking_notices
    where audience = 'coach' and coach_id = uid
    order by created_at desc
    limit 20
  ) n;

  return jsonb_build_object('role', 'coach', 'unread', unread, 'notices', notes, 'slots', slots);
end;
$mig$;

create or replace function public.read_booking_notices(p_share text)
returns void
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  mem record;
begin
  if p_share is not null and length(btrim(p_share)) >= 4 then
    select * into mem from public._booking_member(p_share);
    if mem.member_id is null then
      raise exception '회원 정보를 찾을 수 없습니다';
    end if;
    update public.booking_notices
    set read_at = now()
    where audience = 'member'
      and member_share = mem.member_share
      and read_at is null;
    return;
  end if;
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  update public.booking_notices
  set read_at = now()
  where audience = 'coach' and coach_id = uid and read_at is null;
end;
$mig$;

revoke all on function public._booking_member(text) from public, anon, authenticated;
revoke all on function public._booking_notice(text, uuid, text, text, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public._renumber_waitlist(uuid) from public, anon, authenticated;
revoke all on function public._slot_label(timestamptz) from public, anon, authenticated;
revoke all on function public._close_coach_slot(uuid, boolean) from public, anon, authenticated;
revoke all on function public._slot_grid(date, time, time, int) from public, anon, authenticated;

revoke all on function public.open_schedule(timestamptz, timestamptz) from public, anon;
revoke all on function public.close_schedule(uuid) from public, anon;
revoke all on function public.open_schedule_range(date, date, int[], time, time, int) from public, anon;
revoke all on function public.override_schedule_day(date, text, time, time, int, boolean) from public, anon;
grant execute on function public.open_schedule(timestamptz, timestamptz) to authenticated;
grant execute on function public.close_schedule(uuid) to authenticated;
grant execute on function public.open_schedule_range(date, date, int[], time, time, int) to authenticated;
grant execute on function public.override_schedule_day(date, text, time, time, int, boolean) to authenticated;

create or replace function public.move_schedule(p_schedule_id uuid, p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  old_label text;
  new_label text;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception '종료 시간은 시작 시간보다 뒤여야 합니다';
  end if;
  if p_end - p_start < interval '15 minutes' then
    raise exception '수업은 15분 이상이어야 합니다';
  end if;
  if p_end - p_start > interval '90 minutes' then
    raise exception '한 칸은 90분을 넘길 수 없습니다. 긴 시간은 나누어 열어 주세요';
  end if;
  if p_start <= now() then
    raise exception '이미 지난 시간으로는 옮길 수 없습니다';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.coach_id <> uid then
    raise exception '본인이 연 시간만 수정할 수 있습니다';
  end if;
  if slot.status = 'closed' then
    raise exception '마감된 시간은 수정할 수 없습니다';
  end if;
  if exists (
    select 1 from public.schedules s
    where s.coach_id = uid
      and s.id <> slot.id
      and s.status <> 'closed'
      and s.start_time < p_end
      and s.end_time > p_start
  ) then
    raise exception '이미 겹치는 오픈 시간이 있습니다';
  end if;
  old_label := public._slot_label(slot.start_time);
  update public.schedules
  set start_time = p_start, end_time = p_end
  where id = slot.id;
  new_label := public._slot_label(p_start);
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in ('confirmed', 'waiting')
  loop
    perform public._booking_notice(
      'member', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      'closed', '수업 시간이 변경되었습니다',
      old_label || ' 수업이 ' || new_label || ' 으로 옮겨졌습니다. 예약은 그대로입니다.'
    );
  end loop;
  return jsonb_build_object('id', slot.id, 'start_time', p_start, 'end_time', p_end);
end;
$mig$;

revoke all on function public.move_schedule(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.move_schedule(uuid, timestamptz, timestamptz) to authenticated;

create or replace function public.delete_schedule(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  label text;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.coach_id <> uid then
    raise exception '본인이 연 시간만 취소할 수 있습니다';
  end if;
  if slot.end_time <= now() then
    raise exception '끝난 수업은 삭제하지 않고 진행 완료로 남깁니다';
  end if;
  label := public._slot_label(slot.start_time);
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in ('confirmed', 'waiting')
    for update
  loop
    perform public._booking_notice(
      'member', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      'cancelled', '수업 오픈이 취소되었습니다',
      label || ' 수업이 오픈 전 상태로 되돌려져 예약이 취소되었습니다.'
    );
  end loop;
  update public.booking_notices set schedule_id = null where schedule_id = slot.id;
  delete from public.schedules where id = slot.id;
  return jsonb_build_object('id', p_schedule_id, 'deleted', true);
end;
$mig$;

revoke all on function public.delete_schedule(uuid) from public, anon;
grant execute on function public.delete_schedule(uuid) to authenticated;

create or replace function public.delete_schedules_between(p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  label text;
  deleted_n int := 0;
  booked_n int := 0;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception '기간을 확인해 주세요';
  end if;
  if p_to - p_from > 92 then
    raise exception '한 번에 최대 3개월까지 초기화할 수 있습니다';
  end if;
  for slot in
    select * from public.schedules
    where coach_id = uid
      and (start_time at time zone 'Asia/Seoul')::date between p_from and p_to
      and end_time > now()
    for update
  loop
    label := public._slot_label(slot.start_time);
    for rec in
      select * from public.reservations
      where schedule_id = slot.id and status in ('confirmed', 'waiting')
      for update
    loop
      booked_n := booked_n + 1;
      perform public._booking_notice(
        'member', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
        'cancelled', '수업 오픈이 취소되었습니다',
        label || ' 수업이 오픈 전 상태로 되돌려져 예약이 취소되었습니다.'
      );
    end loop;
    update public.booking_notices set schedule_id = null where schedule_id = slot.id;
    delete from public.schedules where id = slot.id;
    deleted_n := deleted_n + 1;
  end loop;
  return jsonb_build_object('deleted', deleted_n, 'cancelled_bookings', booked_n);
end;
$mig$;

create or replace function public.public_booking_board(p_tokens text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $mig$
declare
  tokens text[] := coalesce(p_tokens, array[]::text[]);
  slots jsonb;
begin
  if cardinality(tokens) > 40 then
    tokens := tokens[1:40];
  end if;
  select coalesce(jsonb_agg(x.slot order by x.start_time), '[]'::jsonb)
    into slots
  from (
    select s.start_time,
      jsonb_build_object(
        'id', s.id,
        'start_time', s.start_time,
        'end_time', s.end_time,
        'status', s.status,
        'cancel_hours', s.cancel_hours,
        'has_confirmed', exists (
          select 1 from public.reservations r
          where r.schedule_id = s.id and r.status = 'confirmed'
        ),
        'wait_count', (
          select count(*) from public.reservations r
          where r.schedule_id = s.id and r.status = 'waiting'
        ),
        'mine', (
          select jsonb_build_object(
            'id', r.id,
            'status', r.status,
            'waiting_order', r.waiting_order,
            'token', r.cancel_token,
            'name', r.member_name
          )
          from public.reservations r
          where r.schedule_id = s.id
            and r.cancel_token = any (tokens)
            and r.status in ('confirmed', 'waiting')
          limit 1
        )
      ) as slot
    from public.schedules s
    where s.status <> 'closed'
      and s.end_time > now()
  ) x;
  return jsonb_build_object('role', 'public', 'slots', slots);
end;
$mig$;

create or replace function public.public_book_slot(p_schedule_id uuid, p_name text, p_contact text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  slot public.schedules%rowtype;
  guest_name text := btrim(coalesce(p_name, ''));
  guest_contact text := regexp_replace(btrim(coalesce(p_contact, '')), '[[:space:]-]', '', 'g');
  guest_id text;
  token text;
  has_confirmed boolean;
  next_order int;
  rid uuid;
  new_status text;
  label text;
begin
  if char_length(guest_name) < 1 or char_length(guest_name) > 30 then
    raise exception '이름을 입력해 주세요';
  end if;
  if char_length(guest_contact) < 4 or char_length(guest_contact) > 40 then
    raise exception '연락처를 입력해 주세요';
  end if;
  guest_id := 'guest:' || md5(lower(guest_name) || '|' || guest_contact);
  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.status = 'closed' then
    raise exception '마감된 시간입니다';
  end if;
  if slot.start_time <= now() then
    raise exception '이미 시작된 수업은 예약할 수 없습니다';
  end if;
  if exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id
      and r.client_id = guest_id
      and r.status in ('confirmed', 'waiting')
  ) then
    raise exception '이미 이 시간을 예약했거나 대기 중입니다';
  end if;
  select exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = 'confirmed'
  ) into has_confirmed;
  label := public._slot_label(slot.start_time);
  if not has_confirmed then
    new_status := 'confirmed';
    next_order := 0;
    update public.schedules set status = 'booked' where id = slot.id;
  else
    new_status := 'waiting';
    select coalesce(max(r.waiting_order), 0) + 1 into next_order
    from public.reservations r
    where r.schedule_id = slot.id and r.status = 'waiting';
  end if;
  insert into public.reservations (
    schedule_id, client_id, member_share, member_name, contact, cancel_token, status, waiting_order
  ) values (
    slot.id, guest_id, '', guest_name, guest_contact, token, new_status, next_order
  ) returning id into rid;
  if new_status = 'confirmed' then
    perform public._booking_notice(
      'coach', slot.coach_id, guest_id, '', slot.id, rid,
      'booked', guest_name || ' 님 예약',
      label || ' ' || guest_name || ' · ' || guest_contact
    );
  else
    perform public._booking_notice(
      'coach', slot.coach_id, guest_id, '', slot.id, rid,
      'waiting', guest_name || ' 님 대기 ' || next_order || '순위',
      label || ' ' || guest_name || ' · ' || guest_contact
    );
  end if;
  return jsonb_build_object(
    'id', rid,
    'status', new_status,
    'waiting_order', next_order,
    'token', token,
    'name', guest_name,
    'contact', guest_contact
  );
end;
$mig$;

create or replace function public.public_claim_bookings(p_name text, p_contact text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $mig$
declare
  guest_name text := lower(btrim(coalesce(p_name, '')));
  guest_contact text := regexp_replace(btrim(coalesce(p_contact, '')), '[[:space:]-]', '', 'g');
  rows jsonb;
begin
  if char_length(guest_name) < 1 or char_length(guest_contact) < 4 then
    raise exception '이름과 연락처를 입력해 주세요';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'token', r.cancel_token,
    'name', r.member_name,
    'contact', r.contact,
    'status', r.status,
    'waiting_order', r.waiting_order,
    'start_time', s.start_time,
    'end_time', s.end_time
  ) order by s.start_time), '[]'::jsonb)
    into rows
  from public.reservations r
  join public.schedules s on s.id = r.schedule_id
  where r.status in ('confirmed', 'waiting')
    and r.cancel_token is not null
    and s.end_time > now()
    and lower(btrim(r.member_name)) = guest_name
    and regexp_replace(r.contact, '[[:space:]-]', '', 'g') = guest_contact;
  return rows;
end;
$mig$;

create or replace function public.public_cancel_reservation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  slot public.schedules%rowtype;
  res public.reservations%rowtype;
  sid uuid;
  promoted_id uuid;
  promoted_name text;
  promoted_share text;
  promoted_member text;
  label text;
begin
  if p_token is null or char_length(btrim(p_token)) < 16 then
    raise exception '예약 확인 정보가 없습니다';
  end if;
  select r.schedule_id into sid
  from public.reservations r
  where r.cancel_token = btrim(p_token);
  if sid is null then
    raise exception '예약을 찾을 수 없습니다';
  end if;
  select * into slot from public.schedules where id = sid for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  select * into res
  from public.reservations
  where cancel_token = btrim(p_token)
  for update;
  if not found or res.status = 'cancelled' then
    raise exception '예약을 찾을 수 없습니다';
  end if;
  if slot.start_time <= now() then
    raise exception '이미 시작된 수업은 취소할 수 없습니다';
  end if;
  if res.status = 'confirmed'
     and slot.start_time - make_interval(hours => coalesce(slot.cancel_hours, 6)) <= now() then
    raise exception '%', format('수업 시작 %s시간 전까지만 취소할 수 있습니다', coalesce(slot.cancel_hours, 6));
  end if;
  update public.reservations
  set status = 'cancelled', waiting_order = 0, cancelled_at = now()
  where id = res.id;
  label := public._slot_label(slot.start_time);
  if res.status = 'confirmed' and slot.status <> 'closed' and slot.start_time > now() then
    select r.id, r.member_name, r.member_share, r.client_id
      into promoted_id, promoted_name, promoted_share, promoted_member
    from public.reservations r
    where r.schedule_id = slot.id
      and r.status = 'waiting'
    order by r.waiting_order asc, r.created_at asc
    limit 1
    for update;
    if promoted_id is not null then
      update public.reservations
      set status = 'confirmed', waiting_order = 0
      where id = promoted_id;
      perform public._booking_notice(
        'coach', slot.coach_id, promoted_member, promoted_share, slot.id, promoted_id,
        'promoted', promoted_name || ' 님 자동 확정',
        label || ' 빈자리로 ' || promoted_name || ' 님이 확정되었습니다.'
      );
    end if;
  end if;
  perform public._renumber_waitlist(slot.id);
  if not exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = 'confirmed'
  ) and slot.status = 'booked' then
    update public.schedules set status = 'available' where id = slot.id;
  end if;
  perform public._booking_notice(
    'coach', slot.coach_id, res.client_id, res.member_share, slot.id, res.id,
    'cancelled', res.member_name || ' 님 취소',
    label || ' 예약이 취소되었습니다.'
  );
  return jsonb_build_object('cancelled_id', res.id, 'promoted', promoted_id is not null);
end;
$mig$;

create or replace function public.coach_book_slot(p_schedule_id uuid, p_name text, p_contact text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  guest_name text := btrim(coalesce(p_name, ''));
  guest_contact text := regexp_replace(btrim(coalesce(p_contact, '')), '[[:space:]-]', '', 'g');
  guest_id text;
  token text;
  rid uuid;
  label text;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if char_length(guest_name) < 1 or char_length(guest_name) > 30 then
    raise exception '이름을 입력해 주세요';
  end if;
  if char_length(guest_contact) < 4 or char_length(guest_contact) > 40 then
    raise exception '연락처를 입력해 주세요';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception '시간을 찾을 수 없습니다';
  end if;
  if slot.coach_id <> uid then
    raise exception '본인이 연 시간만 예약할 수 있습니다';
  end if;
  if slot.status = 'closed' then
    raise exception '마감된 시간입니다';
  end if;
  if slot.end_time <= now() then
    raise exception '이미 끝난 수업은 예약할 수 없습니다';
  end if;
  if exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = 'confirmed'
  ) then
    raise exception '이미 확정된 예약이 있습니다';
  end if;
  guest_id := 'guest:' || md5(lower(guest_name) || '|' || guest_contact);
  if exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id
      and r.client_id = guest_id
      and r.status in ('confirmed', 'waiting')
  ) then
    raise exception '이미 이 시간을 예약했거나 대기 중입니다';
  end if;
  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  label := public._slot_label(slot.start_time);
  insert into public.reservations (
    schedule_id, client_id, member_share, member_name, contact, cancel_token, status, waiting_order
  ) values (
    slot.id, guest_id, '', guest_name, guest_contact, token, 'confirmed', 0
  ) returning id into rid;
  update public.schedules set status = 'booked' where id = slot.id;
  perform public._booking_notice(
    'coach', slot.coach_id, guest_id, '', slot.id, rid,
    'booked', guest_name || ' 님 예약',
    label || ' 코치가 ' || guest_name || ' · ' || guest_contact || ' 예약을 확정했습니다.'
  );
  return jsonb_build_object(
    'id', rid,
    'status', 'confirmed',
    'name', guest_name,
    'contact', guest_contact,
    'token', token
  );
end;
$mig$;

revoke all on function public.coach_book_slot(uuid, text, text) from public, anon;
grant execute on function public.coach_book_slot(uuid, text, text) to authenticated;

create or replace function public.coach_book_series(
  p_from date,
  p_until date,
  p_time time,
  p_minutes int,
  p_rule text,
  p_weekdays int[],
  p_name text,
  p_contact text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  uid uuid := auth.uid();
  guest_name text := btrim(coalesce(p_name, ''));
  guest_contact text := regexp_replace(btrim(coalesce(p_contact, '')), '[[:space:]-]', '', 'g');
  guest_id text;
  d date;
  include_day boolean;
  slot_start timestamptz;
  slot_end timestamptz;
  exact_id uuid;
  rid uuid;
  token text;
  slot_rec record;
  wait_rec record;
  label text;
  created int := 0;
  skipped_past int := 0;
  skipped_conflict int := 0;
  skipped_same int := 0;
  anchor_dow int;
  anchor_day int;
begin
  if uid is null then
    raise exception '로그인이 필요합니다';
  end if;
  if char_length(guest_name) < 1 or char_length(guest_name) > 30 then
    raise exception '이름을 입력해 주세요';
  end if;
  if char_length(guest_contact) < 4 or char_length(guest_contact) > 40 then
    raise exception '연락처를 입력해 주세요';
  end if;
  if p_from is null or p_until is null or p_until < p_from then
    raise exception '종료일은 시작일보다 뒤여야 합니다';
  end if;
  if (p_until - p_from) > 370 then
    raise exception '한 번에 최대 1년까지 반복할 수 있습니다';
  end if;
  if p_time is null then
    raise exception '시작 시간을 입력해 주세요';
  end if;
  if p_minutes not in (30, 50, 60, 90) then
    raise exception '수업 길이는 30, 50, 60, 90분 중에서 고르세요';
  end if;
  if p_rule not in ('daily', 'weekly', 'biweekly', 'monthly') then
    raise exception '반복은 매일, 매주, 격주, 매월 중에서 고르세요';
  end if;
  if p_rule = 'weekly' and (p_weekdays is null or cardinality(p_weekdays) = 0) then
    raise exception '요일을 하나 이상 선택해 주세요';
  end if;

  guest_id := 'guest:' || md5(lower(guest_name) || '|' || guest_contact);
  anchor_dow := extract(dow from p_from)::int;
  anchor_day := extract(day from p_from)::int;
  d := p_from;

  while d <= p_until loop
    include_day := false;
    if p_rule = 'daily' then
      include_day := true;
    elsif p_rule = 'weekly' then
      include_day := extract(dow from d)::int = any(p_weekdays);
    elsif p_rule = 'biweekly' then
      include_day := extract(dow from d)::int = anchor_dow and ((d - p_from) % 14 = 0);
    elsif p_rule = 'monthly' then
      include_day := extract(day from d)::int = anchor_day;
    end if;

    if include_day then
      slot_start := (d + p_time) at time zone 'Asia/Seoul';
      slot_end := slot_start + make_interval(mins => p_minutes);
      if slot_end <= now() then
        skipped_past := skipped_past + 1;
      elsif created >= 200 then
        raise exception '한 번에 200건까지만 반복 예약할 수 있습니다. 기간을 나눠 주세요';
      else
        perform 1
        from public.schedules s
        where s.coach_id = uid
          and s.status <> 'closed'
          and s.start_time < slot_end
          and s.end_time > slot_start
        order by s.id
        for update;

        if exists (
          select 1
          from public.reservations r
          join public.schedules s on s.id = r.schedule_id
          where s.coach_id = uid
            and s.status <> 'closed'
            and s.start_time < slot_end
            and s.end_time > slot_start
            and r.status = 'confirmed'
            and r.client_id <> guest_id
        ) then
          skipped_conflict := skipped_conflict + 1;
        elsif exists (
          select 1
          from public.reservations r
          join public.schedules s on s.id = r.schedule_id
          where s.coach_id = uid
            and s.status <> 'closed'
            and s.start_time = slot_start
            and s.end_time = slot_end
            and r.status = 'confirmed'
            and r.client_id = guest_id
        ) then
          skipped_same := skipped_same + 1;
        else
          for slot_rec in
            select s.id, s.start_time
            from public.schedules s
            where s.coach_id = uid
              and s.status <> 'closed'
              and s.start_time < slot_end
              and s.end_time > slot_start
              and not (s.start_time = slot_start and s.end_time = slot_end)
              and not exists (
                select 1 from public.reservations r
                where r.schedule_id = s.id and r.status = 'confirmed'
              )
            order by s.id
            for update
          loop
            label := public._slot_label(slot_rec.start_time);
            for wait_rec in
              select * from public.reservations
              where schedule_id = slot_rec.id and status = 'waiting'
              for update
            loop
              perform public._booking_notice(
                'member', uid, wait_rec.client_id, wait_rec.member_share, wait_rec.schedule_id, wait_rec.id,
                'cancelled', '대기 신청이 취소되었습니다',
                label || ' 시간에 고정 수업이 잡혀 대기가 취소되었습니다.'
              );
            end loop;
            update public.booking_notices set schedule_id = null where schedule_id = slot_rec.id;
            delete from public.schedules where id = slot_rec.id;
          end loop;

          exact_id := null;
          select s.id into exact_id
          from public.schedules s
          where s.coach_id = uid
            and s.status <> 'closed'
            and s.start_time = slot_start
            and s.end_time = slot_end
          limit 1;

          if exact_id is null then
            insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
            values (uid, slot_start, slot_end, 'booked', 6)
            returning id into exact_id;
          else
            update public.schedules set status = 'booked' where id = exact_id;
          end if;

          rid := null;
          select r.id into rid
          from public.reservations r
          where r.schedule_id = exact_id
            and r.client_id = guest_id
            and r.status = 'waiting'
          for update;

          if rid is null then
            token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
            insert into public.reservations (
              schedule_id, client_id, member_share, member_name, contact, cancel_token, status, waiting_order
            ) values (
              exact_id, guest_id, '', guest_name, guest_contact, token, 'confirmed', 0
            );
          else
            update public.reservations
            set status = 'confirmed', waiting_order = 0, member_name = guest_name, contact = guest_contact
            where id = rid;
          end if;
          created := created + 1;
        end if;
      end if;
    end if;
    d := d + 1;
  end loop;

  if created = 0 and skipped_past = 0 and skipped_conflict = 0 and skipped_same = 0 then
    raise exception '반복할 날짜가 없습니다';
  end if;

  if created > 0 then
    perform public._booking_notice(
      'coach', uid, guest_id, '', null, null,
      'booked', guest_name || ' 님 반복 예약',
      guest_name || ' · ' || guest_contact || ' 고정 수업 ' || created || '건을 확정했습니다.'
    );
  end if;

  return jsonb_build_object(
    'created', created,
    'skipped_past', skipped_past,
    'skipped_conflict', skipped_conflict,
    'skipped_same', skipped_same
  );
end;
$mig$;

revoke all on function public.coach_book_series(date, date, time, int, text, int[], text, text) from public, anon;
grant execute on function public.coach_book_series(date, date, time, int, text, int[], text, text) to authenticated;

revoke all on function public.public_booking_board(text[]) from public;
grant execute on function public.public_booking_board(text[]) to anon, authenticated;
revoke all on function public.public_book_slot(uuid, text, text) from public;
grant execute on function public.public_book_slot(uuid, text, text) to anon, authenticated;
revoke all on function public.public_claim_bookings(text, text) from public;
grant execute on function public.public_claim_bookings(text, text) to anon, authenticated;
revoke all on function public.public_cancel_reservation(text) from public;
grant execute on function public.public_cancel_reservation(text) to anon, authenticated;

revoke all on function public.delete_schedules_between(date, date) from public, anon;
grant execute on function public.delete_schedules_between(date, date) to authenticated;
grant execute on function public.book_slot(text, uuid) to anon, authenticated;
grant execute on function public.cancel_reservation(text, uuid) to anon, authenticated;
grant execute on function public.booking_board(text) to anon, authenticated;
grant execute on function public.read_booking_notices(text) to anon, authenticated;

revoke all on public.schedules from anon, public;
revoke all on public.reservations from anon, public;
revoke all on public.booking_notices from anon, public;
grant select on public.schedules to authenticated;
grant select, update on public.reservations to authenticated;
grant select, update on public.booking_notices to authenticated;
grant all on public.schedules to service_role;
grant all on public.reservations to service_role;
grant all on public.booking_notices to service_role;

do $mig$ begin
  alter publication supabase_realtime add table public.schedules;
exception when duplicate_object then null;
end $mig$;
do $mig$ begin
  alter publication supabase_realtime add table public.reservations;
exception when duplicate_object then null;
end $mig$;
do $mig$ begin
  alter publication supabase_realtime add table public.booking_notices;
exception when duplicate_object then null;
end $mig$;

create or replace function public.split_long_schedules()
returns jsonb
language plpgsql
security definer
set search_path = public
as $mig$
declare
  slot public.schedules%rowtype;
  piece record;
  rec record;
  local_start timestamp;
  local_end timestamp;
  first_id uuid;
  new_id uuid;
  split_n int := 0;
  moved_n int := 0;
  n int := 0;
begin
  for slot in
    select * from public.schedules
    where status <> 'closed'
      and end_time > now()
      and end_time - start_time > interval '90 minutes'
    order by start_time
    for update
  loop
    local_start := slot.start_time at time zone 'Asia/Seoul';
    local_end := slot.end_time at time zone 'Asia/Seoul';
    if local_start::date <> local_end::date then
      continue;
    end if;
    first_id := null;
    for piece in
      select * from public._slot_grid(local_start::date, local_start::time, local_end::time, 60)
    loop
      if piece.is_past then
        continue;
      end if;
      if exists (
        select 1 from public.schedules s
        where s.coach_id = slot.coach_id
          and s.id <> slot.id
          and s.status <> 'closed'
          and s.start_time < piece.slot_end
          and s.end_time > piece.slot_start
      ) then
        continue;
      end if;
      insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
      values (slot.coach_id, piece.slot_start, piece.slot_end, 'available', slot.cancel_hours)
      returning id into new_id;
      if first_id is null then
        first_id := new_id;
      end if;
    end loop;
    if first_id is null then
      continue;
    end if;
    update public.reservations
    set schedule_id = first_id
    where schedule_id = slot.id
      and status in ('confirmed', 'waiting');
    get diagnostics n = row_count;
    moved_n := moved_n + n;
    if exists (
      select 1 from public.reservations r
      where r.schedule_id = first_id and r.status = 'confirmed'
    ) then
      update public.schedules set status = 'booked' where id = first_id;
    end if;
    for rec in
      select * from public.reservations
      where schedule_id = first_id and status in ('confirmed', 'waiting')
    loop
      perform public._booking_notice(
        'member', slot.coach_id, rec.client_id, rec.member_share, first_id, rec.id,
        'closed', '예약 시간이 1시간으로 정리되었습니다',
        public._slot_label(slot.start_time) || ' 부터 이어지던 시간이 나뉘어 ' || public._slot_label((select start_time from public.schedules where id = first_id)) || ' 수업만 예약으로 남았습니다.'
      );
    end loop;
    update public.booking_notices set schedule_id = first_id where schedule_id = slot.id;
    delete from public.schedules where id = slot.id;
    split_n := split_n + 1;
  end loop;
  return jsonb_build_object('split', split_n, 'moved_bookings', moved_n);
end;
$mig$;

revoke all on function public.split_long_schedules() from public, anon, authenticated;

select public.split_long_schedules();

notify pgrst, 'reload schema';
