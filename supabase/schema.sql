-- PT Logger cloud schema. Run once in Supabase SQL Editor.

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
  id text primary key,
  gym_id uuid not null references public.gyms(id) on delete cascade,
  share text not null,
  kind text not null check (kind in ('self_workout', 'diet')),
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

create index if not exists member_logs_share_idx on public.member_logs(share);
create index if not exists member_logs_gym_idx on public.member_logs(gym_id);

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
  using (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()))
  with check (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()));

drop policy if exists member_logs_owner on public.member_logs;
create policy member_logs_owner on public.member_logs
  for all to authenticated
  using (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()))
  with check (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()));

create or replace function public.ensure_gym()
returns table (gym_id uuid, data jsonb, rev bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = auth.uid();
  if gid is null then
    insert into public.gyms (owner_id) values (auth.uid()) returning id into gid;
    insert into public.gym_state (gym_id, data) values (gid, '{"members":[]}'::jsonb);
  end if;
  return query
    select s.gym_id, s.data, s.rev
    from public.gym_state s
    where s.gym_id = gid;
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
  new_rev bigint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select g.id into gid from public.gyms g where g.owner_id = auth.uid();
  if gid is null then
    insert into public.gyms (owner_id) values (auth.uid()) returning id into gid;
    insert into public.gym_state (gym_id, data, rev) values (gid, coalesce(p_data, '{"members":[]}'::jsonb), 1);
    return 1;
  end if;
  update public.gym_state
    set data = coalesce(p_data, '{"members":[]}'::jsonb),
        rev = rev + 1,
        updated_at = now()
    where gym_id = gid
    returning rev into new_rev;
  return new_rev;
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
  select s.gym_id into gid
  from public.gym_state s,
       jsonb_array_elements(s.data->'members') e
  where e->>'share' = p_share
  limit 1;
  if gid is null then
    raise exception 'member not found';
  end if;
  insert into public.member_logs (id, gym_id, share, kind, payload, updated_at)
  values (rid, gid, p_share, p_kind, p_row, now())
  on conflict (id) do update
    set payload = excluded.payload,
        kind = excluded.kind,
        share = excluded.share,
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
create policy "pt media auth write"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'pt-media')
  with check (bucket_id = 'pt-media');

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
