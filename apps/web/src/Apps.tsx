import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ApiError, createApp, createRecord, deleteRecord, listApps, listRecords, updateManifest, updateRecord, type AppRecord, type FieldDefinition, type Manifest, type Permissions, type Space, type VesselApp } from "./api";
import { message } from "./App";
import { asInput, parseValue } from "./record-values";

type Props = { space: Space; permissions: Permissions; onError: (value: string) => void };
type FieldDraft = { name: string; type: FieldDefinition["type"]; nullable: boolean };

export function Apps({ space, permissions, onError }: Props) {
  const [apps, setApps] = useState<VesselApp[]>([]);
  const [activeId, setActiveId] = useState("");
  const [tableName, setTableName] = useState("");
  const [records, setRecords] = useState<AppRecord[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [cursor, setCursor] = useState<string>();
  const [cursorStack, setCursorStack] = useState<Array<string | undefined>>([]);
  const [newAppName, setNewAppName] = useState("");
  const [newTableName, setNewTableName] = useState("");
  const [fieldDrafts, setFieldDrafts] = useState<FieldDraft[]>([{ name: "", type: "text", nullable: false }]);
  const [advancedCreate, setAdvancedCreate] = useState(false);
  const [newManifestText, setNewManifestText] = useState('{"tables":{"items":{"fields":{"name":{"type":"text","nullable":false}}}}}');
  const [manifestText, setManifestText] = useState("");
  const [showManifest, setShowManifest] = useState(false);
  const [formValues, setFormValues] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<AppRecord | null>(null);
  const [busy, setBusy] = useState(false);
  const [recordConflict, setRecordConflict] = useState(false);
  const [manifestConflict, setManifestConflict] = useState(false);
  const active = apps.find(item => item.app_id === activeId) ?? null;
  const fields = active?.manifest.tables[tableName]?.fields ?? {};

  const reloadApps = useCallback(async (preferred?: string) => {
    const result = await listApps(space.space_id);
    setApps(result.apps);
    setActiveId(current => result.apps.find(item => item.app_id === (preferred ?? current))?.app_id ?? result.apps[0]?.app_id ?? "");
  }, [space.space_id]);
  useEffect(() => { void reloadApps().catch(problem => onError(message(problem))); }, [reloadApps, onError]);
  useEffect(() => {
    if (!active) { setTableName(""); return; }
    setTableName(current => Object.hasOwn(active.manifest.tables, current) ? current : Object.keys(active.manifest.tables)[0]);
    setManifestText(JSON.stringify(active.manifest, null, 2));
    setCursor(undefined); setCursorStack([]); setEditing(null); setFormValues({}); setRecordConflict(false); setManifestConflict(false);
  }, [active?.app_id, active?.manifest_version]);
  useEffect(() => {
    if (!active || !tableName) { setRecords([]); return; }
    let live = true;
    void listRecords(active.app_id, tableName, cursor).then(result => {
      if (live) { setRecords(result.records); setNextCursor(result.next_cursor); }
    }).catch(problem => { if (live) onError(message(problem)); });
    return () => { live = false; };
  }, [active?.app_id, tableName, cursor, onError]);

  async function reloadRecords() {
    if (!active || !tableName) return;
    const result = await listRecords(active.app_id, tableName, cursor);
    setRecords(result.records); setNextCursor(result.next_cursor);
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true);
    try {
      const manifest = advancedCreate ? JSON.parse(newManifestText) as Manifest : {
        tables: { [newTableName.trim()]: { fields: Object.fromEntries(fieldDrafts.map(item => [item.name.trim(), { type: item.type, nullable: item.nullable }])) } },
      } satisfies Manifest;
      const result = await createApp(space.space_id, newAppName, manifest);
      setNewAppName(""); setNewTableName(""); setFieldDrafts([{ name: "", type: "text", nullable: false }]);
      await reloadApps(result.app.app_id);
    } catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function saveManifest() {
    if (!active) return;
    setBusy(true);
    try {
      const manifest = JSON.parse(manifestText) as Manifest;
      const result = await updateManifest(active, manifest);
      setApps(items => items.map(item => item.app_id === active.app_id ? result.app : item));
      setShowManifest(false);
      setManifestConflict(false);
    } catch (problem) {
      if (problem instanceof ApiError && problem.code === "APP_MANIFEST_VERSION_CONFLICT") setManifestConflict(true);
      onError(message(problem));
    }
    finally { setBusy(false); }
  }

  async function submitRecord(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!active) return;
    setBusy(true);
    try {
      const values = Object.fromEntries(Object.entries(fields).map(([name, definition]) => [name, parseValue(formValues[name] ?? "", definition)]));
      if (editing) await updateRecord(active.app_id, tableName, editing, values);
      else await createRecord(active.app_id, tableName, values);
      setEditing(null); setFormValues({}); setRecordConflict(false); await reloadRecords();
    } catch (problem) {
      if (problem instanceof ApiError && problem.code === "APP_RECORD_VERSION_CONFLICT") setRecordConflict(true);
      onError(message(problem));
    }
    finally { setBusy(false); }
  }

  async function removeRecord(record: AppRecord) {
    if (!active || !window.confirm("删除这条记录？")) return;
    setBusy(true);
    try { await deleteRecord(active.app_id, tableName, record); await reloadRecords(); }
    catch (problem) { if (problem instanceof ApiError && problem.code === "APP_RECORD_VERSION_CONFLICT") await reloadRecords(); onError(message(problem)); }
    finally { setBusy(false); }
  }

  return <div className="apps-layout"><aside className="resource-rail"><div className="rail-title"><span className="eyebrow">{space.kind === "team" ? "TEAM SPACE" : "PERSONAL SPACE"}</span><h2>Apps</h2></div><div className="resource-list"><h3>数据应用</h3>{apps.map(item => <button key={item.app_id} className={item.app_id === activeId ? "selected" : ""} onClick={() => setActiveId(item.app_id)}>{item.name}</button>)}</div></aside>
    <section className="app-main"><header className="section-header"><div><span className="eyebrow">STRUCTURED DATA</span><h2>{active?.name ?? "创建第一个 App"}</h2><p>{active ? `${Object.keys(active.manifest.tables).length} 张表 · Manifest v${active.manifest_version}` : "为团队或个人建立结构化表格。"}</p></div></header>
      {active ? <>
        <div className="card compact"><div className="card-heading"><h3>表结构</h3><button className="text-button" onClick={() => setShowManifest(value => !value)}>{showManifest ? "收起" : "查看 / 修改 Manifest"}</button></div><div className="tab-row">{Object.keys(active.manifest.tables).map(name => <button key={name} className={tableName === name ? "active" : ""} onClick={() => { setTableName(name); setCursor(undefined); setCursorStack([]); setEditing(null); setFormValues({}); }}>{name}</button>)}</div>
          {showManifest && <div className="manifest-editor"><p className="hint">已有字段不能删除或更改类型；只可新增表和可空字段。</p><textarea aria-label="Manifest JSON" value={manifestText} onChange={event => setManifestText(event.target.value)} rows={12} spellCheck={false} /><button className="primary" disabled={!permissions.can_write || busy || manifestConflict} onClick={() => void saveManifest()}>保存 Manifest</button>{manifestConflict && <button className="secondary" disabled={busy} onClick={() => void reloadApps(active.app_id).then(() => setShowManifest(false)).catch(problem => onError(message(problem)))}>丢弃更改并重新载入 Manifest</button>}</div>}
        </div>
        <div className="card"><div className="card-heading"><h3>{tableName} 记录</h3><span>{records.length} 条</span></div><div className="table-scroll"><table><thead><tr>{Object.keys(fields).map(name => <th key={name}>{name}</th>)}<th>版本</th>{permissions.can_write && <th>操作</th>}</tr></thead><tbody>{records.map(record => <tr key={record.id}>{Object.keys(fields).map(name => <td key={name}>{record.values[name] === null ? "—" : typeof record.values[name] === "object" ? JSON.stringify(record.values[name]) : String(record.values[name] ?? "")}</td>)}<td>{record.row_version}</td>{permissions.can_write && <td><button className="text-button" onClick={() => { setEditing(record); setFormValues(Object.fromEntries(Object.entries(fields).map(([name, definition]) => [name, asInput(record.values[name], definition)]))); }}>编辑</button><button className="text-button danger" onClick={() => void removeRecord(record)}>删除</button></td>}</tr>)}</tbody></table>{records.length === 0 && <p className="hint">暂无记录</p>}</div><div className="pager"><button className="secondary" disabled={cursorStack.length === 0} onClick={() => { setCursor(cursorStack.at(-1)); setCursorStack(items => items.slice(0, -1)); }}>上一页</button><button className="secondary" disabled={!nextCursor} onClick={() => { setCursorStack(items => [...items, cursor]); setCursor(nextCursor ?? undefined); }}>下一页</button></div></div>
        <section className="card"><h3>{editing ? "编辑记录" : "新增记录"}</h3><form className="record-form" onSubmit={event => void submitRecord(event)}>{Object.entries(fields).map(([name, definition]) => <label key={name}>{name}<small>{definition.type}{definition.nullable ? " · 可空" : " · 必填"}</small>{definition.type === "boolean" ? <select aria-label={name} value={formValues[name] ?? "false"} disabled={!permissions.can_write} onChange={event => setFormValues(values => ({ ...values, [name]: event.target.value }))}>{definition.nullable && <option value="">空</option>}<option value="true">是</option><option value="false">否</option></select> : definition.type === "json" ? <textarea aria-label={name} value={formValues[name] ?? ""} disabled={!permissions.can_write} required={!definition.nullable} onChange={event => setFormValues(values => ({ ...values, [name]: event.target.value }))} /> : <input aria-label={name} type="text" placeholder={definition.type === "timestamp" ? "2026-10-15T12:00:00Z" : undefined} value={formValues[name] ?? ""} disabled={!permissions.can_write} required={!definition.nullable} onChange={event => setFormValues(values => ({ ...values, [name]: event.target.value }))} />}</label>)}<div className="form-actions"><button className="primary" disabled={!permissions.can_write || busy || recordConflict}>{editing ? "保存记录" : "新增记录"}</button>{recordConflict && <button type="button" className="secondary" disabled={busy} onClick={() => { setEditing(null); setFormValues({}); setRecordConflict(false); void reloadRecords().catch(problem => onError(message(problem))); }}>丢弃编辑并重新载入记录</button>}{editing && <button type="button" className="secondary" onClick={() => { setEditing(null); setFormValues({}); setRecordConflict(false); }}>取消</button>}</div></form></section>
      </> : null}
      <section className="card"><h3>创建 App</h3><form className="stacked-form" onSubmit={event => void create(event)}><label>App 名称<input value={newAppName} onChange={event => setNewAppName(event.target.value)} required maxLength={120} disabled={!permissions.can_write} /></label><label className="checkbox-label"><input type="checkbox" checked={advancedCreate} onChange={event => setAdvancedCreate(event.target.checked)} disabled={!permissions.can_write} />使用 JSON Manifest</label>{advancedCreate ? <label>Manifest JSON<textarea value={newManifestText} onChange={event => setNewManifestText(event.target.value)} rows={9} spellCheck={false} disabled={!permissions.can_write} /></label> : <><label>表名<input value={newTableName} onChange={event => setNewTableName(event.target.value)} required placeholder="例如 contacts" disabled={!permissions.can_write} /></label>{fieldDrafts.map((field, index) => <div className="field-row" key={index}><label>字段名<input value={field.name} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, name: event.target.value } : item))} required placeholder="例如 name" disabled={!permissions.can_write} /></label><label>类型<select value={field.type} disabled={!permissions.can_write} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, type: event.target.value as FieldDefinition["type"] } : item))}>{["text", "integer", "numeric", "boolean", "timestamp", "uuid", "json"].map(type => <option key={type} value={type}>{type}</option>)}</select></label><label className="checkbox-label"><input type="checkbox" checked={field.nullable} disabled={!permissions.can_write} onChange={event => setFieldDrafts(items => items.map((item, at) => at === index ? { ...item, nullable: event.target.checked } : item))} />可空</label>{fieldDrafts.length > 1 && <button type="button" className="text-button" onClick={() => setFieldDrafts(items => items.filter((_, at) => at !== index))}>移除</button>}</div>)}<button type="button" className="secondary" disabled={!permissions.can_write} onClick={() => setFieldDrafts(items => [...items, { name: "", type: "text", nullable: true }])}>＋ 添加字段</button></>}<button className="primary" disabled={!permissions.can_write || busy}>创建 App</button></form></section>
    </section></div>;
}
