-- PT Logger multi-tenant schema + RLS
-- Supabase Dashboard → SQL Editor 에 이 파일 전체를 붙여넣고 Run 하세요.
-- 함수 본문은 작은따옴표 문자열입니다. 달러 기호 구분자는 SQL Editor에서 본문이 잘립니다.
-- 여러 번 실행해도 안전합니다.
--
-- 회원·스케줄·수업 일지·체성분은 gym_state.data JSON 안에 들어 있고,
-- 회원 전용 운동/식단은 member_logs 에 저장됩니다.
-- 격리 기준은 로그인한 트레이너의 auth.uid() 입니다.

create table if not exists public.gyms (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.gym_state (
  gym_id uuid primary key references public.gyms(id) on delete cascade,
  data jsonb not null default '{"members":[]}'::jsonb,
  rev bigint not null default 1,
  updated_at timestamptz not null default now()
);

create table if not exists public.member_logs (
  id text not null,
  gym_id uuid not null references public.gyms(id) on delete cascade,
  share text not null,
  kind text not null check (kind in ('self_workout', 'diet')),
  payload jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (id)
);

alter table public.gym_state add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.member_logs add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.member_logs add column if not exists member_id text;
alter table public.member_logs add column if not exists video_url text;

do '
declare r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
    where nsp.nspname = ''public''
      and rel.relname = ''member_logs''
      and con.contype = ''c''
  loop
    execute format(''alter table public.member_logs drop constraint %I'', r.conname);
  end loop;
end ';

alter table public.member_logs
  add constraint member_logs_kind_check
  check (kind in ('self_workout', 'diet', 'video'));

update public.gym_state s
  set user_id = g.owner_id
  from public.gyms g
  where g.id = s.gym_id and s.user_id is null;

update public.member_logs m
  set user_id = g.owner_id
  from public.gyms g
  where g.id = m.gym_id and m.user_id is null;

update public.member_logs l
set member_id = e->>'id'
from public.gym_state s,
     jsonb_array_elements(coalesce(s.data->'members', '[]'::jsonb)) e
where (l.member_id is null or l.member_id = '')
  and l.gym_id = s.gym_id
  and e->>'share' = l.share
  and coalesce(e->>'id', '') <> '';

create index if not exists member_logs_share_idx on public.member_logs(share);
create index if not exists member_logs_gym_idx on public.member_logs(gym_id);
create index if not exists member_logs_user_idx on public.member_logs(user_id);
create index if not exists member_logs_member_idx on public.member_logs(member_id);
create index if not exists gym_state_user_idx on public.gym_state(user_id);

alter table public.gyms enable row level security;
alter table public.gym_state enable row level security;
alter table public.member_logs enable row level security;

create or replace function public.owns_gym(p_gym_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as '
  select exists (
    select 1 from public.gyms g
    where g.id = p_gym_id and g.owner_id = auth.uid()
  );
';

create or replace function public.own_user(p_user_id uuid)
returns boolean
language sql
stable
as '
  select p_user_id is not null and p_user_id = auth.uid();
';

do '
declare pol record;
begin
  for pol in
    select policyname, tablename
    from pg_policies
    where schemaname = ''public''
      and tablename in (''gyms'', ''gym_state'', ''member_logs'')
  loop
    execute format(''drop policy if exists %I on public.%I'', pol.policyname, pol.tablename);
  end loop;
end ';

create policy gyms_select on public.gyms
  for select to authenticated
  using (owner_id = auth.uid());
create policy gyms_insert on public.gyms
  for insert to authenticated
  with check (owner_id = auth.uid());
create policy gyms_update on public.gyms
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());
create policy gyms_delete on public.gyms
  for delete to authenticated
  using (owner_id = auth.uid());

-- user_id 가 아직 비어 있는 기존 행도 gym 소유자면 읽을 수 있게 둡니다.
create or replace function public.fill_row_user_id()
returns trigger
language plpgsql
as '
begin
  if NEW.user_id is null then
    NEW.user_id := auth.uid();
  end if;
  return NEW;
end;
';

drop trigger if exists gym_state_fill_user_id on public.gym_state;
create trigger gym_state_fill_user_id
  before insert or update on public.gym_state
  for each row execute procedure public.fill_row_user_id();

drop trigger if exists member_logs_fill_user_id on public.member_logs;
create trigger member_logs_fill_user_id
  before insert or update on public.member_logs
  for each row execute procedure public.fill_row_user_id();

create policy gym_state_select on public.gym_state
  for select to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id));
create policy gym_state_insert on public.gym_state
  for insert to authenticated
  with check ((public.own_user(user_id) or (user_id is null and auth.uid() is not null)) and public.owns_gym(gym_id));
create policy gym_state_update on public.gym_state
  for update to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id))
  with check (public.own_user(user_id) and public.owns_gym(gym_id));
create policy gym_state_delete on public.gym_state
  for delete to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id));

create policy member_logs_select on public.member_logs
  for select to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id));
create policy member_logs_insert on public.member_logs
  for insert to authenticated
  with check ((public.own_user(user_id) or (user_id is null and auth.uid() is not null)) and public.owns_gym(gym_id));
create policy member_logs_update on public.member_logs
  for update to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id))
  with check (public.own_user(user_id) and public.owns_gym(gym_id));
create policy member_logs_delete on public.member_logs
  for delete to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id));

