/* Supabase 공개 키 (anon key는 프론트에 넣어도 됩니다. 실제 보호는 RLS).
   비워 두면 로그인 화면에서 직접 입력하거나, Vercel 환경변수 + /api/cloud-config 를 사용합니다. */
window.PT_CLOUD = {
  supabaseUrl: "",
  supabaseAnonKey: ""
};
