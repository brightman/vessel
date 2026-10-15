import { useCallback, useEffect, useState } from "react";
import { ApiError, type Space } from "../api";
import { commitRestore, getPurge, listTrash, prepareRestore, purgeBatch } from "./api";
import type { ChangePreview, PurgeJob, TrashBatch } from "./types";

type Props = { space: Space; onRestored: () => void; onError: (message: string) => void };
const stamp = (value: string) => new Date(value).toLocaleString("zh-CN", { dateStyle: "medium", timeStyle: "short" });
const describe = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · 请求 ${error.requestId}` : ""}` : error instanceof Error ? error.message : "请求失败";

export function Trash({ space, onRestored, onError }: Props) {
  const [batches, setBatches] = useState<TrashBatch[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [selected, setSelected] = useState<TrashBatch | null>(null);
  const [preview, setPreview] = useState<ChangePreview | null>(null);
  const [targetId, setTargetId] = useState("");
  const [name, setName] = useState("");
  const [job, setJob] = useState<PurgeJob | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const reload = useCallback(async (next?: string) => {
    const result = await listTrash(space.space_id, next);
    setBatches(old => next ? [...old, ...result.trash_batches] : result.trash_batches);
    setCursor(result.next_cursor);
  }, [space.space_id]);
  useEffect(() => { void reload().catch(problem => onError(describe(problem))); }, [reload, onError]);
  useEffect(() => {
    if (!job || ["succeeded", "failed"].includes(job.status)) return;
    const timer = window.setTimeout(() => void getPurge(job.purge_id).then(result => { setJob(result.purge); if (result.purge.status === "succeeded") void reload(); }).catch(problem => setError(describe(problem))), 1000);
    return () => window.clearTimeout(timer);
  }, [job, reload]);

  const makePreview = async () => {
    if (!selected) return;
    setBusy(true); setError(""); setPreview(null);
    try { setPreview((await prepareRestore(selected.batch_id, targetId.trim() || undefined, name.trim() || undefined)).restore); }
    catch (problem) { setError(describe(problem)); }
    finally { setBusy(false); }
  };
  const restore = async () => {
    if (!selected || !preview) return;
    setBusy(true); setError("");
    try { await commitRestore(selected.batch_id, preview); setSelected(null); setPreview(null); await reload(); onRestored(); }
    catch (problem) { setError(describe(problem)); if (problem instanceof ApiError && problem.status === 409) setPreview(null); }
    finally { setBusy(false); }
  };
  const purge = async (batch: TrashBatch) => {
    if (!window.confirm("永久清理这个批次及全部历史版本？此操作无法撤销。")) return;
    setBusy(true); setError("");
    try { setJob((await purgeBatch(batch)).purge); await reload(); }
    catch (problem) { setError(describe(problem)); }
    finally { setBusy(false); }
  };

  return <div className="files-trash-view">
    {error && <p className="error-banner" role="alert">{error} <button onClick={() => { setError(""); setPreview(null); void reload().catch(problem => onError(describe(problem))); }}>重新载入</button></p>}
    {batches.length === 0 && <p className="files-empty">回收站为空。</p>}
    {batches.map(batch => <article key={batch.batch_id} className="files-trash-row"><div><strong>文件批次 {batch.root_item_id.slice(0, 8)}</strong><small>{batch.batch_id}</small><span>回收：{stamp(batch.trashed_at)} · 保留至：{stamp(batch.retention_until)}</span><span>原位置 ID：{batch.original_parent_folder_id}</span></div><div>{batch.status === "trashed" && <button className="secondary" disabled={busy} onClick={() => { setSelected(batch); setPreview(null); setTargetId(""); setName(""); }}>恢复</button>}{batch.status === "trashed" && ["owner", "admin"].includes(space.role) && <button className="secondary danger" disabled={busy} onClick={() => void purge(batch)}>永久清理</button>}{batch.status !== "trashed" && <span>{batch.status}</span>}</div></article>)}
    {cursor && <button className="secondary files-more" onClick={() => void reload(cursor).catch(problem => setError(describe(problem)))}>加载更多</button>}
    {job && <div className="files-purge-job" role="status">清理任务 {job.purge_id.slice(0, 8)}：{job.status === "succeeded" ? "已完成" : job.status === "failed" ? `失败 ${job.failure_code || ""}` : "正在清理"}</div>}
    {selected && <div className="modal-backdrop"><div className="modal-card files-action-modal" role="dialog" aria-label={preview ? "恢复权限变化" : "恢复文件"}><header><h3>恢复回收批次</h3><button className="icon-button" aria-label="关闭恢复" onClick={() => { setSelected(null); setPreview(null); }}>×</button></header><p className="hint">仅恢复该批次。默认返回原位置；名称冲突时可填写新名称或目标文件夹 ID。</p><div className="files-action-form"><label>目标文件夹 ID（可选）<input value={targetId} onChange={event => { setTargetId(event.target.value); setPreview(null); }} /></label><label>新名称（可选）<input value={name} onChange={event => { setName(event.target.value); setPreview(null); }} /></label><button className="secondary" disabled={busy} onClick={() => void makePreview()}>预览恢复</button>{preview && <div className="files-preview"><p>恢复名称：{preview.name}</p><p>目标文件夹：{preview.target_parent_folder_id}</p><p>新增来源：{preview.permission_changes.gained.length}；失去来源：{preview.permission_changes.lost.length}</p>{preview.permission_changes.gained.map(grant => <p key={grant.grant_id}>新增 {grant.grantee_user_id} · {grant.role}</p>)}{preview.permission_changes.lost.map(grant => <p key={grant.grant_id}>失去 {grant.grantee_user_id} · {grant.role}</p>)}<button className="primary" disabled={busy} onClick={() => void restore()}>确认恢复</button></div>}</div></div></div>}
  </div>;
}
