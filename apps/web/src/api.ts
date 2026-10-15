export type User = { user_id: string; name: string; email: string; roles: string[] };
export type Space = { space_id: string; kind: "personal" | "team"; name: string; role: string; status: string };
export type Permissions = { role: string; can_read: boolean; can_write: boolean; can_manage_members: boolean; can_delete: boolean };
export type Member = { user_id: string; role: string; status: string };
export type Invitation = { invitation_id: string; space_id: string; invitee_user_id: string; role: string; status: string; expires_at: string };
export type Directory = { directory_id: string; space_id: string; name: string };
export type PageRecord = { page_id: string; space_id: string; title: string; directory_id: string | null; document: Record<string, unknown>; markdown: string; revision: number; status: string; updated_at: string };
export type PageVersion = { version_id: string; revision: number; title: string; markdown: string; created_at: string };
export type FieldDefinition = { type: "text" | "integer" | "numeric" | "boolean" | "timestamp" | "uuid" | "json"; nullable: boolean };
export type Manifest = { tables: Record<string, { fields: Record<string, FieldDefinition> }> };
export type VesselApp = { app_id: string; space_id: string; name: string; manifest: Manifest; manifest_version: number };
export type AppRecord = { id: string; values: Record<string, unknown>; row_version: number; created_at: string; updated_at: string };

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, readonly detail?: unknown) { super(code); }
}

let accessToken: string | null = null;
let refreshPromise: Promise<User | null> | null = null;

async function request<T>(path: string, init: RequestInit = {}, retry = true): Promise<T> {
  const headers = new Headers(init.headers);
  if (accessToken) headers.set("Authorization", `Bearer ${accessToken}`);
  if (init.body && !(init.body instanceof File) && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...init, headers, credentials: "include" });
  if (response.status === 401 && retry && !path.startsWith("/v1/auth/")) {
    if (await refreshSession()) return request<T>(path, init, false);
  }
  if (!response.ok) {
    const payload = await response.json().catch(() => null) as { detail?: { code?: string } } | null;
    throw new ApiError(response.status, payload?.detail?.code ?? `HTTP_${response.status}`, payload?.detail);
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

export const authOptions = () => request<{ registration_enabled: boolean }>("/v1/auth/options");
export const login = (email: string, password: string) => authenticate("/v1/auth/login", { email, password });
export const register = (name: string, email: string, password: string) => authenticate("/v1/auth/register", { name, email, password });
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

export const listPages = (spaceId: string, status: "active" | "archived" = "active") => request<{ pages: PageRecord[] }>(`/v1/spaces/${id(spaceId)}/pages?status=${status}`);
export const listDirectories = (spaceId: string) => request<{ directories: Directory[] }>(`/v1/spaces/${id(spaceId)}/directories`);
export const createDirectory = (spaceId: string, name: string) => json<{ directory: Directory }>("POST", `/v1/spaces/${id(spaceId)}/directories`, { name });
export const createPage = (spaceId: string, title: string, directoryId: string | null) => json<{ page: PageRecord }>("POST", `/v1/spaces/${id(spaceId)}/pages`, { title, directory_id: directoryId, document: { type: "doc", schema_version: 1, content: [{ type: "paragraph", attrs: { block_id: crypto.randomUUID() } }] } });
export const savePage = (page: PageRecord, title: string, document: Record<string, unknown>, directoryId: string | null) => json<{ page: PageRecord }>("PATCH", `/v1/pages/${id(page.page_id)}`, { expected_revision: page.revision, title, document, directory_id: directoryId });
export const archivePage = (pageId: string) => json("POST", `/v1/pages/${id(pageId)}/archive`);
export const restorePage = (pageId: string) => json<{ page: PageRecord }>("POST", `/v1/pages/${id(pageId)}/restore`);
export const listVersions = (pageId: string) => request<{ versions: PageVersion[] }>(`/v1/pages/${id(pageId)}/versions`);
export const restoreVersion = (page: PageRecord, versionId: string) => json<{ page: PageRecord }>("POST", `/v1/pages/${id(page.page_id)}/versions/${id(versionId)}/restore`, { expected_revision: page.revision });
export async function resolvePageAsset(contentUrl: string): Promise<string> {
  const response = await fetch(contentUrl, { headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : {}, credentials: "include" });
  if (!response.ok) throw new ApiError(response.status, `ASSET_HTTP_${response.status}`);
  return URL.createObjectURL(await response.blob());
}

export const listApps = (spaceId: string) => request<{ apps: VesselApp[] }>(`/v1/spaces/${id(spaceId)}/apps`);
export const createApp = (spaceId: string, name: string, manifest: Manifest) => json<{ app: VesselApp }>("POST", `/v1/spaces/${id(spaceId)}/apps`, { name, manifest });
export const updateManifest = (app: VesselApp, manifest: Manifest) => json<{ app: VesselApp }>("PUT", `/v1/apps/${id(app.app_id)}/manifest`, { expected_version: app.manifest_version, manifest });
export const listRecords = (appId: string, table: string, cursor?: string) => request<{ records: AppRecord[]; next_cursor: string | null }>(`/v1/apps/${id(appId)}/tables/${id(table)}/records?limit=50${cursor ? `&cursor=${id(cursor)}` : ""}`);
export const createRecord = (appId: string, table: string, values: Record<string, unknown>) => json<{ record: AppRecord }>("POST", `/v1/apps/${id(appId)}/tables/${id(table)}/records`, { values });
export const updateRecord = (appId: string, table: string, record: AppRecord, values: Record<string, unknown>) => json<{ record: AppRecord }>("PATCH", `/v1/apps/${id(appId)}/tables/${id(table)}/records/${id(record.id)}`, { expected_row_version: record.row_version, values });
export const deleteRecord = (appId: string, table: string, record: AppRecord) => json("DELETE", `/v1/apps/${id(appId)}/tables/${id(table)}/records/${id(record.id)}`, { expected_row_version: record.row_version });
