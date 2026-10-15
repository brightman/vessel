import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, authOptions, getPermissions, listSpaces, login, logout, refreshSession, register, type Permissions, type Space, type User } from "./api";
import { Teams } from "./Teams";
import { Pages, clearPageDrafts } from "./Pages";
import { Apps } from "./Apps";
import { Files } from "./files/Files";
import { clearTransfers } from "./files/Transfers";

type View = "teams" | "pages" | "apps" | "files";
const selectedKey = "vessel.console.space.v1";

export function message(error: unknown): string {
  if (error instanceof ApiError) {
    const known: Record<string, string> = {
      INVALID_CREDENTIALS: "Incorrect email or password.", EMAIL_ALREADY_REGISTERED: "This email is already registered.",
      REGISTRATION_DISABLED: "Registration is not available.", SPACE_PERMISSION_DENIED: "Your role does not allow this action.",
      PAGE_REVISION_CONFLICT: "This Page was changed by someone else. Copy your changes, then reload.",
      APP_MANAGER_REQUIRED: "Only a space Owner or Admin can manage Apps.",
      APP_SETTINGS_VERSION_CONFLICT: "App settings changed. Reload before saving or changing its status.",
      APP_RELEASE_NOT_PUBLISHABLE: "This draft cannot be published. Check its validation and Manifest version.",
      APP_RELEASE_STORAGE_UNAVAILABLE: "App release storage is unavailable. Please try again later.",
      APP_MANIFEST_VERSION_CONFLICT: "The schema has a newer version. Reload before editing.",
      APP_RECORD_VERSION_CONFLICT: "This record has a newer version. Reload before editing.",
      APP_FIELD_VALUE_INVALID: "A field value does not match the schema.", APP_MANIFEST_INVALID: "The schema format is invalid.",
      APP_SCHEMA_CHANGE_UNSUPPORTED: "You can add tables and nullable fields only.",
    };
    if (known[error.code]) return known[error.code];
    if (error.status === 422) return `Input is invalid: ${error.code}`;
    return `Request failed (${error.status}): ${error.code}`;
  }
  return error instanceof Error ? error.message : "Request failed. Please try again.";
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
    if (user) clearTransfers(user.user_id);
    setUser(null); setSpaces([]); setSpaceId(""); setPermissions(null); setAuthMode("login");
    localStorage.removeItem(selectedKey);
    history.replaceState(null, "", "/console");
  }

  if (booting) return <main className="boot-screen">Connecting to Vessel…</main>;
  if (!user) return <main className="auth-screen"><section className="auth-card">
    <div className="brand-lockup"><span className="brand-symbol">V</span><span>Vessel</span></div>
    <h1>{authMode === "register" ? "Create your Vessel account" : "Sign in to Vessel"}</h1>
    <p className="subtle">Manage Files, Pages, and Apps in personal and team spaces.</p>
    <form onSubmit={event => void authenticate(event)} className="stacked-form">
      {authMode === "register" && <label>Name<input name="name" required maxLength={120} autoComplete="name" /></label>}
      <label>Email<input name="email" type="email" required autoComplete="email" /></label>
      <label>Password<input name="password" type="password" required minLength={authMode === "register" ? 8 : 1} autoComplete={authMode === "register" ? "new-password" : "current-password"} /></label>
      {authError && <p role="alert" className="error-banner">{authError}</p>}
      <button className="primary" disabled={authBusy}>{authBusy ? "Please wait…" : authMode === "register" ? "Create account" : "Sign in"}</button>
    </form>
    {registrationEnabled && (authMode === "login"
      ? <a href="/register" onClick={event => { event.preventDefault(); history.pushState(null, "", "/register"); setAuthMode("register"); setAuthError(""); }}>Create an account</a>
      : <a href="/console" onClick={event => { event.preventDefault(); history.pushState(null, "", "/console"); setAuthMode("login"); setAuthError(""); }}>Already have an account? Sign in</a>)}
  </section></main>;

  const space = spaces.find(item => item.space_id === spaceId);
  return <div className="app-shell">
    <aside className="sidebar">
      <div className="brand-lockup"><span className="brand-symbol">V</span><h1>Vessel</h1></div>
      <label className="space-label">CURRENT SPACE<select aria-label="Current space" value={spaceId} onChange={event => {
        setSpaceId(event.target.value); localStorage.setItem(selectedKey, event.target.value);
      }}>{spaces.map(item => <option key={item.space_id} value={item.space_id}>{item.name}</option>)}</select></label>
      <nav aria-label="Primary navigation">
        <button className={view === "files" ? "active" : ""} onClick={() => setView("files")}>Files</button>
        <button className={view === "pages" ? "active" : ""} onClick={() => setView("pages")}>Pages</button>
        <button className={view === "apps" ? "active" : ""} onClick={() => setView("apps")}>Apps</button>
        <button className={view === "teams" ? "active" : ""} onClick={() => setView("teams")}>Teams</button>
      </nav>
      <div className="sidebar-spacer" />
      <div className="account-panel"><strong>{user.name}</strong><span>{user.email}</span><small>YOUR USER ID</small><div className="copy-row"><code data-testid="current-user-id">{user.user_id}</code><button aria-label="Copy user ID" title="Copy user ID" onClick={() => void navigator.clipboard.writeText(user.user_id)}>Copy</button></div><button className="text-button" onClick={() => void signOut()}>Sign out</button></div>
    </aside>
    <main className="main-panel">
      {error && <div role="alert" className="error-banner">{error}<button onClick={() => setError("")}>Close</button></div>}
      {space && permissions ? <>
        {view === "teams" && <Teams space={space} permissions={permissions} user={user} reloadSpaces={reloadSpaces} onError={setError} />}
        {view === "pages" && <Pages key={space.space_id} space={space} permissions={permissions} user={user} onError={setError} />}
        {view === "apps" && <Apps key={space.space_id} space={space} permissions={permissions} onError={setError} />}
        {view === "files" && <Files key={`${user.user_id}:${space.space_id}`} space={space} user={user} onError={setError} />}
      </> : <div className="loading-panel">Loading space…</div>}
    </main>
  </div>;
}
