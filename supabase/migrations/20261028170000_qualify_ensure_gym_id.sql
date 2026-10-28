-- ensure_gym()의 반환 컬럼 이름이 gym_state.gym_id와 겹쳐
-- 로그인 후 상태 조회가 column reference "gym_id" is ambiguous 로 실패했습니다.
-- 출력 컬럼보다 테이블 컬럼을 쓰고, gym_id는 테이블 별칭으로 가리킵니다.

create or replace function public.ensure_gym()
returns table (gym_id uuid, data jsonb, rev bigint)
language plpgsql
security definer
set search_path = public
as $fn$
#variable_conflict use_column
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
  insert into public.gym_state as gs (gym_id, user_id, data)
    values (gid, uid, '{"members":[]}'::jsonb)
  on conflict (gym_id) do update
    set user_id = coalesce(gs.user_id, excluded.user_id);
  update public.member_logs
    set user_id = uid
    where public.member_logs.gym_id = gid
      and public.member_logs.user_id is null;
  return query
    select s.gym_id, s.data, s.rev
    from public.gym_state s
    where s.gym_id = gid;
end;
$fn$;
