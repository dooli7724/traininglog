-- 회원 목록이 있는 저장본을 빈 목록으로 덮지 않습니다.
-- 이미 적용된 마이그레이션은 수정하지 않습니다.

create or replace function public.keep_gym_members()
returns trigger
language plpgsql
as $fn$
declare
  old_n int := 0;
  new_n int := 0;
begin
  if tg_op <> 'UPDATE' then
    return new;
  end if;
  if jsonb_typeof(old.data -> 'members') = 'array' then
    old_n := jsonb_array_length(old.data -> 'members');
  end if;
  if jsonb_typeof(new.data -> 'members') = 'array' then
    new_n := jsonb_array_length(new.data -> 'members');
  end if;
  if old_n > 0 and new_n = 0 then
    raise exception '회원 목록이 비어 있어 기존 기록을 덮지 않았습니다.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists gym_state_keep_members on public.gym_state;
create trigger gym_state_keep_members
  before update on public.gym_state
  for each row execute procedure public.keep_gym_members();
