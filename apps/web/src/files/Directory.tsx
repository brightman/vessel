import type { FileItem } from "./types";

type Props = {
  items: FileItem[]; selectedId: string | null; loading: boolean; nextCursor: string | null;
  onSelect: (item: FileItem) => void; onOpen: (item: FileItem) => void; onMore: () => void;
};

const size = (item: FileItem) => item.kind === "folder" ? "—" : item.size_bytes == null ? "—" : new Intl.NumberFormat("zh-CN", { notation: "compact" }).format(item.size_bytes) + " B";
const date = (value: string) => new Date(value).toLocaleString("zh-CN", { dateStyle: "medium", timeStyle: "short" });

export function Directory({ items, selectedId, loading, nextCursor, onSelect, onOpen, onMore }: Props) {
  return <div className="files-table-wrap"><table className="files-table">
    <thead><tr><th>名称</th><th>类型</th><th>大小</th><th>修改时间</th></tr></thead>
    <tbody>{items.map(item => <tr key={item.item_id} tabIndex={0} aria-selected={selectedId === item.item_id}
      onClick={() => onSelect(item)} onDoubleClick={() => onOpen(item)}
      onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); onOpen(item); } if (event.key === " ") { event.preventDefault(); onSelect(item); } }}>
      <td><span className="file-glyph" aria-hidden="true">{item.kind === "folder" ? "▣" : "▤"}</span>{item.name}</td>
      <td>{item.kind === "folder" ? "文件夹" : item.content_type || "文件"}</td><td>{size(item)}</td><td>{date(item.updated_at)}</td>
    </tr>)}</tbody>
  </table>
  {!loading && items.length === 0 && <p className="files-empty">这里还没有文件。</p>}
  {loading && <p className="files-muted" role="status">正在加载…</p>}
  {nextCursor && <button className="secondary files-more" disabled={loading} onClick={onMore}>加载更多</button>}
  </div>;
}
