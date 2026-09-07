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
    _flushPromise: null,
    _pendingFlush: false,
    _dirty: false,
    _lastError: null,
    _lastResult: null,
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

  function errMsg(err) {
    if (!err) return "";
    if (typeof err === "string") return err;
    return String(err.message || err.code || err.error_description || err.hint || "");
  }

  Cloud.errorMessage = function (err) {
    const msg = errMsg(err);
    if (/not authenticated|JWT|expired|invalid claim|401|Auth session missing/i.test(msg)) {
      return "로그인 세션이 만료되었습니다. 다시 로그인해 주세요.";
    }
    if (/row-level|RLS|42501|permission denied|violates row-level|policy/i.test(msg)) {
      return "저장 권한이 없습니다. Supabase SQL Editor에서 schema.sql을 다시 실행해 주세요.";
    }
    if (/schema cache|does not exist|PGRST116|PGRST202|Could not find the function/i.test(msg)) {
      return "클라우드 함수가 없습니다. Supabase SQL Editor에서 schema.sql을 다시 실행해 주세요.";
    }
    if (/Failed to fetch|NetworkError|network|Load failed|The Internet connection appears to be offline/i.test(msg)) {
      return "네트워크 연결을 확인하고 다시 저장해 주세요.";
    }
    return msg || "저장에 실패했습니다.";
  };

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
    Cloud.recovering = /type=recovery/i.test(location.hash || "") || /type=recovery/i.test(location.search || "");
    Cloud.canWrite = !!Cloud.user && !Cloud.recovering;
    Cloud.sb.auth.onAuthStateChange((ev, session) => {
      Cloud.user = (session && session.user) || null;
      if (ev === "PASSWORD_RECOVERY") {
        Cloud.recovering = true;
        Cloud.canWrite = false;
        if (typeof Cloud._hooks.onRecovery === "function") Cloud._hooks.onRecovery();
        return;
      }
      Cloud.canWrite = !!Cloud.user && !Cloud.recovering;
      if (typeof Cloud._hooks.onAuth === "function") Cloud._hooks.onAuth(Cloud.user);
    });
    return { user: Cloud.user };
  };

  Cloud.login = async function (email, password) {
    if (!Cloud.sb) throw new Error("클라우드가 연결되지 않았습니다.");
    const { data, error } = await Cloud.sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    Cloud.user = (data.session && data.session.user) || data.user;
    Cloud.canWrite = !!Cloud.user;
    return Cloud.user;
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
    Cloud.recovering = false;
    Cloud._dirty = false;
    Cloud._pendingFlush = false;
  };

  Cloud.resetPassword = async function (email) {
    if (!Cloud.sb) throw new Error("클라우드가 연결되지 않았습니다.");
    const redirectTo = location.origin + location.pathname.replace(/index\.html$/i, "");
    const { error } = await Cloud.sb.auth.resetPasswordForEmail(email, { redirectTo });
    if (error) throw error;
  };

  Cloud.updatePassword = async function (password) {
    if (!Cloud.sb) throw new Error("클라우드가 연결되지 않았습니다.");
    const { data, error } = await Cloud.sb.auth.updateUser({ password });
    if (error) throw error;
    Cloud.recovering = false;
    Cloud.user = (data && data.user) || Cloud.user;
    Cloud.canWrite = !!Cloud.user;
    return Cloud.user;
  };

  function stripLogs(state) {
    return {
      members: (state.members || []).map((m) => {
        const copy = Object.assign({}, m);
        if (Cloud.user && Cloud.user.id) copy.ownerId = Cloud.user.id;
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

  function applyGymRow(row, logs) {
    if (!row) return { members: [] };
    Cloud.gymId = row.gym_id;
    Cloud.rev = Number(row.rev) || 1;
    const members = ((row.data && row.data.members) || []).slice();
    attachLogs(members, logs || []);
    return { members };
  }

  async function fetchOwnLogs() {
    const uid = Cloud.user && Cloud.user.id;
    if (uid) {
      const byUser = await Cloud.sb
        .from("member_logs")
        .select("id, share, kind, payload, updated_at")
        .eq("user_id", uid);
      if (!byUser.error) return byUser.data || [];
    }
    if (Cloud.gymId) {
      const byGym = await Cloud.sb
        .from("member_logs")
        .select("id, share, kind, payload, updated_at")
        .eq("gym_id", Cloud.gymId);
      if (!byGym.error) return byGym.data || [];
    }
    return [];
  }

  Cloud.ensureSession = async function () {
    if (!Cloud.sb) return null;
    const { data, error } = await Cloud.sb.auth.getSession();
    if (error) throw error;
    let session = data && data.session;
    const expMs = session && session.expires_at ? session.expires_at * 1000 : 0;
    if (session && expMs && expMs - Date.now() < 90 * 1000) {
      const refreshed = await Cloud.sb.auth.refreshSession();
      if (!refreshed.error && refreshed.data && refreshed.data.session) {
        session = refreshed.data.session;
      }
    }
    Cloud.user = (session && session.user) || null;
    Cloud.canWrite = !!Cloud.user && !Cloud.recovering;
    return session;
  };

  Cloud.ensureGym = async function () {
    if (!Cloud.sb || !Cloud.user) return null;
    if (Cloud.gymId) return Cloud.gymId;
    const packed = await Cloud.sb.rpc("ensure_gym");
    if (!packed.error && packed.data) {
      const row = Array.isArray(packed.data) ? packed.data[0] : packed.data;
      if (row && row.gym_id) {
        Cloud.gymId = row.gym_id;
        if (row.rev) Cloud.rev = Number(row.rev) || Cloud.rev;
        return Cloud.gymId;
      }
    }
    const uid = Cloud.user.id;
    const found = await Cloud.sb.from("gyms").select("id").eq("owner_id", uid).maybeSingle();
    if (found.error) throw found.error;
    if (found.data && found.data.id) {
      Cloud.gymId = found.data.id;
      return Cloud.gymId;
    }
    const created = await Cloud.sb.from("gyms").insert({ owner_id: uid }).select("id").single();
    if (created.error) throw created.error;
    Cloud.gymId = created.data.id;
    return Cloud.gymId;
  };

  async function pushGymStateDirect(payload) {
    const uid = Cloud.user && Cloud.user.id;
    if (!uid) throw new Error("로그인 세션이 없습니다.");
    const gid = await Cloud.ensureGym();
    if (!gid) throw new Error("트레이너 저장소를 만들지 못했습니다.");
    const existing = await Cloud.sb.from("gym_state").select("gym_id, rev, user_id").eq("gym_id", gid).maybeSingle();
    if (existing.error) throw existing.error;
    if (!existing.data) {
      const ins = await Cloud.sb.from("gym_state").insert({
        gym_id: gid,
        user_id: uid,
        data: payload,
        rev: 1
      }).select("rev").single();
      if (ins.error) throw ins.error;
      Cloud.rev = Number(ins.data && ins.data.rev) || 1;
      return Cloud.rev;
    }
    const nextRev = (Number(existing.data.rev) || 1) + 1;
    const upd = await Cloud.sb.from("gym_state").update({
      data: payload,
      user_id: uid,
      rev: nextRev,
      updated_at: new Date().toISOString()
    }).eq("gym_id", gid).select("rev").single();
    if (upd.error) throw upd.error;
    Cloud.rev = Number(upd.data && upd.data.rev) || nextRev;
    return Cloud.rev;
  }

  Cloud.pull = async function () {
    if (!Cloud.sb || !Cloud.user) return null;
    const packed = await Cloud.sb.rpc("load_trainer_state");
    if (!packed.error && packed.data) {
      const row = typeof packed.data === "string" ? JSON.parse(packed.data) : packed.data;
      if (row && row.gym_id) return applyGymRow(row, row.logs || []);
    }
    const { data, error } = await Cloud.sb.rpc("ensure_gym");
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return { members: [] };
    applyGymRow(row, []);
    const logs = await fetchOwnLogs();
    return applyGymRow(row, logs);
  };

  function collectLogRows(state, uid, gid) {
    const rows = [];
    (state.members || []).forEach((m) => {
      if (!m || !m.share) return;
      (m.selfWorkouts || []).forEach((w) => {
        if (!w || !w.id) return;
        rows.push({ id: w.id, gym_id: gid, user_id: uid, share: m.share, kind: "self_workout", payload: w });
      });
      (m.dietLogs || []).forEach((d) => {
        if (!d || !d.id) return;
        rows.push({ id: d.id, gym_id: gid, user_id: uid, share: m.share, kind: "diet", payload: d });
      });
    });
    return rows;
  }

  async function upsertLogRows(rows) {
    if (!rows.length) return;
    const rpcRows = rows.map((r) => ({
      id: r.id,
      share: r.share,
      kind: r.kind,
      payload: r.payload
    }));
    const viaRpc = await Cloud.sb.rpc("upsert_member_logs", { p_rows: rpcRows });
    if (!viaRpc.error) return;
    const missing = rows.some((r) => !r.user_id || !r.gym_id || !r.id || !r.share);
    if (missing) throw viaRpc.error;
    const { error: upErr } = await Cloud.sb.from("member_logs").upsert(rows, { onConflict: "id" });
    if (upErr) throw upErr;
  }

  async function doFlush() {
    if (!Cloud.sb) return { ok: false, error: new Error("클라우드가 연결되지 않았습니다.") };
    const getState = Cloud._hooks.getState;
    if (!getState) return { ok: false, error: new Error("저장할 상태가 없습니다.") };
    try {
      await Cloud.ensureSession();
    } catch (err) {
      return { ok: false, error: err };
    }
    const uid = Cloud.user && Cloud.user.id;
    if (!Cloud.canWrite || !uid) {
      return { ok: false, error: new Error("로그인 세션이 만료되었습니다. 다시 로그인해 주세요.") };
    }
    const state = getState();
    Cloud._flushing = true;
    Cloud.status = "saving";
    Cloud._lastError = null;
    if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("saving");
    try {
      try {
        await Cloud.ensureGym();
      } catch (gymErr) {
        if (!Cloud.gymId) throw gymErr;
      }
      const payload = stripLogs(state);
      const pushed = await Cloud.sb.rpc("push_gym_state", { p_data: payload });
      if (pushed.error) {
        await pushGymStateDirect(payload);
      } else {
        Cloud.rev = Number(pushed.data) || Cloud.rev + 1;
        if (!Cloud.gymId) await Cloud.ensureGym();
      }
      const rows = collectLogRows(state, uid, Cloud.gymId);
      if (rows.length) await upsertLogRows(rows);
      Cloud._dirty = false;
      Cloud._skipUntil = Date.now() + 5000;
      Cloud.status = "saved";
      Cloud._lastResult = { ok: true };
      if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("saved");
      return Cloud._lastResult;
    } catch (err) {
      Cloud.status = "error";
      Cloud._lastError = err;
      Cloud._lastResult = { ok: false, error: err };
      Cloud._dirty = true;
      if (typeof Cloud._hooks.onStatus === "function") Cloud._hooks.onStatus("error", err);
      return Cloud._lastResult;
    } finally {
      Cloud._flushing = false;
    }
  }

  Cloud.flush = async function () {
    Cloud._pendingFlush = true;
    if (Cloud._flushPromise) return Cloud._flushPromise;
    Cloud._flushPromise = (async () => {
      let result = { ok: false, error: new Error("저장하지 못했습니다.") };
      try {
        while (Cloud._pendingFlush) {
          Cloud._pendingFlush = false;
          result = await doFlush();
        }
        return result;
      } finally {
        Cloud._flushPromise = null;
        if (Cloud._pendingFlush) {
          Cloud._pendingFlush = false;
          Cloud.schedulePush();
        }
      }
    })();
    return Cloud._flushPromise;
  };

  Cloud.schedulePush = function () {
    Cloud._dirty = true;
    if (!Cloud.canWrite) return;
    clearTimeout(Cloud._timer);
    Cloud._timer = setTimeout(() => { Cloud.flush(); }, 500);
  };

  Cloud.isBusy = function () {
    return !!(Cloud._flushing || Cloud._flushPromise || Cloud._pendingFlush || Cloud._dirty);
  };

  Cloud.hydrate = async function () {
    if (Cloud.sb && !Cloud.user) {
      try { await Cloud.ensureSession(); } catch (_) {}
    }
    const remote = await Cloud.pull();
    return remote || { members: [] };
  };

  Cloud.subscribe = function () {
    if (!Cloud.sb || !Cloud.gymId || !Cloud.user || Cloud._channel) return;
    const gymFilter = "gym_id=eq." + Cloud.gymId;
    Cloud._channel = Cloud.sb
      .channel("pt-gym-" + Cloud.gymId)
      .on("postgres_changes", { event: "*", schema: "public", table: "gym_state", filter: gymFilter }, () => {
        Cloud._onRemote();
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "member_logs", filter: gymFilter }, () => {
        Cloud._onRemote();
      })
      .subscribe();
  };

  Cloud.unsubscribe = function () {
    if (Cloud._channel && Cloud.sb) Cloud.sb.removeChannel(Cloud._channel);
    Cloud._channel = null;
  };

  Cloud._onRemote = async function () {
    if (Cloud.isBusy()) return;
    if (Date.now() < Cloud._skipUntil) return;
    try {
      const remote = await Cloud.pull();
      if (!remote) return;
      if (Cloud.isBusy()) return;
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
    if (!Cloud.sb || !share || !row) throw new Error("저장할 기록이 올바르지 않습니다.");
    if (!row.id) throw new Error("기록 ID가 없습니다.");
    if (!kind) throw new Error("기록 종류가 없습니다.");
    const { error } = await Cloud.sb.rpc("member_upsert_log", {
      p_share: share, p_kind: kind, p_row: row
    });
    if (!error) return true;
    if (Cloud.user) {
      await Cloud.ensureSession();
      await Cloud.ensureGym();
      const uid = Cloud.user && Cloud.user.id;
      if (uid && Cloud.gymId) {
        const { error: upErr } = await Cloud.sb.from("member_logs").upsert({
          id: row.id,
          gym_id: Cloud.gymId,
          user_id: uid,
          share,
          kind,
          payload: row,
          updated_at: new Date().toISOString()
        }, { onConflict: "id" });
        if (!upErr) return true;
        throw upErr;
      }
    }
    throw error;
  };

  Cloud.deleteLog = async function (share, id) {
    if (!Cloud.sb || !share || !id) return false;
    const { error } = await Cloud.sb.rpc("member_delete_log", { p_share: share, p_id: id });
    if (error) {
      console.warn("deleteLog", error);
      return false;
    }
    return true;
  };

  Cloud.storagePath = function (id, share) {
    if (Cloud.user && Cloud.canWrite) return "user/" + Cloud.user.id + "/" + id;
    if (share) return "share/" + share + "/" + id;
    return "share/unknown/" + id;
  };

  Cloud.mediaPaths = function (id, share, ownerId) {
    const paths = [];
    const add = function (p) {
      if (p && paths.indexOf(p) < 0) paths.push(p);
    };
    if (ownerId) add("user/" + ownerId + "/" + id);
    if (Cloud.user) add("user/" + Cloud.user.id + "/" + id);
    if (Cloud.gymId) add("gym/" + Cloud.gymId + "/" + id);
    if (share) add("share/" + share + "/" + id);
    add("share/unknown/" + id);
    return paths;
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
      throw error;
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

  Cloud.publicUrl = function (id, share, ownerId) {
    if (!Cloud.sb) return "";
    const paths = Cloud.mediaPaths(id, share, ownerId);
    if (!paths.length) return "";
    const { data } = Cloud.sb.storage.from("pt-media").getPublicUrl(paths[0]);
    return (data && data.publicUrl) || "";
  };

  Cloud.publicUrls = function (id, share, ownerId) {
    if (!Cloud.sb) return [];
    return Cloud.mediaPaths(id, share, ownerId).map((p) => {
      const { data } = Cloud.sb.storage.from("pt-media").getPublicUrl(p);
      return (data && data.publicUrl) || "";
    }).filter(Boolean);
  };

  Cloud.download = async function (id, share, ownerId) {
    if (!Cloud.sb) return null;
    const paths = Cloud.mediaPaths(id, share, ownerId);
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
