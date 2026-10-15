import { Extension, type Editor } from "@tiptap/core";
import Suggestion, { exitSuggestion, type SuggestionProps } from "@tiptap/suggestion";

type SlashItem = { id: string; label: string; keywords: string };

const ITEMS: SlashItem[] = [
  { id: "paragraph", label: "Text", keywords: "text paragraph" },
  { id: "h1", label: "Heading 1", keywords: "heading title h1" },
  { id: "h2", label: "Heading 2", keywords: "heading title h2" },
  { id: "h3", label: "Heading 3", keywords: "heading title h3" },
  { id: "bullet", label: "Bulleted list", keywords: "bullet unordered list" },
  { id: "number", label: "Numbered list", keywords: "ordered numbered list" },
  { id: "checklist", label: "Checklist", keywords: "checkbox todo task" },
  { id: "quote", label: "Quote", keywords: "blockquote quotation" },
  { id: "code", label: "Code", keywords: "code block preformatted" },
  { id: "table", label: "Table", keywords: "grid rows columns" },
  { id: "image", label: "Image", keywords: "photo picture media" },
  { id: "divider", label: "Divider", keywords: "rule separator line" },
];

function applyItem(editor: Editor, range: { from: number; to: number }, item: SlashItem): void {
  const chain = editor.chain().focus().deleteRange(range);
  if (item.id === "h1") chain.setHeading({ level: 1 }).run();
  else if (item.id === "h2") chain.setHeading({ level: 2 }).run();
  else if (item.id === "h3") chain.setHeading({ level: 3 }).run();
  else if (item.id === "bullet") chain.toggleBulletList().run();
  else if (item.id === "number") chain.toggleOrderedList().run();
  else if (item.id === "checklist") chain.insertContent({ type: "taskList", content: [{ type: "taskItem", attrs: { checked: false }, content: [{ type: "paragraph" }] }] }).run();
  else if (item.id === "quote") chain.toggleBlockquote().run();
  else if (item.id === "code") chain.toggleCodeBlock().run();
  else if (item.id === "table") chain.insertTable({ rows: 1, cols: 2, withHeaderRow: false }).run();
  else if (item.id === "image") chain.insertContent({ type: "pagesImage" }).run();
  else if (item.id === "divider") chain.setHorizontalRule().run();
  else chain.setParagraph().run();
}

export function createSlashExtension(): Extension {
  return Extension.create({
    name: "pagesSlash",
    addProseMirrorPlugins() {
      return [
        Suggestion<SlashItem, SlashItem>({
          editor: this.editor,
          char: "/",
          items: ({ query }) => {
            const term = query.trim().toLowerCase();
            return ITEMS.filter(item => `${item.label} ${item.keywords}`.toLowerCase().includes(term));
          },
          command: ({ editor, range, props }) => applyItem(editor, range, props),
          render: () => {
            const menuElement = () => document.getElementById("slashMenu");
            let current: SuggestionProps<SlashItem, SlashItem> | null = null;
            let activeIndex = 0;

            const show = (props: SuggestionProps<SlashItem, SlashItem>) => {
              const menu = menuElement();
              if (!menu) return;
              current = props;
              activeIndex = Math.min(activeIndex, Math.max(0, props.items.length - 1));
              menu.setAttribute("role", "listbox");
              menu.innerHTML = "";
              if (!props.items.length) {
                const empty = document.createElement("div");
                empty.className = "slash-empty";
                empty.textContent = "No matching blocks";
                menu.append(empty);
              }
              props.items.forEach((item, index) => {
                const button = document.createElement("button");
                button.type = "button";
                button.id = `pages-slash-option-${index}`;
                button.setAttribute("role", "option");
                button.setAttribute("aria-selected", String(index === activeIndex));
                button.textContent = item.label;
                button.addEventListener("mousedown", event => event.preventDefault());
                button.addEventListener("click", () => {
                  props.command(item);
                  menu.hidden = true;
                });
                menu.append(button);
              });
              const rect = props.clientRect?.();
              menu.hidden = false;
              if (rect) {
                const edge = 8;
                const gap = 6;
                const below = window.innerHeight - rect.bottom - gap - edge;
                const above = rect.top - gap - edge;
                const aboveCaret = below < Math.min(menu.scrollHeight, 360) && above > below;
                const available = Math.max(80, aboveCaret ? above : below);
                menu.style.position = "fixed";
                menu.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - 320))}px`;
                menu.style.maxHeight = `${Math.min(520, available)}px`;
                const height = menu.getBoundingClientRect().height;
                const desiredTop = aboveCaret ? rect.top - gap - height : rect.bottom + gap;
                menu.style.top = `${Math.max(edge, Math.min(desiredTop, window.innerHeight - height - edge))}px`;
                menu.style.bottom = "auto";
              }
              if (props.items.length) props.editor.view.dom.setAttribute("aria-activedescendant", `pages-slash-option-${activeIndex}`);
              else props.editor.view.dom.removeAttribute("aria-activedescendant");
              menu.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: "nearest" });
            };

            return {
              onStart(props) {
                activeIndex = 0;
                show(props);
              },
              onUpdate(props) {
                activeIndex = 0;
                show(props);
              },
              onKeyDown({ event }) {
                const menu = menuElement();
                if (!menu || !current || event.isComposing) return false;
                if (event.key === "Escape") {
                  menu.hidden = true;
                  exitSuggestion(current.editor.view);
                  return true;
                }
                if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                  if (current.items.length) {
                    const delta = event.key === "ArrowDown" ? 1 : -1;
                    activeIndex = (activeIndex + delta + current.items.length) % current.items.length;
                    show(current);
                  }
                  return true;
                }
                if (event.key === "Enter" && current.items.length) {
                  current.command(current.items[activeIndex]);
                  menu.hidden = true;
                  return true;
                }
                return false;
              },
              onExit() {
                current = null;
                const menu = menuElement();
                if (menu) menu.hidden = true;
                document.getElementById("pageBody")?.removeAttribute("aria-activedescendant");
              },
            };
          },
        }),
      ];
    },
  });
}
