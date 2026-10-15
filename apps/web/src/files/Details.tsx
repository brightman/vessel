import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ApiError, type Space } from "../api";
import { addGrant, downloadFile, getItem, getItemPermissions, listAudit, listGrants, listVersions, restoreVersion, revokeGrant, updateGrant } from "./api";
import type { AuditEvent, FileItem, FilePermissions, FileVersion, Grant } from "./types";
import { Actions } from "./Actions";

type Props = { item: FileItem; space: Space; onClose: () => void; onChanged: () => void; onError: (text: string) => void; onNewVersion: (item: FileItem) => void };
type Tab = "info" | "versions" | "sharing" | "audit";

const stamp = (value: string) => new Date(value).toLocaleString("zh-CN", { dateStyle: "medium", timeStyle: "short" });
const errorText = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · 请求 ${error.requestId}` : ""}` : error instanceof Error ? error.message : "请求失败";

export function Details({ item, space, onClose, onChanged, onError, onNewVersion }: Props) {
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

  return <aside className="files-details" role="dialog" aria-label="文件详情" aria-modal="false">
    <header><div><small>详细信息</small><h3>{fresh.name}</h3></div><button ref={closeRef} className="icon-button" aria-label="关闭文件详情" onClick={onClose}>×</button></header>
    {localError && <div className="files-detail-error" role="alert">{localError} <button onClick={() => void reload().catch(error => setLocalError(errorText(error)))}>重新载入</button></div>}
    <div className="files-detail-tabs" role="tablist">
      <button role="tab" aria-selected={tab === "info"} onClick={() => setTab("info")}>信息</button>
      {fresh.kind === "file" && <button role="tab" aria-selected={tab === "versions"} onClick={() => setTab("versions")}>历史版本</button>}
      {permissions?.can_manage_sharing && <button role="tab" aria-selected={tab === "sharing"} onClick={() => setTab("sharing")}>共享设置</button>}
      {fresh.space_id === space.space_id && ["owner", "admin"].includes(space.role) && <button role="tab" aria-selected={tab === "audit"} onClick={() => void openAudit()}>审计</button>}
    </div>
    <div className="files-detail-body">
      {tab === "info" && <><dl className="files-metadata"><dt>类型</dt><dd>{fresh.kind === "folder" ? "文件夹" : fresh.content_type}</dd><dt>大小</dt><dd>{fresh.size_bytes == null ? "—" : `${fresh.size_bytes.toLocaleString()} B`}</dd><dt>SHA-256</dt><dd>{fresh.sha256 ?? "—"}</dd><dt>创建时间</dt><dd>{stamp(fresh.created_at)}</dd><dt>修改时间</dt><dd>{stamp(fresh.updated_at)}</dd><dt>创建用户 ID</dt><dd>{fresh.created_by_user_id}</dd><dt>更新用户 ID</dt><dd>{fresh.updated_by_user_id}</dd><dt>权限来源</dt><dd>{permissions?.permission_sources.map(source => `${source.type}:${source.role} (${source.source_item_id})`).join("；") ?? "正在加载…"}</dd></dl>
        <div className="files-detail-actions">{fresh.kind === "file" && permissions?.can_read && <button className="secondary" onClick={() => void download()}>下载</button>}{fresh.kind === "file" && permissions?.can_write && <button className="secondary" disabled={busy} onClick={() => onNewVersion(fresh)}>上传新版本</button>}{permissions && <Actions item={fresh} permissions={permissions} spaceId={fresh.space_id} onSaved={() => { void reload(); onChanged(); }} onError={setLocalError} />}</div></>}
      {tab === "versions" && <div className="files-versions">{versions.map(version => <div key={version.version_id}><div><strong>版本 {version.ordinal}</strong><small>{stamp(version.created_at)} · {version.size_bytes.toLocaleString()} B · {version.source}</small></div><button className="text-button" onClick={() => void download(version.version_id)}>下载</button>{permissions?.can_write && <button className="text-button" disabled={busy} onClick={() => { if (window.confirm("恢复为新的逻辑版本？旧版本会保留。")) void act(() => restoreVersion(fresh.item_id, version.version_id, fresh.current_version_id!)); }}>恢复此版本</button>}</div>)}{versionCursor && <button className="secondary" onClick={() => void appendVersions()}>加载更多</button>}</div>}
      {tab === "sharing" && permissions?.can_manage_sharing && <><form className="files-share-form" onSubmit={submitGrant}><label>Vessel 用户 ID<input value={targetId} onChange={event => setTargetId(event.target.value)} required /></label><label>角色<select value={role} onChange={event => setRole(event.target.value as typeof role)}><option value="viewer">Viewer</option><option value="editor">Editor</option></select></label><label>到期时间（可选）<input type="datetime-local" value={expiry} onChange={event => setExpiry(event.target.value)} /></label><button className="primary" disabled={busy}>添加共享</button></form>
        <div className="files-grants">{grants.map(grant => <div key={grant.grant_id}><strong>{grant.grantee_user_id}</strong><small>{grant.inherited ? `继承自 ${grant.source_item_id}` : "直接共享"}{grant.expires_at ? ` · ${stamp(grant.expires_at)} 到期` : ""}</small>{!grant.inherited && <div><select aria-label={`权限 ${grant.grantee_user_id}`} defaultValue={grant.role} disabled={busy} onChange={event => void act(() => updateGrant(fresh.item_id, grant.grant_id, event.target.value as "viewer" | "editor", grant.expires_at, aclRevision))}><option value="viewer">Viewer</option><option value="editor">Editor</option></select><button className="text-button danger" disabled={busy} onClick={() => { if (window.confirm("撤销这项直接共享？")) void act(() => revokeGrant(fresh.item_id, grant.grant_id, aclRevision)); }}>撤销</button></div>}</div>)}{grantCursor && <button className="secondary" onClick={() => void appendGrants()}>加载更多</button>}</div></>}
      {tab === "audit" && <div className="files-audit">{audit.map(event => <div key={event.event_id}><strong>{event.operation}</strong><small>{stamp(event.created_at)} · {event.actor_user_id} · {event.item_id}</small></div>)}{auditCursor && <button className="secondary" onClick={() => void appendAudit()}>加载更多</button>}</div>}
    </div>
  </aside>;
}
