(function (global) {
  const PATTERNS = [
    { id: "squat", keys: ["점프스쿼트", "점프 스쿼트", "고블릿 스쿼트", "박스 스쿼트", "프론트 스쿼트", "불가리안", "레그프레스", "legpress", "스쿼트", "squat", "런지", "lunge", "스텝업"] },
    { id: "hinge", keys: ["루마니안 데드리프트", "루마니안", "스티프 레그", "힙 쓰러스트", "힙쓰러스트", "hipthrust", "케틀벨 스윙", "컨벤셔널", "데드리프트", "deadlift", "굿모닝", "힙힌지", "rdl"] },
    { id: "hpush", keys: ["덤벨 벤치", "벤치 프레스", "벤치프레스", "체스트 프레스", "체스트프레스", "플로어 프레스", "푸시업", "푸쉬업", "pushup", "딥스", "체스트 플라이", "벤치", "bench"] },
    { id: "vpush", keys: ["랜드마인 프레스", "덤벨 숄더", "숄더 프레스", "숄더프레스", "오버헤드", "밀리터리", "사이드 레터럴", "레터럴 레이즈", "숄더", "ohp"] },
    { id: "hpull", keys: ["시티드 로우", "시티드로우", "바벨 로우", "원암 로우", "페이스 풀", "페이스풀", "씨티드 로우", "로우", "row"] },
    { id: "vpull", keys: ["랫 풀다운", "랫풀다운", "랫풀", "풀다운", "턱걸이", "풀업", "pullup", "친업"] },
    { id: "core", keys: ["사이드 플랭크", "데드버그", "버드독", "레그 레이즈", "레그레이즈", "크런치", "플랭크", "plank"] },
    { id: "carry", keys: ["파머스 캐리", "파머", "캐리", "carry"] },
    { id: "cardio", keys: ["에어로바이크", "로잉 머신", "로잉머신", "어썰트", "버피", "자전거"] }
  ];
  const LOWER = { squat: 1, hinge: 1 };
  const UPPER = { hpush: 1, vpush: 1, hpull: 1, vpull: 1 };

  function pad(n) { return String(n).padStart(2, "0"); }
  function dateFromIso(iso) {
    const p = String(iso || "").split("-").map(Number);
    return new Date(p[0], (p[1] || 1) - 1, p[2] || 1);
  }
  function isoFromDate(d) {
    return [d.getFullYear(), pad(d.getMonth() + 1), pad(d.getDate())].join("-");
  }
  function addDays(iso, n) {
    const d = dateFromIso(iso);
    d.setDate(d.getDate() + n);
    return isoFromDate(d);
  }
  function shortDate(iso) {
    const p = String(iso || "").split("-");
    if (p.length < 3) return iso || "";
    return Number(p[1]) + "/" + Number(p[2]);
  }
  function clip(s, n) {
    const t = String(s || "").replace(/\s+/g, " ").trim();
    if (t.length <= n) return t;
    return t.slice(0, n - 1) + "…";
  }
  function compact(s) { return String(s || "").toLowerCase().replace(/\s+/g, ""); }
  function includesKey(name, key) {
    if (key === "로우") return /(?<!슬)로우/.test(name);
    if (key === "row") return /row/.test(name) && !/slow/.test(name);
    return name.includes(key);
  }
  function patternOf(name) {
    const n = compact(name);
    let best = null;
    PATTERNS.forEach((p) => {
      p.keys.forEach((k) => {
        const key = compact(k);
        if (includesKey(n, key) && (!best || key.length > best.len)) best = { id: p.id, len: key.length };
      });
    });
    return best ? best.id : "other";
  }
  function injuryFlags(text) {
    const t = String(text || "");
    return {
      back: /허리|요추|디스크|좌골|척추/.test(t),
      knee: /무릎|슬개|반월/.test(t),
      shoulder: /어깨|회전근|오십견|충돌/.test(t),
      neck: /경추|거북목|목 통증|목통증|목이/.test(t),
      wrist: /손목/.test(t),
      ankle: /발목/.test(t)
    };
  }
  function goalKind(text) {
    const t = String(text || "");
    if (/재활|통증 완화|자세|교정/.test(t)) return "rehab";
    if (/체지방|감량|다이어트|살 빼|린매스|컷팅/.test(t)) return "fat";
    if (/근력|파워|3대|1rm|스트렝스|중량/.test(t)) return "strength";
    if (/근비대|벌크|근육량|사이즈|근육 키/.test(t)) return "hyper";
    if (/체력|컨디|지구력|심폐/.test(t)) return "conditioning";
    return "balance";
  }
  function resolveLevel(profile) {
    const picked = String((profile && profile.level) || "").trim();
    if (["입문", "초급", "중급", "상급"].includes(picked)) return picked;
    const t = String((profile && profile.experience) || "") + " " + String((profile && profile.notes) || "");
    if (/입문|처음|초보|왕초/.test(t)) return "입문";
    if (/상급|고급|선수/.test(t)) return "상급";
    if (/중급/.test(t)) return "중급";
    const years = t.match(/(\d+)\s*년/);
    if (years) {
      const y = Number(years[1]);
      if (y >= 5) return "상급";
      if (y >= 2) return "중급";
      if (y >= 1) return "초급";
      return "입문";
    }
    const months = t.match(/(\d+)\s*개?월/);
    if (months) return Number(months[1]) < 6 ? "입문" : "초급";
    return "초급";
  }
  function legacyRecord(ex) {
    if (!ex) return "";
    if (ex.record != null && String(ex.record).length) return String(ex.record);
    return (ex.sets || []).map((st) => {
      if (!st) return "";
      const typed = st.text != null ? String(st.text).trim() : "";
      if (typed) return typed;
      const bits = [];
      if (st.weight != null && st.weight !== "") bits.push(String(st.weight) + "kg");
      if (st.reps != null && st.reps !== "") bits.push(String(st.reps) + "회");
      return bits.join(" ");
    }).filter(Boolean).join("\n");
  }
  function parseLoads(text) {
    const tops = [];
    let hold = 0;
    String(text || "").split(/\n+| \/ /).forEach((line) => {
      line.split(/\s+\+\s+/).forEach((chunk) => {
        const sec = chunk.match(/(\d+)\s*초/);
        if (sec) hold = Math.max(hold, Number(sec[1]) || 0);
        const xm = chunk.match(/(\d+(?:\.\d+)?)\s*(?:kg)?\s*[x×*]\s*(\d+)/i);
        const kg = chunk.match(/(\d+(?:\.\d+)?)\s*kg/i);
        const repsWord = chunk.match(/(\d+)\s*회/);
        if (xm && (kg || Number(xm[1]) >= 15)) {
          const weight = kg ? Number(kg[1]) : Number(xm[1]);
          const reps = Number(xm[2]);
          if (weight > 0 && weight < 500 && reps > 0 && reps <= 30) tops.push({ weight, reps });
          return;
        }
        if (kg && repsWord) {
          const weight = Number(kg[1]);
          const reps = Number(repsWord[1]);
          const gap = Math.abs(chunk.indexOf(kg[0]) - chunk.indexOf(repsWord[0]));
          if (weight > 0 && reps > 0 && reps <= 30 && gap < 16) tops.push({ weight, reps });
        }
      });
    });
    let top = null;
    tops.forEach((row) => {
      const score = row.weight * (1 + row.reps / 30);
      if (!top || score > top.score) top = Object.assign({ score }, row);
    });
    return { top: top ? { weight: top.weight, reps: top.reps } : null, hold: hold || 0 };
  }
  function isPlaceholderRecord(text) {
    const lines = String(text || "").split("\n").map((s) => s.trim()).filter(Boolean);
    if (!lines.length) return false;
    return lines.every((line) => /^목표[:：]/.test(line) || /^\(지난/.test(line));
  }
  function fmtKg(n) {
    const v = Math.round(Number(n) * 10) / 10;
    return (Math.abs(v - Math.round(v)) < 0.05 ? String(Math.round(v)) : String(v)) + "kg";
  }
  function repCap(kind) {
    if (kind === "strength") return 5;
    if (kind === "hyper") return 10;
    if (kind === "fat") return 12;
    if (kind === "conditioning") return 12;
    return 8;
  }
  function bumpWeight(weight, level) {
    const w = Number(weight);
    if (w < 50 && w % 2 === 0 && w % 5 !== 0) return w + 2;
    if (level === "상급" && w >= 80) return w + 5;
    return Math.round((w + 2.5) * 2) / 2;
  }
  function nextLoad(last, kind, level) {
    if (!last) return null;
    if (kind === "rehab") {
      if (last.top) return { weight: last.top.weight, reps: last.top.reps, why: "통증 없이 같은 무게를 유지합니다." };
      if (last.hold) return { seconds: last.hold, why: "시간은 늘리지 않고 자세만 유지합니다." };
    }
    if (last.top) {
      const cap = repCap(kind);
      if (last.top.reps < cap) {
        return {
          weight: last.top.weight,
          reps: last.top.reps + 1,
          why: "같은 무게에서 횟수를 하나 올립니다."
        };
      }
      const weight = bumpWeight(last.top.weight, level);
      const reps = last.top.reps <= 8 ? last.top.reps : Math.max(6, last.top.reps - 2);
      return {
        weight,
        reps,
        why: reps === last.top.reps
          ? "지난 무게보다 한 단계만 올립니다."
          : "무게를 한 단계 올리고 횟수는 " + reps + "회로 맞춥니다."
      };
    }
    if (last.hold) {
      const add = level === "상급" ? 10 : 5;
      return { seconds: last.hold + add, why: "버틴 시간을 " + add + "초 늘립니다." };
    }
    return null;
  }
  function unsafeReasons(name, flags) {
    const n = String(name || "");
    const reasons = [];
    if (flags.back && /굿모닝|컨벤셔널|바벨 로우|바벨로우|싯업|크런치/.test(n)) reasons.push("허리");
    if (flags.back && /데드리프트|deadlift/i.test(n) && !/루마니안|rdl|스티프/i.test(n)) reasons.push("허리");
    if (flags.knee && /점프|버피|피스톨/.test(n)) reasons.push("무릎");
    if ((flags.shoulder || flags.neck) && /비하인드|업라이트|밀리터리|딥스/.test(n)) reasons.push(flags.neck && !flags.shoulder ? "목" : "어깨");
    if (flags.neck && /오버헤드|숄더 프레스|숄더프레스/.test(n)) reasons.push("목");
    if (flags.wrist && /프론트 스쿼트|업라이트/.test(n)) reasons.push("손목");
    if (flags.ankle && /점프|버피/.test(n)) reasons.push("발목");
    return [...new Set(reasons)];
  }
  function safeName(pattern, flags) {
    if (pattern === "squat") {
      if (flags.back) return "고블릿 스쿼트";
      if (flags.knee) return "박스 스쿼트";
      return "스쿼트";
    }
    if (pattern === "hinge") return flags.back ? "힙 쓰러스트" : "루마니안 데드리프트";
    if (pattern === "hpush") {
      if (flags.shoulder) return "플로어 프레스";
      if (flags.wrist) return "머신 체스트 프레스";
      return "덤벨 벤치 프레스";
    }
    if (pattern === "vpush") return (flags.shoulder || flags.neck) ? "랜드마인 프레스" : "덤벨 숄더 프레스";
    if (pattern === "hpull") return flags.back ? "시티드 로우" : "원암 로우";
    if (pattern === "vpull") return "랫 풀다운";
    if (pattern === "core") return flags.back ? "데드버그" : "플랭크";
    if (pattern === "carry") return "파머스 캐리";
    return "전신 서킷";
  }
  function defaultCue(pattern, flags) {
    if (pattern === "squat" && flags.knee) return "통증 없는 깊이까지만 앉습니다.";
    if (pattern === "squat" && flags.back) return "가슴을 열고 허리가 말리지 않게 합니다.";
    if (pattern === "hinge" && flags.back) return "바닥까지 내리지 않고 골반만 접습니다.";
    if (pattern === "hpush" && flags.shoulder) return "팔꿈치는 몸통에서 45도, 어깨를 으쓱하지 않습니다.";
    if (pattern === "vpush" && (flags.shoulder || flags.neck)) return "몸통을 살짝 기울여 목이 뒤로 빠지지 않게 합니다.";
    if (pattern === "hpull") return "어깨뼈를 모으고 허리는 중립으로 둡니다.";
    if (pattern === "vpull") return "가슴을 열고 팔꿈치로 당깁니다.";
    if (pattern === "core" && flags.back) return "허리가 뜨지 않는 범위에서 호흡을 유지합니다.";
    if (pattern === "squat") return "발바닥 전체로 밀고 무릎은 발끝 방향입니다.";
    if (pattern === "hinge") return "무릎은 살짝 굽히고 엉덩이를 뒤로 보냅니다.";
    if (pattern === "hpush") return "견갑을 고정하고 가슴으로 밉니다.";
    if (pattern === "core") return "골반이 돌아가지 않게 버팁니다.";
    return "동작이 흐트러지면 횟수보다 자세를 먼저 맞춥니다.";
  }
  function collect(member, date) {
    const start = addDays(date, -14);
    const sessions = (member && member.sessions) || {};
    return Object.keys(sessions).filter((d) => d >= start && d < date).sort().map((d) => {
      const s = sessions[d] || {};
      const exercises = (s.exercises || []).map((ex) => {
        const record = legacyRecord(ex);
        return {
          name: String(ex.name || "").trim(),
          record,
          feedback: String(ex.feedback || "").trim(),
          loads: parseLoads(isPlaceholderRecord(record) ? "" : record),
          pattern: patternOf(ex.name)
        };
      }).filter((ex) => ex.name);
      return {
        date: d,
        program: String(s.program || "").trim(),
        feedback: String(s.feedback || "").trim(),
        exercises
      };
    }).filter((s) => s.exercises.length || s.program || s.feedback);
  }
  function rowsFor(sessions, pattern) {
    const rows = [];
    sessions.forEach((s) => {
      s.exercises.forEach((ex) => {
        if (ex.pattern === pattern) rows.push(Object.assign({ date: s.date }, ex));
      });
    });
    return rows;
  }
  function lastNumbered(rows) {
    for (let i = rows.length - 1; i >= 0; i--) {
      if (rows[i].loads.top || rows[i].loads.hold) return rows[i];
    }
    return null;
  }
  function patternScore(pattern, sessions, date) {
    const rows = rowsFor(sessions, pattern);
    if (!rows.length) return 5;
    const last = rows[rows.length - 1].date;
    const days = Math.round((dateFromIso(date) - dateFromIso(last)) / 86400000);
    if (days <= 2) return 0.4;
    if (days >= 5 && days <= 9) return 8 + Math.min(days, 9);
    return 3 + Math.min(days, 12);
  }
  function choosePatterns(sessions, flags, date) {
    const pool = ["squat", "hinge", "hpush", "hpull", "vpush", "vpull"];
    const ranked = pool.map((id) => ({ id, score: patternScore(id, sessions, date) }))
      .sort((a, b) => b.score - a.score);
    const picked = [];
    function region(id) { return LOWER[id] ? "lower" : (UPPER[id] ? "upper" : ""); }
    ranked.forEach((row) => {
      if (picked.length >= 2) return;
      if (!picked.length) { picked.push(row.id); return; }
      if (region(row.id) && region(row.id) === region(picked[0]) && ranked.some((x) => !picked.includes(x.id) && region(x.id) !== region(picked[0]) && x.score >= 3)) return;
      picked.push(row.id);
    });
    while (picked.length < 2) {
      const next = pool.find((id) => !picked.includes(id));
      if (!next) break;
      picked.push(next);
    }
    const acc = [];
    ranked.forEach((row) => {
      if (acc.length >= 2 || picked.includes(row.id)) return;
      acc.push(row.id);
    });
    if (flags.back && !picked.includes("core") && !acc.includes("core")) acc[acc.length - 1] = "core";
    else if (!acc.includes("core") && !picked.includes("core")) acc.push("core");
    return { mains: picked.slice(0, 2), accessories: acc.slice(0, 2) };
  }
  function materialize(pattern, sessions, flags) {
    const rows = rowsFor(sessions, pattern);
    const safeRows = rows.filter((row) => !unsafeReasons(row.name, flags).length);
    const source = safeRows.length ? safeRows[safeRows.length - 1] : null;
    const blocked = !source && rows.length ? rows[rows.length - 1] : null;
    const reasons = blocked ? unsafeReasons(blocked.name, flags) : [];
    const name = source ? source.name : safeName(pattern, flags);
    const historyRows = rows.filter((row) => row.name === name);
    const last = lastNumbered(historyRows);
    const cueBits = [];
    if (blocked && reasons.length) cueBits.push(blocked.name + " 대신 " + reasons.join("·") + " 부담을 줄이려고 바꿨습니다.");
    cueBits.push(defaultCue(pattern, flags));
    return {
      pattern,
      name,
      cue: cueBits.join(" "),
      last,
      flags,
      swappedFrom: blocked && reasons.length ? blocked : null
    };
  }
  function warmup(flags, used) {
    const pool = [];
    if (flags.back) pool.push("캣카우", "버드독");
    if (flags.knee) pool.push("글루트 브릿지", "무릎 굽혔다 펴기");
    if (flags.shoulder || flags.neck) pool.push("월 슬라이드", "밴드 풀어파트");
    if (flags.ankle) pool.push("발목 원 그리기", "카프 레이즈");
    if (!pool.length) pool.push("암 서클", "바디웨이트 스쿼트");
    return pool.filter((name, i) => pool.indexOf(name) === i && !used.has(name)).slice(0, 2).map((name) => ({
      name,
      cue: "본 세트 전에 관절 범위만 천천히 엽니다.",
      record: ""
    }));
  }
  function finisher(kind, flags, used) {
    let name = "플랭크";
    if (kind === "fat" || kind === "conditioning") name = flags.ankle ? "에어로바이크" : "에어로바이크";
    else if (kind === "rehab" || flags.back) name = "데드버그";
    else if (kind === "strength") name = "사이드 플랭크";
    if (used.has(name)) name = used.has("사이드 플랭크") ? "글루트 브릿지" : "사이드 플랭크";
    const cue = kind === "fat" || kind === "conditioning"
      ? "말은 가능한 속도로 4–6분만 갑니다."
      : "호흡이 무너지면 멈춥니다.";
    return { name, cue, record: "" };
  }
  function recordFor(item, kind, level) {
    const next = nextLoad(item.last ? { top: item.last.loads.top, hold: item.last.loads.hold } : null, kind, level);
    if (!next && item.swappedFrom) {
      const why = unsafeReasons(item.swappedFrom.name, item.flags || {}).join("·");
      return {
        record: "",
        overload: {
          name: item.name,
          lastLabel: item.swappedFrom.name + (why ? " · " + why + " 부담" : ""),
          nextLabel: "오늘은 가벼운 무게로 8회부터",
          note: item.cue || ""
        }
      };
    }
    if (!next) return { record: "", overload: null };
    const when = item.last ? shortDate(item.last.date) : "";
    if (next.seconds) {
      const lastLabel = when + " · " + item.last.loads.hold + "초";
      return {
        record: "목표: " + next.seconds + "초\n(지난 " + when + " " + item.last.loads.hold + "초)",
        overload: { name: item.name, lastLabel, nextLabel: "오늘 " + next.seconds + "초", note: next.why }
      };
    }
    const last = item.last.loads.top;
    const lastLabel = when + " · " + fmtKg(last.weight) + " × " + last.reps + "회";
    const nextLabel = "오늘 " + fmtKg(next.weight) + " × " + next.reps + "회";
    return {
      record: "목표: " + fmtKg(next.weight) + " × " + next.reps + "회\n(지난 " + when + " " + fmtKg(last.weight) + " × " + last.reps + "회)",
      overload: { name: item.name, lastLabel, nextLabel, note: next.why }
    };
  }
  function latestFeedback(sessions) {
    for (let i = sessions.length - 1; i >= 0; i--) {
      if (sessions[i].feedback) return { date: sessions[i].date, text: sessions[i].feedback };
      for (let j = sessions[i].exercises.length - 1; j >= 0; j--) {
        if (sessions[i].exercises[j].feedback) return { date: sessions[i].date, text: sessions[i].exercises[j].feedback };
      }
    }
    return null;
  }
  function injurySentence(flags, raw) {
    const parts = [];
    if (flags.back) parts.push("허리");
    if (flags.knee) parts.push("무릎");
    if (flags.shoulder) parts.push("어깨");
    if (flags.neck) parts.push("목");
    if (flags.wrist) parts.push("손목");
    if (flags.ankle) parts.push("발목");
    if (parts.length) return parts.join("·") + " 이력이 있어, 그 부위를 세게 접거나 점프하는 동작은 빼거나 각도를 낮춥니다.";
    const note = clip(raw, 42);
    if (note) return "적어 둔 특이사항 「" + note + "」을 동작 선택에 반영합니다.";
    return "등록된 부상 이력이 없습니다. 수업 시작 전에 오늘 아픈 곳이 있는지만 확인하면 됩니다.";
  }
  function recentPatternLabels(sessions) {
    const seen = [];
    sessions.forEach((s) => {
      s.exercises.forEach((ex) => {
        if (ex.pattern === "other" || seen.includes(ex.name)) return;
        seen.push(ex.name);
      });
    });
    return seen.slice(-6);
  }
  function writeDirection(ctx) {
    const bits = [];
    if (ctx.goal) bits.push("오늘 수업은 「" + clip(ctx.goal, 48) + "」 쪽으로 맞춥니다.");
    else bits.push("운동 목표가 비어 있어 하체와 상체를 한 수업 안에서 고르게 가져갑니다.");
    bits.push(injurySentence(ctx.flags, ctx.history));
    const exp = [ctx.statedLevel, ctx.experience].filter(Boolean).join(" · ");
    bits.push(exp
      ? "경력·수준은 " + exp + "이라, 무게는 한 단계만 올립니다."
      : "경력 정보가 없어 초급으로 보고 무게 점프를 작게 둡니다.");
    if (ctx.feedback) bits.push("지난 " + shortDate(ctx.feedback.date) + " 피드백 「" + clip(ctx.feedback.text, 70) + "」을 오늘 큐로 가져옵니다.");
    if (!ctx.sessions.length) bits.push("최근 2주 일지가 없습니다. 전신으로 시작하고, 오늘 무게와 횟수를 적어두면 다음 수업부터 과부하를 계산합니다.");
    else {
      const done = recentPatternLabels(ctx.sessions);
      const todayNames = ctx.mains.map((item) => item.name).join(", ");
      bits.push("최근 2주에는 " + (done.length ? done.join(", ") : "운동") + " 기록이 있습니다. 오늘은 " + todayNames + "를 메인으로 두고, 지난 중량에서 한 단계만 올립니다.");
    }
    const age = Number(ctx.age);
    if (Number.isFinite(age) && age >= 50) bits.push("준비운동은 서두르지 않고, 가동 범위는 편한 곳까지만 씁니다.");
    return bits.join(" ");
  }
  function programText(direction, blocks) {
    const lines = ["[오늘 방향]", direction, ""];
    blocks.forEach((block) => {
      lines.push(block.phase);
      block.items.forEach((item) => {
        const target = (item.record || "").split("\n")[0].replace(/^목표:\s*/, "");
        lines.push("- " + item.name + (target ? " — " + target : ""));
      });
      lines.push("");
    });
    return lines.join("\n").trim();
  }
  function build(member, date) {
    const profile = (member && member.profile) || {};
    const history = [profile.history, member && member.injuries, profile.notes].map((s) => String(s || "").trim()).filter((s, i, arr) => s && arr.indexOf(s) === i).join("\n");
    const flags = injuryFlags(history);
    const kind = goalKind(profile.goal || "");
    const level = resolveLevel(profile);
    const sessions = collect(member || {}, date);
    const picked = choosePatterns(sessions, flags, date);
    const used = new Set();
    const mains = picked.mains.map((pattern) => materialize(pattern, sessions, flags));
    const accessories = picked.accessories.map((pattern) => materialize(pattern, sessions, flags))
      .filter((item) => !mains.some((main) => main.name === item.name));
    mains.concat(accessories).forEach((item) => used.add(item.name));
    const warm = warmup(flags, used);
    warm.forEach((item) => used.add(item.name));
    const end = finisher(kind, flags, used);
    function pack(list) {
      return list.map((item) => {
        const prog = recordFor(item, kind, level);
        return { name: item.name, cue: item.cue || "", record: prog.record, overload: prog.overload };
      });
    }
    const blocks = [
      { phase: "워밍업", items: warm },
      { phase: "메인", items: pack(mains) },
      { phase: "보조", items: pack(accessories) },
      { phase: "마무리", items: [{ name: end.name, cue: end.cue, record: "", overload: null }] }
    ].filter((block) => block.items.length);
    const overload = [];
    blocks.forEach((block) => {
      block.items.forEach((item) => { if (item.overload) overload.push(item.overload); });
    });
    const feedback = latestFeedback(sessions);
    const direction = writeDirection({
      goal: String(profile.goal || "").trim(),
      history,
      flags,
      statedLevel: String(profile.level || "").trim(),
      experience: String(profile.experience || "").trim(),
      age: profile.age,
      feedback,
      sessions,
      mains
    });
    const exercises = [];
    blocks.forEach((block) => {
      block.items.forEach((item) => exercises.push({ name: item.name, record: item.record || "" }));
    });
    return {
      direction,
      blocks,
      overload,
      program: programText(direction, blocks),
      exercises,
      meta: {
        sessions: sessions.length,
        level,
        kind,
        polished: false
      }
    };
  }
  function brief(member, date, plan) {
    const profile = (member && member.profile) || {};
    const sessions = collect(member || {}, date).map((s) => ({
      date: s.date,
      feedback: s.feedback,
      exercises: s.exercises.map((ex) => ({
        name: ex.name,
        record: isPlaceholderRecord(ex.record) ? "" : ex.record,
        feedback: ex.feedback
      }))
    }));
    return {
      goal: profile.goal || "",
      history: [profile.history, member && member.injuries, profile.notes].filter(Boolean).join("\n"),
      experience: profile.experience || "",
      level: profile.level || "",
      age: profile.age || "",
      recent: sessions,
      draftDirection: plan ? plan.direction : ""
    };
  }

  function withDirection(plan, direction) {
    const text = String(direction || "").trim();
    if (!plan || !text) return plan;
    return Object.assign({}, plan, {
      direction: text,
      program: programText(text, plan.blocks || []),
      meta: Object.assign({}, plan.meta, { polished: true })
    });
  }

  global.CoachPlan = { build, brief, withDirection, isPlaceholderRecord, parseLoads };
})(typeof window !== "undefined" ? window : global);
