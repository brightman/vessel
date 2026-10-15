import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, authOptions, getPermissions, listSpaces, login, logout, refreshSession, register, type Permissions, type Space, type User } from "./api";
import { Teams } from "./Teams";
import { Pages, clearPageDrafts } from "./Pages";
import { Apps } from "./Apps";

type View = "teams" | "pages" | "apps";
const selectedKey = "vessel.console.space.v1";

export function message(error: unknown): string {
  if (error instanceof ApiError) {
    const known: Record<string, string> = {
      INVALID_CREDENTIALS: "邮箱或密码错误。", EMAIL_ALREADY_REGISTERED: "这个邮箱已注册。",
      REGISTRATION_DISABLED: "目前未开放注册。", SPACE_PERMISSION_DENIED: "当前角色没有此操作权限。",
      PAGE_REVISION_CONFLICT: "Page 已被其他人修改。请复制当前内容，再重新载入。",
      APP_MANIFEST_VERSION_CONFLICT: "表结构已有新版本，请重新载入后再修改。",
      APP_RECORD_VERSION_CONFLICT: "记录已有新版本，请重新载入后再修改。",
      APP_FIELD_VALUE_INVALID: "字段值不符合表结构。", APP_MANIFEST_INVALID: "表结构格式无效。",
      APP_SCHEMA_CHANGE_UNSUPPORTED: "只允许新增表和可空字段。",
    };
    if (known[error.code]) return known[error.code];
    if (error.status === 422) return `输入不符合要求：${error.code}`;
    return `请求失败（${error.status}）：${error.code}`;
  }
  return error instanceof Error ? error.message : "请求失败，请重试。";
}

