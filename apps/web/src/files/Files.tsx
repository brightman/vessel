import { useCallback, useEffect, useState } from "react";
import type { Space, User } from "../api";
import { getRoot, listChildren, listItems, listShared, searchItems } from "./api";
import { Directory } from "./Directory";
import type { FileItem } from "./types";
import "./files.css";

type View = "mine" | "shared" | "trash";
type Props = { space: Space; user: User; onError: (message: string) => void };

export function Files({ space, onError }: Props) {
  const [view, setView] = useState<View>("mine");
  const [root, setRoot] = useState<FileItem | null>(null);
  const [folder, setFolder] = useState<FileItem | null>(null);
  const [sharedRoot, setSharedRoot] = useState<FileItem | null>(null);
  const [trail, setTrail] = useState<FileItem[]>([]);
  const [items, setItems] = useState<FileItem[]>([]);
  const [selected, setSelected] = useState<FileItem | null>(null);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [nameFilter, setNameFilter] = useState("");
  const [kindFilter, setKindFilter] = useState<"" | "file" | "folder">("");
  const [folderDrawer, setFolderDrawer] = useState(false);

  useEffect(() => {
    let live = true;
    void getRoot(space.space_id).then(result => { if (live) { setRoot(result.folder); setFolder(result.folder); } }).catch(error => { if (live) onError(String(error)); });
    return () => { live = false; };
  }, [space.space_id, onError]);

  const load = useCallback(async (next?: string) => {
    setLoading(true);
    try {
      const result = view === "shared" && !folder ? await listShared(next)
        : view === "shared" && folder ? await listChildren(folder.item_id, next, kindFilter || undefined)
          : nameFilter.trim() || kindFilter ? await searchItems(space.space_id, { ...(nameFilter.trim() ? { name_contains: nameFilter.trim() } : {}), ...(kindFilter ? { kind: kindFilter } : {}) }, next)
            : folder ? await listItems(space.space_id, folder.item_id, next, kindFilter || undefined) : { items: [], next_cursor: null };
      setItems(old => next ? [...old, ...result.items] : result.items);
      setCursor(result.next_cursor);
    } catch (error) { onError(String(error)); }
    finally { setLoading(false); }
  }, [view, folder, kindFilter, nameFilter, space.space_id, onError]);

  useEffect(() => { if (view !== "trash" && (folder || view === "shared")) { setItems([]); setCursor(null); setSelected(null); void load(); } }, [load, view, folder]);

  function switchView(next: View) {
    setView(next); setSelected(null); setCursor(null); setItems([]); setTrail([]); setNameFilter(""); setKindFilter("");
    setFolder(next === "mine" ? root : null); setSharedRoot(null); setFolderDrawer(false);
  }
  function open(item: FileItem) {
    if (item.kind === "folder") {
      if (view === "shared" && !folder) setSharedRoot(item);
      setTrail(current => [...current, item]); setFolder(item); setSelected(null); setFolderDrawer(false);
    } else setSelected(item);
  }
  function backTo(index: number) {
    if (index < 0) { setTrail([]); setFolder(view === "mine" ? root : null); }
    else { setFolder(trail[index]); setTrail(trail.slice(0, index + 1)); }
    setSelected(null);
  }
  return <div className="files-layout">
    <aside className={`files-rail ${folderDrawer ? "open" : ""}`} aria-label="Files 目录">
      <div className="files-rail-heading"><h2>Files</h2><button className="files-rail-close" onClick={() => setFolderDrawer(false)}>关闭</button></div>
      <button className={view === "mine" ? "active" : ""} onClick={() => switchView("mine")}>我的文件</button>
      <button className={view === "shared" ? "active" : ""} onClick={() => switchView("shared")}>共享给我</button>
      <button className={view === "trash" ? "active" : ""} onClick={() => switchView("trash")}>回收站</button>
      {view !== "trash" && trail.length > 0 && <div className="files-tree"><p>当前位置</p>{trail.map((node, index) => <button key={node.item_id} onClick={() => backTo(index)}>{node.name}</button>)}</div>}
    </aside>
    {folderDrawer && <button className="files-rail-shade" aria-label="关闭目录" onClick={() => setFolderDrawer(false)} />}
    <section className="files-main">
      <div className="files-toolbar"><button className="files-mobile-menu secondary" onClick={() => setFolderDrawer(true)}>目录</button><div className="files-breadcrumbs"><button onClick={() => backTo(-1)}>{view === "mine" ? "我的文件" : view === "shared" ? "共享给我" : "回收站"}</button>{trail.map((node, index) => <span key={node.item_id}> / <button onClick={() => backTo(index)}>{node.name}</button></span>)}</div></div>
      <div className="files-content"><header className="files-content-header"><div><small className="eyebrow">{space.name}</small><h2>{view === "mine" && !trail.length ? "我的文件" : view === "shared" && !trail.length ? "共享给我" : view === "trash" ? "回收站" : folder?.name}</h2></div></header>
        {view === "mine" && <div className="files-filters"><label>搜索名称<input value={nameFilter} onChange={event => setNameFilter(event.target.value)} placeholder="搜索当前空间" /></label><label>类型<select value={kindFilter} onChange={event => setKindFilter(event.target.value as typeof kindFilter)}><option value="">全部</option><option value="file">文件</option><option value="folder">文件夹</option></select></label></div>}
        {view === "shared" && sharedRoot && <p className="files-muted">仅显示已共享的文件夹内容。</p>}
        {view === "trash" ? <p className="files-empty">回收站正在载入。</p> : <Directory items={items} selectedId={selected?.item_id ?? null} loading={loading} nextCursor={cursor} onSelect={setSelected} onOpen={open} onMore={() => void load(cursor ?? undefined)} />}
      </div>
    </section>
  </div>;
}
