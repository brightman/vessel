"""Independent shared file domain; generated frozen PostgreSQL DDL.

Revision ID: 0009_shared_files
Revises: 0008_space_resources
"""

from alembic import op

revision = "0009_shared_files"
down_revision = "0008_space_resources"
branch_labels = None
depends_on = None


def upgrade():
    op.execute(
        "CREATE TABLE drive_items (\n\titem_id VARCHAR(36) NOT NULL, \n\tspace_id VARCHAR(36) NOT NULL, \n\tkind VARCHAR(512) NOT NULL, \n\tparent_id VARCHAR(512), \n\tname VARCHAR(512) NOT NULL, \n\tnormalized_name VARCHAR(512) NOT NULL, \n\tmetadata_version INTEGER NOT NULL, \n\tstatus VARCHAR(16) NOT NULL, \n\ttrash_batch_id VARCHAR(512), \n\tcreated_by_user_id VARCHAR(36) NOT NULL, \n\tupdated_by_user_id VARCHAR(36) NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tupdated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (item_id), \n\tUNIQUE (space_id, item_id), \n\tFOREIGN KEY(space_id, parent_id) REFERENCES drive_items (space_id, item_id), \n\tCHECK (kind IN ('folder','file')), \n\tCHECK (status IN ('active','trashed','purging','purged')), \n\tFOREIGN KEY(space_id) REFERENCES spaces (space_id), \n\tFOREIGN KEY(created_by_user_id) REFERENCES users (user_id), \n\tFOREIGN KEY(updated_by_user_id) REFERENCES users (user_id)\n)"
    )
    op.execute(
        "CREATE UNIQUE INDEX uq_drive_item_root ON drive_items (space_id) WHERE parent_id IS NULL"
    )
    op.execute(
        "CREATE UNIQUE INDEX uq_drive_item_active_name ON drive_items (space_id, parent_id, normalized_name) WHERE status='active' AND parent_id IS NOT NULL"
    )
    op.execute(
        "CREATE INDEX ix_drive_items_parent_status ON drive_items (space_id, parent_id, status)"
    )
    op.execute(
        "CREATE TABLE drive_file_uploads (\n\tupload_id VARCHAR(36) NOT NULL, \n\tspace_id VARCHAR(36) NOT NULL, \n\tactor_user_id VARCHAR(512) NOT NULL, \n\tmode VARCHAR(512) NOT NULL, \n\ttarget_item_id VARCHAR(512), \n\tparent_id VARCHAR(512), \n\tname VARCHAR(512), \n\texpected_current_version_id VARCHAR(512), \n\texpected_metadata_version INTEGER, \n\tsize_bytes BIGINT NOT NULL, \n\tsha256 VARCHAR(512) NOT NULL, \n\tcontent_type VARCHAR(512) NOT NULL, \n\treserved_bytes BIGINT NOT NULL, \n\ttemp_key VARCHAR(512) NOT NULL, \n\tfinal_key VARCHAR(512), \n\tverified_json JSON, \n\tcomplete_parts JSON NOT NULL, \n\tattempts INTEGER NOT NULL, \n\tlease_until TIMESTAMP WITH TIME ZONE, \n\toss_upload_id VARCHAR(512), \n\tstatus VARCHAR(16) NOT NULL, \n\ttransfer_mode VARCHAR(512) NOT NULL, \n\tpart_size_bytes BIGINT NOT NULL, \n\tpart_count INTEGER NOT NULL, \n\texpires_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tversion_id VARCHAR(512), \n\tfailure_code VARCHAR(512), \n\tpublication_id VARCHAR(512) NOT NULL, \n\tverified_bucket VARCHAR(512), \n\tverified_key VARCHAR(512), \n\tverified_version_id VARCHAR(512), \n\tparts JSON NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tupdated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (upload_id), \n\tFOREIGN KEY(space_id) REFERENCES spaces (space_id)\n)"
    )
    op.execute(
        "CREATE INDEX ix_drive_file_uploads_status ON drive_file_uploads (status)"
    )
    op.execute(
        "CREATE TABLE drive_trash_batches (\n\tbatch_id VARCHAR(36) NOT NULL, \n\tspace_id VARCHAR(36) NOT NULL, \n\troot_item_id VARCHAR(512) NOT NULL, \n\toriginal_parent_folder_id VARCHAR(512) NOT NULL, \n\tactor_user_id VARCHAR(512) NOT NULL, \n\tstatus VARCHAR(16) NOT NULL, \n\tbatch_version INTEGER NOT NULL, \n\ttrashed_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tretention_until TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (batch_id), \n\tFOREIGN KEY(space_id) REFERENCES spaces (space_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_quota_usage (\n\tspace_id VARCHAR(36) NOT NULL, \n\tcommitted_bytes BIGINT NOT NULL, \n\treserved_bytes BIGINT NOT NULL, \n\tlimit_bytes BIGINT NOT NULL, \n\tPRIMARY KEY (space_id), \n\tCONSTRAINT ck_drive_quota_nonnegative CHECK (committed_bytes >= 0 AND reserved_bytes >= 0 AND limit_bytes >= 0), \n\tFOREIGN KEY(space_id) REFERENCES spaces (space_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_idempotency_receipts (\n\treceipt_id VARCHAR(36) NOT NULL, \n\tactor_user_id VARCHAR(512) NOT NULL, \n\toperation VARCHAR(512) NOT NULL, \n\ttarget VARCHAR(512) NOT NULL, \n\tkey VARCHAR(128) NOT NULL, \n\trequest_hash VARCHAR(512) NOT NULL, \n\tstatus VARCHAR(512) NOT NULL, \n\tresponse JSON, \n\tstatus_code INTEGER, \n\texpires_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (receipt_id), \n\tUNIQUE (actor_user_id, operation, target, key)\n)"
    )
    op.execute(
        "CREATE TABLE drive_audit_events (\n\tevent_id VARCHAR(36) NOT NULL, \n\tspace_id VARCHAR(512) NOT NULL, \n\titem_id VARCHAR(512), \n\tactor_user_id VARCHAR(512) NOT NULL, \n\toperation VARCHAR(512) NOT NULL, \n\tresult VARCHAR(16) NOT NULL, \n\tbefore_version INTEGER, \n\tafter_version INTEGER, \n\trequest_id VARCHAR(512), \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (event_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_outbox (\n\toutbox_id VARCHAR(36) NOT NULL, \n\tbusiness_key VARCHAR(512) NOT NULL, \n\tkind VARCHAR(512) NOT NULL, \n\tpayload JSON NOT NULL, \n\tstatus VARCHAR(16) NOT NULL, \n\tattempts INTEGER NOT NULL, \n\tlease_until TIMESTAMP WITH TIME ZONE, \n\tavailable_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tfailure_code VARCHAR(512), \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tupdated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (outbox_id), \n\tUNIQUE (business_key)\n)"
    )
    op.execute("CREATE INDEX ix_drive_outbox_status ON drive_outbox (status)")
    op.execute(
        "CREATE TABLE drive_purge_jobs (\n\tpurge_id VARCHAR(36) NOT NULL, \n\tspace_id VARCHAR(512) NOT NULL, \n\tbatch_id VARCHAR(512) NOT NULL, \n\tstatus VARCHAR(16) NOT NULL, \n\tfailure_code VARCHAR(512), \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tupdated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tPRIMARY KEY (purge_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_operation_previews (\n\tpreview_id VARCHAR(36) NOT NULL, \n\tactor_user_id VARCHAR(512) NOT NULL, \n\tspace_id VARCHAR(512) NOT NULL, \n\tkind VARCHAR(512) NOT NULL, \n\titem_id VARCHAR(512) NOT NULL, \n\tbatch_id VARCHAR(512), \n\tpreview_hash VARCHAR(512) NOT NULL, \n\tpayload JSON NOT NULL, \n\texpires_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tconsumed_at TIMESTAMP WITH TIME ZONE, \n\tPRIMARY KEY (preview_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_space_state (\n\tspace_id VARCHAR(36) NOT NULL, \n\troot_item_id VARCHAR(36) NOT NULL, \n\tacl_revision INTEGER NOT NULL, \n\tPRIMARY KEY (space_id), \n\tFOREIGN KEY(space_id) REFERENCES spaces (space_id), \n\tUNIQUE (root_item_id), \n\tFOREIGN KEY(root_item_id) REFERENCES drive_items (item_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_files (\n\titem_id VARCHAR(36) NOT NULL, \n\tcurrent_version_id VARCHAR(512), \n\tPRIMARY KEY (item_id), \n\tFOREIGN KEY(item_id) REFERENCES drive_items (item_id)\n)"
    )
    op.execute(
        "CREATE TABLE drive_grants (\n\tgrant_id VARCHAR(36) NOT NULL, \n\titem_id VARCHAR(36) NOT NULL, \n\tuser_id VARCHAR(36) NOT NULL, \n\trole VARCHAR(512) NOT NULL, \n\texpires_at TIMESTAMP WITH TIME ZONE, \n\tcreated_by_user_id VARCHAR(512) NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\trevoked_at TIMESTAMP WITH TIME ZONE, \n\tversion INTEGER NOT NULL, \n\tPRIMARY KEY (grant_id), \n\tCHECK (role IN ('viewer','editor')), \n\tFOREIGN KEY(item_id) REFERENCES drive_items (item_id), \n\tFOREIGN KEY(user_id) REFERENCES users (user_id)\n)"
    )
    op.execute(
        "CREATE UNIQUE INDEX uq_drive_grants_live ON drive_grants (item_id, user_id) WHERE revoked_at IS NULL"
    )
    op.execute(
        "CREATE INDEX ix_drive_grants_user ON drive_grants (user_id, revoked_at, item_id)"
    )
    op.execute(
        "CREATE TABLE drive_file_versions (\n\tversion_id VARCHAR(36) NOT NULL, \n\titem_id VARCHAR(36) NOT NULL, \n\tordinal INTEGER NOT NULL, \n\tbucket VARCHAR(512) NOT NULL, \n\tobject_key VARCHAR(512) NOT NULL, \n\toss_version_id VARCHAR(512) NOT NULL, \n\tsize_bytes BIGINT NOT NULL, \n\tsha256 VARCHAR(512) NOT NULL, \n\tcrc64 VARCHAR(512), \n\tcontent_type VARCHAR(512) NOT NULL, \n\tcreated_by_user_id VARCHAR(512) NOT NULL, \n\tcreated_at TIMESTAMP WITH TIME ZONE NOT NULL, \n\tsource VARCHAR(16) NOT NULL, \n\trestored_from_version_id VARCHAR(512), \n\tPRIMARY KEY (version_id), \n\tUNIQUE (item_id, ordinal), \n\tUNIQUE (item_id, version_id), \n\tFOREIGN KEY(item_id) REFERENCES drive_files (item_id)\n)"
    )
    op.execute(
        "ALTER TABLE drive_files ADD CONSTRAINT fk_drive_current_version FOREIGN KEY(item_id, current_version_id) REFERENCES drive_file_versions (item_id, version_id) DEFERRABLE INITIALLY DEFERRED"
    )


def downgrade():
    raise RuntimeError(
        "Shared files downgrade destroys metadata; restore a database backup instead"
    )