export function App() {
  const [user, setUser] = useState<User | null>(null);
  const [booting, setBooting] = useState(true);
  const [registrationEnabled, setRegistrationEnabled] = useState(false);
  const [authMode, setAuthMode] = useState<"login" | "register">(window.location.pathname === "/register" ? "register" : "login");
  const [authBusy, setAuthBusy] = useState(false);
  const [authError, setAuthError] = useState("");
  const [spaces, setSpaces] = useState<Space[]>([]);
  const [spaceId, setSpaceId] = useState("");
  const [permissions, setPermissions] = useState<Permissions | null>(null);
  const [view, setView] = useState<View>("pages");
  const [error, setError] = useState("");

  const reloadSpaces = useCallback(async (preferred?: string) => {
    const result = await listSpaces();
    setSpaces(result.spaces);
    const remembered = preferred ?? localStorage.getItem(selectedKey) ?? "";
    const chosen = result.spaces.find(space => space.space_id === remembered) ?? result.spaces[0];
    const next = chosen?.space_id ?? "";
    setSpaceId(next);
    if (next) localStorage.setItem(selectedKey, next);
  }, []);

  useEffect(() => {
    clearPageDrafts();
    let live = true;
    void Promise.all([refreshSession(), authOptions().catch(() => ({ registration_enabled: false }))]).then(async ([restored, options]) => {
      if (!live) return;
      setRegistrationEnabled(options.registration_enabled);
      if (!options.registration_enabled) setAuthMode("login");
      setUser(restored);
      if (restored) {
        try { await reloadSpaces(); } catch (problem) { if (live) setError(message(problem)); }
      }
    }).finally(() => { if (live) setBooting(false); });
    return () => { live = false; };
  }, [reloadSpaces]);

  useEffect(() => {
    if (!user || !spaceId) { setPermissions(null); return; }
    let live = true;
    setPermissions(null);
    void getPermissions(spaceId).then(value => { if (live) setPermissions(value); }).catch(problem => { if (live) setError(message(problem)); });
    return () => { live = false; };
  }, [user, spaceId]);

  async function authenticate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setAuthBusy(true); setAuthError("");
    const form = new FormData(event.currentTarget);
    try {
      const email = String(form.get("email") ?? "");
      const password = String(form.get("password") ?? "");
      const signed = authMode === "register"
        ? await register(String(form.get("name") ?? ""), email, password)
        : await login(email, password);
      setUser(signed);
      history.replaceState(null, "", "/console");
      await reloadSpaces();
    } catch (problem) { setAuthError(message(problem)); }
    finally { setAuthBusy(false); }
  }

  async function signOut() {
    try { await logout(); } catch (problem) { setError(message(problem)); return; }
    clearPageDrafts();
    setUser(null); setSpaces([]); setSpaceId(""); setPermissions(null); setAuthMode("login");
    localStorage.removeItem(selectedKey);
    history.replaceState(null, "", "/console");
  }

  if (booting) return <main className="boot-screen">正在连接 Vessel…</main>;
  if (!user) return <main className="auth-screen"><section className="auth-card">
    <div className="brand-lockup"><span className="brand-symbol">V</span><span>Vessel</span></div>
    <h1>{authMode === "register" ? "创建 Vessel 账号" : "登录 Vessel"}</h1>
    <p className="subtle">在个人空间和团队中管理 Pages 与 Apps。</p>
    <form onSubmit={event => void authenticate(event)} className="stacked-form">
      {authMode === "register" && <label>姓名<input name="name" required maxLength={120} autoComplete="name" /></label>}
      <label>邮箱<input name="email" type="email" required autoComplete="email" /></label>
      <label>密码<input name="password" type="password" required minLength={authMode === "register" ? 8 : 1} autoComplete={authMode === "register" ? "new-password" : "current-password"} /></label>
      {authError && <p role="alert" className="error-banner">{authError}</p>}
      <button className="primary" disabled={authBusy}>{authBusy ? "请稍候…" : authMode === "register" ? "注册" : "登录"}</button>
    </form>
    {registrationEnabled && (authMode === "login"
      ? <a href="/register" onClick={event => { event.preventDefault(); history.pushState(null, "", "/register"); setAuthMode("register"); setAuthError(""); }}>创建账号</a>
      : <a href="/console" onClick={event => { event.preventDefault(); history.pushState(null, "", "/console"); setAuthMode("login"); setAuthError(""); }}>已有账号？登录</a>)}
  </section></main>;

  const space = spaces.find(item => item.space_id === spaceId);
  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand-lockup"><span className="brand-symbol">V</span><h1>Vessel</h1></div>
      <label className="space-label">当前空间<select aria-label="当前空间" value={spaceId} onChange={event => {
        setSpaceId(event.target.value); localStorage.setItem(selectedKey, event.target.value);
      }}>{spaces.map(item => <option key={item.space_id} value={item.space_id}>{item.name}</option>)}</select></label>
      <nav aria-label="主要导航">
        <button className={view === "pages" ? "active" : ""} onClick={() => setView("pages")}>Pages</button>
        <button className={view === "apps" ? "active" : ""} onClick={() => setView("apps")}>Apps</button>
        <button className={view === "teams" ? "active" : ""} onClick={() => setView("teams")}>团队</button>
      </nav>
      <div className="sidebar-spacer" />
      <div className="account-panel"><strong>{user.name}</strong><span>{user.email}</span><small>我的用户 ID</small><div className="copy-row"><code data-testid="current-user-id">{user.user_id}</code><button aria-label="复制用户 ID" title="复制用户 ID" onClick={() => void navigator.clipboard.writeText(user.user_id)}>复制</button></div><button className="text-button" onClick={() => void signOut()}>退出登录</button></div>
    </aside>
    <main className="main-panel">
      {error && <div role="alert" className="error-banner">{error}<button onClick={() => setError("")}>关闭</button></div>}
      {space && permissions ? <>
        {view === "teams" && <Teams space={space} permissions={permissions} user={user} reloadSpaces={reloadSpaces} onError={setError} />}
        {view === "pages" && <Pages key={space.space_id} space={space} permissions={permissions} user={user} onError={setError} />}
        {view === "apps" && <Apps key={space.space_id} space={space} permissions={permissions} onError={setError} />}
      </> : <div className="loading-panel">正在加载空间…</div>}
    </main>
  </div>;
}
