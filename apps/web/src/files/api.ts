import { request } from "../api";
import type { AuditEvent, ChangePreview, Download, FileItem, FilePermissions, FileVersion, Grant, PurgeJob, TrashBatch, Upload, UploadInstruction } from "./types";

const id = encodeURIComponent;
const query = (values: Record<string, string | number | undefined>) => {
  const parts = Object.entries(values).filter(([, value]) => value !== undefined).map(([key, value]) => `${id(key)}=${id(String(value))}`);
  return parts.length ? `?${parts.join("&")}` : "";
};
export const intentKey = () => crypto.randomUUID();

export async function fileRequest<T>(method: string, path: string, body?: unknown, key?: string): Promise<T> {
  const headers = new Headers();
  if (key) headers.set("Idempotency-Key", key);
  return request<T>(path, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
}

export const getRoot = (spaceId: string) => request<{ folder: FileItem }>(`/v1/spaces/${id(spaceId)}/folders/root`);
export const listItems = (spaceId: string, folderId: string, cursor?: string, kind?: string) => request<{ items: FileItem[]; next_cursor: string | null }>(`/v1/spaces/${id(spaceId)}/file-items${query({ parent_folder_id: folderId, cursor, kind })}`);
export const listChildren = (folderId: string, cursor?: string, kind?: string) => request<{ items: FileItem[]; next_cursor: string | null }>(`/v1/folders/${id(folderId)}/children${query({ cursor, kind })}`);
export const listShared = (cursor?: string) => request<{ items: FileItem[]; next_cursor: string | null }>(`/v1/shared-files${query({ cursor })}`);
export const searchItems = (spaceId: string, filter: { name_contains?: string; kind?: "file" | "folder" }, cursor?: string) => fileRequest<{ items: FileItem[]; next_cursor: string | null }>("POST", `/v1/spaces/${id(spaceId)}/file-items/search`, { ...filter, cursor });
export const getItem = (itemId: string) => request<{ item: FileItem }>(`/v1/file-items/${id(itemId)}`);
export const getItemPermissions = (itemId: string) => request<{ permissions: FilePermissions }>(`/v1/file-items/${id(itemId)}/permissions`);

export const createFolder = (spaceId: string, parentId: string, name: string) => fileRequest<{ folder: FileItem }>("POST", `/v1/spaces/${id(spaceId)}/folders`, { name, parent_folder_id: parentId }, intentKey());
export const renameItem = (item: FileItem, name: string) => fileRequest<{ item: FileItem }>("PATCH", `/v1/file-items/${id(item.item_id)}`, { name, expected_metadata_version: item.metadata_version }, intentKey());
export const listVersions = (fileId: string, cursor?: string) => request<{ versions: FileVersion[]; next_cursor: string | null }>(`/v1/files/${id(fileId)}/versions${query({ cursor })}`);
export const restoreVersion = (fileId: string, versionId: string, expected: string) => fileRequest<{ file: FileItem; version: FileVersion }>("POST", `/v1/files/${id(fileId)}/versions/${id(versionId)}/restore`, { expected_current_version_id: expected }, intentKey());
export const downloadFile = (fileId: string, versionId?: string) => fileRequest<{ download: Download }>("POST", `/v1/files/${id(fileId)}/download`, versionId ? { version_id: versionId } : {});
export const listGrants = (itemId: string, cursor?: string) => request<{ grants: Grant[]; acl_revision: number; next_cursor: string | null }>(`/v1/file-items/${id(itemId)}/grants${query({ cursor })}`);
export const addGrant = (itemId: string, userId: string, role: "viewer" | "editor", expiry: string | null, revision: number) => fileRequest<{ grant: Grant; acl_revision: number }>("POST", `/v1/file-items/${id(itemId)}/grants`, { grantee_user_id: userId, role, expires_at: expiry, expected_acl_revision: revision }, intentKey());
export const updateGrant = (itemId: string, grantId: string, role: "viewer" | "editor", expiry: string | null, revision: number) => fileRequest<{ grant: Grant; acl_revision: number }>("PATCH", `/v1/file-items/${id(itemId)}/grants/${id(grantId)}`, { role, expires_at: expiry, expected_acl_revision: revision }, intentKey());
export const revokeGrant = (itemId: string, grantId: string, revision: number) => fileRequest<void>("DELETE", `/v1/file-items/${id(itemId)}/grants/${id(grantId)}`, { expected_acl_revision: revision }, intentKey());
export const listAudit = (spaceId: string, cursor?: string) => request<{ events: AuditEvent[]; next_cursor: string | null }>(`/v1/spaces/${id(spaceId)}/file-audit${query({ cursor })}`);

export const prepareMove = (item: FileItem, targetId: string, name?: string) => fileRequest<{ move: ChangePreview }>("POST", `/v1/file-items/${id(item.item_id)}/move/prepare`, { target_parent_folder_id: targetId, expected_metadata_version: item.metadata_version, ...(name ? { name } : {}) }, intentKey());
export const commitMove = (itemId: string, preview: ChangePreview) => fileRequest<{ item: FileItem }>("POST", `/v1/file-items/${id(itemId)}/move/commit`, { preview_id: preview.preview_id, preview_hash: preview.preview_hash, expected_metadata_version: preview.expected_metadata_version, expected_acl_revision: preview.expected_acl_revision }, intentKey());
export const trashItem = (item: FileItem) => fileRequest<{ trash_batch: TrashBatch }>("POST", `/v1/file-items/${id(item.item_id)}/trash`, { expected_metadata_version: item.metadata_version }, intentKey());
export const listTrash = (spaceId: string, cursor?: string) => request<{ trash_batches: TrashBatch[]; next_cursor: string | null }>(`/v1/spaces/${id(spaceId)}/file-trash${query({ cursor })}`);
export const prepareRestore = (batchId: string, targetId?: string, name?: string) => fileRequest<{ restore: ChangePreview }>("POST", `/v1/file-trash/${id(batchId)}/restore/prepare`, { ...(targetId ? { target_parent_folder_id: targetId } : {}), ...(name ? { name } : {}) }, intentKey());
export const commitRestore = (batchId: string, preview: ChangePreview) => fileRequest<{ item: FileItem; trash_batch: TrashBatch }>("POST", `/v1/file-trash/${id(batchId)}/restore`, { preview_id: preview.preview_id, preview_hash: preview.preview_hash, expected_acl_revision: preview.expected_acl_revision }, intentKey());
export const purgeBatch = (batch: TrashBatch) => fileRequest<{ purge: PurgeJob }>("POST", `/v1/file-trash/${id(batch.batch_id)}/purge`, { expected_batch_version: batch.batch_version }, intentKey());
export const getPurge = (purgeId: string) => request<{ purge: PurgeJob }>(`/v1/file-purges/${id(purgeId)}`);

export const createUpload = (spaceId: string, payload: Record<string, unknown>) => fileRequest<{ upload: Upload }>("POST", `/v1/spaces/${id(spaceId)}/file-uploads`, payload, intentKey());
export const signParts = (uploadId: string, parts: number[]) => fileRequest<{ instructions: UploadInstruction[] }>("POST", `/v1/file-uploads/${id(uploadId)}/parts/sign`, { part_numbers: parts });
export const completeUpload = (uploadId: string, parts: { part_number: number; etag: string }[]) => fileRequest<{ upload: Upload }>("POST", `/v1/file-uploads/${id(uploadId)}/complete`, { parts }, intentKey());
export const getUpload = (uploadId: string) => request<{ upload: Upload }>(`/v1/file-uploads/${id(uploadId)}`);
export const cancelUpload = (uploadId: string) => fileRequest<{ upload: Upload }>("POST", `/v1/file-uploads/${id(uploadId)}/cancel`, {}, intentKey());
