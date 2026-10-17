import { Button } from "../components/controls";
import type { FileItem } from "./types";

type Props = {
  items: FileItem[]; selectedId: string | null; loading: boolean; nextCursor: string | null;
  onSelect: (item: FileItem) => void; onOpen: (item: FileItem) => void; onMore: () => void;
};

const size = (item: FileItem) => item.kind === "folder" ? "—" : item.size_bytes == null ? "—" : new Intl.NumberFormat("en-US", { notation: "compact" }).format(item.size_bytes) + " B";
const date = (value: string) => new Date(value).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" });

export function Directory({ items, selectedId, loading, nextCursor, onSelect, onOpen, onMore }: Props) {
  return <div className="files-table-wrap"><table className="files-table">
    <thead><tr><th>Name</th><th>Type</th><th>Size</th><th>Modified</th></tr></thead>
    <tbody>{items.map(item => <tr key={item.item_id} data-file-row-id={item.item_id} tabIndex={0} aria-selected={selectedId === item.item_id}
      onClick={() => onSelect(item)} onDoubleClick={() => onOpen(item)}
      onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); onOpen(item); } if (event.key === " ") { event.preventDefault(); onSelect(item); } }}>
      <td><span className="file-glyph" aria-hidden="true">{item.kind === "folder" ? "▣" : "▤"}</span>{item.name}</td>
      <td>{item.kind === "folder" ? "Folder" : item.content_type || "File"}</td><td>{size(item)}</td><td>{date(item.updated_at)}</td>
    </tr>)}</tbody>
  </table>
  {!loading && items.length === 0 && <p className="files-empty">There are no files here yet.</p>}
  {loading && <p className="files-muted" role="status">Loading…</p>}
  {nextCursor && <Button className="secondary files-more" disabled={loading} onClick={onMore}>Load more</Button>}
  </div>;
}
