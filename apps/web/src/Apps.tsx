import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, bulkDeleteRecords, createApp, createAppDraft, createRecord, getApp, launchAppRelease, listAppAudit, listAppReleases, listApps, publishAppRelease, queryRecords, rollbackAppRelease, saveAppSettings, setAppArchived, updateManifest, updateRecord, uploadAppRelease, type AppRecord, type AppRelease, type AuditEvent, type FieldDefinition, type Manifest, type Permissions, type RecordFilter, type RecordQuery, type Space, type VesselApp } from "./api";
import { message } from "./App";
import { asInput, parseValue } from "./record-values";

type Props = { space: Space; permissions: Permissions; onError: (value: string) => void };
type FieldDraft = { name: string; type: FieldDefinition["type"]; nullable: boolean };
const fieldTypes: FieldDefinition["type"][] = ["text", "integer", "numeric", "boolean", "timestamp", "uuid", "json"];

function ValueInput({ label, value, definition, disabled, onChange }: { label: string; value: string; definition: FieldDefinition; disabled: boolean; onChange: (value: string) => void }) {
  const props = { "aria-label": label, value, disabled, onChange: (event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => onChange(event.target.value) };
  if (definition.type === "boolean") return <select {...props}>{definition.nullable && <option value="">Empty</option>}<option value="true">Yes</option><option value="false">No</option></select>;
  if (definition.type === "json") return <textarea {...props} required={!definition.nullable} />;
  return <input {...props} type="text" required={!definition.nullable} placeholder={definition.type === "timestamp" ? "2026-10-15T12:00:00Z" : undefined} />;
}

export function Apps({ space, permissions, onError }: Props) {
  const manager = ["owner", "admin"].includes(permissions.role);
  const [apps, setApps] = useState<VesselApp[]>([]);
  const [status, setStatus] = useState<"active" | "archived">("active");
  const [activeId, setActiveId] = useState("");
  const [tab, setTab] = useState<"Settings" | "Data" | "Publish">("Data");
  const [tableName, setTableName] = useState("");
  const [records, setRecords] = useState<AppRecord[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [cursor, setCursor] = useState<string>();
  const [cursorStack, setCursorStack] = useState<Array<string | undefined>>([]);
  const [query, setQuery] = useState<RecordQuery>({ limit: 50 });
  const [search, setSearch] = useState("");
  const [filterField, setFilterField] = useState("");
  const [filterOp, setFilterOp] = useState<RecordFilter["op"]>("eq");
  const [filterValue, setFilterValue] = useState("");
  const [sortField, setSortField] = useState("");
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("asc");
  const [selected, setSelected] = useState<string[]>([]);
  const [inline, setInline] = useState<Record<string, Record<string, string>>>({});
  const [recordModal, setRecordModal] = useState(false);
  const [newAppName, setNewAppName] = useState("");
  const [newTableName, setNewTableName] = useState("");
  const [fieldDrafts, setFieldDrafts] = useState<FieldDraft[]>([{ name: "", type: "text", nullable: false }]);
  const [advancedCreate, setAdvancedCreate] = useState(false);
  const [newManifestText, setNewManifestText] = useState('{"tables":{"items":{"fields":{"name":{"type":"text","nullable":false}}}}}');
  const [manifestText, setManifestText] = useState("");
  const [showManifest, setShowManifest] = useState(false);
  const [settingsName, setSettingsName] = useState("");
  const [description, setDescription] = useState("");
  const [addTableName, setAddTableName] = useState("");
  const [addFieldName, setAddFieldName] = useState("");
  const [addFieldType, setAddFieldType] = useState<FieldDefinition["type"]>("text");
  const [formValues, setFormValues] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<AppRecord | null>(null);
  const [busy, setBusy] = useState(false);
  const [recordConflict, setRecordConflict] = useState(false);
  const [manifestConflict, setManifestConflict] = useState(false);
  const [settingsConflict, setSettingsConflict] = useState(false);
  const [releases, setReleases] = useState<AppRelease[]>([]);
  const [draftId, setDraftId] = useState("");
  const [zip, setZip] = useState<File | null>(null);
  const [preview, setPreview] = useState("");
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [auditCursor, setAuditCursor] = useState<string | null>(null);
  const active = apps.find(item => item.app_id === activeId) ?? null;
  const archived = active?.status === "archived";
  const canManage = manager && !archived;
  const canWrite = permissions.can_write && !archived;
  const fields = active?.manifest.tables[tableName]?.fields ?? {};
  const draft = releases.find(item => item.release_id === draftId);

  const resetPage = () => { setCursor(undefined); setCursorStack([]); setSelected([]); };
  const replaceApp = (app: VesselApp) => setApps(items => items.map(item => item.app_id === app.app_id ? app : item));
  const fail = (problem: unknown) => {
    if (problem instanceof ApiError) {
      if (problem.code === "APP_RECORD_VERSION_CONFLICT") setRecordConflict(true);
      if (problem.code === "APP_MANIFEST_VERSION_CONFLICT") setManifestConflict(true);
      if (problem.code === "APP_SETTINGS_VERSION_CONFLICT") setSettingsConflict(true);
    }
    onError(message(problem));
  };
  async function run(action: () => Promise<void>) { setBusy(true); try { await action(); } catch (problem) { fail(problem); } finally { setBusy(false); } }
  const reloadApps = useCallback(async (preferred?: string, requestedStatus = status) => {
    const result = await listApps(space.space_id, requestedStatus);
    setApps(result.apps);
    setActiveId(current => result.apps.find(item => item.app_id === (preferred ?? current))?.app_id ?? result.apps[0]?.app_id ?? "");
  }, [space.space_id, status]);
  useEffect(() => { void reloadApps().catch(problem => onError(message(problem))); }, [reloadApps, onError]);
  useEffect(() => {
    setRecords([]); setReleases([]); setEvents([]); setAuditCursor(null); setDraftId(""); setPreview(""); setZip(null);
    setTableName(active ? Object.keys(active.manifest.tables)[0] ?? "" : "");
    setQuery({ limit: 50 }); setSearch(""); setFilterField(""); setSortField(""); resetPage();
    setRecordModal(false); setEditing(null); setFormValues({}); setInline({}); setRecordConflict(false);
  }, [active?.app_id, active?.status]);
  useEffect(() => {
    if (!active) return;
    setManifestText(JSON.stringify(active.manifest, null, 2)); setManifestConflict(false);
    setTableName(current => Object.hasOwn(active.manifest.tables, current) ? current : Object.keys(active.manifest.tables)[0] ?? "");
  }, [active?.app_id, active?.manifest_version]);
  useEffect(() => { setSettingsName(active?.name ?? ""); setDescription(active?.description ?? ""); setSettingsConflict(false); }, [active?.app_id, active?.settings_version]);
  useEffect(() => {
    if (!active || !tableName || archived || tab !== "Data") return;
    let live = true;
    void queryRecords(active.app_id, tableName, { ...query, cursor }).then(result => {
      if (live) { setRecords(result.records); setNextCursor(result.next_cursor); setInline({}); setSelected([]); }
    }).catch(problem => { if (live) onError(message(problem)); });
    return () => { live = false; };
  }, [active?.app_id, tableName, cursor, query, archived, tab, onError]);
  useEffect(() => {
    if (!active) return;
    let live = true;
    if (tab === "Publish" && !archived) void listAppReleases(active.app_id).then(result => { if (live) setReleases(result.releases); }).catch(problem => { if (live) onError(message(problem)); });
    if (tab === "Settings" && manager) void listAppAudit(active.app_id).then(result => { if (live) { setEvents(result.events); setAuditCursor(result.next_cursor); } }).catch(problem => { if (live) onError(message(problem)); });
    return () => { live = false; };
  }, [active?.app_id, active?.settings_version, active?.manifest_version, tab, archived, manager, onError]);

  async function reloadRecords() {
    if (!active || !tableName) return;
    const result = await queryRecords(active.app_id, tableName, { ...query, cursor });
    setRecords(result.records); setNextCursor(result.next_cursor); setSelected([]); setInline({});
  }
  async function reloadReleases() { if (active) setReleases((await listAppReleases(active.app_id)).releases); }
  async function reloadApp() { if (active) replaceApp((await getApp(active.app_id)).app); }
  async function openRelease(release: AppRelease) {
    if (!active) return;
    const result = await launchAppRelease(active.app_id, release.release_id);
    window.location.assign(result.launch_url);
  }
  const valuesFor = (raw: Record<string, string>) => Object.fromEntries(Object.entries(fields).map(([name, definition]) => [name, parseValue(raw[name] ?? (definition.type === "boolean" && !definition.nullable ? "false" : ""), definition)]));
  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!manager) return;
    await run(async () => {
      const manifest = advancedCreate ? JSON.parse(newManifestText) as Manifest : { tables: { [newTableName.trim()]: { fields: Object.fromEntries(fieldDrafts.map(item => [item.name.trim(), { type: item.type, nullable: item.nullable }])) } } } satisfies Manifest;
      const result = await createApp(space.space_id, newAppName, manifest);
      setNewAppName(""); setNewTableName(""); setFieldDrafts([{ name: "", type: "text", nullable: false }]); await reloadApps(result.app.app_id); setTab("Data");
    });
  }
  async function saveManifest(manifest: Manifest) {
    if (!active || !canManage) return;
    replaceApp((await updateManifest(active, manifest)).app); setManifestConflict(false); setShowManifest(false);
  }
  async function submitRecord(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!active || !canWrite || recordConflict) return;
    await run(async () => {
      if (editing) await updateRecord(active.app_id, tableName, editing, valuesFor(formValues));
      else await createRecord(active.app_id, tableName, valuesFor(formValues));
      setEditing(null); setRecordModal(false); setFormValues({}); await reloadRecords();
    });
  }
  function applyQuery(event: FormEvent) {
    event.preventDefault();
    try {
      let filter: RecordFilter | undefined;
      if (filterField) {
        if (filterOp === "is_null" && !["true", "false"].includes(filterValue)) throw new Error("Use true or false for the empty-value filter.");
        const definition = fields[filterField];
        const value = filterOp === "is_null" ? filterValue !== "false" : filterOp === "in" ? (() => { const list = JSON.parse(filterValue) as unknown; if (!Array.isArray(list) || list.length > 50) throw new Error("Enter a JSON array of at most 50 values. Use strings for numeric values."); if (definition.type === "numeric" && list.some(item => item !== null && typeof item !== "string")) throw new Error("Use quoted decimal strings in numeric filters to preserve precision."); return list.map(item => parseValue(asInput(item, definition), definition)); })() : parseValue(filterValue, definition);
        filter = { field: filterField, op: filterOp, value };
      }
      setQuery({ limit: 50, ...(search ? { search } : {}), ...(filter ? { filter } : {}), sort: sortField ? [{ field: sortField, direction: sortDirection }] : [] }); resetPage();
    } catch (problem) { fail(problem); }
  }

  return <div className="apps-layout"><aside className="resource-rail"><div className="rail-title"><span className="eyebrow">{space.kind === "team" ? "TEAM SPACE" : "PERSONAL SPACE"}</span><h2>Apps</h2></div>{manager && <label>App status<select aria-label="App status" value={status} disabled={busy} onChange={event => { setApps([]); setActiveId(""); setStatus(event.target.value as typeof status); if (event.target.value === "archived") setTab("Settings"); }}><option value="active">Active</option><option value="archived">Archived</option></select></label>}<div className="resource-list"><h3>DATA APPS</h3>{apps.map(item => <button key={item.app_id} disabled={busy} className={item.app_id === activeId ? "selected" : ""} onClick={() => setActiveId(item.app_id)}>{item.name}</button>)}</div></aside>
    <section className="app-main"><header className="section-header"><div><span className="eyebrow">STRUCTURED DATA</span><h2>{active?.name ?? "Create your first App"}</h2><p>{active ? `${Object.keys(active.manifest.tables).length} tables · Manifest v${active.manifest_version} · ${active.status}` : "Create structured data for a personal or team space."}</p></div></header>
      {active && <><nav className="tab-row app-workspace-tabs" aria-label="App workspace">{(["Settings", "Data", "Publish"] as const).map(name => <button key={name} disabled={busy || (!!archived && name !== "Settings")} className={tab === name ? "active" : ""} onClick={() => setTab(name)}>{name}</button>)}</nav>
      {tab === "Settings" && <>
        <section className="card"><h3>App settings</h3><form className="stacked-form" onSubmit={event => { event.preventDefault(); if (canManage && !settingsConflict) void run(async () => replaceApp((await saveAppSettings(active, settingsName, description)).app)); }}><label>App display name<input aria-label="App display name" value={settingsName} maxLength={120} required disabled={!canManage || busy} onChange={event => setSettingsName(event.target.value)} /></label><label>App description<textarea value={description} maxLength={2000} disabled={!canManage || busy} onChange={event => setDescription(event.target.value)} /></label><button className="primary" disabled={!canManage || busy || settingsConflict}>Save app settings</button></form>{settingsConflict && <button className="secondary" disabled={busy} onClick={() => void run(reloadApp)}>Discard changes and reload settings</button>}<button className="secondary" disabled={!manager || busy || settingsConflict} onClick={() => { if (window.confirm(archived ? "Restore this App?" : "Archive this App? Members will lose access until it is restored.")) void run(async () => { const result = await setAppArchived(active, !archived); if (archived) { setStatus("active"); setTab("Data"); await reloadApps(result.app.app_id, "active"); } else { setTab("Settings"); await reloadApps(); } }); }}>{archived ? "Restore App" : "Archive App"}</button></section>
        <section className="card"><h3>Schema</h3><p className="hint">Add tables or nullable fields. Existing fields cannot be changed or removed.</p><form className="inline-form" onSubmit={event => { event.preventDefault(); void run(async () => { if (Object.hasOwn(active.manifest.tables, addTableName)) throw new Error("This table already exists."); await saveManifest({ tables: { ...active.manifest.tables, [addTableName]: { fields: { name: { type: "text", nullable: true } } } } }); setAddTableName(""); }); }}><label>New table name<input value={addTableName} required pattern="[a-z][a-z0-9_]*" disabled={!canManage || busy} onChange={event => setAddTableName(event.target.value)} /></label><button className="secondary" disabled={!canManage || busy || manifestConflict}>Add table</button></form><p className="hint">New tables start with an optional text field named name.</p><form className="inline-form" onSubmit={event => { event.preventDefault(); void run(async () => { if (Object.hasOwn(fields, addFieldName)) throw new Error("This field already exists."); await saveManifest({ tables: { ...active.manifest.tables, [tableName]: { fields: { ...fields, [addFieldName]: { type: addFieldType, nullable: true } } } } }); setAddFieldName(""); }); }}><label>Schema table<select value={tableName} disabled={!canManage || busy} onChange={event => setTableName(event.target.value)}>{Object.keys(active.manifest.tables).map(name => <option key={name}>{name}</option>)}</select></label><label>New nullable field name<input value={addFieldName} required pattern="[a-z][a-z0-9_]*" disabled={!canManage || busy} onChange={event => setAddFieldName(event.target.value)} /></label><label>New field type<select value={addFieldType} disabled={!canManage || busy} onChange={event => setAddFieldType(event.target.value as FieldDefinition["type"])}>{fieldTypes.map(type => <option key={type}>{type}</option>)}</select></label><button className="secondary" disabled={!canManage || busy || manifestConflict}>Add nullable field</button></form><button className="text-button" onClick={() => setShowManifest(value => !value)}>{showManifest ? "Hide" : "View / edit Manifest"}</button>{showManifest && <div className="manifest-editor"><textarea aria-label="Manifest JSON" value={manifestText} disabled={!canManage || busy} onChange={event => setManifestText(event.target.value)} rows={12} spellCheck={false} /><button className="primary" disabled={!canManage || busy || manifestConflict} onClick={() => void run(async () => saveManifest(JSON.parse(manifestText) as Manifest))}>Save Manifest</button></div>}{manifestConflict && <button className="secondary" disabled={busy} onClick={() => void run(async () => { await reloadApp(); setShowManifest(false); })}>Discard changes and reload Manifest</button>}</section>
        {manager && <section className="card"><h3>Audit history</h3>{events.map(event => <div className="list-line" key={event.event_id}><span>{event.action}</span><small>{event.created_at} · {event.actor_user_id}</small></div>)}{!events.length && <p className="hint">No audit events yet.</p>}<button className="secondary" disabled={!auditCursor || busy} onClick={() => void run(async () => { const result = await listAppAudit(active.app_id, auditCursor ?? undefined); setEvents(items => [...items, ...result.events]); setAuditCursor(result.next_cursor); })}>More audit events</button></section>}
      </>}
      {tab === "Data" && !archived && <>
        <section className="card"><div className="tab-row">{Object.keys(active.manifest.tables).map(name => <button key={name} disabled={busy} className={tableName === name ? "active" : ""} onClick={() => { setRecords([]); setTableName(name); setQuery({ limit: 50 }); setSearch(""); setFilterField(""); setSortField(""); setRecordConflict(false); resetPage(); }}>{name}</button>)}</div><form className="app-query" onSubmit={applyQuery}><label>Search records<input maxLength={120} value={search} onChange={event => setSearch(event.target.value)} /></label><label>Filter field<select aria-label="Filter field" value={filterField} onChange={event => setFilterField(event.target.value)}><option value="">No filter</option>{Object.entries(fields).filter(([, field]) => field.type !== "json").map(([name]) => <option key={name}>{name}</option>)}</select></label><label>Filter operator<select value={filterOp} onChange={event => setFilterOp(event.target.value as typeof filterOp)}>{["eq", "ne", "lt", "lte", "gt", "gte", "in", "is_null"].map(op => <option key={op}>{op}</option>)}</select></label><label>Filter value<input value={filterValue} onChange={event => setFilterValue(event.target.value)} placeholder={filterOp === "in" ? 'JSON array, e.g. ["A","B"]' : filterOp === "is_null" ? "true or false" : undefined} /></label><label>Sort field<select aria-label="Sort field" value={sortField} onChange={event => setSortField(event.target.value)}><option value="">Created order</option>{Object.entries(fields).filter(([, field]) => field.type !== "json").map(([name]) => <option key={name}>{name}</option>)}</select></label><label>Sort direction<select value={sortDirection} onChange={event => setSortDirection(event.target.value as typeof sortDirection)}><option value="asc">Ascending</option><option value="desc">Descending</option></select></label><button className="secondary" disabled={busy}>Apply query</button></form></section>
        <section className="card"><div className="card-heading"><h3>{tableName} records</h3><button className="primary" disabled={!canWrite || busy} onClick={() => { setRecordModal(true); setEditing(null); setFormValues({}); }}>New record</button></div><div className="table-scroll"><table><thead><tr><th>Select</th>{Object.keys(fields).map(name => <th key={name}>{name}<small> · {fields[name].type}</small></th>)}<th>Version</th><th>Actions</th></tr></thead><tbody>{records.map(record => <tr key={record.id}><td><input type="checkbox" aria-label={`Select record ${record.id}`} disabled={!canWrite || busy || recordConflict} checked={selected.includes(record.id)} onChange={event => setSelected(items => event.target.checked ? [...items, record.id] : items.filter(id => id !== record.id))} /></td>{Object.entries(fields).map(([name, definition]) => <td key={name}><span className="record-cell-value">{asInput(record.values[name], definition) || "—"}</span><ValueInput label={`Edit ${name} for record ${record.id}`} definition={definition} value={inline[record.id]?.[name] ?? asInput(record.values[name], definition)} disabled={!canWrite || busy || recordConflict} onChange={value => setInline(items => ({ ...items, [record.id]: { ...Object.fromEntries(Object.entries(fields).map(([field, def]) => [field, asInput(record.values[field], def)])), ...items[record.id], [name]: value } }))} /></td>)}<td>{record.row_version}</td><td><button className="text-button" aria-label={`Save record ${record.id}`} disabled={!canWrite || busy || recordConflict || !inline[record.id]} onClick={() => void run(async () => { await updateRecord(active.app_id, tableName, record, valuesFor(inline[record.id])); await reloadRecords(); })}>Save</button><button className="text-button" disabled={!canWrite || busy || recordConflict} onClick={() => { setEditing(record); setFormValues(Object.fromEntries(Object.entries(fields).map(([name, definition]) => [name, asInput(record.values[name], definition)]))); setRecordModal(true); }}>Edit</button></td></tr>)}</tbody></table>{!records.length && <p className="hint">No records found.</p>}</div><div className="pager"><button className="secondary" disabled={!cursorStack.length || busy} onClick={() => { setCursor(cursorStack.at(-1)); setCursorStack(items => items.slice(0, -1)); }}>Previous</button><button className="secondary" disabled={!nextCursor || busy} onClick={() => { setCursorStack(items => [...items, cursor]); setCursor(nextCursor ?? undefined); }}>Next</button><button className="secondary" disabled={!canWrite || !selected.length || busy || recordConflict} onClick={() => { if (window.confirm(`Delete ${selected.length} selected records? This cannot be undone from the console.`)) void run(async () => { await bulkDeleteRecords(active.app_id, tableName, records.filter(record => selected.includes(record.id))); await reloadRecords(); }); }}>Delete selected records</button></div>{recordConflict && !recordModal && <button className="secondary" disabled={busy} onClick={() => void run(async () => { await reloadRecords(); setRecordConflict(false); setRecordModal(false); setEditing(null); setFormValues({}); })}>Discard edits and reload record</button>}</section>
      </>}
      {tab === "Publish" && !archived && <><section className="card"><h3>H5 publishing</h3><p className="hint">Upload and preview a static ZIP, then publish explicitly. Drafts are bound to their Manifest version.</p><button className="secondary" disabled={!canManage || busy} onClick={() => void run(async () => { const result = await createAppDraft(active.app_id); await reloadReleases(); setDraftId(result.release.release_id); setPreview(""); setZip(null); })}>Create draft</button><form className="stacked-form" onSubmit={event => { event.preventDefault(); if (canManage && draft && zip) void run(async () => { setPreview(""); const result = await uploadAppRelease(active.app_id, draft.release_id, zip); await reloadReleases(); setPreview(result.preview_url ?? ""); }); }}><label>Draft<select aria-label="Draft" value={draftId} disabled={!canManage || busy} onChange={event => { setDraftId(event.target.value); setPreview(""); setZip(null); }}><option value="">Select a draft</option>{releases.filter(item => item.status !== "published").map(item => <option key={item.release_id} value={item.release_id}>Version {item.version} · {item.status} · Manifest v{item.manifest_version}</option>)}</select></label><label>H5 ZIP file<input type="file" accept=".zip,application/zip" disabled={!canManage || busy || !draft} onChange={event => { setZip(event.target.files?.[0] ?? null); setPreview(""); }} /></label><button className="primary" disabled={!canManage || busy || !draft || !zip || zip.size > 50 * 1024 * 1024}>Upload H5 ZIP</button>{zip && zip.size > 50 * 1024 * 1024 && <p className="hint">Choose a ZIP no larger than 50 MiB.</p>}</form>{draft && <p role="status">Version {draft.version} · {draft.status}{draft.validation_error_code ? ` · ${draft.validation_error_code}` : ""}</p>}{preview && <a href={preview} target="_blank" rel="noreferrer">Preview draft</a>}<button className="primary" disabled={!canManage || busy || draft?.status !== "draft" || !draft.entry_file || draft.manifest_version !== active.manifest_version} onClick={() => void run(async () => { if (draft) await publishAppRelease(active.app_id, draft.release_id); setDraftId(""); setPreview(""); setZip(null); await reloadReleases(); })}>Publish draft</button>{draft && draft.manifest_version !== active.manifest_version && <p className="hint">The schema changed. Create a new draft before publishing.</p>}</section><section className="card"><h3>Release history</h3>{!releases.length && <p className="hint">No releases yet.</p>}{releases.map(release => <div className="list-line" key={release.release_id}><div><strong>Version {release.version} · {release.status}{release.is_current ? " · Current" : ""}</strong><small>Manifest v{release.manifest_version} · {release.file_count ?? 0} files · {release.created_at}</small>{release.validation_error_code && <small>{release.validation_error_code}</small>}{release.status === "published" && <button className="text-button" disabled={busy} onClick={() => void run(() => openRelease(release))}>Open version {release.version}</button>}</div><button className="secondary" disabled={!canManage || busy || release.status !== "published" || release.is_current} onClick={() => { if (window.confirm(`Rollback to version ${release.version}?`)) void run(async () => { await rollbackAppRelease(active.app_id, release.release_id); await reloadReleases(); }); }}>Rollback to version {release.version}</button></div>)}</section></>}
      </>}
      {recordModal && <div className="app-modal-backdrop"><section className="card app-record-modal" role="dialog" aria-modal="true" aria-label={editing ? "Edit record" : "Create record"}><h3>{editing ? "Edit record" : "New record"}</h3><form className="record-form" onSubmit={event => void submitRecord(event)}>{Object.entries(fields).map(([name, definition]) => <label key={name}>{name}<small>{definition.type}{definition.nullable ? " · optional" : " · required"}</small><ValueInput label={name} value={formValues[name] ?? (definition.type === "boolean" && !definition.nullable ? "false" : "")} definition={definition} disabled={!canWrite || busy} onChange={value => setFormValues(items => ({ ...items, [name]: value }))} /></label>)}<div className="form-actions"><button className="primary" disabled={!canWrite || busy || recordConflict}>{editing ? "Save record" : "Add record"}</button><button type="button" className="secondary" disabled={busy} onClick={() => setRecordModal(false)}>Cancel</button>{recordConflict && <button type="button" className="secondary" disabled={busy} onClick={() => void run(async () => { await reloadRecords(); setRecordConflict(false); setRecordModal(false); })}>Discard edits and reload record</button>}</div></form></section></div>}
      {status === "active" && <section className="card"><h3>Create an App</h3><form className="stacked-form" onSubmit={event => void create(event)}><label>App name<input value={newAppName} onChange={event => setNewAppName(event.target.value)} required maxLength={120} disabled={!manager} /></label><label className="checkbox-label"><input type="checkbox" checked={advancedCreate} onChange={event => setAdvancedCreate(event.target.checked)} disabled={!manager} />Use JSON Manifest</label>{advancedCreate ? <label>Manifest JSON<textarea value={newManifestText} onChange={event => setNewManifestText(event.target.value)} rows={9} spellCheck={false} disabled={!manager} /></label> : <><label>Table name<input value={newTableName} onChange={event => setNewTableName(event.target.value)} required placeholder="For example, contacts" disabled={!manager} /></label>{fieldDrafts.map((field, index) => <div className="field-row" key={index}><label>Field name<input value={field.name} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, name: event.target.value } : item))} required placeholder="For example, name" disabled={!manager} /></label><label>Type<select value={field.type} disabled={!manager} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, type: event.target.value as FieldDefinition["type"] } : item))}>{["text", "integer", "numeric", "boolean", "timestamp", "uuid", "json"].map(type => <option key={type} value={type}>{type}</option>)}</select></label><label className="checkbox-label"><input type="checkbox" checked={field.nullable} disabled={!manager} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, nullable: event.target.checked } : item))} />Optional</label>{fieldDrafts.length > 1 && <button type="button" className="text-button" disabled={!manager || busy} onClick={() => setFieldDrafts(items => items.filter((_, at) => at !== index))}>Remove</button>}</div>)}<button type="button" className="secondary" disabled={!manager} onClick={() => setFieldDrafts(items => [...items, { name: "", type: "text", nullable: true }])}>＋ Add field</button></>}<button className="primary" disabled={!manager || busy}>Create App</button></form></section>}    </section></div>;
}
