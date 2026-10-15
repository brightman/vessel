import { useEffect, useState, type FormEvent } from "react";
import { ApiError } from "../api";
import { commitMove, getItem, getItemPermissions, getRoot, listChildren, prepareMove, renameItem, trashItem } from "./api";
import type { ChangePreview, FileItem, FilePermissions } from "./types";

type Props = { item: FileItem; permissions: FilePermissions; spaceId: string; onSaved: () => void; onError: (text: string) => void };
type Mode = "rename" | "move" | "trash" | null;
const description = (error: unknown) => error instanceof ApiError ? `${error.code}${error.requestId ? ` · 请求 ${error.requestId}` : ""}` : error instanceof Error ? error.message : "请求失败";

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
      if (!access.permissions.can_create_children || isForbiddenDestination(folder)) { setError("目标目录不可写，或位于当前文件夹内。"); return; }
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
    {permissions.can_write && <button className="secondary" onClick={() => { setName(item.name); setMode("rename"); }}>重命名</button>}
    {permissions.can_move && <button className="secondary" onClick={() => setMode("move")}>移动</button>}
    {permissions.can_trash && <button className="secondary danger" onClick={() => setMode("trash")}>移入回收站</button>}
    {mode && <div className="modal-backdrop" onClick={() => setMode(null)}><div className="modal-card files-action-modal" role="dialog" aria-label={mode === "move" && preview ? "移动权限变化" : mode === "move" ? "选择移动位置" : mode === "rename" ? "重命名文件" : "移入回收站"} onClick={event => event.stopPropagation()}>
      <header><h3>{mode === "move" ? "移动文件" : mode === "rename" ? "重命名" : "移入回收站"}</h3><button className="icon-button" aria-label="关闭操作" onClick={() => setMode(null)}>×</button></header>
      {error && <p role="alert" className="error-banner">{error} <button onClick={() => mode === "move" ? void reloadAndPrepare() : (setPreview(null), setError(""))}>重新载入并再次预览</button></p>}
      {mode === "rename" && <form className="files-action-form" onSubmit={rename}><label>名称<input value={name} onChange={event => setName(event.target.value)} required /></label><button className="primary" disabled={busy}>保存名称</button></form>}
      {mode === "move" && <div className="files-action-form"><p>目标：{destination?.name ?? "正在加载…"}</p><div className="files-folder-picker"><button className="text-button" onClick={returnToRoot}>根目录</button><span>{browse?.name}</span>{folders.map(folder => <div key={folder.item_id}><span>{folder.name}</span><button className="text-button" disabled={isForbiddenDestination(folder)} title={isForbiddenDestination(folder) ? "不能移动到自身或子文件夹" : undefined} onClick={() => void pick(folder)}>选择 {folder.name}</button><button className="text-button" onClick={() => openFolder(folder)}>打开</button></div>)}{folderCursor && <button className="text-button" disabled={loadingFolders} onClick={() => void loadMoreFolders()}>加载更多目录</button>}</div><button className="secondary" disabled={!destination || busy} onClick={() => void prepare()}>预览移动</button>
        {preview && <div className="files-preview"><h4>权限变化</h4><p>新增来源：{preview.permission_changes.gained.length}；失去来源：{preview.permission_changes.lost.length}</p>{preview.permission_changes.gained.map(grant => <p key={grant.grant_id}>新增 {grant.grantee_user_id} · {grant.role}</p>)}{preview.permission_changes.lost.map(grant => <p key={grant.grant_id}>失去 {grant.grantee_user_id} · {grant.role}</p>)}<button className="primary" disabled={busy} onClick={() => void run(() => commitMove(item.item_id, preview))}>确认移动</button></div>}</div>}
      {mode === "trash" && <div className="files-action-form"><p>确认将“{item.name}”及其中的文件移入回收站？</p><button className="primary danger" disabled={busy} onClick={() => void run(() => trashItem(item))}>确认移入回收站</button></div>}
    </div></div>}
  </div>;
}
