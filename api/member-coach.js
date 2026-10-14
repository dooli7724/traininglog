async function readJson(req) {
  if (req.body && typeof req.body === "object") return req.body;
  if (typeof req.body === "string" && req.body) {
    try { return JSON.parse(req.body); } catch (_) { return {}; }
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch (_) { return {}; }
}

function clip(value, max) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, max);
}

function contextBlock(ctx) {
  const profile = (ctx && ctx.profile) || {};
  const recent = (ctx && ctx.recent) || {};
  const lines = ["회원 프로필"];
  lines.push("- 목표: " + (clip(profile.goal, 200) || "없음"));
  lines.push("- 부상/통증: " + (clip(profile.history, 400) || "없음"));
  const level = [clip(profile.level, 20), clip(profile.experience, 80)].filter(Boolean).join(" · ");
  lines.push("- 경력/수준: " + (level || "없음"));
  if (profile.age) lines.push("- 연령: " + clip(profile.age, 12));
  if (profile.gender) lines.push("- 성별: " + clip(profile.gender, 12));
  const workouts = Array.isArray(recent.workouts) ? recent.workouts.slice(-8) : [];
  lines.push("최근 개인 운동");
  if (!workouts.length) lines.push("- 없음");
  workouts.forEach((row) => {
    lines.push("- " + [clip(row.date, 12), clip(row.name, 40), clip(row.weight, 12) && (clip(row.weight, 12) + "kg"), clip(row.reps, 8) && (clip(row.reps, 8) + "회"), clip(row.note, 80)].filter(Boolean).join(" "));
  });
  const diets = Array.isArray(recent.diets) ? recent.diets.slice(-8) : [];
  lines.push("최근 식단");
  if (!diets.length) lines.push("- 없음");
  diets.forEach((row) => {
    lines.push("- " + [clip(row.date, 12), clip(row.meal, 12), clip(row.text, 160)].filter(Boolean).join(" "));
  });
  const sessions = Array.isArray(recent.sessions) ? recent.sessions.slice(-4) : [];
  lines.push("최근 트레이너 수업");
  if (!sessions.length) lines.push("- 없음");
  sessions.forEach((row) => {
    const moves = (Array.isArray(row.exercises) ? row.exercises : []).slice(0, 6).map((ex) => {
      const name = clip(ex && ex.name, 30);
      const record = clip(ex && ex.record, 80);
      return record ? name + " " + record : name;
    }).filter(Boolean).join(" / ");
    const feedback = clip(row.feedback, 120);
    lines.push("- " + [clip(row.date, 12), moves, feedback && ("피드백 " + feedback)].filter(Boolean).join(" "));
  });
  return lines.join("\n").slice(0, 6000);
}

function cleanMessages(list) {
  const out = [];
  (Array.isArray(list) ? list : []).forEach((row) => {
    if (!row || (row.role !== "user" && row.role !== "assistant")) return;
    const content = String(row.content || "").trim().slice(0, 1200);
    if (!content) return;
    out.push({ role: row.role, content });
  });
  return out.slice(-16);
}

module.exports = async (req, res) => {
  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    res.status(204).end();
    return;
  }
  if (req.method !== "POST") {
    res.status(405).json({ configured: false, reply: "" });
    return;
  }
  const key = process.env.OPENAI_API_KEY || process.env.AI_API_KEY || "";
  if (!key) {
    res.status(200).json({ configured: false, reply: "" });
    return;
  }
  try {
    const body = await readJson(req);
    const messages = cleanMessages(body && body.messages);
    const last = messages[messages.length - 1];
    if (!last || last.role !== "user") {
      res.status(200).json({ configured: true, reply: "" });
      return;
    }
    const system = [
      "너는 전문 피트니스 코치다. 회원의 목표, 부상 이력, 일일 식단, 개인 운동에 대해 친절하고 과학적인 조언을 제공한다.",
      "한국어 존댓말로 말한다. 메시지 앱에서 읽기 좋게 짧게 나누고, 필요할 때만 줄을 나눠 적는다.",
      "진단, 약, 치료 식단, 치료 지시를 하지 않는다. 통증이 심하거나 저리면 운동을 멈추고 담당 트레이너나 의료진에게 알리라고 한다.",
      "프로필에 적힌 부상 부위를 자극하는 고중량, 점프, 끝까지 굽히는 동작은 추천하지 않는다.",
      "입력에 없는 체중, 병명, 먹은 음식을 지어내지 않는다. 기록이 없으면 없다고 말하고 일반적인 제안을 한다.",
      "운동을 추천할 때는 워밍업, 본운동, 마무리 순서로 제안할 수 있다.",
      "식단을 물을 때는 오늘 기록된 끼니를 먼저 짚고, 저녁은 목표에 맞게 구체적으로 제안한다.",
      "",
      contextBlock(body && body.context)
    ].join("\n");
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + key,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model: process.env.AI_MODEL || "gpt-4o-mini",
        temperature: 0.5,
        max_tokens: 700,
        messages: [{ role: "system", content: system }].concat(messages)
      })
    });
    if (!response.ok) {
      res.status(200).json({ configured: true, reply: "" });
      return;
    }
    const data = await response.json();
    const reply = String(data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content || "").trim().slice(0, 2000);
    res.status(200).json({ configured: true, reply });
  } catch (_) {
    res.status(200).json({ configured: true, reply: "" });
  }
};