create or replace function public.ensure_gym()
returns table (gym_id uuid, data jsonb, rev bigint)
language plpgsql
security definer
set search_path = public
as '
declare
  gid uuid;
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception ''not authenticated'';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data)
    values (gid, uid, ''{"members":[]}''::jsonb)
  on conflict (gym_id) do update
    set user_id = coalesce(public.gym_state.user_id, excluded.user_id);
  update public.member_logs
    set user_id = uid
    where member_logs.gym_id = gid and member_logs.user_id is null;
  return query
    select s.gym_id, s.data, s.rev
    from public.gym_state s
    where s.gym_id = gid;
end;
';

create or replace function public.load_trainer_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid;
  gid uuid;
  payload jsonb;
  r_rev bigint;
  logs jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception ''not authenticated'';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data)
    values (gid, uid, ''{"members":[]}''::jsonb)
  on conflict (gym_id) do update
    set user_id = coalesce(public.gym_state.user_id, excluded.user_id);
  update public.member_logs
    set user_id = uid
    where member_logs.gym_id = gid and member_logs.user_id is null;
  select s.data, s.rev into payload, r_rev
    from public.gym_state s
    where s.gym_id = gid;
  select coalesce(jsonb_agg(jsonb_build_object(
      ''id'', l.id,
      ''share'', l.share,
      ''kind'', l.kind,
      ''member_id'', l.member_id,
      ''video_url'', l.video_url,
      ''payload'', l.payload
    ) order by l.updated_at), ''[]''::jsonb)
    into logs
    from public.member_logs l
    where l.gym_id = gid;
  return jsonb_build_object(
    ''gym_id'', gid,
    ''data'', coalesce(payload, ''{"members":[]}''::jsonb),
    ''rev'', coalesce(r_rev, 1),
    ''logs'', coalesce(logs, ''[]''::jsonb)
  );
end;
';

create or replace function public.push_gym_state(p_data jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as '
declare
  gid uuid;
  uid uuid;
  new_rev bigint;
begin
  uid := auth.uid();
  if uid is null then
    raise exception ''not authenticated'';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data, rev)
    values (gid, uid, coalesce(p_data, ''{"members":[]}''::jsonb), 1)
  on conflict (gym_id) do update
    set data = excluded.data,
        user_id = uid,
        rev = public.gym_state.rev + 1,
        updated_at = now()
    returning rev into new_rev;
  return coalesce(new_rev, 1);
end;
';

