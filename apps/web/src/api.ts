export type User = { user_id: string; name: string; email: string; roles: string[] };
export type Space = { space_id: string; kind: "personal" | "team"; name: string; role: string; status: string };
export type Permissions = { role: string; can_read: boolean; can_write: boolean; can_manage_members: boolean; can_delete: boolean };
export type Member = { user_id: string; role: string; status: string };
export type Invitation = { invitation_id: string; space_id: string; invitee_user_id: string; role: string; status: string; expires_at: string };
export type Directory = { directory_id: string; space_id: string; name: string };
export type NoteRecord = { note_id: string; space_id: string; title: string; directory_id: string | null; document: Record<string, unknown>; markdown: string; revision: number; status: string; updated_at: string };
export type NoteVersion = { version_id: string; revision: number; title: string; markdown: string; created_at: string };
export type FieldDefinition = { type: "text" | "integer" | "numeric" | "boolean" | "timestamp" | "uuid" | "json"; nullable: boolean };
export type Manifest = { tables: Record<string, { fields: Record<string, FieldDefinition> }> };
export type VesselApp = { app_id: string; space_id: string; name: string; manifest: Manifest; manifest_version: number; description: string; settings_version: number; status: "active" | "archived" };
export type AppRecord = { id: string; values: Record<string, unknown>; row_version: number; created_at: string; updated_at: string };

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, readonly detail?: unknown, readonly requestId?: string | null, readonly retryAfter?: number) { super(code); }
}

let accessToken: string | null = null;
let refreshPromise: Promise<User | null> | null = null;

export async function request<T>(path: string, init: RequestInit = {}, retry = true): Promise<T> {
  const headers = new Headers(init.headers);
  if (accessToken) headers.set("Authorization", `Bearer ${accessToken}`);
  if (init.body && !(init.body instanceof File) && !(init.body instanceof FormData) && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...init, headers, credentials: "include" });
  if (response.status === 401 && retry && !path.startsWith("/v1/auth/")) {
    if (await refreshSession()) return request<T>(path, init, false);
  }
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { detail?: { code?: string } } | null;
    const retry = Number(response.headers.get("Retry-After"));
    throw new ApiError(response.status, payload?.detail?.code ?? `HTTP_${response.status}`, payload?.detail, response.headers.get("X-Request-ID"), Number.isFinite(retry) && retry > 0 ? Math.min(Math.ceil(retry), 86400) : undefined);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

