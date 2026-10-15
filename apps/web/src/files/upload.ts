import { cancelUpload, completeUpload, createUpload, getUpload, signParts } from "./api";
import { putSignedParts } from "./upload-transport";
import type { Upload } from "./types";

export type UploadTarget =
  | { mode: "create"; spaceId: string; parentFolderId: string; name: string }
  | { mode: "new_version"; spaceId: string; fileId: string; expectedCurrentVersionId: string; expectedMetadataVersion: number };
export type UploadProgress = { stage: "hashing" | "transfer" | "publishing"; bytesDone: number; bytesTotal: number };
export type UploadResult = { upload: Upload };

const terminal = new Set(["ready", "failed", "expired", "cancelled", "conflict"]);
const pause = (ms: number, signal: AbortSignal) => new Promise<void>((resolve, reject) => {
  const timer = window.setTimeout(() => { signal.removeEventListener("abort", abort); resolve(); }, ms);
  const abort = () => { window.clearTimeout(timer); reject(new DOMException("Aborted", "AbortError")); };
  signal.addEventListener("abort", abort, { once: true });
});

export function hashFile(file: File, onProgress: (done: number, total: number) => void, signal: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./upload-worker.ts", import.meta.url), { type: "module" });
    const cleanup = () => { worker.terminate(); signal.removeEventListener("abort", abort); };
    const abort = () => { cleanup(); reject(new DOMException("Aborted", "AbortError")); };
    if (signal.aborted) { abort(); return; }
    signal.addEventListener("abort", abort, { once: true });
    worker.onmessage = (event: MessageEvent<{ type: string; bytesDone?: number; bytesTotal?: number; sha256?: string; code?: string }>) => {
      if (event.data.type === "progress") onProgress(event.data.bytesDone ?? 0, event.data.bytesTotal ?? file.size);
      else if (event.data.type === "done" && event.data.sha256) { cleanup(); resolve(event.data.sha256); }
      else if (event.data.type === "error") { cleanup(); reject(new Error(event.data.code || "HASH_FAILED")); }
    };
    worker.onerror = () => { cleanup(); reject(new Error("HASH_FAILED")); };
    worker.postMessage({ file });
  });
}

export async function uploadFile(file: File, target: UploadTarget, onProgress: (progress: UploadProgress) => void, signal: AbortSignal, onUploadId: (uploadId: string) => void): Promise<UploadResult> {
  const sha256 = await hashFile(file, (bytesDone, bytesTotal) => onProgress({ stage: "hashing", bytesDone, bytesTotal }), signal);
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
  const intent = await createUpload(target.spaceId, {
    mode: target.mode, size_bytes: file.size, sha256, content_type: file.type || "application/octet-stream",
    ...(target.mode === "create" ? { parent_folder_id: target.parentFolderId, name: target.name } : {
      file_id: target.fileId, expected_current_version_id: target.expectedCurrentVersionId,
      expected_metadata_version: target.expectedMetadataVersion,
    }),
  });
  const upload = intent.upload;
  onUploadId(upload.upload_id);
  let parts: { part_number: number; etag: string }[] = [];
  try {
    onProgress({ stage: "transfer", bytesDone: 0, bytesTotal: file.size });
    parts = await putSignedParts(file, upload, async numbers => (await signParts(upload.upload_id, numbers)).instructions, fetch, (bytesDone, bytesTotal) => onProgress({ stage: "transfer", bytesDone, bytesTotal }), signal);
  } catch (error) {
    try { await cancelUpload(upload.upload_id); } catch { /* terminal state is read on reopen */ }
    throw error;
  }
  try {
    onProgress({ stage: "publishing", bytesDone: file.size, bytesTotal: file.size });
    await completeUpload(upload.upload_id, upload.transfer_mode === "multipart" ? parts : []);
    for (;;) {
      if (signal.aborted) throw new DOMException("Aborted", "AbortError");
      const state = await getUpload(upload.upload_id);
      if (terminal.has(state.upload.status)) {
        if (state.upload.status !== "ready") throw new Error(state.upload.failure_code || `UPLOAD_${state.upload.status.toUpperCase()}`);
        return state;
      }
      await pause(1000, signal);
    }
  } catch (error) {
    if (signal.aborted) { try { await cancelUpload(upload.upload_id); } catch { /* status read on reopen */ } }
    throw error;
  }
}
