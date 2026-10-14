const { spawnSync } = require("child_process");
const { existsSync, readFileSync } = require("fs");
const { join } = require("path");

const root = join(__dirname, "..");
const ref = "trayuemhwffwcalrjasy";

function loadEnv(path) {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (process.env[key] == null || process.env[key] === "") process.env[key] = value;
  }
}

loadEnv(join(root, ".env"));

let dbUrl = process.env.SUPABASE_DB_URL || "";
if (!dbUrl && process.env.SUPABASE_DB_PASSWORD) {
  const password = encodeURIComponent(process.env.SUPABASE_DB_PASSWORD);
  dbUrl = `postgresql://postgres.${ref}:${password}@aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres?sslmode=require`;
}

if (!dbUrl) {
  console.error(
    "DB 비밀번호가 없습니다. Supabase Dashboard → Project Settings → Database 의 비밀번호를 .env 의 SUPABASE_DB_PASSWORD 에 한 번만 넣어 주세요. .env 는 커밋되지 않습니다."
  );
  process.exit(1);
}

const bin = join(root, "node_modules", ".bin", "supabase");
const result = spawnSync(bin, ["db", "push", "--yes", "--db-url", dbUrl], {
  cwd: root,
  stdio: "inherit",
  env: process.env
});

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status == null ? 1 : result.status);
