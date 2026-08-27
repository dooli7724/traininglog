(function (global) {
  const CFG_KEY = "pt-logger-cloud-config";
  const Cloud = {
    sb: null,
    user: null,
    gymId: null,
    rev: 0,
    ready: false,
    canWrite: false,
    status: "idle",
    _hooks: {},
    _timer: null,
    _flushing: false,
    _skipUntil: 0,
    _channel: null
  };

  function readLocalCfg() {
    try { return JSON.parse(localStorage.getItem(CFG_KEY) || "null") || {}; }
    catch { return {}; }
  }

  Cloud.saveConfig = function (url, anonKey) {
    const cfg = { url: String(url || "").trim().replace(/\/$/, ""), anonKey: String(anonKey || "").trim() };
    localStorage.setItem(CFG_KEY, JSON.stringify(cfg));
    return cfg;
  };

  Cloud.clearConfig = function () {
    localStorage.removeItem(CFG_KEY);
  };

  Cloud.cfg = function () {
    const baked = global.PT_CLOUD || {};
    if (baked.supabaseUrl && baked.supabaseAnonKey) {
      return { url: String(baked.supabaseUrl).replace(/\/$/, ""), anonKey: String(baked.supabaseAnonKey) };
    }
    const ls = readLocalCfg();
    return {
      url: ls.url || "",
      anonKey: ls.anonKey || ""
    };
  };

  Cloud.hasConfig = function () {
    const c = Cloud.cfg();
    return !!(c.url && c.anonKey);
  };

  Cloud.attach = function (hooks) {
    Cloud._hooks = hooks || {};
  };

  async function fetchHostedCfg() {
    try {
      const res = await fetch("/api/cloud-config", { cache: "no-store" });
      if (!res.ok) return null;
      const j = await res.json();
      if (j && j.url && j.anonKey) return { url: j.url, anonKey: j.anonKey };
    } catch (_) {}
    return null;
  }

  function lib() {
    return global.supabase || (global.supabaseJs) || null;
  }

  Cloud.initClient = async function () {
    let c = Cloud.cfg();
    if (!c.url || !c.anonKey) {
      const hosted = await fetchHostedCfg();
      if (hosted) c = hosted;
    }
    if (!c.url || !c.anonKey) {
      Cloud.sb = null;
      Cloud.ready = false;
      return false;
    }
    const sdk = lib();
    if (!sdk || !sdk.createClient) {
      Cloud.status = "error";
      return false;
    }
    Cloud.sb = sdk.createClient(c.url, c.anonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    Cloud.ready = true;
    return true;
  };

  Cloud.init = async function () {
    await Cloud.initClient();
    if (!Cloud.sb) return { user: null };
    const { data } = await Cloud.sb.auth.getSession();
    Cloud.user = (data && data.session && data.session.user) || null;
    Cloud.canWrite = !!Cloud.user;
    Cloud.sb.auth.onAuthStateChange((_ev, session) => {
      Cloud.user = (session && session.user) || null;
      Cloud.canWrite = !!Cloud.user;
      if (typeof Cloud._hooks.onAuth === "function") Cloud._hooks.onAuth(Cloud.user);
    });
    return { user: Cloud.user };
  };

  Cloud.login = async function (email, password) {
    if (!Cloud.sb) throw new Error("클라우드가 연결되지 않았습니다.");
    const { data, error } = await Cloud.sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    Cloud.user = data.user;
    Cloud.canWrite = true;
    return data.user;
  };

  Cloud.signup = async function (email, password) {
    if (!Cloud.sb) throw new Error("클라우드가 연결되지 않았습니다.");
    const { data, error } = await Cloud.sb.auth.signUp({ email, password });
    if (error) throw error;
    Cloud.user = data.user;
    Cloud.canWrite = !!(data.session && data.user);
    return data;
  };

  Cloud.logout = async function () {
    Cloud.unsubscribe();
    if (Cloud.sb) await Cloud.sb.auth.signOut();
    Cloud.user = null;
    Cloud.canWrite = false;
    Cloud.gymId = null;
  };

  function stripLogs(state) {
    return {
      members: (state.members || []).map((m) => {
        const copy = Object.assign({}, m);
        delete copy.selfWorkouts;
        delete copy.dietLogs;
        return copy;
      })
    };
  }

  function attachLogs(members, logs) {
    const bag = {};
    (logs || []).forEach((row) => {
      const share = row.share;
      if (!bag[share]) bag[share] = { selfWorkouts: [], dietLogs: [] };
      if (row.kind === "self_workout") bag[share].selfWorkouts.push(row.payload);
      else if (row.kind === "diet") bag[share].dietLogs.push(row.payload);
    });
    (members || []).forEach((m) => {
      const g = bag[m.share] || { selfWorkouts: [], dietLogs: [] };
      m.selfWorkouts = g.selfWorkouts;
      m.dietLogs = g.dietLogs;
    });
    return members;
  }

  Cloud.pull = async function () {
    if (!Cloud.sb || !Cloud.user) return null;
    const { data, error } = await Cloud.sb.rpc("ensure_gym");
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return { members: [] };
    Cloud.gymId = row.gym_id;
    Cloud.rev = Number(row.rev) || 1;
    const members = ((row.data && row.data.members) || []).slice();
    const { data: logs, error: logErr } = await Cloud.sb
      .from("member_logs")
      .select("id, share, kind, payload, updated_at")
      .eq("gym_id", Cloud.gymId);
    if (logErr) throw logErr;
    attachLogs(members, logs || []);
    return { members };
  };

  Cloud.flush = async function () {
    if (!Cloud.canWrite || !Cloud.sb || Cloud._flushing) return;
    const getState = Cloud._hooks.getState;
    if (!getState) return;
    const state = getState();
    Cloud._flushing = true;
    Cloud.status = "saving";
    if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("saving");
    try {
      const payload = stripLogs(state);
      const { data, error } = await Cloud.sb.rpc("push_gym_state", { p_data: payload });
      if (error) throw error;
      Cloud.rev = Number(data) || Cloud.rev + 1;
      const rows = [];
      (state.members || []).forEach((m) => {
        (m.selfWorkouts || []).forEach((w) => {
          rows.push({ id: w.id, gym_id: Cloud.gymId, share: m.share, kind: "self_workout", payload: w });
        });
        (m.dietLogs || []).forEach((d) => {
          rows.push({ id: d.id, gym_id: Cloud.gymId, share: m.share, kind: "diet", payload: d });
        });
      });
      if (Cloud.gymId && rows.length) {
        const { error: upErr } = await Cloud.sb.from("member_logs").upsert(rows, { onConflict: "id" });
        if (upErr) throw upErr;
      }
      Cloud._skipUntil = Date.now() + 1200;
      Cloud.status = "saved";
      if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("saved");
    } catch (err) {
      Cloud.status = "error";
      if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("error", err);
    } finally {
      Cloud._flushing = false;
    }
  };

  Cloud.schedulePush = function () {
    if (!Cloud.canWrite) return;
    clearTimeout(Cloud._timer);
    Cloud._timer = setTimeout(() => { Cloud.flush(); }, 700);
  };

  Cloud.hydrate = async function (localState) {
    const remote = await Cloud.pull();
    if (!remote) return localState || { members: [] };
    const localMembers = (localState && localState.members) || [];
    if (!(remote.members || []).length && localMembers.length) {
      if (typeof Cloud._hooks.setState === "function") Cloud._hooks.setState({ members: localMembers });
      await Cloud.flush();
      return { members: localMembers };
    }
    return remote;
  };

  Cloud.subscribe = function () {
    if (!Cloud.sb || !Cloud.gymId || Cloud._channel) return;
    Cloud._channel = Cloud.sb
      .channel("pt-gym-" + Cloud.gymId)
      .on("postgres_changes", { event: "*", schema: "public", table: "gym_state", filter: "gym_id=eq." + Cloud.gymId }, () => {
        Cloud._onRemote();
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "member_logs", filter: "gym_id=eq." + Cloud.gymId }, () => {
        Cloud._onRemote();
      })
      .subscribe();
  };

  Cloud.unsubscribe = function () {
    if (Cloud._channel && Cloud.sb) Cloud.sb.removeChannel(Cloud._channel);
    Cloud._channel = null;
  };

  Cloud._onRemote = async function () {
    if (Date.now() < Cloud._skipUntil) return;
    try {
      const remote = await Cloud.pull();
      if (!remote) return;
      if (typeof Cloud._hooks.setState === "function") Cloud._hooks.setState(remote);
      if (typeof Cloud._hooks.onRemote === "function") Cloud._hooks.onRemote(remote);
    } catch (_) {}
  };

  Cloud.fetchMember = async function (ref) {
    if (!Cloud.sb || !ref) return null;
    const { data, error } = await Cloud.sb.rpc("member_public", { p_ref: ref });
    if (error || !data) return null;
    return data;
  };

  Cloud.upsertLog = async function (share, kind, row) {
    if (!Cloud.sb || !share || !row) return false;
    const { error } = await Cloud.sb.rpc("member_upsert_log", {
      p_share: share, p_kind: kind, p_row: row
    });
    if (error) {
      console.warn("upsertLog", error);
      return false;
    }
    return true;
  };

  Cloud.deleteLog = async function (share, id) {
    if (!Cloud.sb || !share || !id) return false;
    const { error } = await Cloud.sb.rpc("member_delete_log", { p_share: share, p_id: id });
    return !error;
  };

  Cloud.storagePath = function (id, share) {
    if (Cloud.gymId && Cloud.canWrite) return "gym/" + Cloud.gymId + "/" + id;
    if (share) return "share/" + share + "/" + id;
    return "share/unknown/" + id;
  };

  Cloud.upload = async function (id, blob, share) {
    if (!Cloud.sb || !blob) return "";
    const path = Cloud.storagePath(id, share);
    const { error } = await Cloud.sb.storage.from("pt-media").upload(path, blob, {
      upsert: true,
      contentType: blob.type || "image/jpeg"
    });
    if (error) {
      console.warn("upload", error);
      return "";
    }
    const { data } = Cloud.sb.storage.from("pt-media").getPublicUrl(path);
    return (data && data.publicUrl) || "";
  };

  Cloud.removeFile = async function (id, share) {
    if (!Cloud.sb) return;
    const paths = [];
    if (Cloud.gymId) paths.push("gym/" + Cloud.gymId + "/" + id);
    if (share) paths.push("share/" + share + "/" + id);
    if (!paths.length) return;
    await Cloud.sb.storage.from("pt-media").remove(paths);
  };

  Cloud.publicUrl = function (id, share) {
    if (!Cloud.sb) return "";
    const path = Cloud.gymId ? "gym/" + Cloud.gymId + "/" + id : (share ? "share/" + share + "/" + id : "");
    if (!path) return "";
    const { data } = Cloud.sb.storage.from("pt-media").getPublicUrl(path);
    return (data && data.publicUrl) || "";
  };

  Cloud.download = async function (id, share) {
    if (!Cloud.sb) return null;
    const paths = [];
    if (Cloud.gymId) paths.push("gym/" + Cloud.gymId + "/" + id);
    if (share) paths.push("share/" + share + "/" + id);
    (Cloud._hooks.shares ? Cloud._hooks.shares() : []).forEach((s) => {
      if (s) paths.push("share/" + s + "/" + id);
    });
    const seen = {};
    for (let i = 0; i < paths.length; i++) {
      const p = paths[i];
      if (seen[p]) continue;
      seen[p] = true;
      const { data, error } = await Cloud.sb.storage.from("pt-media").download(p);
      if (!error && data) return data;
    }
    return null;
  };

  Cloud.migrateLocalFiles = async function (listIds, getBlob) {
    if (!Cloud.canWrite || !Cloud.gymId) return;
    const ids = await listIds();
    for (const id of ids) {
      try {
        const blob = await getBlob(id);
        if (blob) await Cloud.upload(id, blob);
      } catch (_) {}
    }
  };

  global.Cloud = Cloud;
})(window);
