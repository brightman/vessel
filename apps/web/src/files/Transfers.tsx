import { useCallback, useEffect, useRef, useState } from "react";
import { ApiError } from "../api";
import { cancelUpload, getUpload } from "./api";
import { uploadFile, type UploadProgress, type UploadTarget } from "./upload";

type Task = { key: string; name: string; file?: File; target?: UploadTarget; uploadId?: string; state: string; progress?: UploadProgress; error?: string; controller?: AbortController };
type Props = { userId: string; spaceId: string; folderId: string; canUpload: boolean; onFinished: () => void; versionTarget?: UploadTarget | null; clearVersionTarget?: () => void };
const storageKey = (userId: string) => `vessel.files.uploads.${userId}`;
const keep = (userId: string, ids: string[]) => sessionStorage.setItem(storageKey(userId), JSON.stringify(ids));
const read = (userId: string): string[] => { try { const parsed: unknown = JSON.parse(sessionStorage.getItem(storageKey(userId)) || "[]"); return Array.isArray(parsed) ? parsed.filter(value => typeof value === "string") : []; } catch { return []; } };
const discard = (userId: string, uploadId: string) => {
  const ids = read(userId).filter(value => value !== uploadId);
  if (ids.length) keep(userId, ids);
  else sessionStorage.removeItem(storageKey(userId));
};
export const clearTransfers = (userId: string) => sessionStorage.removeItem(storageKey(userId));

function uploadError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 503 || error.code === "FILE_STORAGE_UNAVAILABLE") return "文件存储暂时不可用，请稍后重试。";
    if (error.status === 413) return "文件大小或空间配额超限。";
    return `${error.code}${error.requestId ? ` · 请求 ${error.requestId}` : ""}`;
  }
  return error instanceof Error ? error.message : "上传失败";
}

export function Transfers({ userId, spaceId, folderId, canUpload, onFinished, versionTarget, clearVersionTarget }: Props) {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [expanded, setExpanded] = useState(false);
  const running = useRef(new Set<string>());
  const pending = useRef<Task[]>([]);
  const alive = useRef(true);
  const controllers = useRef(new Map<string, AbortController>());
  const onFinishedRef = useRef(onFinished);
  onFinishedRef.current = onFinished;
  const update = useCallback((key: string, patch: Partial<Task>) => {
    if (!alive.current) return;
    setTasks(current => current.map(task => task.key === key ? { ...task, ...patch } : task));
  }, []);

  useEffect(() => {
    alive.current = true;
    const ids = read(userId);
    if (ids.length) {
      void Promise.all(ids.map(async uploadId => {
        try { const state = await getUpload(uploadId); return { key: uploadId, name: `上传 ${uploadId.slice(0, 8)}`, uploadId, state: state.upload.status } as Task; }
        catch { return null; }
      })).then(rows => {
        if (!alive.current) return;
        const active = rows.filter((row): row is Task => row !== null && !["ready", "failed", "expired", "cancelled", "conflict"].includes(row.state));
        setTasks(current => [...current, ...rows.filter((row): row is Task => row !== null)]);
        if (active.length) keep(userId, active.map(row => row.uploadId!));
        else clearTransfers(userId);
      });
    }
    return () => {
      alive.current = false;
      pending.current = [];
      for (const controller of controllers.current.values()) controller.abort();
      controllers.current.clear();
    };
  }, [userId]);

  const runNext = useCallback(() => {
    if (!alive.current) return;
    while (running.current.size < 2 && pending.current.length) {
      const task = pending.current.shift()!;
      running.current.add(task.key);
      const controller = new AbortController();
      controllers.current.set(task.key, controller);
      update(task.key, { state: "hashing", controller });
      void uploadFile(task.file!, task.target!, (progress) => update(task.key, { state: progress.stage, progress }), controller.signal, uploadId => {
        if (!alive.current) return;
        update(task.key, { uploadId });
        keep(userId, Array.from(new Set([...read(userId), uploadId])));
      }).then(result => {
        if (!alive.current) return;
        discard(userId, result.upload.upload_id);
        update(task.key, { state: "已完成", file: undefined, controller: undefined });
        clearVersionTarget?.();
        onFinishedRef.current();
      }).catch(error => {
        if (!alive.current) return;
        update(task.key, { state: controller.signal.aborted ? "已取消" : "失败", error: controller.signal.aborted ? undefined : uploadError(error), file: undefined, controller: undefined });
      }).finally(() => {
        controllers.current.delete(task.key);
        running.current.delete(task.key);
        if (alive.current) runNext();
      });
    }
  }, [clearVersionTarget, update, userId]);

  function enqueue(files: File[]) {
    if (!canUpload || files.length === 0) return;
    const created = files.map(file => ({ key: crypto.randomUUID(), name: file.name, file, target: versionTarget ?? { mode: "create" as const, spaceId, parentFolderId: folderId, name: file.name }, state: "等待中" }));
    pending.current.push(...created);
    setTasks(current => [...created, ...current]); setExpanded(true);
    window.setTimeout(runNext, 0);
  }
  const cancel = async (task: Task) => {
    task.controller?.abort();
    if (!task.controller) pending.current = pending.current.filter(value => value.key !== task.key);
    if (task.uploadId && !task.controller) { try { await cancelUpload(task.uploadId); } catch { /* status remains visible */ } }
    update(task.key, { state: "已取消", file: undefined });
  };

  return <div className="files-transfer-wrap" onDragOver={event => { if (canUpload) event.preventDefault(); }} onDrop={event => { if (!canUpload) return; event.preventDefault(); enqueue(Array.from(event.dataTransfer.files)); }}>
    {canUpload && <label className="primary files-upload-label">{versionTarget ? "选择新版本" : "上传文件"}<input aria-label="选择文件上传" type="file" multiple={!versionTarget} onChange={event => { enqueue(Array.from(event.target.files ?? [])); event.target.value = ""; }} /></label>}
    {tasks.length > 0 && <div className="files-transfer-queue" role="status" aria-label="上传队列" aria-live="polite"><button className="files-transfer-toggle" onClick={() => setExpanded(value => !value)}>上传队列 · {tasks.length} {expanded ? "收起" : "展开"}</button>{expanded && <div>{tasks.map(task => <div key={task.key}><strong>{task.name}</strong><span>{task.state}{task.progress?.stage === "transfer" ? ` ${Math.round(task.progress.bytesDone / Math.max(1, task.progress.bytesTotal) * 100)}%` : ""}</span>{task.error && <small>{task.error}</small>}{!["已完成", "已取消", "失败"].includes(task.state) && <button className="text-button" onClick={() => void cancel(task)}>取消</button>}</div>)}</div>}</div>}
  </div>;
}
