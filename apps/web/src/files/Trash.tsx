import { useDialogs } from "../components/dialogs";
import { Modal, Button, Input } from "../components/controls";
import { useCallback, useEffect, useState } from "react";
import { ApiError, type Space } from "../api";
import { commitRestore, getPurge, listTrash, prepareRestore, purgeBatch } from "./api";
import type { ChangePreview, PurgeJob, TrashBatch } from "./types";

type Props = { space: Space; onRestored: () => void; onError: (message: string) => void };
const stamp = (value: string) => new Date(value).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" });
const describe = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · Request ${error.requestId}` : ""}` : error instanceof Error ? error.message : "Request failed";

export function Trash({ space, onRestored, onError }: Props) {
  const { confirm } = useDialogs();
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
    if (!(await confirm("Permanently purge this batch and all version history? This cannot be undone."))) return;
    setBusy(true); setError("");
    try { setJob((await purgeBatch(batch)).purge); await reload(); }
    catch (problem) { setError(describe(problem)); }
    finally { setBusy(false); }
  };

  return <div className="files-trash-view">
    {error && <p className="error-banner" role="alert">{error} <Button onClick={() => { setError(""); setPreview(null); void reload().catch(problem => onError(describe(problem))); }}>Reload</Button></p>}
    {batches.length === 0 && <p className="files-empty">Trash is empty.</p>}
    {batches.map(batch => <article key={batch.batch_id} className="files-trash-row"><div><strong>File batch {batch.root_item_id.slice(0, 8)}</strong><small>{batch.batch_id}</small><span>Trashed: {stamp(batch.trashed_at)} · Kept until: {stamp(batch.retention_until)}</span><span>Original parent ID: {batch.original_parent_folder_id}</span></div><div>{batch.status === "trashed" && <Button className="secondary" disabled={busy} onClick={() => { setSelected(batch); setPreview(null); setTargetId(""); setName(""); }}>Restore</Button>}{batch.status === "trashed" && ["owner", "admin"].includes(space.role) && <Button className="secondary danger" disabled={busy} onClick={() => void purge(batch)}>Permanently purge</Button>}{batch.status !== "trashed" && <span>{batch.status}</span>}</div></article>)}
    {cursor && <Button className="secondary files-more" onClick={() => void reload(cursor).catch(problem => setError(describe(problem)))}>Load more</Button>}
    {job && <div className="files-purge-job" role="status">Purge job {job.purge_id.slice(0, 8)}: {job.status === "succeeded" ? "Complete" : job.status === "failed" ? `Failed ${job.failure_code || ""}` : "Purging"}</div>}
    {selected && <Modal title={preview ? "Restore permission changes" : "Restore files"} onClose={() => { setSelected(null); setPreview(null); }} className="files-action-modal"><header><h3>Restore trashed batch</h3><Button className="icon-button" aria-label="Close restore" onClick={() => { setSelected(null); setPreview(null); }}>×</Button></header><p className="hint">Only this batch will be restored. It returns to the original location by default; provide a new name or target folder ID if there is a conflict.</p><div className="files-action-form"><label>Target folder ID (optional)<Input value={targetId} onChange={event => { setTargetId(event.target.value); setPreview(null); }} /></label><label>New name (optional)<Input value={name} onChange={event => { setName(event.target.value); setPreview(null); }} /></label><Button className="secondary" disabled={busy} onClick={() => void makePreview()}>Preview restore</Button>{preview && <div className="files-preview"><p>Restore name: {preview.name}</p><p>Target folder: {preview.target_parent_folder_id}</p><p>Gained sources: {preview.permission_changes.gained.length}; lost sources: {preview.permission_changes.lost.length}</p>{preview.permission_changes.gained.map(grant => <p key={grant.grant_id}>Gained {grant.grantee_user_id} · {grant.role}</p>)}{preview.permission_changes.lost.map(grant => <p key={grant.grant_id}>Lost {grant.grantee_user_id} · {grant.role}</p>)}<Button className="primary" disabled={busy} onClick={() => void restore()}>Confirm restore</Button></div>}</div></Modal>}
  </div>;
}
