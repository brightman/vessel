import type { Editor } from "@tiptap/core";
import type { Node as PMNode } from "@tiptap/pm/model";
import { closeHistory } from "@tiptap/pm/history";

export type BlockInfo = { index: number; id: string; level: number; text: string; from: number; to: number };

export function documentBlocks(doc: PMNode): BlockInfo[] {
  const blocks: BlockInfo[] = [];
  let from = 0;
  doc.forEach((node, _offset, index) => {
    blocks.push({
      index,
      id: String(node.attrs["block-id"] ?? `block-${index}`),
      level: node.type.name === "heading" ? Number(node.attrs.level) : 0,
      text: node.textContent.trim(),
      from,
      to: from + node.nodeSize,
    });
    from += node.nodeSize;
  });
  return blocks;
}

export function sectionEnd(blocks: BlockInfo[], start: number): number {
  const level = blocks[start]?.level ?? 0;
  if (!level) return start + 1;
  for (let index = start + 1; index < blocks.length; index += 1) {
    if (blocks[index].level && blocks[index].level <= level) return index;
  }
  return blocks.length;
}

export function visibleBlockIndices(blocks: BlockInfo[], collapsed: ReadonlySet<string>): number[] {
  const visible: number[] = [];
  const headings: { level: number; collapsed: boolean }[] = [];
  for (const block of blocks) {
    if (block.level) while (headings.length && headings.at(-1)!.level >= block.level) headings.pop();
    if (!headings.some(heading => heading.collapsed)) visible.push(block.index);
    if (block.level) headings.push({ level: block.level, collapsed: collapsed.has(block.id) });
  }
  return visible;
}

export function moveBlockRange(editor: Editor, start: number, end: number, boundary: number): boolean {
  const blocks = documentBlocks(editor.state.doc);
  if (start < 0 || start >= end || end > blocks.length || boundary < 0 || boundary > blocks.length) return false;
  if (boundary >= start && boundary <= end) return false;
  const from = blocks[start].from;
  const to = blocks[end - 1].to;
  const target = boundary === blocks.length ? editor.state.doc.content.size : blocks[boundary].from;
  const content = editor.state.doc.slice(from, to).content;
  const transaction = closeHistory(editor.state.tr.delete(from, to));
  transaction.insert(target > to ? target - (to - from) : target, content);
  editor.view.dispatch(transaction);
  return true;
}
