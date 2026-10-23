import { useDialogs } from "./components/dialogs";
import { DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem } from "./components/ui/dropdown-menu";
import { Button } from "./components/controls";
import { useEffect, useMemo, useRef, useState } from "react";
import type { Editor as TiptapEditor } from "@tiptap/core";
import { EditorContent, useEditor } from "@tiptap/react";
import { BubbleMenu } from "@tiptap/react/menus";
import StarterKit from "@tiptap/starter-kit";
import UniqueID from "@tiptap/extension-unique-id";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import { TableKit } from "@tiptap/extension-table";
import { CodeBlockTab } from "./editor/code-block-tab";
import { ImageBlock } from "./editor/image-block";
import { createSlashExtension } from "./editor/slash";
import { mountSectionControls } from "./editor/drag";
import { mountTableControls } from "./editor/table-controls";
import { resolveNoteAsset, type NoteRecord } from "./api";

type Props = {
  note: NoteRecord;
  collapsedSectionIds: string[];
  onCollapse: (ids: string[]) => void;
  onDocumentChange: (document: Record<string, unknown>) => void;
  readOnly: boolean;
};

function toEditorDocument(value: Record<string, unknown>): Record<string, unknown> {
  const visit = (node: Record<string, unknown>): Record<string, unknown> => {
    const attrs = node.attrs && typeof node.attrs === "object" ? { ...(node.attrs as Record<string, unknown>) } : undefined;
    if (attrs && attrs.block_id && !attrs["block-id"]) attrs["block-id"] = attrs.block_id;
    if (attrs) delete attrs.block_id;
    const content = Array.isArray(node.content)
      ? node.content.map(child => visit(child as Record<string, unknown>))
      : undefined;
    return {
      ...node,
      ...(node.type === "image" ? { type: "notesImage" } : {}),
      ...(attrs ? { attrs } : {}),
      ...(content ? { content } : {}),
    };
  };
  return visit(value);
}

function toApiDocument(value: Record<string, unknown>): Record<string, unknown> {
  const visit = (node: Record<string, unknown>): Record<string, unknown> => {
    const attrs = node.attrs && typeof node.attrs === "object" ? { ...(node.attrs as Record<string, unknown>) } : undefined;
    if (attrs && attrs["block-id"]) attrs.block_id = attrs["block-id"];
    if (attrs) delete attrs["block-id"];
    const content = Array.isArray(node.content)
      ? node.content.map(child => visit(child as Record<string, unknown>))
      : undefined;
    return { ...node, ...(attrs ? { attrs } : {}), ...(content ? { content } : {}) };
  };
  return { ...visit(value), schema_version: 1 };
}

function applyBlockStyle(editor: TiptapEditor, style: string): void {
  const chain = editor.chain().focus();
  if (style === "paragraph") chain.setParagraph().run();
  else if (style === "heading-1") chain.toggleHeading({ level: 1 }).run();
  else if (style === "heading-2") chain.toggleHeading({ level: 2 }).run();
  else if (style === "heading-3") chain.toggleHeading({ level: 3 }).run();
  else if (style === "bullet-list") chain.toggleBulletList().run();
  else if (style === "numbered-list") chain.toggleOrderedList().run();
  else if (style === "quote") chain.toggleBlockquote().run();
  else if (style === "code-block") chain.toggleCodeBlock().run();
}

