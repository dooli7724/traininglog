# traininglog

PT 운동 일지 웹앱. 트레이너 화면은 로그인 후 Supabase 클라우드에 저장되어 아이폰·아이패드·PC에서 같은 데이터가 보입니다. 회원 공유 링크는 로그인 없이 동작합니다.

## 클라우드 연결 (최초 1회)

1. [Supabase](https://supabase.com/dashboard)에서 무료 프로젝트를 만듭니다.
2. **Project Settings → API**에서 Project URL과 `anon public` 키를 복사합니다.
3. **SQL Editor**에 `supabase/schema.sql` 전체를 붙여넣고 실행합니다.
4. **Authentication → Providers → Email**에서 Confirm email을 끕니다. (본인만 쓰는 앱)
5. 배포된 앱에서 URL과 anon key를 입력한 뒤, 트레이너 계정을 만들어 로그인합니다.

이 기기에 있던 기존 기록은 클라우드가 비어 있을 때 자동으로 올라갑니다.

Vercel 환경변수로 넣을 수도 있습니다: `SUPABASE_URL`, `SUPABASE_ANON_KEY` (`/api/cloud-config`).
