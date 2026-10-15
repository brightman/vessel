# Shared Files Implementation Plan

**Goal:** Implement docs/api-contract-files.md and docs/shared-files-design.md using Aliyun OSS only.
**Architecture:** Dedicated files models/services/router and storage adapter. Current spaces/accounts remain authoritative. Spaces row locks serialize ACL, hierarchy and mutations. Persistent uploads/jobs make remote operations recoverable.
**Tech Stack:** FastAPI, SQLAlchemy, Alembic, PostgreSQL, Aliyun OSS Python SDK.

## Global constraints

- Preserve Page/Apps work and existing var/ data. Work in existing feature branch codex/pages-api-base; no reset or automatic commit of unrelated files.
- Paths and success/error formats follow docs/api-contract-files.md. No raw OSS keys exposed except signed URLs.
- Personal ACL viewer/editor additive with folder inheritance. Team shared by current role. Folder depth 32; normalized name unique. File limit 512 MiB; quota 10 GiB; trash retention 30 days.
- Test database authority/security with real service behavior; only storage network boundary uses test fake. Live OSS requires user's existing config, never ask for plaintext secrets.

### Task 1: File metadata, access and shared hierarchy
- [x] Write tests/test_files_metadata.py for private root, nested sharing and revocation, team role denial, cross-space parents, rename conflicts, move cycles, trash batches/restore.
- [x] Run tests to observe missing files feature failures.
- [x] Create files/models.py, files/permissions.py, files/metadata.py and files/schemas.py supporting root, listing/search, grants, move/restore previews, trash and audit.
- [x] Run metadata tests; report interfaces, tests and remaining gaps.

### Task 2: OSS boundary
- [x] Write tests/test_files_storage.py exercising generated requests via external-boundary test doubles: signed overwrite header, exact version download/delete, SHA256 verification, multipart control and configuration.
- [x] Observe missing adapter failures.
- [x] Create files/storage.py with FilesSettings, OSSStorage, methods start_upload, sign_parts, verify, publish, sign_download, cleanup_upload, delete_version. Lazy SDK configuration so metadata works without OSS.
- [x] Run covering tests. Credentials remain server-side; no local production file storage alternative.

### Task 3: HTTP integration and persistent upload lifecycle
- [x] Write tests/test_files_api.py for quota, upload lifecycle, duplicate complete, checksum failure, concurrent-version conflict, async revocation, downloads, versions, purge retry, idempotency and pagination.
- [x] Observe failures before implementing files/router.py, files/uploads.py, files/jobs.py and file-specific API wiring.
- [x] Add migration 0009 after 0008, model registration, file settings/router wiring and external storage injection.
- [x] Add background worker runner and persistent publication/purge jobs; recheck current authorization on publication.
- [x] Run metadata/storage/API tests and <=100 affected core tests; isolated PostgreSQL real HTTP E2E for folders/sharing, concurrent moves, versions and uploads using real OSS.
- [x] Run live OSS E2E only when valid configured dedicated test buckets or an approved existing Bucket with an isolated prefix are available. Report untested live paths explicitly.

### Task 4: Review and delivery
- [x] Independent code/security review against the contracts, fix blockers and recheck.
- [x] Update README and file implementation status with exact evidence and operational commands.
- [x] Preserve all unrelated edits, deliver inspectable files and verification results without deployment.

## Execution record

2026-10-15: 95 affected tests passed. Real PostgreSQL migration to 0009 and HTTP/OSS E2E run 8fc9348a passed including 17 MiB multipart, concurrent crossing moves, SHA256, version restore, revocation, trash/restore and purge. Recursive PostgreSQL sharing/search pagination separately passed. No production deployment or unrelated reset. Known limits recorded in docs/files-runtime.md.
