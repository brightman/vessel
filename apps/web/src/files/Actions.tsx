import { Modal, Button, Input } from "../components/controls";
import { useEffect, useState, type FormEvent } from "react";
import { ApiError } from "../api";
import { commitMove, getItem, getItemPermissions, getRoot, listChildren, prepareMove, renameItem, trashItem } from "./api";
import type { ChangePreview, FileItem, FilePermissions } from "./types";

type Props = { item: FileItem; permissions: FilePermissions; spaceId: string; onSaved: () => void; onError: (text: string) => void };
type Mode = "rename" | "move" | "trash" | null;
const description = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · Request ${error.requestId}` : ""}` : error instanceof Error ? error.message : "Request failed";

export function Actions({ item, permissions, spaceId, onSaved, onError }: Props) {
  const [mode, setMode] = useState<Mode>(null);
  const [name, setName] = useState(item.name);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [root, setRoot] = useState<FileItem | null>(null);
  const [browse, setBrowse] = useState<FileItem | null>(null);
  const [browseTrail, setBrowseTrail] = useState<FileItem[]>([]);
  const [folders, setFolders] = useState<FileItem[]>([]);
  const [folderCursor, setFolderCursor] = useState<string | null>(null);
  const [loadingFolders, setLoadingFolders] = useState(false);
  const [destination, setDestination] = useState<FileItem | null>(null);
  const [preview, setPreview] = useState<ChangePreview | null>(null);

  useEffect(() => {
    if (mode !== "move") return;
    let live = true;
    void getRoot(spaceId).then(result => {
      if (live) {
        setRoot(result.folder);
        setBrowse(result.folder);
        setBrowseTrail([result.folder]);
        setDestination(result.folder);
      }
    }).catch(problem => { if (live) setError(description(problem)); });
    return () => { live = false; };
  }, [mode, spaceId]);
  useEffect(() => {
    if (!browse || mode !== "move") return;
    let live = true;
    void listChildren(browse.item_id, undefined, "folder").then(result => {
      if (!live) return;
      setFolders(result.items);
      setFolderCursor(result.next_cursor);
    }).catch(problem => { if (live) setError(description(problem)); });
    return () => { live = false; };
  }, [browse, mode]);

  const run = async (work: () => Promise<unknown>) => {
    setBusy(true); setError("");
    try { await work(); setMode(null); setPreview(null); onSaved(); }
    catch (problem) { setError(description(problem)); onError(description(problem)); if (problem instanceof ApiError && problem.status === 409) setPreview(null); }
    finally { setBusy(false); }
  };
  const rename = (event: FormEvent) => { event.preventDefault(); void run(() => renameItem(item, name.trim())); };
  const isForbiddenDestination = (folder: FileItem) => folder.item_id === item.item_id || (item.kind === "folder" && browseTrail.some(node => node.item_id === item.item_id));
  const openFolder = (folder: FileItem) => {
    setBrowse(folder);
    setBrowseTrail(current => [...current, folder]);
  };
  const returnToRoot = () => {
    if (!root) return;
    setBrowse(root);
    setBrowseTrail([root]);
  };
  const pick = async (folder: FileItem) => {
    try {
      const access = await getItemPermissions(folder.item_id);
      if (!access.permissions.can_create_children || isForbiddenDestination(folder)) { setError("The destination cannot accept files, or it is inside the current folder."); return; }
      setDestination(folder); setPreview(null); setError("");
    } catch (problem) { setError(description(problem)); }
  };
  const prepare = async () => {
    if (!destination) return;
    setBusy(true); setError("");
    try { setPreview((await prepareMove(item, destination.item_id)).move); }
    catch (problem) { setPreview(null); setError(description(problem)); }
    finally { setBusy(false); }
  };
  const loadMoreFolders = async () => {
    if (!browse || !folderCursor) return;
    setLoadingFolders(true);
    try {
      const result = await listChildren(browse.item_id, folderCursor, "folder");
      setFolders(current => [...current, ...result.items]);
      setFolderCursor(result.next_cursor);
    } catch (problem) { setError(description(problem)); }
    finally { setLoadingFolders(false); }
  };
  const reloadAndPrepare = async () => {
    if (!destination) return;
    setBusy(true); setPreview(null); setError("");
    try {
      const fresh = (await getItem(item.item_id)).item;
      setPreview((await prepareMove(fresh, destination.item_id)).move);
    } catch (problem) { setError(description(problem)); }
    finally { setBusy(false); }
  };

  return <div className="files-actions">
    {permissions.can_write && <Button className="secondary" onClick={() => { setName(item.name); setMode("rename"); }}>Rename</Button>}
    {permissions.can_move && <Button className="secondary" onClick={() => setMode("move")}>Move</Button>}
    {permissions.can_trash && <Button className="secondary danger" onClick={() => setMode("trash")}>Move to Trash</Button>}
    {mode && <Modal title={mode === "move" && preview ? "Move permission changes" : mode === "move" ? "Select move destination" : mode === "rename" ? "Rename file" : "Move to Trash"} onClose={() => setMode(null)} className="files-action-modal">
      <header><h3>{mode === "move" ? "Move file" : mode === "rename" ? "Rename" : "Move to Trash"}</h3><Button className="icon-button" aria-label="Close action" onClick={() => setMode(null)}>×</Button></header>
      {error && <p role="alert" className="error-banner">{error} <Button onClick={() => mode === "move" ? void reloadAndPrepare() : (setPreview(null), setError(""))}>Reload and preview again</Button></p>}
      {mode === "rename" && <form className="files-action-form" onSubmit={rename}><label>Name<Input value={name} onChange={event => setName(event.target.value)} required /></label><Button className="primary" disabled={busy}>Save name</Button></form>}
      {mode === "move" && <div className="files-action-form"><p>Destination: {destination?.name ?? "Loading…"}</p><div className="files-folder-picker"><Button className="text-button" onClick={returnToRoot}>Root folder</Button><span>{browse?.name}</span>{folders.map(folder => <div key={folder.item_id}><span>{folder.name}</span><Button className="text-button" disabled={isForbiddenDestination(folder)} title={isForbiddenDestination(folder) ? "You cannot move an item into itself or one of its subfolders" : undefined} onClick={() => void pick(folder)}>Select {folder.name}</Button><Button className="text-button" onClick={() => openFolder(folder)}>Open</Button></div>)}{folderCursor && <Button className="text-button" disabled={loadingFolders} onClick={() => void loadMoreFolders()}>Load more folders</Button>}</div><Button className="secondary" disabled={!destination || busy} onClick={() => void prepare()}>Preview move</Button>
        {preview && <div className="files-preview"><h4>Permission changes</h4><p>Gained sources: {preview.permission_changes.gained.length}; lost sources: {preview.permission_changes.lost.length}</p>{preview.permission_changes.gained.map(grant => <p key={grant.grant_id}>Gained {grant.grantee_user_id} · {grant.role}</p>)}{preview.permission_changes.lost.map(grant => <p key={grant.grant_id}>Lost {grant.grantee_user_id} · {grant.role}</p>)}<Button className="primary" disabled={busy} onClick={() => void run(() => commitMove(item.item_id, preview))}>Confirm move</Button></div>}</div>}
      {mode === "trash" && <div className="files-action-form"><p>Move “{item.name}” and its contents to Trash?</p><Button className="primary danger" disabled={busy} onClick={() => void run(() => trashItem(item))}>Confirm move to Trash</Button></div>}
    </Modal>}
  </div>;
}