function json<T>(method: string, path: string, body?: unknown): Promise<T> {
  return request<T>(path, { method, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
}

async function authenticate(path: string, body: unknown): Promise<User> {
  const result = await json<{ access_token: string; user: User }>("POST", path, body);
  accessToken = result.access_token;
  return result.user;
}

export const authOptions = () => request<{ registration_enabled: boolean; registration_email_verification_required: boolean; registration_email_resend_seconds: number }>("/v1/auth/options");
export const login = (email: string, password: string) => authenticate("/v1/auth/login", { email, password });
export const register = (name: string, email: string, password: string, challenge_id?: string, verification_code?: string) => authenticate("/v1/auth/register", { name, email, password, challenge_id, verification_code });
export const requestRegistrationCode = (email: string) => json<{ challenge_id: string; expires_in: number; resend_after: number }>("POST", "/v1/auth/registration/email-code", { email });
export async function refreshSession(): Promise<User | null> {
  if (!refreshPromise) refreshPromise = (async () => {
    try {
      const result = await request<{ access_token: string; user: User }>("/v1/auth/refresh", { method: "POST" }, false);
      accessToken = result.access_token;
      return result.user;
    } catch { accessToken = null; return null; }
  })().finally(() => { refreshPromise = null; });
  return refreshPromise;
}
export async function logout(): Promise<void> {
  await request<void>("/v1/auth/logout", { method: "POST" }, false);
  accessToken = null;
}

const id = encodeURIComponent;
function clientBlockId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  return `block-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
export const listSpaces = () => request<{ spaces: Space[] }>("/v1/spaces");
export const getPermissions = (spaceId: string) => request<Permissions>(`/v1/spaces/${id(spaceId)}/permissions`);
export const createTeam = (name: string) => json<{ space: Space }>("POST", "/v1/teams", { name });
export const listMembers = (spaceId: string) => request<{ members: Member[] }>(`/v1/teams/${id(spaceId)}/members`);
export const listTeamInvitations = (spaceId: string) => request<{ invitations: Invitation[] }>(`/v1/teams/${id(spaceId)}/invitations`);
export const listMyInvitations = () => request<{ invitations: Invitation[] }>("/v1/team-invitations");
export const inviteMember = (spaceId: string, inviteeUserId: string, role: string) => json<{ invitation: Invitation }>("POST", `/v1/teams/${id(spaceId)}/invitations`, { invitee_user_id: inviteeUserId, role });
export const acceptInvitation = (invitationId: string) => json("POST", `/v1/team-invitations/${id(invitationId)}/accept`);
export const revokeInvitation = (spaceId: string, invitationId: string) => json("DELETE", `/v1/teams/${id(spaceId)}/invitations/${id(invitationId)}`);
export const updateMember = (spaceId: string, userId: string, role: string) => json("PATCH", `/v1/teams/${id(spaceId)}/members/${id(userId)}`, { role });
export const removeMember = (spaceId: string, userId: string) => json("DELETE", `/v1/teams/${id(spaceId)}/members/${id(userId)}`);

export const listNotes = (spaceId: string, status: "active" | "archived" = "active") => request<{ notes: NoteRecord[] }>(`/v1/spaces/${id(spaceId)}/notes?status=${status}`);
export const listDirectories = (spaceId: string) => request<{ directories: Directory[] }>(`/v1/spaces/${id(spaceId)}/directories`);
export const createDirectory = (spaceId: string, name: string) => json<{ directory: Directory }>("POST", `/v1/spaces/${id(spaceId)}/directories`, { name });
export const createNote = (spaceId: string, title: string, directoryId: string | null) => json<{ note: NoteRecord }>("POST", `/v1/spaces/${id(spaceId)}/notes`, { title, directory_id: directoryId, document: { type: "doc", schema_version: 1, content: [{ type: "paragraph", attrs: { block_id: clientBlockId() } }] } });
export const saveNote = (note: NoteRecord, title: string, document: Record<string, unknown>, directoryId: string | null) => json<{ note: NoteRecord }>("PATCH", `/v1/notes/${id(note.note_id)}`, { expected_revision: note.revision, title, document, directory_id: directoryId });
export const archiveNote = (noteId: string) => json("POST", `/v1/notes/${id(noteId)}/archive`);
export const restoreNote = (noteId: string) => json<{ note: NoteRecord }>("POST", `/v1/notes/${id(noteId)}/restore`);
export const listVersions = (noteId: string) => request<{ versions: NoteVersion[] }>(`/v1/notes/${id(noteId)}/versions`);
export const restoreVersion = (note: NoteRecord, versionId: string) => json<{ note: NoteRecord }>("POST", `/v1/notes/${id(note.note_id)}/versions/${id(versionId)}/restore`, { expected_revision: note.revision });

export type NoteProposal = { proposal_id: string; note_id: string; base_revision: number; run_id: string; status: string; summary: string | null; preview: { title: string; markdown: string; document: Record<string, unknown> }; operation_count: number; failure_code: string | null };
export type NoteAgentEvent = { event_type: string; event_id?: string; payload: Record<string, unknown> };
export type AgentMode = "ask" | "edit" | "auto";
export type AgentResponse = { schema_version: 1; type: "answer" | "clarification" | "edit"; message: string; sources?: { title: string; url: string }[]; options?: { id: string; label: string }[] };
export type NoteAgentRun = { run_id: string; mode: AgentMode; status: string; failure_code: string | null; reply: string | null; prompt: string; response: AgentResponse | null; answered_by_run_id?: string | null };
export const noteAgentStatus = (noteId: string) => request<{ configured: boolean; edit_configured: boolean; online: boolean; active_run: { run_id: string; mode: AgentMode } | null; latest_run: NoteAgentRun | null }>(`/v1/notes/${id(noteId)}/agent/status`);
export const startNoteAgentRun = (noteId: string, prompt: string, mode: AgentMode = "auto", continuation?: { reply_to_run_id: string; option_id?: string }) => json<{ run_id: string; status: string }>("POST", `/v1/notes/${id(noteId)}/agent/runs`, { message: prompt, mode, ...continuation });
export const getNoteAgentRun = (noteId: string, runId: string) => request<NoteAgentRun>(`/v1/notes/${id(noteId)}/agent/runs/${id(runId)}`);
export const cancelNoteAgentRun = (noteId: string, runId: string) => json<{ status: string }>("POST", `/v1/notes/${id(noteId)}/agent/runs/${id(runId)}/cancel`);
export const listNoteProposals = (noteId: string) => request<{ proposals: NoteProposal[] }>(`/v1/notes/${id(noteId)}/proposals`);
export const acceptNoteProposal = (noteId: string, proposalId: string, key: string) => json<{ note: NoteRecord }>("POST", `/v1/notes/${id(noteId)}/proposals/${id(proposalId)}/accept`, { idempotency_key: key });
export const rejectNoteProposal = (noteId: string, proposalId: string) => json<{ proposal: NoteProposal }>("POST", `/v1/notes/${id(noteId)}/proposals/${id(proposalId)}/reject`);

export async function streamNoteAgentRun(
  noteId: string, runId: string, onEvent: (event: NoteAgentEvent) => void, signal: AbortSignal,
  retryAuth = true,
): Promise<void> {
  const path = `/v1/notes/${id(noteId)}/agent/runs/${id(runId)}/events`;
  const headers = new Headers({ Accept: "text/event-stream" });
  if (accessToken) headers.set("Authorization", `Bearer ${accessToken}`);
  const response = await fetch(path, { headers, credentials: "include", signal });
  if (response.status === 401 && retryAuth && await refreshSession()) return streamNoteAgentRun(noteId, runId, onEvent, signal, false);
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { detail?: { code?: string } } | null;
    throw new ApiError(response.status, payload?.detail?.code ?? `HTTP_${response.status}`);
  }
  if (!response.body) throw new Error("Agent event stream is unavailable");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const dispatch = (frame: string) => {
    const lines = frame.split(/\r?\n/);
    const eventType = lines.find(line => line.startsWith("event:"))?.slice(6).trim();
    const eventId = lines.find(line => line.startsWith("id:"))?.slice(3).trim();
    const data = lines.filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n");
    if (!eventType || !data) return;
    try {
      const parsed = JSON.parse(data) as { payload?: Record<string, unknown>; status?: string };
      onEvent({ event_type: eventType, event_id: eventId, payload: eventType === "done" ? { status: parsed.status } : parsed.payload ?? {} });
    } catch { /* Ignore malformed frames; later events can still arrive. */ }
  };
  while (!signal.aborted) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    let boundary = buffer.match(/\r?\n\r?\n/);
    while (boundary?.index !== undefined) {
      dispatch(buffer.slice(0, boundary.index));
      buffer = buffer.slice(boundary.index + boundary[0].length);
      boundary = buffer.match(/\r?\n\r?\n/);
    }
    if (done) break;
  }
  if (buffer.trim()) dispatch(buffer);
}
export async function resolveNoteAsset(contentUrl: string): Promise<string> {
  const response = await fetch(contentUrl, { headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : {}, credentials: "include" });
  if (!response.ok) throw new ApiError(response.status, `ASSET_HTTP_${response.status}`);
  return URL.createObjectURL(await response.blob());
}

export const listApps = (spaceId: string, status: "active" | "archived" = "active") => request<{ apps: VesselApp[] }>(`/v1/spaces/${id(spaceId)}/apps?status=${status}`);
export const createApp = (spaceId: string, name: string, manifest: Manifest) => json<{ app: VesselApp }>("POST", `/v1/spaces/${id(spaceId)}/apps`, { name, manifest });
export const updateManifest = (app: VesselApp, manifest: Manifest) => json<{ app: VesselApp }>("PUT", `/v1/apps/${id(app.app_id)}/manifest`, { expected_version: app.manifest_version, manifest });
export const listRecords = (appId: string, table: string, cursor?: string) => request<{ records: AppRecord[]; next_cursor: string | null }>(`/v1/apps/${id(appId)}/tables/${id(table)}/records?limit=50${cursor ? `&cursor=${id(cursor)}` : ""}`);
export const createRecord = (appId: string, table: string, values: Record<string, unknown>) => json<{ record: AppRecord }>("POST", `/v1/apps/${id(appId)}/tables/${id(table)}/records`, { values });
export const updateRecord = (appId: string, table: string, record: AppRecord, values: Record<string, unknown>) => json<{ record: AppRecord }>("PATCH", `/v1/apps/${id(appId)}/tables/${id(table)}/records/${id(record.id)}`, { expected_row_version: record.row_version, values });
export const deleteRecord = (appId: string, table: string, record: AppRecord) => json("DELETE", `/v1/apps/${id(appId)}/tables/${id(table)}/records/${id(record.id)}`, { expected_row_version: record.row_version });

export type AuditEvent = { event_id: string; release_id: string | null; actor_user_id: string; action: string; details: Record<string, unknown>; created_at: string };
export type AppRelease = { release_id: string; app_id: string; version: number; manifest_version: number; status: "draft" | "validation_failed" | "published"; entry_file: string | null; file_count: number | null; total_size_bytes: number | null; checksum_sha256: string | null; validation_error_code: string | null; is_current: boolean; created_at: string; published_at: string | null; public_url: string | null };
export type RecordFilter = { field: string; op: "eq" | "ne" | "lt" | "lte" | "gt" | "gte" | "in" | "is_null"; value: unknown };
export type RecordQuery = { search?: string; filter?: RecordFilter | { and: RecordFilter[] }; sort?: Array<{ field: string; direction: "asc" | "desc" }>; limit?: number; cursor?: string };
export const getApp = (appId: string) => request<{ app: VesselApp }>(`/v1/apps/${id(appId)}`);
export const saveAppSettings = (app: VesselApp, name: string, description: string) => json<{ app: VesselApp }>("PATCH", `/v1/apps/${id(app.app_id)}`, { expected_settings_version: app.settings_version, name, description });
export const setAppArchived = (app: VesselApp, archived: boolean) => json<{ app: VesselApp }>("POST", `/v1/apps/${id(app.app_id)}/${archived ? "archive" : "restore"}`, { expected_settings_version: app.settings_version });
export const listAppAudit = (appId: string, cursor?: string) => request<{ events: AuditEvent[]; next_cursor: string | null }>(`/v1/apps/${id(appId)}/audit-events?limit=50${cursor ? `&cursor=${id(cursor)}` : ""}`);
export const queryRecords = (appId: string, table: string, query: RecordQuery) => json<{ records: AppRecord[]; next_cursor: string | null }>("POST", `/v1/apps/${id(appId)}/tables/${id(table)}/records/query`, query);
export const bulkDeleteRecords = (appId: string, table: string, records: AppRecord[]) => json<{ deleted_count: number }>("POST", `/v1/apps/${id(appId)}/tables/${id(table)}/records/bulk-delete`, { records: records.map(record => ({ id: record.id, expected_row_version: record.row_version })) });
export const listAppReleases = (appId: string) => request<{ releases: AppRelease[] }>(`/v1/apps/${id(appId)}/releases`);
export const createAppDraft = (appId: string) => json<{ release: AppRelease }>("POST", `/v1/apps/${id(appId)}/releases`);
export const uploadAppRelease = (appId: string, releaseId: string, file: File) => {
  const body = new FormData(); body.append("file", file);
  return request<{ release: AppRelease; preview_url: string | null }>(`/v1/apps/${id(appId)}/releases/${id(releaseId)}/upload`, { method: "POST", body });
};
export const publishAppRelease = (appId: string, releaseId: string) => json<{ release: AppRelease }>("POST", `/v1/apps/${id(appId)}/releases/${id(releaseId)}/publish`);
export const rollbackAppRelease = (appId: string, releaseId: string) => json<{ release: AppRelease }>("POST", `/v1/apps/${id(appId)}/releases/${id(releaseId)}/rollback`);
export const launchAppRelease = (appId: string, releaseId: string) => json<{ launch_url: string }>("POST", `/v1/apps/${id(appId)}/releases/${id(releaseId)}/launch`);
