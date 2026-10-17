import { useDialogs } from "../components/dialogs";
import { Button, Input } from "../components/controls";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ApiError, type Space } from "../api";
import { addGrant, downloadFile, getItem, getItemPermissions, listAudit, listGrants, listVersions, restoreVersion, revokeGrant, updateGrant } from "./api";
import type { AuditEvent, FileItem, FilePermissions, FileVersion, Grant } from "./types";
import { Actions } from "./Actions";

type Props = { item: FileItem; space: Space; onClose: () => void; onChanged: () => void; onError: (text: string) => void; onNewVersion: (item: FileItem) => void };
type Tab = "info" | "versions" | "sharing" | "audit";

const stamp = (value: string) => new Date(value).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" });
const errorText = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · Request ${error.requestId}` : ""}` : error instanceof Error ? error.message : "Request failed";

export function Details({ item, space, onClose, onChanged, onError, onNewVersion }: Props) {
  const { confirm } = useDialogs();
  const [fresh, setFresh] = useState<FileItem>(item);
  const [permissions, setPermissions] = useState<FilePermissions | null>(null);
  const [tab, setTab] = useState<Tab>("info");
  const [versions, setVersions] = useState<FileVersion[]>([]);
  const [versionCursor, setVersionCursor] = useState<string | null>(null);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [grantCursor, setGrantCursor] = useState<string | null>(null);
  const [aclRevision, setAclRevision] = useState(1);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [auditCursor, setAuditCursor] = useState<string | null>(null);
  const [targetId, setTargetId] = useState("");
  const [role, setRole] = useState<"viewer" | "editor">("viewer");
  const [expiry, setExpiry] = useState("");
  const [busy, setBusy] = useState(false);
  const [localError, setLocalError] = useState("");
  const closeRef = useRef<HTMLButtonElement>(null);

  const reload = useCallback(async () => {
    const [metadata, access] = await Promise.all([getItem(item.item_id), getItemPermissions(item.item_id)]);
    setFresh(metadata.item); setPermissions(access.permissions);
    if (metadata.item.kind === "file") {
      const page = await listVersions(item.item_id);
      setVersions(page.versions); setVersionCursor(page.next_cursor);
    }
    if (access.permissions.can_manage_sharing) {
      const page = await listGrants(item.item_id);
      setGrants(page.grants); setGrantCursor(page.next_cursor); setAclRevision(page.acl_revision);
    } else { setGrants([]); setGrantCursor(null); }
  }, [item.item_id]);

  useEffect(() => {
    let active = true;
    setFresh(item); setPermissions(null); setTab("info"); setLocalError("");
    void reload().catch(error => {
      if (!active) return;
      if (error instanceof ApiError && (error.status === 403 || error.status === 404)) onClose();
      else setLocalError(errorText(error));
    });
    closeRef.current?.focus();
    return () => { active = false; };
  }, [item, reload, onClose]);

  const act = async (work: () => Promise<unknown>) => {
    setBusy(true); setLocalError("");
    try { await work(); await reload(); onChanged(); }
    catch (error) {
      setLocalError(errorText(error));
      if (error instanceof ApiError && (error.status === 403 || error.status === 404)) onClose();
      else if (!(error instanceof ApiError)) onError(errorText(error));
    } finally { setBusy(false); }
  };

  const download = async (versionId?: string) => {
    setLocalError("");
    try {
      const result = await downloadFile(fresh.item_id, versionId);
      const link = document.createElement("a"); link.href = result.download.url; link.rel = "noopener noreferrer";
      link.download = result.download.name; document.body.append(link); link.click(); link.remove();
    } catch (error) { setLocalError(errorText(error)); }
  };

  const appendVersions = async () => {
    if (!versionCursor) return;
    try { const page = await listVersions(fresh.item_id, versionCursor); setVersions(current => [...current, ...page.versions]); setVersionCursor(page.next_cursor); }
    catch (error) { setLocalError(errorText(error)); }
  };
  const appendGrants = async () => {
    if (!grantCursor) return;
    try { const page = await listGrants(fresh.item_id, grantCursor); setGrants(current => [...current, ...page.grants]); setGrantCursor(page.next_cursor); setAclRevision(page.acl_revision); }
    catch (error) { setLocalError(errorText(error)); }
  };
  const openAudit = async () => {
    setTab("audit");
    try { const page = await listAudit(space.space_id); setAudit(page.events); setAuditCursor(page.next_cursor); }
    catch (error) { setLocalError(errorText(error)); }
  };
  const appendAudit = async () => {
    if (!auditCursor) return;
    try { const page = await listAudit(space.space_id, auditCursor); setAudit(current => [...current, ...page.events]); setAuditCursor(page.next_cursor); }
    catch (error) { setLocalError(errorText(error)); }
  };
  const submitGrant = (event: FormEvent) => {
    event.preventDefault();
    void act(async () => { await addGrant(fresh.item_id, targetId.trim(), role, expiry ? new Date(expiry).toISOString() : null, aclRevision); setTargetId(""); setExpiry(""); });
  };

  return <aside className="files-details" role="dialog" aria-label="File details" aria-modal="false">
    <header><div><small>DETAILS</small><h3>{fresh.name}</h3></div><Button ref={closeRef} className="icon-button" aria-label="Close file details" onClick={onClose}>×</Button></header>
    {localError && <div className="files-detail-error" role="alert">{localError} <Button onClick={() => void reload().catch(error => setLocalError(errorText(error)))}>Reload</Button></div>}
    <div className="files-detail-tabs" role="tablist">
      <Button role="tab" aria-selected={tab === "info"} onClick={() => setTab("info")}>Info</Button>
      {fresh.kind === "file" && <Button role="tab" aria-selected={tab === "versions"} onClick={() => setTab("versions")}>Version history</Button>}
      {permissions?.can_manage_sharing && <Button role="tab" aria-selected={tab === "sharing"} onClick={() => setTab("sharing")}>Sharing</Button>}
      {fresh.space_id === space.space_id && ["owner", "admin"].includes(space.role) && <Button role="tab" aria-selected={tab === "audit"} onClick={() => void openAudit()}>Audit</Button>}
    </div>
    <div className="files-detail-body">
      {tab === "info" && <><dl className="files-metadata"><dt>Type</dt><dd>{fresh.kind === "folder" ? "Folder" : fresh.content_type}</dd><dt>Size</dt><dd>{fresh.size_bytes == null ? "—" : `${fresh.size_bytes.toLocaleString("en-US")} B`}</dd><dt>SHA-256</dt><dd>{fresh.sha256 ?? "—"}</dd><dt>Created</dt><dd>{stamp(fresh.created_at)}</dd><dt>Modified</dt><dd>{stamp(fresh.updated_at)}</dd><dt>Created by user ID</dt><dd>{fresh.created_by_user_id}</dd><dt>Updated by user ID</dt><dd>{fresh.updated_by_user_id}</dd><dt>Permission sources</dt><dd>{permissions?.permission_sources.map(source => `${source.type}:${source.role} (${source.source_item_id})`).join("; ") ?? "Loading…"}</dd></dl>
        <div className="files-detail-actions">{fresh.kind === "file" && permissions?.can_read && <Button className="secondary" onClick={() => void download()}>Download</Button>}{fresh.kind === "file" && permissions?.can_write && <Button className="secondary" disabled={busy} onClick={() => onNewVersion(fresh)}>Upload new version</Button>}{permissions && <Actions item={fresh} permissions={permissions} spaceId={fresh.space_id} onSaved={() => { void reload(); onChanged(); }} onError={setLocalError} />}</div></>}
      {tab === "versions" && <div className="files-versions">{versions.map(version => <div key={version.version_id}><div><strong>Version {version.ordinal}</strong><small>{stamp(version.created_at)} · {version.size_bytes.toLocaleString("en-US")} B · {version.source}</small></div><Button className="text-button" onClick={() => void download(version.version_id)}>Download</Button>{permissions?.can_write && <Button className="text-button" disabled={busy} onClick={async () => { if (await confirm("Restore this as a new logical version? Older versions will be kept.")) void act(() => restoreVersion(fresh.item_id, version.version_id, fresh.current_version_id!)); }}>Restore this version</Button>}</div>)}{versionCursor && <Button className="secondary" onClick={() => void appendVersions()}>Load more</Button>}</div>}
      {tab === "sharing" && permissions?.can_manage_sharing && <><form className="files-share-form" onSubmit={submitGrant}><label>Vessel user ID<Input value={targetId} onChange={event => setTargetId(event.target.value)} required /></label><label>Role<select value={role} onChange={event => setRole(event.target.value as typeof role)}><option value="viewer">Viewer</option><option value="editor">Editor</option></select></label><label>Expires at (optional)<Input type="datetime-local" value={expiry} onChange={event => setExpiry(event.target.value)} /></label><Button className="primary" disabled={busy}>Add share</Button></form>
        <div className="files-grants">{grants.map(grant => <div key={grant.grant_id}><strong>{grant.grantee_user_id}</strong><small>{grant.inherited ? `Inherited from ${grant.source_item_id}` : "Direct share"}{grant.expires_at ? ` · Expires ${stamp(grant.expires_at)}` : ""}</small>{!grant.inherited && <div><select aria-label={`Permission for ${grant.grantee_user_id}`} defaultValue={grant.role} disabled={busy} onChange={event => void act(() => updateGrant(fresh.item_id, grant.grant_id, event.target.value as "viewer" | "editor", grant.expires_at, aclRevision))}><option value="viewer">Viewer</option><option value="editor">Editor</option></select><Button className="text-button danger" disabled={busy} onClick={async () => { if (await confirm("Revoke this direct share?")) void act(() => revokeGrant(fresh.item_id, grant.grant_id, aclRevision)); }}>Revoke</Button></div>}</div>)}{grantCursor && <Button className="secondary" onClick={() => void appendGrants()}>Load more</Button>}</div></>}
      {tab === "audit" && <div className="files-audit">{audit.map(event => <div key={event.event_id}><strong>{event.operation}</strong><small>{stamp(event.created_at)} · {event.actor_user_id} · {event.item_id}</small></div>)}{auditCursor && <Button className="secondary" onClick={() => void appendAudit()}>Load more</Button>}</div>}
    </div>
  </aside>;
}
