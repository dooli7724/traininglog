(function (global) {
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

  Cloud.cfg = function () {
    const baked = global.PT_CLOUD || {};
    return {
      url: String(baked.supabaseUrl || "").replace(/\/$/, ""),
      anonKey: String(baked.supabaseAnonKey || "")
    };
  };

  Cloud.hasConfig = function () {
    const c = Cloud.cfg();
    return !!(c.url && c.anonKey);
  };

  Cloud.attach = function (hooks) {
    Cloud._hooks = hooks || {};
  };

  function lib() {
    return global.supabase || (global.supabaseJs) || null;
  }

  Cloud.initClient = async function () {
    const c = Cloud.cfg();
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
    let logs = [];
    let logErr = null;
    if (Cloud.user) {
      const first = await Cloud.sb
        .from("member_logs")
        .select("id, share, kind, payload, updated_at")
        .eq("user_id", Cloud.user.id);
      logs = first.data;
      logErr = first.error;
    }
    if (logErr || !Cloud.user) {
      const second = await Cloud.sb
        .from("member_logs")
        .select("id, share, kind, payload, updated_at")
        .eq("gym_id", Cloud.gymId);
      if (!second.error) { logs = second.data; logErr = null; }
      else if (!logs) logErr = second.error;
    }
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
      const uid = Cloud.user && Cloud.user.id;
      (state.members || []).forEach((m) => {
        (m.selfWorkouts || []).forEach((w) => {
          rows.push({ id: w.id, gym_id: Cloud.gymId, user_id: uid, share: m.share, kind: "self_workout", payload: w });
        });
        (m.dietLogs || []).forEach((d) => {
          rows.push({ id: d.id, gym_id: Cloud.gymId, user_id: uid, share: m.share, kind: "diet", payload: d });
        });
      });
      if (Cloud.gymId && rows.length) {
        let { error: upErr } = await Cloud.sb.from("member_logs").upsert(rows, { onConflict: "id" });
        if (upErr) {
          rows.forEach((r) => { delete r.user_id; });
          const retry = await Cloud.sb.from("member_logs").upsert(rows, { onConflict: "id" });
          upErr = retry.error;
        }
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

  Cloud.hydrate = async function () {
    const remote = await Cloud.pull();
    return remote || { members: [] };
  };

  Cloud.subscribe = function () {
    if (!Cloud.sb || !Cloud.gymId || !Cloud.user || Cloud._channel) return;
    Cloud._channel = Cloud.sb
      .channel("pt-gym-" + Cloud.gymId)
      .on("postgres_changes", { event: "*", schema: "public", table: "gym_state", filter: "user_id=eq." + Cloud.user.id }, () => {
        Cloud._onRemote();
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "member_logs", filter: "user_id=eq." + Cloud.user.id }, () => {
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
    if (Cloud.user && Cloud.canWrite) return "user/" + Cloud.user.id + "/" + id;
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
    if (Cloud.user) paths.push("user/" + Cloud.user.id + "/" + id);
    if (Cloud.gymId) paths.push("gym/" + Cloud.gymId + "/" + id);
    if (share) paths.push("share/" + share + "/" + id);
    if (!paths.length) return;
    await Cloud.sb.storage.from("pt-media").remove(paths);
  };

  Cloud.publicUrl = function (id, share) {
    if (!Cloud.sb) return "";
    const path = Cloud.user
      ? "user/" + Cloud.user.id + "/" + id
      : (Cloud.gymId ? "gym/" + Cloud.gymId + "/" + id : (share ? "share/" + share + "/" + id : ""));
    if (!path) return "";
    const { data } = Cloud.sb.storage.from("pt-media").getPublicUrl(path);
    return (data && data.publicUrl) || "";
  };

  Cloud.download = async function (id, share) {
    if (!Cloud.sb) return null;
    const paths = [];
    if (Cloud.user) paths.push("user/" + Cloud.user.id + "/" + id);
    if (Cloud.gymId) paths.push("gym/" + Cloud.gymId + "/" + id);
    if (share) paths.push("share/" + share + "/" + id);
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

  Cloud.migrateLocalFiles = async function () {};

  global.Cloud = Cloud;
})(window);
