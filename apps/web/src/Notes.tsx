import "./note-agent-preview.css";
import { useDialogs } from "./components/dialogs";
import { Modal, Button, Input } from "./components/controls";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { PanelRightOpen, PanelRightClose, Plus, FolderPlus, Archive } from "lucide-react";
import { archiveNote, createDirectory, createNote, listDirectories, listNotes, listVersions, restoreNote, restoreVersion, saveNote, type Directory, type NoteRecord, type NoteVersion, type Permissions, type Space, type User } from "./api";
import { message } from "./App";
import { NoteEditor } from "./editor";
import { NoteAgent, type AgentPreview } from "./NoteAgent";

type Props = { space: Space; permissions: Permissions; user: User; sidebarHost: HTMLDivElement | null; onError: (value: string) => void };
type Draft = { title: string; document: Record<string, unknown>; directoryId: string | null; revision: number };
const noteDrafts = new Map<string, Draft>();

export function clearNoteDrafts(): void {
  noteDrafts.clear();
  for (const key of Object.keys(localStorage)) {
    if (key.startsWith("vessel.note.draft.v1:")) localStorage.removeItem(key);
  }
}

export function Notes({ space, permissions, user, sidebarHost, onError }: Props) {
  const { confirm, prompt } = useDialogs();
  const [agentPreview, setAgentPreview] = useState<AgentPreview | null>(null);
  const [notes, setNotes] = useState<NoteRecord[]>([]);
  const [archived, setArchived] = useState<NoteRecord[]>([]);
  const [directories, setDirectories] = useState<Directory[]>([]);
  const [activeId, setActiveId] = useState("");
  const activeIdRef = useRef(activeId);
  activeIdRef.current = activeId;
  const [selectedDirectoryId, setSelectedDirectoryId] = useState<string | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saveState, setSaveState] = useState("Saved");
  const [versions, setVersions] = useState<NoteVersion[] | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const [collapsed, setCollapsed] = useState<string[]>([]);
  const [editorEpoch, setEditorEpoch] = useState(0);
  const [busy, setBusy] = useState(false);
  const [agentCollapsed, setAgentCollapsed] = useState(() => localStorage.getItem("vessel.console.agent.collapsed.v1") === "true");
  const active = notes.find(item => item.note_id === activeId) ?? null;
  const selectedDirectory = directories.find(item => item.directory_id === selectedDirectoryId) ?? null;
  const selectedLocationName = selectedDirectory?.name ?? "All Notes";
  useEffect(() => {
    if (!agentPreview || !active) return;
    const before = (active.document.content ?? []) as Record<string, unknown>[];
    const after = (agentPreview.proposal.preview.document.content ?? []) as Record<string, unknown>[];
    const timer = window.setTimeout(() => {
      const blocks = document.querySelectorAll(".note-paper-preview .doc > *");
      after.forEach((block, index) => {
        const attrs = block.attrs as Record<string, unknown> | undefined;
        const blockId = attrs?.block_id ?? attrs?.["block-id"];
        const original = blockId ? before.find(item => { const old = item.attrs as Record<string, unknown> | undefined; return (old?.block_id ?? old?.["block-id"]) === blockId; }) : before[index];
        blocks[index]?.classList.toggle("agent-changed-block", JSON.stringify(original) !== JSON.stringify(block));
      });
    }, 0);
    return () => window.clearTimeout(timer);
  }, [agentPreview?.proposal, active]);
  function toggleAgent() {
    setAgentCollapsed(value => {
      localStorage.setItem("vessel.console.agent.collapsed.v1", String(!value));
      return !value;
    });
  }

  const draftKey = (noteId: string) => `${user.user_id}:${space.space_id}:${noteId}`;
  const selectDirectory = useCallback((directoryId: string | null) => {
    setAgentPreview(null);
    setEditorEpoch(value => value + 1);
    activeIdRef.current = "";
    setActiveId("");
    setSelectedDirectoryId(directoryId);
    setDraft(null);
    setDirty(false);
    setSaveState("Saved");
    setCollapsed([]);
  }, []);
  const select = useCallback((note: NoteRecord | null, force = false) => {
    if (!note) { selectDirectory(null); return; }
    if (!force && activeIdRef.current === note.note_id) return;
    activeIdRef.current = note.note_id;
    setAgentPreview(null);
    setEditorEpoch(value => value + 1);
    setActiveId(note.note_id);
    setSelectedDirectoryId(note.directory_id);
    const recovered = noteDrafts.get(`${user.user_id}:${space.space_id}:${note.note_id}`);
    if (recovered && recovered.revision === note.revision) { setDraft(recovered); setDirty(true); setSaveState("Unsaved draft"); }
    else if (recovered) { setDraft(recovered); setDirty(true); setSaveState("Draft is out of date. Copy it, then reload."); }
    else { setDraft({ title: note.title, document: note.document, directoryId: note.directory_id, revision: note.revision }); setDirty(false); setSaveState("Saved"); }
    setCollapsed([]);
  }, [selectDirectory, user.user_id, space.space_id]);

  const reload = useCallback(async (preferred?: string, location?: string | null) => {
    const [noteResult, directoryResult, archivedResult] = await Promise.all([listNotes(space.space_id), listDirectories(space.space_id), listNotes(space.space_id, "archived")]);
    setNotes(noteResult.notes); setDirectories(directoryResult.directories); setArchived(archivedResult.notes);
    const note = preferred
      ? noteResult.notes.find(item => item.note_id === preferred) ?? null
      : location === undefined ? noteResult.notes[0] ?? null : null;
    if (note) select(note, true);
    else selectDirectory(location ?? null);
  }, [space.space_id, select, selectDirectory]);

  useEffect(() => { void reload().catch(problem => {
    if (problem instanceof Error && "status" in problem && problem.status === 403) {
      for (const key of noteDrafts.keys()) if (key.startsWith(`${user.user_id}:${space.space_id}:`)) noteDrafts.delete(key);
    }
    onError(message(problem));
  }); }, [reload, onError, user.user_id, space.space_id]);

  function change(patch: Partial<Draft>) {
    if (!active || !permissions.can_write || busy || agentPreview) return;
    const next = { ...(draft ?? { title: active.title, document: active.document, directoryId: active.directory_id, revision: active.revision }), ...patch };
    setDraft(next); setDirty(true); setSaveState("Unsaved changes");
    noteDrafts.set(draftKey(active.note_id), next);
  }

  async function makeNote() {
    setBusy(true);
    try {
      const result = await createNote(space.space_id, "Untitled Note", selectedDirectoryId);
      await reload(result.note.note_id);
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

  async function save(): Promise<boolean> {
    if (!active || !draft || !permissions.can_write || busy) return false;
    if (draft.revision !== active.revision) { setSaveState("Draft is out of date. Copy it, then reload."); return false; }
    setBusy(true); setSaveState("Saving…");
    try {
      const result = await saveNote(active, draft.title, draft.document, draft.directoryId);
      setNotes(items => items.map(item => item.note_id === result.note.note_id ? result.note : item));
      setDraft({ title: result.note.title, document: result.note.document, directoryId: result.note.directory_id, revision: result.note.revision });
      setSelectedDirectoryId(result.note.directory_id);
      setDirty(false); setSaveState("Saved");
      noteDrafts.delete(draftKey(active.note_id));
      return true;
    } catch (problem) { setSaveState(problem instanceof Error && "status" in problem && problem.status === 409 ? "Save conflict. Copy your changes, then reload." : "Save failed"); onError(message(problem)); return false; }
    finally { setBusy(false); }
  }

  async function archive() {
    if (!active || busy || !(await confirm(dirty ? `Archive “${active.title}”? Unsaved changes will be lost.` : `Archive “${active.title}”?`))) return;
    try { await archiveNote(active.note_id); noteDrafts.delete(draftKey(active.note_id)); await reload(); }
    catch (problem) { onError(message(problem)); }
  }

  async function showVersions() {
    if (!active) return;
    try { setVersions((await listVersions(active.note_id)).versions); }
    catch (problem) { onError(message(problem)); }
  }

  async function restoreOldVersion(version: NoteVersion) {
    if (!active || !(await confirm(`Restore version ${version.revision}?`))) return;
    try { const result = await restoreVersion(active, version.version_id); setVersions(null); await reload(result.note.note_id); }
    catch (problem) { onError(message(problem)); }
  }

  function acceptedAgentEdit(note: NoteRecord) {
    noteDrafts.delete(draftKey(note.note_id));
    setNotes(items => items.map(item => item.note_id === note.note_id ? note : item));
    if (activeIdRef.current !== note.note_id) return;
    setDraft({ title: note.title, document: note.document, directoryId: note.directory_id, revision: note.revision });
    setSelectedDirectoryId(note.directory_id);
    setDirty(false);
    setSaveState("Saved");
    setEditorEpoch(value => value + 1);
  }

  const receiveAgentPreview = useCallback((preview: AgentPreview | null) => {
    if (activeIdRef.current === activeId) setAgentPreview(preview);
  }, [activeId]);

  const navigation = <section className="notes-sidebar-nav" aria-label="Note navigation"><div className="rail-title"><span className="eyebrow">{space.kind === "team" ? "TEAM SPACE" : "PERSONAL SPACE"}</span><h2>Notes</h2></div>
      <Button className="primary full" disabled={!permissions.can_write || busy} onClick={() => void makeNote()}><Plus size={16} aria-hidden="true" />New Note</Button>
      <Button className="notes-new-folder" disabled={!permissions.can_write || busy} onClick={() => void makeDirectory()}><FolderPlus size={16} aria-hidden="true" />New folder</Button>
      <div className="resource-list"><Button className={selectedDirectoryId === null ? "directory-selector selected" : "directory-selector"} aria-label="Select all Notes" disabled={busy} onClick={() => selectDirectory(null)}>All Notes</Button>
        {notes.filter(item => !item.directory_id).map(item => <Button key={item.note_id} disabled={busy} className={activeId === item.note_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</Button>)}
        {directories.map(directory => <div key={directory.directory_id}><Button className={selectedDirectoryId === directory.directory_id ? "directory-selector selected" : "directory-selector"} aria-label={`Select folder ${directory.name}`} disabled={busy} onClick={() => selectDirectory(directory.directory_id)}>{directory.name}</Button>{notes.filter(item => item.directory_id === directory.directory_id).map(item => <Button key={item.note_id} disabled={busy} className={activeId === item.note_id ? "selected" : ""} onClick={() => select(item)}>{item.title}</Button>)}</div>)}
      </div><Button className="notes-archive-toggle" onClick={() => setShowArchived(value => !value)}><Archive size={16} aria-hidden="true" />{showArchived ? "Hide archived" : `Archived Notes (${archived.length})`}</Button>
      {showArchived && <div className="archive-list">{archived.map(item => <div key={item.note_id}><span>{item.title}</span><Button disabled={!permissions.can_write || busy} onClick={() => void restoreNote(item.note_id).then(() => reload(item.note_id)).catch(problem => onError(message(problem)))}>Restore</Button></div>)}</div>}
    </section>;

  return <div className={`notes-layout${agentCollapsed ? " agent-collapsed" : ""}`}>
    {sidebarHost && createPortal(navigation, sidebarHost)}
    <section className="note-panel">{active && draft ? <>
      <header className="note-actionbar"><span className="breadcrumb">{space.name} / Notes</span><div className="note-actions"><span role="status" aria-label="Note save status" className={dirty ? "unsaved" : "saved"}>{saveState}</span>{(saveState.includes("conflict") || saveState.includes("out of date")) && <Button className="secondary" disabled={busy} onClick={() => { noteDrafts.delete(draftKey(active.note_id)); void reload(active.note_id).catch(problem => onError(message(problem))); }}>Discard draft and reload</Button>}<Button className="secondary" disabled={busy} onClick={() => void showVersions()}>Versions</Button><Button className="secondary" disabled={!permissions.can_write || busy || Boolean(agentPreview)} onClick={() => void archive()}>Archive</Button><Button className="primary" disabled={!permissions.can_write || !dirty || busy || Boolean(agentPreview)} onClick={() => void save()}>Save Note</Button><Button className="note-agent-toggle" type="button" aria-label={agentCollapsed ? "Show Note Agent" : "Hide Note Agent"} title={agentCollapsed ? "Show Note Agent" : "Hide Note Agent"} aria-expanded={!agentCollapsed} aria-controls="note-agent-panel" onClick={toggleAgent}>{agentCollapsed ? <PanelRightOpen size={18} aria-hidden="true" /> : <PanelRightClose size={18} aria-hidden="true" />}</Button></div></header>
      <div className={`note-paper${agentPreview ? " note-paper-preview" : ""}`}>{agentPreview && <div className="note-preview-banner" role="status">Proposed changes · Review before saving</div>}<select aria-label="Note folder" value={draft.directoryId ?? ""} disabled={!permissions.can_write || busy || Boolean(agentPreview)} onChange={event => change({ directoryId: event.target.value || null })}><option value="">All Notes</option>{directories.map(item => <option key={item.directory_id} value={item.directory_id}>{item.name}</option>)}</select><Input className="note-title h-auto rounded-none border-0 px-0 py-0 text-[clamp(32px,3.5vw,43px)] font-[640] shadow-none md:text-[clamp(32px,3.5vw,43px)]" aria-label="Note title" value={agentPreview?.proposal.preview.title ?? draft.title} readOnly={Boolean(agentPreview)} disabled={!permissions.can_write || busy} onChange={event => change({ title: event.target.value })} />
        <NoteEditor key={`${active.note_id}:${editorEpoch}:${agentPreview?.proposal.proposal_id ?? "draft"}`} note={{ ...active, document: agentPreview?.proposal.preview.document ?? draft.document }} collapsedSectionIds={collapsed} onCollapse={setCollapsed} onDocumentChange={document => change({ document })} readOnly={!permissions.can_write || busy || Boolean(agentPreview)} />
        {agentPreview?.controls}
      </div>
    </> : <div className="empty-state"><span className="empty-mark">✦</span><h2>No Notes in {selectedLocationName}</h2><p>Create a Note here to organize content for your personal or team space.</p><Button className="primary" disabled={!permissions.can_write || busy} onClick={() => void makeNote()}>Create Note in {selectedLocationName}</Button></div>}</section>
    {active && <NoteAgent key={active.note_id} note={active} dirty={dirty} canWrite={permissions.can_write} onSave={save} onAccepted={acceptedAgentEdit} onError={onError} onCollapse={toggleAgent} onPreview={receiveAgentPreview} />}
    {versions && <Modal className="max-w-[650px]" title="Version history" onClose={() => setVersions(null)}><div className="card-heading"><h3>Version history</h3><Button className="icon-button" aria-label="Close version history" onClick={() => setVersions(null)}>×</Button></div><div className="version-list">{versions.map(item => <div key={item.version_id}><div><strong>Version {item.revision} · {item.title}</strong><small>{new Date(item.created_at).toLocaleString("en-US")}</small></div><Button className="secondary" disabled={!permissions.can_write} onClick={() => void restoreOldVersion(item)}>Restore</Button></div>)}</div></Modal>}
  </div>;
}
