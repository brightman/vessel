import { useCallback, useEffect, useState } from "react";
import { archivePage, createDirectory, createPage, listDirectories, listPages, listVersions, restorePage, restoreVersion, savePage, type Directory, type PageRecord, type PageVersion, type Permissions, type Space, type User } from "./api";
import { message } from "./App";
import { PageEditor } from "./editor";

type Props = { space: Space; permissions: Permissions; user: User; onError: (value: string) => void };
type Draft = { title: string; document: Record<string, unknown>; directoryId: string | null; revision: number };
const pageDrafts = new Map<string, Draft>();

export function clearPageDrafts(): void {
  pageDrafts.clear();
  for (const key of Object.keys(localStorage)) {
    if (key.startsWith("vessel.page.draft.v1:")) localStorage.removeItem(key);
  }
}

export function Pages({ space, permissions, user, onError }: Props) {
  const [pages, setPages] = useState<PageRecord[]>([]);
  const [archived, setArchived] = useState<PageRecord[]>([]);
  const [directories, setDirectories] = useState<Directory[]>([]);
  const [activeId, setActiveId] = useState("");
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saveState, setSaveState] = useState("已保存");
  const [versions, setVersions] = useState<PageVersion[] | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [collapsed, setCollapsed] = useState<string[]>([]);
  const [editorEpoch, setEditorEpoch] = useState(0);
  const [busy, setBusy] = useState(false);
  const active = pages.find(item => item.page_id === activeId) ?? null;

  const draftKey = (pageId: string) => `${user.user_id}:${space.space_id}:${pageId}`;
  const select = useCallback((page: PageRecord | null) => {
    setEditorEpoch(value => value + 1);
    setActiveId(page?.page_id ?? "");
    if (!page) { setDraft(null); setDirty(false); return; }
    const recovered = pageDrafts.get(`${user.user_id}:${space.space_id}:${page.page_id}`);
    if (recovered && recovered.revision === page.revision) { setDraft(recovered); setDirty(true); setSaveState("有未保存草稿"); }
    else if (recovered) { setDraft(recovered); setDirty(true); setSaveState("草稿版本过旧，请复制内容后重新载入"); }
    else { setDraft({ title: page.title, document: page.document, directoryId: page.directory_id, revision: page.revision }); setDirty(false); setSaveState("已保存"); }
    setCollapsed([]);
  }, [user.user_id, space.space_id]);

  const reload = useCallback(async (preferred?: string) => {
    const [pageResult, directoryResult, archivedResult] = await Promise.all([listPages(space.space_id), listDirectories(space.space_id), listPages(space.space_id, "archived")]);
    setPages(pageResult.pages); setDirectories(directoryResult.directories); setArchived(archivedResult.pages);
    select(pageResult.pages.find(item => item.page_id === preferred) ?? pageResult.pages[0] ?? null);
  }, [space.space_id, select]);

  useEffect(() => { void reload().catch(problem => {
    if (problem instanceof Error && "status" in problem && problem.status === 403) {
      for (const key of pageDrafts.keys()) if (key.startsWith(`${user.user_id}:${space.space_id}:`)) pageDrafts.delete(key);
    }
    onError(message(problem));
  }); }, [reload, onError, user.user_id, space.space_id]);

  function change(patch: Partial<Draft>) {
    if (!active || !permissions.can_write || busy) return;
    const next = { ...(draft ?? { title: active.title, document: active.document, directoryId: active.directory_id, revision: active.revision }), ...patch };
    setDraft(next); setDirty(true); setSaveState("未保存");
    pageDrafts.set(draftKey(active.page_id), next);
  }

  async function makePage() {
    setBusy(true);
    try {
      const result = await createPage(space.space_id, "未命名 Page", null);
      await reload(result.page.page_id);
    } catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function makeDirectory() {
    const name = window.prompt("目录名称");
    if (!name?.trim()) return;
    try { await createDirectory(space.space_id, name.trim()); await reload(activeId); }
    catch (problem) { onError(message(problem)); }
  }

  async function save() {
    if (!active || !draft || !permissions.can_write || busy) return;
    if (draft.revision !== active.revision) { setSaveState("草稿版本过旧，请复制内容后重新载入"); return; }
    setBusy(true); setSaveState("保存中…");
    try {
      const result = await savePage(active, draft.title, draft.document, draft.directoryId);
      setPages(items => items.map(item => item.page_id === result.page.page_id ? result.page : item));
      setDraft({ title: result.page.title, document: result.page.document, directoryId: result.page.directory_id, revision: result.page.revision });
      setDirty(false); setSaveState("已保存");
      pageDrafts.delete(draftKey(active.page_id));
    } catch (problem) { setSaveState(problem instanceof Error && "status" in problem && problem.status === 409 ? "保存冲突，请复制内容后重新载入" : "保存失败"); onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function archive() {
    if (!active || busy || !window.confirm(dirty ? `归档 “${active.title}”？未保存的更改会丢失。` : `归档 “${active.title}”？`)) return;
    try { await archivePage(active.page_id); pageDrafts.delete(draftKey(active.page_id)); await reload(); }
    catch (problem) { onError(message(problem)); }
  }

  async function showVersions() {
    if (!active) return;
    try { setVersions((await listVersions(active.page_id)).versions); }
    catch (problem) { onError(message(problem)); }
  }

  async function restoreOldVersion(version: PageVersion) {
    if (!active || !window.confirm(`恢复版本 ${version.revision}？`)) return;
    try { const result = await restoreVersion(active, version.version_id); setVersions(null); await reload(result.page.page_id); }
    catch (problem) { onError(message(problem)); }
  }

  return <div className="pages-layout">
    <aside className="resource-rail"><div className="rail-title"><span className="eyebrow">{space.kind === "team" ? "TEAM SPACE" : "PERSONAL SPACE"}</span><h2>Pages</h2></div>
      <button className="primary full" disabled={!permissions.can_write || busy} onClick={() => void makePage()}>新建 Page</button>
      <button className="text-button" disabled={!permissions.can_write || busy} onClick={() => void makeDirectory()}>＋ 新建目录</button>
      <div className="resource-list"><h3>所有页面</h3>{pages.filter(item => !item.directory_id).map(item => <button key={item.page_id} disabled={busy} className={activeId === item.page_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</button>)}
        {directories.map(directory => <div key={directory.directory_id}><h3>{directory.name}</h3>{pages.filter(item => item.directory_id === directory.directory_id).map(item => <button key={item.page_id} disabled={busy} className={activeId === item.page_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</button>)}</div>)}
      </div><button className="text-button" onClick={() => setShowArchived(value => !value)}>{showArchived ? "收起归档" : `归档页面 (${archived.length})`}</button>
      {showArchived && <div className="archive-list">{archived.map(item => <div key={item.page_id}><span>{item.title}</span><button disabled={!permissions.can_write || busy} onClick={() => void restorePage(item.page_id).then(() => reload(item.page_id)).catch(problem => onError(message(problem)))}>恢复</button></div>)}</div>}
    </aside>
    <section className="page-panel">{active && draft ? <>
      <header className="page-actionbar"><span className="breadcrumb">{space.name} / Pages</span><div className="page-actions"><span role="status" aria-label="Page 保存状态" className={dirty ? "unsaved" : "saved"}>{saveState}</span>{(saveState.includes("冲突") || saveState.includes("过旧")) && <button className="secondary" disabled={busy} onClick={() => { pageDrafts.delete(draftKey(active.page_id)); void reload(active.page_id).catch(problem => onError(message(problem))); }}>丢弃草稿并载入服务器版本</button>}<button className="secondary" disabled={busy} onClick={() => void showVersions()}>版本</button><button className="secondary" disabled={!permissions.can_write || busy} onClick={() => void archive()}>归档</button><button className="primary" disabled={!permissions.can_write || !dirty || busy} onClick={() => void save()}>保存 Page</button></div></header>
      <div className="page-paper"><select aria-label="Page 所在目录" value={draft.directoryId ?? ""} disabled={!permissions.can_write || busy} onChange={event => change({ directoryId: event.target.value || null })}><option value="">根目录</option>{directories.map(item => <option key={item.directory_id} value={item.directory_id}>{item.name}</option>)}</select><input className="page-title" aria-label="Page 标题" value={draft.title} disabled={!permissions.can_write || busy} onChange={event => change({ title: event.target.value })} />
        <PageEditor key={`${active.page_id}:${editorEpoch}`} page={{ ...active, document: draft.document }} collapsedSectionIds={collapsed} onCollapse={setCollapsed} onDocumentChange={document => change({ document })} readOnly={!permissions.can_write || busy} />
      </div>
    </> : <div className="empty-state"><span className="empty-mark">✦</span><h2>开始写下第一篇 Page</h2><p>记录内容，并在个人或团队空间中共享。</p><button className="primary" disabled={!permissions.can_write} onClick={() => void makePage()}>创建第一篇 Page</button></div>}</section>
    {versions && <div className="modal-backdrop"><section role="dialog" aria-modal="true" aria-label="版本历史" className="modal-card"><div className="card-heading"><h3>版本历史</h3><button className="icon-button" aria-label="关闭版本历史" onClick={() => setVersions(null)}>×</button></div><div className="version-list">{versions.map(item => <div key={item.version_id}><div><strong>版本 {item.revision} · {item.title}</strong><small>{new Date(item.created_at).toLocaleString()}</small></div><button className="secondary" disabled={!permissions.can_write} onClick={() => void restoreOldVersion(item)}>恢复</button></div>)}</div></section></div>}
  </div>;
}
