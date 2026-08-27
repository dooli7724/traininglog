-- PT Logger multi-tenant schema. Safe to re-run in the SQL Editor.

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

drop policy if exists gyms_owner on public.gyms;
create policy gyms_owner on public.gyms
  for all to authenticated
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

drop policy if exists gym_state_owner on public.gym_state;
create policy gym_state_owner on public.gym_state
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists member_logs_owner on public.member_logs;
create policy member_logs_owner on public.member_logs
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

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
    insert into public.gym_state (gym_id, user_id, data)
      values (gid, uid, '{"members":[]}'::jsonb);
  else
    update public.gym_state
      set user_id = coalesce(user_id, uid)
      where gym_state.gym_id = gid;
  end if;
  return query
    select s.gym_id, s.data, s.rev
    from public.gym_state s
    where s.gym_id = gid and s.user_id = uid;
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
    insert into public.gym_state (gym_id, user_id, data, rev)
      values (gid, uid, coalesce(p_data, '{"members":[]}'::jsonb), 1);
    return 1;
  end if;
  update public.gym_state
    set data = coalesce(p_data, '{"members":[]}'::jsonb),
        user_id = uid,
        rev = rev + 1,
        updated_at = now()
    where gym_id = gid and user_id = uid
    returning rev into new_rev;
  if new_rev is null then
    update public.gym_state
      set data = coalesce(p_data, '{"members":[]}'::jsonb),
          user_id = uid,
          rev = rev + 1,
          updated_at = now()
      where gym_id = gid
      returning rev into new_rev;
  end if;
  return coalesce(new_rev, 1);
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
       jsonb_array_elements(s.data->'members') e
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
  select s.gym_id, s.user_id into gid, uid
  from public.gym_state s,
       jsonb_array_elements(s.data->'members') e
  where e->>'share' = p_share
  limit 1;
  if gid is null then
    raise exception 'member not found';
  end if;
  if uid is null then
    select g.owner_id into uid from public.gyms g where g.id = gid;
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

revoke all on public.gyms from anon;
revoke all on public.gym_state from anon;
revoke all on public.member_logs from anon;
grant select, insert, update, delete on public.gyms to authenticated;
grant select, insert, update, delete on public.gym_state to authenticated;
grant select, insert, update, delete on public.member_logs to authenticated;

grant execute on function public.ensure_gym() to authenticated;
grant execute on function public.push_gym_state(jsonb) to authenticated;
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
