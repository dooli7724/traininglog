# traininglog

PT 운동 일지 웹앱. 배포된 주소에서 누구나 이메일로 가입·로그인할 수 있고, 트레이너마다 회원·스케줄·일지가 따로 저장됩니다. 회원 공유 링크는 로그인 없이 동작합니다.

데이터베이스 변경은 `supabase/migrations`에 파일을 추가한 뒤 `npm run db:push`로 반영합니다. SQL Editor에 붙여 넣지 않습니다. 최초 한 번만 `.env`에 `SUPABASE_DB_PASSWORD`를 넣으면 됩니다. `schema.sql`은 전체 구조 참고용입니다.
