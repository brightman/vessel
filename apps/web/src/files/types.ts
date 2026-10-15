export type FileItem = {
  item_id: string; space_id: string; kind: "file" | "folder"; folder_id?: string;
  parent_folder_id: string | null; name: string; metadata_version: number; status: string;
  created_by_user_id: string; updated_by_user_id: string; created_at: string; updated_at: string;
  current_version_id?: string | null; size_bytes?: number | null; sha256?: string | null; content_type?: string | null;
};

export type FilePermissions = {
  item_id: string; can_read: boolean; can_write: boolean; can_create_children: boolean;
  can_move: boolean; can_trash: boolean; can_restore: boolean; can_manage_sharing: boolean;
  can_purge: boolean; permission_sources: Array<{ type: string; role: string; source_item_id: string; grant_id?: string }>;
};

export type FileVersion = {
  version_id: string; file_id: string; ordinal: number; size_bytes: number; sha256: string;
  crc64: string | null; content_type: string; created_by_user_id: string; created_at: string;
  source: "upload" | "restore"; restored_from_version_id: string | null;
};
export type Grant = {
  grant_id: string; item_id: string; grantee_user_id: string; role: "viewer" | "editor";
  expires_at: string | null; created_by_user_id: string; created_at: string;
  inherited: boolean; source_item_id: string;
};
export type Download = {
  file_id: string; version_id: string; name: string; size_bytes: number; sha256: string;
  content_type: string; url: string; expires_at: string;
};
export type ChangePreview = {
  preview_id: string; preview_hash: string; item_id: string; target_parent_folder_id: string;
  name: string; expected_metadata_version: number; expected_acl_revision: number;
  target_metadata_version: number; batch_version: number | null;
  permission_changes: { lost: Grant[]; gained: Grant[] }; expires_at: string;
};
export type TrashBatch = {
  batch_id: string; space_id: string; root_item_id: string; original_parent_folder_id: string;
  status: "trashed" | "restored" | "purging" | "purged"; batch_version: number;
  trashed_at: string; retention_until: string;
};
export type PurgeJob = {
  purge_id: string; space_id: string; batch_id: string;
  status: "pending" | "running" | "succeeded" | "failed"; failure_code: string | null;
  created_at: string; updated_at: string; status_url: string;
};
export type AuditEvent = {
  event_id: string; space_id: string; item_id: string | null; actor_user_id: string;
  operation: string; result: string; before_version: number | null; after_version: number | null;
  request_id: string | null; created_at: string;
};
export type Upload = {
  upload_id: string; space_id: string; mode: "create" | "new_version"; file_id: string | null;
  status: string; size_bytes: number; sha256: string; content_type: string;
  transfer_mode: "single" | "multipart"; part_size_bytes: number; part_count: number;
  expires_at: string; version_id: string | null; failure_code: string | null; status_url: string;
};
export type UploadInstruction = {
  part_number: number; method: "PUT"; url: string; headers: Record<string, string>;
  expires_at: string; size_bytes: number;
};