create or replace function public.upsert_member_logs(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid;
  gid uuid;
  n int := 0;
  rec jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception ''not authenticated'';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> ''array'' then
    return 0;
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    return 0;
  end if;
  for rec in select value from jsonb_array_elements(p_rows)
  loop
    if coalesce(rec->>''id'', '''') = '''' then
      continue;
    end if;
    if coalesce(rec->>''kind'', '''') not in (''self_workout'', ''diet'', ''video'') then
      continue;
    end if;
    insert into public.member_logs (id, gym_id, user_id, member_id, share, kind, payload, video_url, updated_at)
    values (
      rec->>''id'',
      gid,
      uid,
      nullif(coalesce(rec->>''member_id'', rec#>>''{payload,member_id}''), ''''),
      coalesce(rec->>''share'', ''''),
      rec->>''kind'',
      coalesce(rec->''payload'', ''{}''::jsonb),
      nullif(coalesce(rec->>''video_url'', rec#>>''{payload,video_url}''), ''''),
      now()
    )
    on conflict (id) do update
      set payload = excluded.payload,
          kind = excluded.kind,
          share = excluded.share,
          gym_id = excluded.gym_id,
          user_id = excluded.user_id,
          member_id = coalesce(excluded.member_id, public.member_logs.member_id),
          video_url = coalesce(excluded.video_url, public.member_logs.video_url),
          updated_at = now()
      where public.member_logs.gym_id = gid;
    n := n + 1;
  end loop;
  return n;
end;
';

create or replace function public.member_public(p_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
declare
  mem jsonb;
  p_share text;
  p_member text;
  workouts jsonb;
  diets jsonb;
  videos jsonb;
  oid uuid;
begin
  if p_ref is null or length(trim(p_ref)) < 4 then
    return null;
  end if;
  select e, coalesce(s.user_id, g.owner_id) into mem, oid
  from public.gym_state s
  join public.gyms g on g.id = s.gym_id,
       jsonb_array_elements(coalesce(s.data->''members'', ''[]''::jsonb)) e
  where e->>''share'' = p_ref or e->>''id'' = p_ref
  limit 1;
  if mem is null then
    return null;
  end if;
  p_share := mem->>''share'';
  p_member := mem->>''id'';
  select coalesce(jsonb_agg(payload order by updated_at), ''[]''::jsonb)
    into workouts
    from public.member_logs
    where share = p_share and kind = ''self_workout''
      and (member_id is null or member_id = '''' or member_id = p_member);
  select coalesce(jsonb_agg(payload order by updated_at), ''[]''::jsonb)
    into diets
    from public.member_logs
    where share = p_share and kind = ''diet''
      and (member_id is null or member_id = '''' or member_id = p_member);
  select coalesce(jsonb_agg(jsonb_build_object(
      ''id'', l.id,
      ''member_id'', l.member_id,
      ''share'', l.share,
      ''kind'', l.kind,
      ''video_url'', l.video_url,
      ''payload'', l.payload
    ) order by l.updated_at), ''[]''::jsonb)
    into videos
    from public.member_logs l
    where l.member_id = p_member
      and l.kind = ''video''
      and coalesce(l.video_url, '''') <> '''';
  return mem || jsonb_build_object(
    ''selfWorkouts'', workouts,
    ''dietLogs'', diets,
    ''videos'', videos,
    ''ownerId'', oid
  );
end;
';

create or replace function public.member_upsert_log(p_share text, p_kind text, p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
declare
  gid uuid;
  uid uuid;
  rid text;
  mem_id text;
  vurl text;
begin
  if p_kind not in (''self_workout'', ''diet'', ''video'') then
    raise exception ''invalid kind'';
  end if;
  if p_share is null or length(trim(p_share)) < 4 then
    raise exception ''invalid share'';
  end if;
  rid := coalesce(p_row->>''id'', '''');
  if rid = '''' then
    raise exception ''missing id'';
  end if;
  select s.gym_id, coalesce(s.user_id, g.owner_id), e->>''id''
    into gid, uid, mem_id
  from public.gym_state s
  join public.gyms g on g.id = s.gym_id,
       jsonb_array_elements(coalesce(s.data->''members'', ''[]''::jsonb)) e
  where e->>''share'' = p_share
  limit 1;
  if gid is null then
    raise exception ''member not found'';
  end if;
  if p_row ? ''member_id'' and coalesce(p_row->>''member_id'', '''') <> '''' and p_row->>''member_id'' <> mem_id then
    raise exception ''member mismatch'';
  end if;
  vurl := nullif(coalesce(p_row->>''video_url'', ''''), '''');
  insert into public.member_logs (id, gym_id, user_id, member_id, share, kind, payload, video_url, updated_at)
  values (rid, gid, uid, mem_id, p_share, p_kind, p_row, vurl, now())
  on conflict (id) do update
    set payload = excluded.payload,
        kind = excluded.kind,
        share = excluded.share,
        gym_id = excluded.gym_id,
        user_id = excluded.user_id,
        member_id = excluded.member_id,
        video_url = coalesce(excluded.video_url, public.member_logs.video_url),
        updated_at = now()
    where public.member_logs.member_id is null
       or public.member_logs.member_id = ''''
       or public.member_logs.member_id = excluded.member_id;
  return p_row || jsonb_build_object(''member_id'', mem_id, ''video_url'', coalesce(vurl, ''''));
end;
';

create or replace function public.member_delete_log(p_share text, p_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as '
declare
  n int;
begin
  if p_share is null or p_id is null then
    return false;
  end if;
  delete from public.member_logs
    where id = p_id and share = p_share;
  get diagnostics n = row_count;
  return n > 0;
end;
';

create or replace view public.member_journal
with (security_invoker = true) as
select
  id,
  gym_id,
  user_id,
  member_id,
  share,
  kind,
  video_url,
  payload,
  updated_at
from public.member_logs
where member_id is not null
  and member_id <> '';

create or replace function public.member_journal_for(p_member_id text)
returns setof public.member_logs
language sql
stable
security invoker
set search_path = public
as '
  select l.*
  from public.member_logs l
  where l.member_id = p_member_id
    and auth.uid() is not null
    and (public.own_user(l.user_id) or public.owns_gym(l.gym_id));
';

grant usage on schema public to anon, authenticated, service_role;
revoke all on public.gyms from anon, public;
revoke all on public.gym_state from anon, public;
revoke all on public.member_logs from anon, public;
grant select, insert, update, delete on public.gyms to authenticated;
grant select, insert, update, delete on public.gym_state to authenticated;
grant select, insert, update, delete on public.member_logs to authenticated;
grant all on public.gyms to service_role;
grant all on public.gym_state to service_role;
grant all on public.member_logs to service_role;

grant execute on function public.owns_gym(uuid) to authenticated, anon, public;
grant execute on function public.own_user(uuid) to authenticated, anon, public;

revoke all on function public.ensure_gym() from public, anon;
revoke all on function public.load_trainer_state() from public, anon;
revoke all on function public.push_gym_state(jsonb) from public, anon;
revoke all on function public.upsert_member_logs(jsonb) from public, anon;
grant execute on function public.ensure_gym() to authenticated;
grant execute on function public.load_trainer_state() to authenticated;
grant execute on function public.push_gym_state(jsonb) to authenticated;
grant execute on function public.upsert_member_logs(jsonb) to authenticated;
grant execute on function public.member_public(text) to anon, authenticated;
grant execute on function public.member_upsert_log(text, text, jsonb) to anon, authenticated;
grant execute on function public.member_delete_log(text, text) to anon, authenticated;
revoke all on function public.member_journal_for(text) from public, anon;
grant execute on function public.member_journal_for(text) to authenticated;
revoke all on public.member_journal from anon, public;
grant select on public.member_journal to authenticated;

insert into storage.buckets (id, name, public, file_size_limit)
values ('pt-media', 'pt-media', true, 5242880)
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit;

drop policy if exists "pt media public read" on storage.objects;
create policy "pt media public read"
  on storage.objects for select
  to public
  using (bucket_id = 'pt-media');

drop policy if exists "pt media auth write" on storage.objects;
drop policy if exists "pt media auth write own" on storage.objects;
create policy "pt media auth write own"
  on storage.objects for all
  to authenticated
  using (
    bucket_id = 'pt-media'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  )
  with check (
    bucket_id = 'pt-media'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  );

drop policy if exists "pt media anon upload share" on storage.objects;
create policy "pt media anon upload share"
  on storage.objects for insert
  to anon
  with check (
    bucket_id = 'pt-media'
    and split_part(name, '/', 1) = 'share'
  );

drop policy if exists "pt media anon update share" on storage.objects;
create policy "pt media anon update share"
  on storage.objects for update
  to anon
  using (
    bucket_id = 'pt-media'
    and split_part(name, '/', 1) = 'share'
  )
  with check (
    bucket_id = 'pt-media'
    and split_part(name, '/', 1) = 'share'
  );

insert into storage.buckets (id, name, public, file_size_limit)
values ('workout-videos', 'workout-videos', true, 52428800)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit;

-- SELECT 는 로그인·승인 없이 공개 URL 로 재생. 쓰기는 본인 경로만.
drop policy if exists "workout videos auth write own" on storage.objects;
drop policy if exists "workout videos public read" on storage.objects;
drop policy if exists "workout videos anon read" on storage.objects;
drop policy if exists "workout videos authenticated read" on storage.objects;

create policy "workout videos public read"
  on storage.objects for select
  to public
  using (bucket_id = 'workout-videos');

create policy "workout videos anon read"
  on storage.objects for select
  to anon
  using (bucket_id = 'workout-videos');

create policy "workout videos authenticated read"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'workout-videos');

drop policy if exists "workout videos auth insert own" on storage.objects;
create policy "workout videos auth insert own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'workout-videos'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  );

drop policy if exists "workout videos auth update own" on storage.objects;
create policy "workout videos auth update own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'workout-videos'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  )
  with check (
    bucket_id = 'workout-videos'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  );

drop policy if exists "workout videos auth delete own" on storage.objects;
create policy "workout videos auth delete own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'workout-videos'
    and split_part(name, '/', 1) = 'user'
    and split_part(name, '/', 2) = auth.uid()::text
  );

do ' begin
  alter publication supabase_realtime add table public.gym_state;
exception when duplicate_object then null;
end ';

do ' begin
  alter publication supabase_realtime add table public.member_logs;
exception when duplicate_object then null;
end ';

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
create index if not exists booking_notices_member_idx on public.booking_notices (member_share, created_at desc);

alter table public.schedules enable row level security;
alter table public.reservations enable row level security;
alter table public.booking_notices enable row level security;

do '
declare pol record;
begin
  for pol in
    select policyname, tablename
    from pg_policies
    where schemaname = ''public''
      and tablename in (''schedules'', ''reservations'', ''booking_notices'')
  loop
    execute format(''drop policy if exists %I on public.%I'', pol.policyname, pol.tablename);
  end loop;
end ';

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
as '
  select
    e->>''id'',
    coalesce(nullif(e->>''name'', ''''), ''회원''),
    e->>''share'',
    coalesce(s.user_id, g.owner_id),
    g.id
  from public.gym_state s
  join public.gyms g on g.id = s.gym_id,
       jsonb_array_elements(coalesce(s.data->''members'', ''[]''::jsonb)) e
  where (e->>''share'' = btrim(p_ref) or e->>''id'' = btrim(p_ref))
    and coalesce(e->>''id'', '''') <> ''''
    and coalesce(e->>''share'', '''') <> ''''
  limit 1;
';

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
as '
  insert into public.booking_notices (
    audience, coach_id, member_id, member_share, schedule_id, reservation_id, kind, title, body
  ) values (
    p_audience, p_coach, p_member_id, p_share, p_schedule, p_reservation, p_kind, p_title, coalesce(p_body, '''')
  );
';

create or replace function public._renumber_waitlist(p_schedule uuid)
returns void
language plpgsql
security definer
set search_path = public
as '
begin
  with ranked as (
    select id, row_number() over (order by waiting_order, created_at) as n
    from public.reservations
    where schedule_id = p_schedule and status = ''waiting''
  )
  update public.reservations r
  set waiting_order = ranked.n
  from ranked
  where r.id = ranked.id
    and r.waiting_order is distinct from ranked.n;
end;
';

create or replace function public._slot_label(p_start timestamptz)
returns text
language sql
stable
as '
  select to_char(p_start at time zone ''Asia/Seoul'', ''FMMM/FMDD HH24:MI'');
';

create or replace function public.open_schedule(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid := auth.uid();
  sid uuid;
begin
  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception ''종료 시간은 시작 시간보다 뒤여야 합니다'';
  end if;
  if p_end - p_start < interval ''15 minutes'' then
    raise exception ''수업은 15분 이상이어야 합니다'';
  end if;
  if p_start <= now() then
    raise exception ''이미 지난 시간은 오픈할 수 없습니다'';
  end if;
  if exists (
    select 1 from public.schedules s
    where s.coach_id = uid
      and s.status <> ''closed''
      and s.start_time < p_end
      and s.end_time > p_start
  ) then
    raise exception ''이미 겹치는 오픈 시간이 있습니다'';
  end if;
  insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
  values (uid, p_start, p_end, ''available'', 6)
  returning id into sid;
  return jsonb_build_object(''id'', sid, ''status'', ''available'');
end;
';

create or replace function public._close_coach_slot(p_schedule_id uuid, p_quiet boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  n int := 0;
begin
  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception ''시간을 찾을 수 없습니다'';
  end if;
  if slot.coach_id <> uid then
    raise exception ''본인이 연 시간만 마감할 수 있습니다'';
  end if;
  if slot.status = ''closed'' then
    return;
  end if;
  update public.schedules set status = ''closed'' where id = slot.id;
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in (''confirmed'', ''waiting'')
    for update
  loop
    n := n + 1;
    update public.reservations
    set status = ''cancelled'', waiting_order = 0, cancelled_at = now()
    where id = rec.id;
    perform public._booking_notice(
      ''member'', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      ''closed'', ''수업 시간이 마감되었습니다'',
      public._slot_label(slot.start_time) || '' 수업이 마감되어 예약이 취소되었습니다.''
    );
  end loop;
  if n > 0 or not coalesce(p_quiet, false) then
    perform public._booking_notice(
      ''coach'', slot.coach_id, null, null, slot.id, null,
      ''closed'', ''시간을 마감했습니다'',
      public._slot_label(slot.start_time) || '' 시간을 마감했습니다.''
    );
  end if;
end;
';

create or replace function public.close_schedule(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
begin
  perform public._close_coach_slot(p_schedule_id, false);
  return jsonb_build_object(''id'', p_schedule_id, ''status'', ''closed'');
end;
';

-- 한국 시간 기준. 수업 길이만큼 잘라 미래 슬롯만 후보로 돌려줍니다.
create or replace function public._slot_grid(p_date date, p_start time, p_end time, p_minutes int)
returns table(slot_start timestamptz, slot_end timestamptz, is_past boolean)
language plpgsql
stable
set search_path = public
as '
declare
  cursor_ts timestamp;
  day_end timestamp;
  s timestamptz;
  e timestamptz;
begin
  if p_minutes not in (30, 50, 60, 90) then
    raise exception ''수업 길이는 30, 50, 60, 90분 중에서 고르세요'';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception ''종료 시간은 시작 시간보다 뒤여야 합니다'';
  end if;
  if (p_end - p_start) < make_interval(mins => p_minutes) then
    raise exception ''시간 범위가 수업 길이보다 짧습니다'';
  end if;
  cursor_ts := p_date + p_start;
  day_end := p_date + p_end;
  while cursor_ts + make_interval(mins => p_minutes) <= day_end loop
    s := cursor_ts at time zone ''Asia/Seoul'';
    e := (cursor_ts + make_interval(mins => p_minutes)) at time zone ''Asia/Seoul'';
    slot_start := s;
    slot_end := e;
    is_past := s <= now();
    return next;
    cursor_ts := cursor_ts + make_interval(mins => p_minutes);
  end loop;
end;
';

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
as '
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
    raise exception ''로그인이 필요합니다'';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception ''종료일은 시작일보다 뒤여야 합니다'';
  end if;
  if (p_to - p_from) > 92 then
    raise exception ''한 번에 최대 3개월까지 열 수 있습니다'';
  end if;
  if p_weekdays is null or cardinality(p_weekdays) = 0 then
    raise exception ''요일을 선택해 주세요'';
  end if;
  if exists (select 1 from unnest(p_weekdays) w where w < 0 or w > 6) then
    raise exception ''요일 값이 올바르지 않습니다'';
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
            and s.status <> ''closed''
            and s.start_time < slot.slot_end
            and s.end_time > slot.slot_start
        ) then
          skipped_overlap := skipped_overlap + 1;
        else
          if created >= 800 then
            raise exception ''한 번에 800개까지만 열 수 있습니다. 기간을 나눠 주세요'';
          end if;
          insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
          values (uid, slot.slot_start, slot.slot_end, ''available'', 6);
          created := created + 1;
        end if;
      end loop;
    end if;
    d := d + 1;
  end loop;

  if created = 0 and skipped_past = 0 and skipped_overlap = 0 then
    raise exception ''선택한 요일에 해당하는 날이 없습니다'';
  end if;

  return jsonb_build_object(
    ''created'', created,
    ''skipped_past'', skipped_past,
    ''skipped_overlap'', skipped_overlap
  );
end;
';

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
as '
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
    raise exception ''로그인이 필요합니다'';
  end if;
  if p_date is null then
    raise exception ''날짜를 선택해 주세요'';
  end if;
  if p_mode not in (''closed'', ''hours'') then
    raise exception ''처리할 수 없는 예외입니다'';
  end if;

  perform 1
  from public.schedules s
  where s.coach_id = uid
    and s.status <> ''closed''
    and (s.start_time at time zone ''Asia/Seoul'')::date = p_date
  for update;

  if p_mode = ''closed'' then
    select count(*) into booked_hit
    from public.reservations r
    join public.schedules s on s.id = r.schedule_id
    where s.coach_id = uid
      and s.status <> ''closed''
      and s.start_time > now()
      and (s.start_time at time zone ''Asia/Seoul'')::date = p_date
      and r.status in (''confirmed'', ''waiting'');
    if booked_hit > 0 and not coalesce(p_cancel_booked, false) then
      raise exception ''%'', format(''이 날짜에 예약 %s건이 있습니다'', booked_hit);
    end if;
    for rec in
      select s.id
      from public.schedules s
      where s.coach_id = uid
        and s.status <> ''closed''
        and s.start_time > now()
        and (s.start_time at time zone ''Asia/Seoul'')::date = p_date
    loop
      perform public._close_coach_slot(rec.id, true);
      closed_n := closed_n + 1;
    end loop;
    if closed_n = 0 then
      raise exception ''그 날짜에 마감할 열린 시간이 없습니다'';
    end if;
    return jsonb_build_object(''closed'', closed_n, ''created'', 0, ''cancelled_bookings'', booked_hit);
  end if;

  if p_minutes is null then
    p_minutes := 60;
  end if;

  select count(*) into booked_hit
  from public.reservations r
  join public.schedules s on s.id = r.schedule_id
  where s.coach_id = uid
    and s.status <> ''closed''
    and s.start_time > now()
    and (s.start_time at time zone ''Asia/Seoul'')::date = p_date
    and r.status in (''confirmed'', ''waiting'')
    and not exists (
      select 1 from public._slot_grid(p_date, p_start, p_end, p_minutes) g
      where g.is_past = false
        and g.slot_start = s.start_time
        and g.slot_end = s.end_time
    );
  if booked_hit > 0 and not coalesce(p_cancel_booked, false) then
    raise exception ''%'', format(''이 날짜에 예약 %s건이 있습니다'', booked_hit);
  end if;

  for rec in
    select s.id
    from public.schedules s
    where s.coach_id = uid
      and s.status <> ''closed''
      and s.start_time > now()
      and (s.start_time at time zone ''Asia/Seoul'')::date = p_date
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
        and s.status <> ''closed''
        and s.start_time < slot.slot_end
        and s.end_time > slot.slot_start
    ) then
      skipped_overlap := skipped_overlap + 1;
    else
      insert into public.schedules (coach_id, start_time, end_time, status, cancel_hours)
      values (uid, slot.slot_start, slot.slot_end, ''available'', 6);
      created_n := created_n + 1;
    end if;
  end loop;

  if closed_n = 0 and created_n = 0 and skipped_overlap = 0 then
    raise exception ''바꿀 시간이 없습니다. 지난 시간이거나 범위가 너무 짧습니다'';
  end if;

  return jsonb_build_object(
    ''closed'', closed_n,
    ''created'', created_n,
    ''skipped_overlap'', skipped_overlap,
    ''cancelled_bookings'', booked_hit
  );
end;
';

create or replace function public.book_slot(p_share text, p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
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
    raise exception ''회원 정보를 찾을 수 없습니다'';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception ''시간을 찾을 수 없습니다'';
  end if;
  if slot.coach_id is distinct from mem.coach_id then
    raise exception ''이 트레이너의 시간이 아닙니다'';
  end if;
  if slot.status = ''closed'' then
    raise exception ''마감된 시간입니다'';
  end if;
  if slot.start_time <= now() then
    raise exception ''이미 시작된 수업은 예약할 수 없습니다'';
  end if;
  if exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id
      and r.client_id = mem.member_id
      and r.status in (''confirmed'', ''waiting'')
  ) then
    raise exception ''이미 이 시간을 예약했거나 대기 중입니다'';
  end if;

  select exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = ''confirmed''
  ) into has_confirmed;

  label := public._slot_label(slot.start_time);
  if not has_confirmed then
    new_status := ''confirmed'';
    next_order := 0;
    update public.schedules set status = ''booked'' where id = slot.id;
  else
    new_status := ''waiting'';
    select coalesce(max(r.waiting_order), 0) + 1 into next_order
    from public.reservations r
    where r.schedule_id = slot.id and r.status = ''waiting'';
  end if;

  insert into public.reservations (
    schedule_id, client_id, member_share, member_name, status, waiting_order
  ) values (
    slot.id, mem.member_id, mem.member_share, mem.member_name, new_status, next_order
  ) returning id into rid;

  if new_status = ''confirmed'' then
    perform public._booking_notice(
      ''member'', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      ''booked'', ''예약이 확정되었습니다'', label || '' 수업이 확정되었습니다.''
    );
    perform public._booking_notice(
      ''coach'', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      ''booked'', mem.member_name || '' 님 예약'', label || '' 수업이 확정되었습니다.''
    );
  else
    perform public._booking_notice(
      ''member'', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      ''waiting'', ''대기 '' || next_order || ''순위로 신청되었습니다'',
      label || '' 수업은 이미 예약되어 대기 '' || next_order || ''순위입니다. 앞 순번이 취소되면 자동으로 확정됩니다.''
    );
    perform public._booking_notice(
      ''coach'', slot.coach_id, mem.member_id, mem.member_share, slot.id, rid,
      ''waiting'', mem.member_name || '' 님 대기 '' || next_order || ''순위'',
      label || '' 수업에 대기가 추가되었습니다.''
    );
  end if;

  return jsonb_build_object(''id'', rid, ''status'', new_status, ''waiting_order'', next_order);
end;
';

create or replace function public.cancel_reservation(p_share text, p_reservation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
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
    raise exception ''예약을 찾을 수 없습니다'';
  end if;

  select * into slot from public.schedules where id = sid for update;
  if not found then
    raise exception ''시간을 찾을 수 없습니다'';
  end if;
  select * into res from public.reservations where id = p_reservation_id for update;
  if not found or res.status = ''cancelled'' then
    raise exception ''이미 취소된 예약입니다'';
  end if;

  if p_share is not null and length(btrim(p_share)) >= 4 then
    select * into mem from public._booking_member(p_share);
    if mem.member_id is null or mem.member_id <> res.client_id then
      raise exception ''본인 예약만 취소할 수 있습니다'';
    end if;
    if slot.start_time <= now() then
      raise exception ''이미 시작된 수업은 취소할 수 없습니다'';
    end if;
    if res.status = ''confirmed''
       and slot.start_time - make_interval(hours => coalesce(slot.cancel_hours, 6)) <= now() then
      raise exception ''%'', format(''수업 시작 %s시간 전까지만 취소할 수 있습니다'', coalesce(slot.cancel_hours, 6));
    end if;
  elsif uid is not null and uid = slot.coach_id then
    is_coach := true;
  else
    raise exception ''취소 권한이 없습니다'';
  end if;

  update public.reservations
  set status = ''cancelled'', waiting_order = 0, cancelled_at = now()
  where id = res.id;

  label := public._slot_label(slot.start_time);

  if res.status = ''confirmed'' and slot.status <> ''closed'' and slot.start_time > now() then
    select r.id, r.member_name, r.member_share, r.client_id
      into promoted_id, promoted_name, promoted_share, promoted_member
    from public.reservations r
    where r.schedule_id = slot.id
      and r.status = ''waiting''
    order by r.waiting_order asc, r.created_at asc
    limit 1
    for update;

    if promoted_id is not null then
      update public.reservations
      set status = ''confirmed'', waiting_order = 0
      where id = promoted_id;
      perform public._booking_notice(
        ''member'', slot.coach_id, promoted_member, promoted_share, slot.id, promoted_id,
        ''promoted'', ''대기에서 예약이 확정되었습니다'',
        label || '' 수업이 확정되었습니다. 앞 순번 취소로 자동 승계되었습니다.''
      );
      perform public._booking_notice(
        ''coach'', slot.coach_id, promoted_member, promoted_share, slot.id, promoted_id,
        ''promoted'', promoted_name || '' 님 자동 확정'',
        label || '' 빈자리로 '' || promoted_name || '' 님이 확정되었습니다.''
      );
    end if;
  end if;

  perform public._renumber_waitlist(slot.id);

  if not exists (
    select 1 from public.reservations r
    where r.schedule_id = slot.id and r.status = ''confirmed''
  ) and slot.status = ''booked'' then
    update public.schedules set status = ''available'' where id = slot.id;
  end if;

  perform public._booking_notice(
    ''member'', slot.coach_id, res.client_id, res.member_share, slot.id, res.id,
    ''cancelled'', ''예약이 취소되었습니다'',
    label || '' 예약이 취소되었습니다.''
  );
  perform public._booking_notice(
    ''coach'', slot.coach_id, res.client_id, res.member_share, slot.id, res.id,
    ''cancelled'', res.member_name || '' 님 취소'',
    label || '' 예약이 취소되었습니다.'' ||
    case when promoted_id is not null then '' '' || promoted_name || '' 님이 확정으로 올라갔습니다.'' else '''' end
  );

  return jsonb_build_object(
    ''cancelled_id'', res.id,
    ''promoted'', case
      when promoted_id is null then null
      when is_coach then jsonb_build_object(''id'', promoted_id, ''name'', promoted_name)
      else jsonb_build_object(''ok'', true)
    end
  );
end;
';

create or replace function public.booking_board(p_share text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as '
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
      raise exception ''회원 정보를 찾을 수 없습니다'';
    end if;

    select coalesce(jsonb_agg(x.slot order by x.start_time), ''[]''::jsonb)
      into slots
    from (
      select s.start_time,
        jsonb_build_object(
          ''id'', s.id,
          ''start_time'', s.start_time,
          ''end_time'', s.end_time,
          ''status'', s.status,
          ''cancel_hours'', s.cancel_hours,
          ''has_confirmed'', exists (
            select 1 from public.reservations r
            where r.schedule_id = s.id and r.status = ''confirmed''
          ),
          ''wait_count'', (
            select count(*) from public.reservations r
            where r.schedule_id = s.id and r.status = ''waiting''
          ),
          ''mine'', (
            select jsonb_build_object(
              ''id'', r.id,
              ''status'', r.status,
              ''waiting_order'', r.waiting_order
            )
            from public.reservations r
            where r.schedule_id = s.id
              and r.client_id = mem.member_id
              and r.status in (''confirmed'', ''waiting'')
            limit 1
          )
        ) as slot
      from public.schedules s
      where s.coach_id = mem.coach_id
        and s.status <> ''closed''
        and s.end_time > now()
    ) x;

    select count(*) into unread
    from public.booking_notices n
    where n.audience = ''member''
      and n.member_share = mem.member_share
      and n.read_at is null;

    select coalesce(jsonb_agg(jsonb_build_object(
      ''id'', n.id, ''kind'', n.kind, ''title'', n.title, ''body'', n.body,
      ''created_at'', n.created_at, ''read_at'', n.read_at
    ) order by n.created_at desc), ''[]''::jsonb)
      into notes
    from (
      select * from public.booking_notices
      where audience = ''member'' and member_share = mem.member_share
      order by created_at desc
      limit 20
    ) n;

    return jsonb_build_object(''role'', ''member'', ''unread'', unread, ''notices'', notes, ''slots'', slots);
  end if;

  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;

  select coalesce(jsonb_agg(x.slot order by x.start_time), ''[]''::jsonb)
    into slots
  from (
    select s.start_time,
      jsonb_build_object(
        ''id'', s.id,
        ''start_time'', s.start_time,
        ''end_time'', s.end_time,
        ''status'', s.status,
        ''cancel_hours'', s.cancel_hours,
        ''reservations'', coalesce((
          select jsonb_agg(jsonb_build_object(
            ''id'', r.id,
            ''client_id'', r.client_id,
            ''name'', r.member_name,
            ''status'', r.status,
            ''waiting_order'', r.waiting_order
          ) order by case r.status when ''confirmed'' then 0 when ''waiting'' then 1 else 2 end, r.waiting_order, r.created_at)
          from public.reservations r
          where r.schedule_id = s.id and r.status <> ''cancelled''
        ), ''[]''::jsonb)
      ) as slot
    from public.schedules s
    where s.coach_id = uid
      and s.end_time > now()
  ) x;

  select count(*) into unread
  from public.booking_notices n
  where n.audience = ''coach'' and n.coach_id = uid and n.read_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    ''id'', n.id, ''kind'', n.kind, ''title'', n.title, ''body'', n.body,
    ''created_at'', n.created_at, ''read_at'', n.read_at
  ) order by n.created_at desc), ''[]''::jsonb)
    into notes
  from (
    select * from public.booking_notices
    where audience = ''coach'' and coach_id = uid
    order by created_at desc
    limit 20
  ) n;

  return jsonb_build_object(''role'', ''coach'', ''unread'', unread, ''notices'', notes, ''slots'', slots);
end;
';

create or replace function public.read_booking_notices(p_share text)
returns void
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid := auth.uid();
  mem record;
begin
  if p_share is not null and length(btrim(p_share)) >= 4 then
    select * into mem from public._booking_member(p_share);
    if mem.member_id is null then
      raise exception ''회원 정보를 찾을 수 없습니다'';
    end if;
    update public.booking_notices
    set read_at = now()
    where audience = ''member''
      and member_share = mem.member_share
      and read_at is null;
    return;
  end if;
  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;
  update public.booking_notices
  set read_at = now()
  where audience = ''coach'' and coach_id = uid and read_at is null;
end;
';

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
as '
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  old_label text;
  new_label text;
begin
  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception ''종료 시간은 시작 시간보다 뒤여야 합니다'';
  end if;
  if p_end - p_start < interval ''15 minutes'' then
    raise exception ''수업은 15분 이상이어야 합니다'';
  end if;
  if p_start <= now() then
    raise exception ''이미 지난 시간으로는 옮길 수 없습니다'';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception ''시간을 찾을 수 없습니다'';
  end if;
  if slot.coach_id <> uid then
    raise exception ''본인이 연 시간만 수정할 수 있습니다'';
  end if;
  if slot.status = ''closed'' then
    raise exception ''마감된 시간은 수정할 수 없습니다'';
  end if;
  if exists (
    select 1 from public.schedules s
    where s.coach_id = uid
      and s.id <> slot.id
      and s.status <> ''closed''
      and s.start_time < p_end
      and s.end_time > p_start
  ) then
    raise exception ''이미 겹치는 오픈 시간이 있습니다'';
  end if;
  old_label := public._slot_label(slot.start_time);
  update public.schedules
  set start_time = p_start, end_time = p_end
  where id = slot.id;
  new_label := public._slot_label(p_start);
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in (''confirmed'', ''waiting'')
  loop
    perform public._booking_notice(
      ''member'', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      ''closed'', ''수업 시간이 변경되었습니다'',
      old_label || '' 수업이 '' || new_label || '' 으로 옮겨졌습니다. 예약은 그대로입니다.''
    );
  end loop;
  return jsonb_build_object(''id'', slot.id, ''start_time'', p_start, ''end_time'', p_end);
end;
';

revoke all on function public.move_schedule(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.move_schedule(uuid, timestamptz, timestamptz) to authenticated;

create or replace function public.delete_schedule(p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as '
declare
  uid uuid := auth.uid();
  slot public.schedules%rowtype;
  rec record;
  label text;
begin
  if uid is null then
    raise exception ''로그인이 필요합니다'';
  end if;
  select * into slot from public.schedules where id = p_schedule_id for update;
  if not found then
    raise exception ''시간을 찾을 수 없습니다'';
  end if;
  if slot.coach_id <> uid then
    raise exception ''본인이 연 시간만 취소할 수 있습니다'';
  end if;
  label := public._slot_label(slot.start_time);
  for rec in
    select * from public.reservations
    where schedule_id = slot.id and status in (''confirmed'', ''waiting'')
    for update
  loop
    perform public._booking_notice(
      ''member'', slot.coach_id, rec.client_id, rec.member_share, slot.id, rec.id,
      ''cancelled'', ''수업 오픈이 취소되었습니다'',
      label || '' 수업이 오픈 전 상태로 되돌려져 예약이 취소되었습니다.''
    );
  end loop;
  update public.booking_notices set schedule_id = null where schedule_id = slot.id;
  delete from public.schedules where id = slot.id;
  return jsonb_build_object(''id'', p_schedule_id, ''deleted'', true);
end;
';

revoke all on function public.delete_schedule(uuid) from public, anon;
grant execute on function public.delete_schedule(uuid) to authenticated;
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

do ' begin
  alter publication supabase_realtime add table public.schedules;
exception when duplicate_object then null;
end ';
do ' begin
  alter publication supabase_realtime add table public.reservations;
exception when duplicate_object then null;
end ';
do ' begin
  alter publication supabase_realtime add table public.booking_notices;
exception when duplicate_object then null;
end ';

notify pgrst, 'reload schema';
