import { RegistrationEmail } from "./RegistrationEmail";
import { Button, Input } from "./components/controls";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, authOptions, getPermissions, listSpaces, login, logout, refreshSession, register, type Permissions, type Space, type User } from "./api";
import { Teams } from "./Teams";
import { Notes, clearNoteDrafts } from "./Notes";
import { Apps } from "./Apps";
import { Files } from "./files/Files";
import { clearTransfers } from "./files/Transfers";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "./components/ui/tooltip";
import { BookOpen, Files as FilesIcon, LayoutGrid, LogOut, NotebookText, PanelLeftClose, PanelLeftOpen, UsersRound } from "lucide-react";

type View = "teams" | "notes" | "apps" | "files";
const selectedKey = "vessel.console.space.v1";
const sidebarKey = "vessel.console.sidebar.collapsed.v1";

function viewFromHistory(): View {
  const saved = history.state?.consoleView;
  return saved === "notes" || saved === "apps" || saved === "teams" || saved === "files" ? saved : "files";
}

export function message(error: unknown): string {
  if (error instanceof ApiError) {
    const known: Record<string, string> = {
      INVALID_CREDENTIALS: "Incorrect email or password.", EMAIL_ALREADY_REGISTERED: "This email is already registered.",
      EMAIL_VERIFICATION_REQUIRED: "Request an email verification code before creating your account.",
      EMAIL_CODE_INVALID: "The verification code is invalid or expired. Check the code or request a new one.",
      EMAIL_CODE_RATE_LIMITED: "Too many verification requests. Please wait before trying again.",
      EMAIL_DELIVERY_UNAVAILABLE: "Verification email is temporarily unavailable. Please try again later.",
      REGISTRATION_DISABLED: "Registration is not available.", SPACE_PERMISSION_DENIED: "Your role does not allow this action.",
      NOTE_REVISION_CONFLICT: "This Note was changed by someone else. Copy your changes, then reload.",
      NOTE_AGENT_NOT_CONFIGURED: "Note Agent is not configured on the server yet.",
      AGENT_GATEWAY_NOT_CONFIGURED: "Note Agent gateway identity is not configured yet.",
      NOTE_AGENT_MCP_NOT_CONFIGURED: "Note Agent Edit needs a reachable Vessel MCP address.",
      NOTE_AGENT_RUN_ACTIVE: "An Agent Run is already active for this Note. Wait for it to finish or stop it.",
      NOTE_AGENT_CONTEXT_TOO_LARGE: "This Note is too large to send to Note Agent.",
      AGENT_THREAD_BUSY: "The previous Agent Run still occupies this Note's conversation. Resume or stop it before retrying.",
      AGENT_PLATFORM_RUN_START_FAILED: "Note Agent could not start. Check the Agent gateway identity and Agent ID.",
      AGENT_PLATFORM_EVENTS_UNAVAILABLE: "The Note Agent event stream is unavailable.",
      AGENT_PLATFORM_CANCEL_FAILED: "The Note Agent Run could not be stopped.",
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
  const [verificationRequired, setVerificationRequired] = useState(true);
  const [authEmail, setAuthEmail] = useState("");
  const [emailChallenge, setEmailChallenge] = useState<string | null>(null);
  const [authMode, setAuthMode] = useState<"login" | "register">(window.location.pathname === "/register" ? "register" : "login");
  const [authBusy, setAuthBusy] = useState(false);
  const [authError, setAuthError] = useState("");
  const [spaces, setSpaces] = useState<Space[]>([]);
  const [spaceId, setSpaceId] = useState("");
  const [permissions, setPermissions] = useState<Permissions | null>(null);
  const [view, setView] = useState<View>(viewFromHistory);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => localStorage.getItem(sidebarKey) === "true");
  const [notesSidebarHost, setNotesSidebarHost] = useState<HTMLDivElement | null>(null);
  const [error, setError] = useState("");
  const notesSidebarRef = useCallback((node: HTMLDivElement | null) => setNotesSidebarHost(node), []);

  function toggleSidebar() {
    setSidebarCollapsed(value => {
      localStorage.setItem(sidebarKey, String(!value));
      return !value;
    });
  }

  function openView(next: View) {
    setView(next);
    history.replaceState({ ...(history.state ?? {}), consoleView: next }, "", window.location.href);
  }

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
    clearNoteDrafts();
    let live = true;
    void Promise.all([refreshSession(), authOptions().catch(() => ({ registration_enabled: false, registration_email_verification_required: true }))]).then(async ([restored, options]) => {
      if (!live) return;
      setRegistrationEnabled(options.registration_enabled);
      setVerificationRequired(options.registration_email_verification_required !== false);
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
        ? await register(String(form.get("name") ?? ""), email, password, emailChallenge ?? undefined, String(form.get("verification_code") ?? "") || undefined)
        : await login(email, password);
      setUser(signed);
      setView("files");
      history.replaceState(null, "", "/console");
      await reloadSpaces();
    } catch (problem) { setAuthError(message(problem)); }
    finally { setAuthBusy(false); }
  }

  async function signOut() {
    try { await logout(); } catch (problem) { setError(message(problem)); return; }
    clearNoteDrafts();
    if (user) clearTransfers(user.user_id);
    setUser(null); setSpaces([]); setSpaceId(""); setPermissions(null); setAuthMode("login"); setView("files");
    localStorage.removeItem(selectedKey);
    history.replaceState(null, "", "/console");
  }

  if (booting) return <main className="boot-screen">Connecting to Karama.Cloud…</main>;
  if (!user) return <main className="auth-screen"><section className="auth-card">
    <div className="brand-lockup"><span className="brand-symbol">K</span><span>Karama.Cloud</span></div>
    <h1>{authMode === "register" ? "Create your Karama.Cloud account" : "Sign in to Karama.Cloud"}</h1>
    <p className="subtle">Manage Files, Notes, and Apps in personal and team spaces.</p>
    <form onSubmit={event => void authenticate(event)} className="stacked-form">
      {authMode === "register" && <label>Name<Input name="name" required maxLength={120} autoComplete="name" /></label>}
      <label>Email<Input name="email" type="email" value={authEmail} onChange={event => { setAuthEmail(event.target.value); setAuthError(""); }} required autoComplete="email" /></label>
      <label>Password<Input name="password" type="password" required minLength={authMode === "register" ? 8 : 1} autoComplete={authMode === "register" ? "new-password" : "current-password"} /></label>
      {authMode === "register" && verificationRequired && <RegistrationEmail email={authEmail} onChallenge={setEmailChallenge} describeError={message} />}
      {authError && <p role="alert" className="error-banner">{authError}</p>}
      <Button className="primary" disabled={authBusy || (authMode === "register" && verificationRequired && !emailChallenge)}>{authBusy ? "Please wait…" : authMode === "register" ? "Create account" : "Sign in"}</Button>
    </form>
    {registrationEnabled && (authMode === "login"
      ? <a href="/register" onClick={event => { event.preventDefault(); history.pushState(null, "", "/register"); setAuthMode("register"); setAuthError(""); }}>Create an account</a>
      : <a href="/console" onClick={event => { event.preventDefault(); history.pushState(null, "", "/console"); setAuthMode("login"); setAuthError(""); }}>Already have an account? Sign in</a>)}
  </section></main>;

  const space = spaces.find(item => item.space_id === spaceId);
  const docsLink = <a className="sidebar-docs-link" href="/docs" aria-label="API Docs"><BookOpen size={18} aria-hidden="true" /><span className="nav-label">API Docs</span></a>;
  return <div className={`app-shell${sidebarCollapsed ? " sidebar-collapsed" : ""}${view === "notes" ? " is-notes-view" : ""}`}>
    <aside className="sidebar">
      <div className="sidebar-brand-row"><div className="brand-lockup"><span className="brand-symbol">K</span><h1>Karama.Cloud</h1></div><Button className="sidebar-toggle" type="button" aria-label={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"} title={sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar"} tooltipSide="right" aria-expanded={!sidebarCollapsed} aria-controls="console-sidebar-navigation console-note-navigation" onClick={toggleSidebar}>{sidebarCollapsed ? <PanelLeftOpen size={18} aria-hidden="true" /> : <PanelLeftClose size={18} aria-hidden="true" />}</Button></div>
      <label className="space-label">CURRENT SPACE<select aria-label="Current space" value={spaceId} onChange={event => {
        setSpaceId(event.target.value); localStorage.setItem(selectedKey, event.target.value);
      }}>{spaces.map(item => <option key={item.space_id} value={item.space_id}>{item.name}</option>)}</select></label>
      <nav aria-label="Primary navigation" id="console-sidebar-navigation">
        <Button className={view === "files" ? "active" : ""} title={sidebarCollapsed ? "Files" : undefined} tooltipSide="right" aria-label="Files" onClick={() => openView("files")}><FilesIcon size={18} aria-hidden="true" /><span className="nav-label">Files</span></Button>
        <Button className={view === "notes" ? "active" : ""} title={sidebarCollapsed ? "Notes" : undefined} tooltipSide="right" aria-label="Notes" onClick={() => openView("notes")}><NotebookText size={18} aria-hidden="true" /><span className="nav-label">Notes</span></Button>
        <Button className={view === "apps" ? "active" : ""} title={sidebarCollapsed ? "Apps" : undefined} tooltipSide="right" aria-label="Apps" onClick={() => openView("apps")}><LayoutGrid size={18} aria-hidden="true" /><span className="nav-label">Apps</span></Button>
        <Button className={view === "teams" ? "active" : ""} title={sidebarCollapsed ? "Teams" : undefined} tooltipSide="right" aria-label="Teams" onClick={() => openView("teams")}><UsersRound size={18} aria-hidden="true" /><span className="nav-label">Teams</span></Button>
      </nav>
      <div className="sidebar-notes-slot" id="console-note-navigation" ref={notesSidebarRef} />
      <div className="sidebar-spacer" />
      <div className="sidebar-footer">{sidebarCollapsed ? <TooltipProvider delayDuration={350}><Tooltip><TooltipTrigger asChild>{docsLink}</TooltipTrigger><TooltipContent className="console-nav-tooltip" side="right" sideOffset={10}>API Docs</TooltipContent></Tooltip></TooltipProvider> : docsLink}
        <div className="account-panel"><div className="account-identity"><strong>{user.name}</strong><span>{user.email}</span><small>YOUR USER ID</small><div className="copy-row"><code data-testid="current-user-id">{user.user_id}</code><Button aria-label="Copy user ID" onClick={() => void navigator.clipboard.writeText(user.user_id)}>Copy</Button></div></div><Button className="sidebar-signout-row" type="button" aria-label="Sign out" title={sidebarCollapsed ? "Sign out" : undefined} tooltipSide="right" onClick={() => void signOut()}><LogOut size={18} aria-hidden="true" /><span className="nav-label">Sign out</span></Button></div>
      </div>
    </aside>
    <main className="main-panel">
      {error && <div role="alert" className="error-banner">{error}<Button onClick={() => setError("")}>Close</Button></div>}
      {space && permissions ? <>
        {view === "teams" && <Teams space={space} permissions={permissions} user={user} reloadSpaces={reloadSpaces} onError={setError} />}
        {view === "notes" && <Notes key={space.space_id} space={space} permissions={permissions} user={user} sidebarHost={notesSidebarHost} onError={setError} />}
        {view === "apps" && <Apps key={space.space_id} space={space} permissions={permissions} onError={setError} />}
        {view === "files" && <Files key={`${user.user_id}:${space.space_id}`} space={space} user={user} onError={setError} />}
      </> : <div className="loading-panel">Loading space…</div>}
    </main>
  </div>;
}
