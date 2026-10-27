# HealthKit workout records

## Behavior

Read-only HealthKit authorization now includes workouts and active energy.
The Apple Health source sheet offers “管理健康读取授权” for existing installations.
The app never writes workouts. Read permission status is not inferred from empty results.

Health refresh reads workouts beginning in the selected natural day, and observes
workout changes using the existing foreground/background refresh lifecycle.
A whole cross-midnight workout belongs to its start date. Completed records only.
Fields: native UUID, type, start/end, workout duration excluding pauses, available
distance and active energy, source name, user-entered flag. Missing metrics stay nil.
Common workout types receive Chinese names; unrecognized types retain the raw type code.

Workout UUIDs deduplicate repeated results. Different source UUIDs are preserved,
not heuristically merged; UI and AI evidence warn against adding duplicate sources.
Successful snapshot replacement removes deleted workouts. Refresh failures retain
stale snapshots, as with steps and sleep. Deleting a WiseLife fragment does not
delete HealthKit data.

Timeline and detail display workouts; step totals and midnight archives exclude them.
Ask AI and recap use existing activity/health permission and external-send consent.
Workout duration is not exercise-ring time and is never counted as recording duration.
Manual entries retain their lower-authority provenance.

## Verification

- test_life_moments.sh passed: UUID deduplication, pause-aware duration, midnight
  ownership, unfinished exclusion, missing metrics, manual provenance, Codable and
  SQLite roundtrip, workout-only readiness, deletion refresh, step archive isolation.
- test_daily_recaps.sh passed.
- Final iOS Simulator workspace Debug build passed.
- git diff --check passed.
- test_conversations.sh passed, including workout retrieval and health-permission exclusion.

## Device acceptance

No real HealthKit workout data was accessed in this task. On iPhone, open the Apple
Health source, tap 管理健康读取授权, allow workouts and active energy, then refresh
a date with a recorded workout. Check Watch sync delay, optional metrics, manual
entries, source deletion and denied permission on device. Background delivery is
system scheduled, not guaranteed immediately.