export function NoteEditor({ note, collapsedSectionIds, onCollapse, onDocumentChange, readOnly }: Props) {
  const { prompt } = useDialogs();
  const styleChosen = useRef(false);
  const toolbarRef = useRef<HTMLDivElement>(null);
  const [styleMenuOpen, setStyleMenuOpen] = useState(false);
  const onChangeRef = useRef(onDocumentChange);
  const onCollapseRef = useRef(onCollapse);
  const sectionsRef = useRef<ReturnType<typeof mountSectionControls> | null>(null);
  onChangeRef.current = onDocumentChange;
  onCollapseRef.current = onCollapse;
  const initialContent = useMemo(() => toEditorDocument(note.document), []);
  const editorProps = useMemo(() => ({
    attributes: { id: "noteBody", class: "doc", "data-testid": "note-body", "aria-label": "Note document" },
  }), []);
  const extensions = useMemo(() => [
    StarterKit,
    TaskList,
    TaskItem,
    TableKit,
    CodeBlockTab,
    ImageBlock.configure({
      uploadAsset: null,
      resolveAsset: (contentUrl: string) => resolveNoteAsset(contentUrl),
    }),
    UniqueID.configure({
      attributeName: "block-id",
      types: ["paragraph", "heading", "blockquote", "bulletList", "orderedList", "codeBlock", "horizontalRule", "taskList", "table", "notesImage"],
    }),
    createSlashExtension(),
  ], []);
  const editor = useEditor({
    extensions,
    content: initialContent,
    editable: !readOnly,
    onUpdate: ({ editor: instance, transaction }) => {
      if (transaction.docChanged) onChangeRef.current(toApiDocument(instance.getJSON() as Record<string, unknown>));
    },
    editorProps,
  });
  useEffect(() => { editor?.setEditable(!readOnly); }, [editor, readOnly]);
  useEffect(() => {
    if (!editor) return;
    if (readOnly) return;
    const sections = mountSectionControls(editor);
    const tables = mountTableControls(editor);
    sectionsRef.current = sections;
    return () => { sectionsRef.current = null; sections.destroy(); tables.destroy(); };
  }, [editor, readOnly]);

  useEffect(() => {
    if (!editor) return;
    editor.commands.setContent(toEditorDocument(note.document), { emitUpdate: false });
  }, [editor, note.note_id]);

  useEffect(() => {
    if (!editor) return;
    sectionsRef.current?.setNote(
      note.note_id,
      collapsedSectionIds,
      true,
      ids => onCollapseRef.current(ids),
    );
  }, [editor, note.note_id, collapsedSectionIds]);

  return <div className="editor-canvas">
    <div id="sectionGutter" aria-label="Section controls" />
    <div className="editor-document"><EditorContent editor={editor} />
      {editor && !readOnly && <BubbleMenu
        editor={editor}
        pluginKey="vessel-selection-menu"
        updateDelay={0}
        options={{ placement: "top", strategy: "fixed", offset: 8, flip: true, shift: { padding: 12 }, onShow: () => {
          // Measure after React has committed the toolbar and its menu trigger.
          requestAnimationFrame(() => { if (!editor.isDestroyed) editor.commands.setMeta("vessel-selection-menu", "updatePosition"); });
        } }}
        shouldShow={({ editor: instance }) => {
          const selection = instance.state.selection;
          return instance.isEditable && !selection.empty && selection.$from.parent.inlineContent && selection.$to.parent.inlineContent;
        }}
      >
        <div ref={toolbarRef} className="selection-toolbar" data-testid="selection-toolbar" role="toolbar" aria-label="Selected text formatting" onMouseDown={event => event.preventDefault()}>
          <Button type="button" aria-label="Bold" aria-pressed={editor.isActive("bold")} onClick={() => editor.chain().focus().toggleBold().run()}><strong>B</strong></Button>
          <Button type="button" aria-label="Italic" aria-pressed={editor.isActive("italic")} onClick={() => editor.chain().focus().toggleItalic().run()}><em>I</em></Button>
          <Button type="button" aria-label="Underline" aria-pressed={editor.isActive("underline")} onClick={() => editor.chain().focus().toggleUnderline().run()}><u>U</u></Button>
          <Button type="button" aria-label="Strikethrough" aria-pressed={editor.isActive("strike")} onClick={() => editor.chain().focus().toggleStrike().run()}><s>S</s></Button>
          <Button type="button" aria-label="Inline code" aria-pressed={editor.isActive("code")} onClick={() => editor.chain().focus().toggleCode().run()}>&lt;/&gt;</Button>
          <Button type="button" aria-label="Link" onClick={async () => {
            const value = await prompt("Paste a link");
            if (!value) return;
            try {
              const url = new URL(value);
              if (["http:", "https:"].includes(url.protocol)) editor.chain().focus().setLink({ href: url.href }).run();
            } catch { /* Keep the current selection when the URL is invalid. */ }
          }}>↗</Button>
          <DropdownMenu open={styleMenuOpen} onOpenChange={setStyleMenuOpen}>
            <DropdownMenuTrigger asChild><Button type="button" aria-label="Text">Text⌄</Button></DropdownMenuTrigger>
            <DropdownMenuContent container={toolbarRef.current} aria-labelledby={undefined} aria-label="Text style" onCloseAutoFocus={event => { if (styleChosen.current) { event.preventDefault(); editor.commands.focus(); styleChosen.current = false; } }}>
              {[["paragraph", "Text"], ["heading-1", "Heading 1"], ["heading-2", "Heading 2"], ["heading-3", "Heading 3"], ["bullet-list", "Bulleted list"], ["numbered-list", "Numbered list"], ["quote", "Quote"], ["code-block", "Code block"]].map(([style, label]) => <DropdownMenuItem key={style} onSelect={() => { styleChosen.current = true; applyBlockStyle(editor, style); }}>{label}</DropdownMenuItem>)}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </BubbleMenu>}
    </div>
    <div id="slashMenu" className="slash-menu" role="listbox" aria-label="Insert block" hidden />
  </div>;
}
