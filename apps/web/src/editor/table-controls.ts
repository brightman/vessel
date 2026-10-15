import type { Editor } from "@tiptap/core";

export function mountTableControls(editor: Editor): { destroy(): void; refresh(): void } {
  const toolbar = document.createElement("div");
  toolbar.className = "table-controls";
  toolbar.setAttribute("role", "toolbar");
  toolbar.setAttribute("aria-label", "Table controls");
  toolbar.hidden = true;

  const actions = [
    { label: "Add row below", command: () => editor.chain().focus().addRowAfter().run() },
    { label: "Delete row", command: () => editor.chain().focus().deleteRow().run() },
    { label: "Add column right", command: () => editor.chain().focus().addColumnAfter().run() },
    { label: "Delete column", command: () => editor.chain().focus().deleteColumn().run() },
  ];
  for (const action of actions) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = action.label;
    button.setAttribute("aria-label", action.label);
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      if (!editor.isEditable) return;
      action.command();
      refresh();
    });
    toolbar.append(button);
  }
  document.body.append(toolbar);

  function selectedTable(): HTMLElement | null {
    if (!editor.isEditable) return null;
    const { $from } = editor.state.selection;
    for (let depth = $from.depth; depth > 0; depth--) {
      if ($from.node(depth).type.name !== "table") continue;
      const dom = editor.view.nodeDOM($from.before(depth));
      if (!(dom instanceof HTMLElement)) return null;
      return dom.matches("table") ? dom : dom.querySelector("table");
    }
    return null;
  }

  function refresh(): void {
    const table = selectedTable();
    toolbar.hidden = !table;
    if (!table) return;
    const rect = table.getBoundingClientRect();
    const width = toolbar.getBoundingClientRect().width;
    toolbar.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`;
    const above = rect.top - toolbar.offsetHeight - 8;
    toolbar.style.top = `${above >= 8 ? above : Math.min(rect.bottom + 8, window.innerHeight - toolbar.offsetHeight - 8)}px`;
  }

  editor.on("selectionUpdate", refresh);
  editor.on("transaction", refresh);
  window.addEventListener("scroll", refresh, true);
  window.addEventListener("resize", refresh);
  return {
    refresh,
    destroy() {
      editor.off("selectionUpdate", refresh);
      editor.off("transaction", refresh);
      window.removeEventListener("scroll", refresh, true);
      window.removeEventListener("resize", refresh);
      toolbar.remove();
    },
  };
}
