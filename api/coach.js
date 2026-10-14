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

module.exports = async (req, res) => {
  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");
    res.status(204).end();
    return;
  }
  if (req.method !== "POST") {
    res.status(405).json({ configured: false });
    return;
  }
  const key = process.env.OPENAI_API_KEY || process.env.AI_API_KEY || "";
  if (!key) {
    res.status(200).json({ configured: false });
    return;
  }
  try {
    const body = await readJson(req);
    const brief = body && body.brief ? body.brief : {};
    const model = process.env.AI_MODEL || "gpt-4o-mini";
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + key,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        model,
        temperature: 0.4,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content: "너는 1:1 PT 트레이너의 수업 보조다. 한국어로만 말한다. 입력 brief의 목표, 부상, 최근 일지, draftDirection을 읽고 오늘의 코칭 방향만 다듬는다. JSON {\"direction\":\"...\"} 만 반환한다. 3~5문장. 입력에 없는 중량이나 횟수를 만들지 않는다. 진단이나 치료 지시를 하지 않는다. 부상 부위를 억지로 밀어붙이지 않는다."
          },
          { role: "user", content: JSON.stringify(brief).slice(0, 12000) }
        ]
      })
    });
    if (!response.ok) {
      res.status(200).json({ configured: true, direction: "" });
      return;
    }
    const data = await response.json();
    const raw = data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
    let direction = "";
    try { direction = String((JSON.parse(raw) || {}).direction || "").trim(); } catch (_) { direction = ""; }
    res.status(200).json({ configured: true, direction });
  } catch (_) {
    res.status(200).json({ configured: true, direction: "" });
  }
};
