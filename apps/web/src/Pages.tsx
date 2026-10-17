import { useDialogs } from "./components/dialogs";
import { Modal, Button, Input } from "./components/controls";
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
  const { confirm, prompt } = useDialogs();
  const [pages, setPages] = useState<PageRecord[]>([]);
  const [archived, setArchived] = useState<PageRecord[]>([]);
  const [directories, setDirectories] = useState<Directory[]>([]);
  const [activeId, setActiveId] = useState("");
  const [selectedDirectoryId, setSelectedDirectoryId] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saveState, setSaveState] = useState("Saved");
  const [versions, setVersions] = useState<PageVersion[] | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [collapsed, setCollapsed] = useState<string[]>([]);
  const [editorEpoch, setEditorEpoch] = useState(0);
  const [busy, setBusy] = useState(false);
  const active = pages.find(item => item.page_id === activeId) ?? null;
  const selectedDirectory = directories.find(item => item.directory_id === selectedDirectoryId) ?? null;
  const selectedLocationName = selectedDirectory?.name ?? "All Pages";

  const draftKey = (pageId: string) => `${user.user_id}:${space.space_id}:${pageId}`;
  const selectDirectory = useCallback((directoryId: string | null) => {
    setEditorEpoch(value => value + 1);
    setActiveId("");
    setSelectedDirectoryId(directoryId);
    setDraft(null);
    setDirty(false);
    setSaveState("Saved");
    setCollapsed([]);
  }, []);
  const select = useCallback((page: PageRecord | null) => {
    if (!page) { selectDirectory(null); return; }
    setEditorEpoch(value => value + 1);
    setActiveId(page.page_id);
    setSelectedDirectoryId(page.directory_id);
    const recovered = pageDrafts.get(`${user.user_id}:${space.space_id}:${page.page_id}`);
    if (recovered && recovered.revision === page.revision) { setDraft(recovered); setDirty(true); setSaveState("Unsaved draft"); }
    else if (recovered) { setDraft(recovered); setDirty(true); setSaveState("Draft is out of date. Copy it, then reload."); }
    else { setDraft({ title: page.title, document: page.document, directoryId: page.directory_id, revision: page.revision }); setDirty(false); setSaveState("Saved"); }
    setCollapsed([]);
  }, [selectDirectory, user.user_id, space.space_id]);

  const reload = useCallback(async (preferred?: string, location?: string | null) => {
    const [pageResult, directoryResult, archivedResult] = await Promise.all([listPages(space.space_id), listDirectories(space.space_id), listPages(space.space_id, "archived")]);
    setPages(pageResult.pages); setDirectories(directoryResult.directories); setArchived(archivedResult.pages);
    const page = preferred
      ? pageResult.pages.find(item => item.page_id === preferred) ?? null
      : location === undefined ? pageResult.pages[0] ?? null : null;
    if (page) select(page);
    else selectDirectory(location ?? null);
  }, [space.space_id, select, selectDirectory]);

  useEffect(() => { void reload().catch(problem => {
    if (problem instanceof Error && "status" in problem && problem.status === 403) {
      for (const key of pageDrafts.keys()) if (key.startsWith(`${user.user_id}:${space.space_id}:`)) pageDrafts.delete(key);
    }
    onError(message(problem));
  }); }, [reload, onError, user.user_id, space.space_id]);

  function change(patch: Partial<Draft>) {
    if (!active || !permissions.can_write || busy) return;
    const next = { ...(draft ?? { title: active.title, document: active.document, directoryId: active.directory_id, revision: active.revision }), ...patch };
    setDraft(next); setDirty(true); setSaveState("Unsaved changes");
    pageDrafts.set(draftKey(active.page_id), next);
  }

  async function makePage() {
    setBusy(true);
    try {
      const result = await createPage(space.space_id, "Untitled Page", selectedDirectoryId);
      await reload(result.page.page_id);
    } catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function makeDirectory() {
    const name = await prompt("Folder name");
    if (!name?.trim()) return;
    setBusy(true);
    try {
      const result = await createDirectory(space.space_id, name.trim());
      await reload(undefined, result.directory.directory_id);
    } catch (problem) { onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function save() {
    if (!active || !draft || !permissions.can_write || busy) return;
    if (draft.revision !== active.revision) { setSaveState("Draft is out of date. Copy it, then reload."); return; }
    setBusy(true); setSaveState("Saving…");
    try {
      const result = await savePage(active, draft.title, draft.document, draft.directoryId);
      setPages(items => items.map(item => item.page_id === result.page.page_id ? result.page : item));
      setDraft({ title: result.page.title, document: result.page.document, directoryId: result.page.directory_id, revision: result.page.revision });
      setSelectedDirectoryId(result.page.directory_id);
      setDirty(false); setSaveState("Saved");
      pageDrafts.delete(draftKey(active.page_id));
    } catch (problem) { setSaveState(problem instanceof Error && "status" in problem && problem.status === 409 ? "Save conflict. Copy your changes, then reload." : "Save failed"); onError(message(problem)); }
    finally { setBusy(false); }
  }

  async function archive() {
    if (!active || busy || !(await confirm(dirty ? `Archive “${active.title}”? Unsaved changes will be lost.` : `Archive “${active.title}”?`))) return;
    try { await archivePage(active.page_id); pageDrafts.delete(draftKey(active.page_id)); await reload(); }
    catch (problem) { onError(message(problem)); }
  }

  async function showVersions() {
    if (!active) return;
    try { setVersions((await listVersions(active.page_id)).versions); }
    catch (problem) { onError(message(problem)); }
  }

  async function restoreOldVersion(version: PageVersion) {
    if (!active || !(await confirm(`Restore version ${version.revision}?`))) return;
    try { const result = await restoreVersion(active, version.version_id); setVersions(null); await reload(result.page.page_id); }
    catch (problem) { onError(message(problem)); }
  }

  return <div className="pages-layout">
    <aside className="resource-rail"><div className="rail-title"><span className="eyebrow">{space.kind === "team" ? "TEAM SPACE" : "PERSONAL SPACE"}</span><h2>Pages</h2></div>
      <Button className="primary full" disabled={!permissions.can_write || busy} onClick={() => void makePage()}>New Page</Button>
      <Button className="text-button" disabled={!permissions.can_write || busy} onClick={() => void makeDirectory()}>＋ New folder</Button>
      <div className="resource-list"><Button className={selectedDirectoryId === null ? "directory-selector selected" : "directory-selector"} aria-label="Select all Pages" disabled={busy} onClick={() => selectDirectory(null)}>All Pages</Button>
        {pages.filter(item => !item.directory_id).map(item => <Button key={item.page_id} disabled={busy} className={activeId === item.page_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</Button>)}
        {directories.map(directory => <div key={directory.directory_id}><Button className={selectedDirectoryId === directory.directory_id ? "directory-selector selected" : "directory-selector"} aria-label={`Select folder ${directory.name}`} disabled={busy} onClick={() => selectDirectory(directory.directory_id)}>{directory.name}</Button>{pages.filter(item => item.directory_id === directory.directory_id).map(item => <Button key={item.page_id} disabled={busy} className={activeId === item.page_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</Button>)}</div>)}
      </div><Button className="text-button" onClick={() => setShowArchived(value => !value)}>{showArchived ? "Hide archived" : `Archived Pages (${archived.length})`}</Button>
      {showArchived && <div className="archive-list">{archived.map(item => <div key={item.page_id}><span>{item.title}</span><Button disabled={!permissions.can_write || busy} onClick={() => void restorePage(item.page_id).then(() => reload(item.page_id)).catch(problem => onError(message(problem)))}>Restore</Button></div>)}</div>}
    </aside>
    <section className="page-panel">{active && draft ? <>
      <header className="page-actionbar"><span className="breadcrumb">{space.name} / Pages</span><div className="page-actions"><span role="status" aria-label="Page save status" className={dirty ? "unsaved" : "saved"}>{saveState}</span>{(saveState.includes("conflict") || saveState.includes("out of date")) && <Button className="secondary" disabled={busy} onClick={() => { pageDrafts.delete(draftKey(active.page_id)); void reload(active.page_id).catch(problem => onError(message(problem))); }}>Discard draft and reload</Button>}<Button className="secondary" disabled={busy} onClick={() => void showVersions()}>Versions</Button><Button className="secondary" disabled={!permissions.can_write || busy} onClick={() => void archive()}>Archive</Button><Button className="primary" disabled={!permissions.can_write || !dirty || busy} onClick={() => void save()}>Save Page</Button></div></header>
      <div className="page-paper"><select aria-label="Page folder" value={draft.directoryId ?? ""} disabled={!permissions.can_write || busy} onChange={event => change({ directoryId: event.target.value || null })}><option value="">All Pages</option>{directories.map(item => <option key={item.directory_id} value={item.directory_id}>{item.name}</option>)}</select><Input className="page-title h-auto rounded-none border-0 px-0 py-0 text-[clamp(32px,4vw,44px)] font-[740] shadow-none md:text-[clamp(32px,4vw,44px)]" aria-label="Page title" value={draft.title} disabled={!permissions.can_write || busy} onChange={event => change({ title: event.target.value })} />
        <PageEditor key={`${active.page_id}:${editorEpoch}`} page={{ ...active, document: draft.document }} collapsedSectionIds={collapsed} onCollapse={setCollapsed} onDocumentChange={document => change({ document })} readOnly={!permissions.can_write || busy} />
      </div>
    </> : <div className="empty-state"><span className="empty-mark">✦</span><h2>No Pages in {selectedLocationName}</h2><p>Create a Page here to organize content for your personal or team space.</p><Button className="primary" disabled={!permissions.can_write || busy} onClick={() => void makePage()}>Create Page in {selectedLocationName}</Button></div>}</section>
    {versions && <Modal className="max-w-[650px]" title="Version history" onClose={() => setVersions(null)}><div className="card-heading"><h3>Version history</h3><Button className="icon-button" aria-label="Close version history" onClick={() => setVersions(null)}>×</Button></div><div className="version-list">{versions.map(item => <div key={item.version_id}><div><strong>Version {item.revision} · {item.title}</strong><small>{new Date(item.created_at).toLocaleString("en-US")}</small></div><Button className="secondary" disabled={!permissions.can_write} onClick={() => void restoreOldVersion(item)}>Restore</Button></div>)}</div></Modal>}
  </div>;
}
