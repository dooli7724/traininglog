-- PT Logger multi-tenant schema + RLS
-- Supabase Dashboard → SQL Editor 에 이 파일 전체를 붙여넣고 Run 하세요.
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

update public.gym_state s
  set user_id = g.owner_id
  from public.gyms g
  where g.id = s.gym_id and s.user_id is null;

update public.member_logs m
  set user_id = g.owner_id
  from public.gyms g
  where g.id = m.gym_id and m.user_id is null;

create index if not exists member_logs_share_idx on public.member_logs(share);
create index if not exists member_logs_gym_idx on public.member_logs(gym_id);
create index if not exists member_logs_user_idx on public.member_logs(user_id);
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
as $$
  select exists (
    select 1 from public.gyms g
    where g.id = p_gym_id and g.owner_id = auth.uid()
  );
$$;

create or replace function public.own_user(p_user_id uuid)
returns boolean
language sql
stable
as $$
  select p_user_id is not null and p_user_id = auth.uid();
$$;

do $$
declare pol record;
begin
  for pol in
    select policyname, tablename
    from pg_policies
    where schemaname = 'public'
      and tablename in ('gyms', 'gym_state', 'member_logs')
  loop
    execute format('drop policy if exists %I on public.%I', pol.policyname, pol.tablename);
  end loop;
end $$;

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
create policy gym_state_select on public.gym_state
  for select to authenticated
  using (public.own_user(user_id) or public.owns_gym(gym_id));
create policy gym_state_insert on public.gym_state
  for insert to authenticated
  with check (public.own_user(user_id) and public.owns_gym(gym_id));
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
  with check (public.own_user(user_id) and public.owns_gym(gym_id));
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
as $$
declare
  gid uuid;
  uid uuid;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'not authenticated';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data)
    values (gid, uid, '{"members":[]}'::jsonb)
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
$$;

create or replace function public.load_trainer_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  gid uuid;
  payload jsonb;
  r_rev bigint;
  logs jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'not authenticated';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data)
    values (gid, uid, '{"members":[]}'::jsonb)
  on conflict (gym_id) do update
    set user_id = coalesce(public.gym_state.user_id, excluded.user_id);
  update public.member_logs
    set user_id = uid
    where member_logs.gym_id = gid and member_logs.user_id is null;
  select s.data, s.rev into payload, r_rev
    from public.gym_state s
    where s.gym_id = gid;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id,
      'share', l.share,
      'kind', l.kind,
      'payload', l.payload
    ) order by l.updated_at), '[]'::jsonb)
    into logs
    from public.member_logs l
    where l.gym_id = gid;
  return jsonb_build_object(
    'gym_id', gid,
    'data', coalesce(payload, '{"members":[]}'::jsonb),
    'rev', coalesce(r_rev, 1),
    'logs', coalesce(logs, '[]'::jsonb)
  );
end;
$$;

create or replace function public.push_gym_state(p_data jsonb)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  uid uuid;
  new_rev bigint;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'not authenticated';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    insert into public.gyms (owner_id) values (uid) returning id into gid;
  end if;
  insert into public.gym_state (gym_id, user_id, data, rev)
    values (gid, uid, coalesce(p_data, '{"members":[]}'::jsonb), 1)
  on conflict (gym_id) do update
    set data = excluded.data,
        user_id = uid,
        rev = public.gym_state.rev + 1,
        updated_at = now()
    returning rev into new_rev;
  return coalesce(new_rev, 1);
end;
$$;

create or replace function public.upsert_member_logs(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  gid uuid;
  n int := 0;
  rec jsonb;
begin
  uid := auth.uid();
  if uid is null then
    raise exception 'not authenticated';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;
  select g.id into gid from public.gyms g where g.owner_id = uid;
  if gid is null then
    return 0;
  end if;
  for rec in select value from jsonb_array_elements(p_rows)
  loop
    if coalesce(rec->>'id', '') = '' then
      continue;
    end if;
    if coalesce(rec->>'kind', '') not in ('self_workout', 'diet') then
      continue;
    end if;
    insert into public.member_logs (id, gym_id, user_id, share, kind, payload, updated_at)
    values (
      rec->>'id',
      gid,
      uid,
      coalesce(rec->>'share', ''),
      rec->>'kind',
      coalesce(rec->'payload', '{}'::jsonb),
      now()
    )
    on conflict (id) do update
      set payload = excluded.payload,
          kind = excluded.kind,
          share = excluded.share,
          gym_id = excluded.gym_id,
          user_id = excluded.user_id,
          updated_at = now()
      where public.member_logs.gym_id = gid;
    n := n + 1;
  end loop;
  return n;
end;
$$;

create or replace function public.member_public(p_ref text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  mem jsonb;
  p_share text;
  workouts jsonb;
  diets jsonb;
begin
  if p_ref is null or length(trim(p_ref)) < 4 then
    return null;
  end if;
  select e into mem
  from public.gym_state s,
       jsonb_array_elements(coalesce(s.data->'members', '[]'::jsonb)) e
  where e->>'share' = p_ref or e->>'id' = p_ref
  limit 1;
  if mem is null then
    return null;
  end if;
  p_share := mem->>'share';
  select coalesce(jsonb_agg(payload order by updated_at), '[]'::jsonb)
    into workouts
    from public.member_logs
    where share = p_share and kind = 'self_workout';
  select coalesce(jsonb_agg(payload order by updated_at), '[]'::jsonb)
    into diets
    from public.member_logs
    where share = p_share and kind = 'diet';
  return mem || jsonb_build_object('selfWorkouts', workouts, 'dietLogs', diets);
end;
$$;

create or replace function public.member_upsert_log(p_share text, p_kind text, p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
  uid uuid;
  rid text;
begin
  if p_kind not in ('self_workout', 'diet') then
    raise exception 'invalid kind';
  end if;
  if p_share is null or length(trim(p_share)) < 4 then
    raise exception 'invalid share';
  end if;
  rid := coalesce(p_row->>'id', '');
  if rid = '' then
    raise exception 'missing id';
  end if;
  select s.gym_id, coalesce(s.user_id, g.owner_id) into gid, uid
  from public.gym_state s
  join public.gyms g on g.id = s.gym_id,
       jsonb_array_elements(coalesce(s.data->'members', '[]'::jsonb)) e
  where e->>'share' = p_share
  limit 1;
  if gid is null then
    raise exception 'member not found';
  end if;
  insert into public.member_logs (id, gym_id, user_id, share, kind, payload, updated_at)
  values (rid, gid, uid, p_share, p_kind, p_row, now())
  on conflict (id) do update
    set payload = excluded.payload,
        kind = excluded.kind,
        share = excluded.share,
        gym_id = excluded.gym_id,
        user_id = excluded.user_id,
        updated_at = now();
  return p_row;
end;
$$;

create or replace function public.member_delete_log(p_share text, p_id text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
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
$$;

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

do $$ begin
  alter publication supabase_realtime add table public.gym_state;
exception when duplicate_object then null;
end $$;

do $$ begin
  alter publication supabase_realtime add table public.member_logs;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';
