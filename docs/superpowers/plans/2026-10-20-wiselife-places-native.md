# WiseLife capture places and devices

Approved prototype: `apps/wrist-notes/prototype/places-design.md`. Scope: native iPhone and Watch, no Ring SDK enablement.

1. Add optional, validated capture metadata with backward compatible decoding. Persist audio metadata in the existing SQLite payload; add photo metadata columns with a versioned SQLite migration. Keep capture time separate from import time.
2. Capture a bounded location sample asynchronously when recording starts. Settings default off, synchronize the preference to Watch using application context; each device respects OS permission. Stop/cancel/pause invalidates outstanding acquisition. Audio never waits for GPS. Preserve metadata through drafts, Watch pending files, transfer, inbox, and retries.
3. Extract original photo EXIF/GPS/device before recompression. Use selected PHAsset metadata only with existing authorization. Camera samples are time checked against shutter metadata; missing original metadata never becomes the importing phone's location/device.
4. Project locations separately for AI permission filtering. Add daily location markers/list/details, capture device rows, and photo capture/import times. Omit missing location rows. Preserve legacy save-time snapshots with their original descriptions.
5. Verify invalid GPS, old data decoding, actual SQLite reopen/migration/delete, transfer payload and pause/cancel boundaries; build both native targets. Record hardware verification limits.

Privacy: no continuous tracking or address lookup/network geocoding. Coordinates, provenance, and accuracy remain local. Existing AI location permission governs separate location evidence; metadata is not appended to audio/photo transcript text.

Shared dirty checkout: baseline snapshot in `/private/tmp/wiselife-places-native-*`; scoped edits only, no commit/release.
