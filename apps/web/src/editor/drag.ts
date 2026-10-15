import type { Editor } from "@tiptap/core";
import { documentBlocks, moveBlockRange, sectionEnd, visibleBlockIndices, type BlockInfo } from "./sections";

type PageState = { pageId: string; collapsed: Set<string>; editable: boolean; onCollapse: (ids: string[]) => void };
type ActiveDrag = { start: number; end: number; boundary: number | null };

export function mountSectionControls(editor: Editor) {
  const gutter = document.getElementById("sectionGutter")!;
  const indicator = document.createElement("div");
  indicator.dataset.testid = "drop-indicator";
  indicator.className = "section-drop-indicator";
  indicator.hidden = true;
  document.body.append(indicator);
  const menu = document.createElement("div");
  menu.className = "section-action-menu";
  menu.setAttribute("role", "menu");
  menu.setAttribute("aria-label", "Block actions");
  menu.hidden = true;
  document.body.append(menu);
  const visibilityStyle = document.createElement("style");
  visibilityStyle.dataset.pagesSectionVisibility = "";
  document.head.append(visibilityStyle);
  let page: PageState | null = null;
  let drag: ActiveDrag | null = null;
  let hovered = "";
  let suppressNextClick = false;
  let pointer: { x: number; y: number } | null = null;
  let scrollFrame = 0;

  const elements = () => Array.from(editor.view.dom.children) as HTMLElement[];

  function cancelDrag() {
    drag = null;
    pointer = null;
    if (scrollFrame) cancelAnimationFrame(scrollFrame);
    scrollFrame = 0;
    indicator.hidden = true;
    document.body.classList.remove("section-is-dragging");
  }

  function closeMenu() {
    menu.hidden = true;
    menu.replaceChildren();
  }

  function moveAdjacent(index: number, direction: -1 | 1) {
    const blocks = documentBlocks(editor.state.doc);
    const block = blocks[index];
    if (!block) return;
    const end = block.level ? sectionEnd(blocks, index) : index + 1;
    let boundary: number;
    if (direction < 0) {
      if (index === 0) return;
      boundary = index - 1;
      if (block.level) {
        while (boundary >= 0 && blocks[boundary].level !== block.level) {
          if (blocks[boundary].level && blocks[boundary].level < block.level) return;
          boundary -= 1;
        }
        if (boundary < 0) return;
      }
    } else {
      if (end >= blocks.length) return;
      const next = blocks[end];
      if (block.level && next.level !== block.level) return;
      boundary = next.level ? sectionEnd(blocks, end) : end + 1;
    }
    if (moveBlockRange(editor, index, end, boundary)) requestAnimationFrame(render);
  }

  function openMenu(handle: HTMLElement, index: number) {
    closeMenu();
    const rect = handle.getBoundingClientRect();
    menu.style.left = `${Math.min(rect.right + 8, window.innerWidth - 152)}px`;
    menu.style.top = `${Math.min(rect.top, window.innerHeight - 86)}px`;
    for (const [label, direction] of [["Move up", -1], ["Move down", 1]] as const) {
      const action = document.createElement("button");
      action.type = "button";
      action.setAttribute("role", "menuitem");
      action.textContent = label;
      action.addEventListener("click", () => {
        closeMenu();
        moveAdjacent(index, direction);
      });
      menu.append(action);
    }
    menu.hidden = false;
    menu.querySelector("button")?.focus();
  }

  function boundaryNear(clientY: number, blocks: BlockInfo[]): { index: number; y: number } | null {
    if (!page) return null;
    const children = elements();
    const visible = visibleBlockIndices(blocks, page.collapsed);
    const boundaries: { index: number; y: number }[] = [];
    for (const index of visible) {
      const rect = children[index]?.getBoundingClientRect();
      if (rect) boundaries.push({ index, y: rect.top });
    }
    const last = visible.at(-1);
    if (last !== undefined) {
      const rect = children[last]?.getBoundingClientRect();
      if (rect) boundaries.push({ index: last + 1, y: rect.bottom });
    }
    return boundaries
      .filter(boundary => !drag || boundary.index < drag.start || boundary.index > drag.end)
      .sort((a, b) => Math.abs(clientY - a.y) - Math.abs(clientY - b.y))[0] ?? null;
  }

  function updateDropTarget(clientX: number, clientY: number) {
    if (!drag) return;
    const body = editor.view.dom;
    const bodyRect = body.getBoundingClientRect();
    if (clientX < bodyRect.left - 48 || clientX > bodyRect.right + 16) {
      indicator.hidden = true;
      drag.boundary = null;
      return;
    }
    const blocks = documentBlocks(editor.state.doc);
    const children = elements();
    const first = children[drag.start]?.getBoundingClientRect();
    const last = children[drag.end - 1]?.getBoundingClientRect();
    if (first && last && clientY >= first.top && clientY <= last.bottom) {
      indicator.hidden = true;
      drag.boundary = null;
      return;
    }
    const target = boundaryNear(clientY, blocks);
    if (!target) {
      indicator.hidden = true;
      drag.boundary = null;
      return;
    }
    drag.boundary = target.index;
    indicator.style.left = `${bodyRect.left}px`;
    indicator.style.top = `${target.y - 1}px`;
    indicator.style.width = `${bodyRect.width}px`;
    indicator.hidden = false;
  }

  function autoScroll() {
    scrollFrame = 0;
    if (!drag || !pointer) return;
    const body = editor.view.dom;
    const scroller = body.closest(".editor, .document-panel");
    const scrollerRect = scroller?.getBoundingClientRect();
    if (!scroller || !scrollerRect || indicator.hidden) return;
    const delta = pointer.y < scrollerRect.top + 48 ? -16 : pointer.y > scrollerRect.bottom - 48 ? 16 : 0;
    if (!delta) return;
    const before = scroller.scrollTop;
    scroller.scrollBy(0, delta);
    if (scroller.scrollTop === before) return;
    updateDropTarget(pointer.x, pointer.y);
    scrollFrame = requestAnimationFrame(autoScroll);
  }

  function onPointerMove(event: PointerEvent) {
    if (!drag) return;
    pointer = { x: event.clientX, y: event.clientY };
    updateDropTarget(pointer.x, pointer.y);
    if (!scrollFrame) scrollFrame = requestAnimationFrame(autoScroll);
  }

  function onPointerUp(event: PointerEvent) {
    if (!drag) return;
    updateDropTarget(event.clientX, event.clientY);
    const { start, end, boundary } = drag;
    cancelDrag();
    if (boundary !== null) {
      suppressNextClick = true;
      setTimeout(() => { suppressNextClick = false; }, 0);
      moveBlockRange(editor, start, end, boundary);
    }
    requestAnimationFrame(render);
  }

  function onKeyDown(event: KeyboardEvent) {
    if (event.key === "Escape" && (drag || !menu.hidden)) {
      event.preventDefault();
      event.stopPropagation();
      cancelDrag();
      closeMenu();
    }
  }

  function onDocumentPointerDown(event: PointerEvent) {
    if (!menu.contains(event.target as Node)) closeMenu();
  }

  function render() {
    gutter.replaceChildren();
    if (!page) {
      visibilityStyle.textContent = "";
      return;
    }
    const body = editor.view.dom;
    const blocks = documentBlocks(editor.state.doc);
    const children = elements();
    const visible = new Set(visibleBlockIndices(blocks, page.collapsed));
    visibilityStyle.textContent = blocks
      .filter(block => !visible.has(block.index))
      .map(block => `#pageBody > :nth-child(${block.index + 1}) { display: none !important; }`)
      .join("\n");
    if (!page.editable) return;
    const gutterRect = gutter.getBoundingClientRect();
    for (const block of blocks) {
      const element = children[block.index];
      if (!element) continue;
      if (!visible.has(block.index)) continue;
      const rect = element.getBoundingClientRect();
      const top = rect.top - gutterRect.top + Math.max(0, (rect.height - 22) / 2);
      if (block.level && block.text) {
        const folded = page.collapsed.has(block.id);
        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "section-toggle";
        toggle.style.top = `${top}px`;
        toggle.textContent = folded ? "›" : "⌄";
        toggle.setAttribute("aria-label", `${folded ? "Expand" : "Collapse"} ${block.text}`);
        toggle.setAttribute("aria-expanded", String(!folded));
        toggle.addEventListener("click", () => {
          if (!page) return;
          if (page.collapsed.has(block.id)) page.collapsed.delete(block.id);
          else {
            page.collapsed.add(block.id);
            editor.commands.setTextSelection(block.from + 1);
          }
          page.onCollapse([...page.collapsed]);
          render();
        });
        gutter.append(toggle);
      }
      const handle = document.createElement("button");
      handle.type = "button";
      handle.className = `drag-handle${block.level ? " persistent" : ""}`;
      handle.style.top = `${top}px`;
      handle.textContent = "⠿";
      handle.setAttribute("aria-label", `Drag ${block.level ? "section" : "block"} ${block.text || "empty block"}`);
      if (!block.level && hovered !== block.id) handle.classList.add("drag-handle-idle");
      handle.addEventListener("pointerdown", event => {
        if (event.button !== 0) return;
        event.preventDefault();
        closeMenu();
        drag = { start: block.index, end: block.level ? sectionEnd(blocks, block.index) : block.index + 1, boundary: null };
        document.body.classList.add("section-is-dragging");
      });
      handle.addEventListener("click", () => {
        if (!suppressNextClick) openMenu(handle, block.index);
      });
      gutter.append(handle);
    }
  }

  function onPointerOver(event: PointerEvent) {
    if (drag || !page) return;
    const block = (event.target as Element).closest("#pageBody > *");
    const index = elements().indexOf(block as HTMLElement);
    const id = documentBlocks(editor.state.doc)[index]?.id ?? "";
    if (id === hovered) return;
    hovered = id;
    render();
  }

  editor.view.dom.addEventListener("pointerover", onPointerOver);
  document.addEventListener("pointermove", onPointerMove);
  document.addEventListener("pointerup", onPointerUp);
  document.addEventListener("pointercancel", cancelDrag);
  document.addEventListener("keydown", onKeyDown, true);
  document.addEventListener("pointerdown", onDocumentPointerDown, true);
  editor.on("update", () => requestAnimationFrame(render));
  window.addEventListener("resize", render);

  return {
    setPage(pageId: string, collapsedIds: string[], editable: boolean, onCollapse: (ids: string[]) => void) {
      cancelDrag();
      closeMenu();
      page = { pageId, collapsed: new Set(collapsedIds), editable, onCollapse };
      requestAnimationFrame(render);
    },
    refresh: render,
    destroy() {
      cancelDrag();
      gutter.replaceChildren();
      indicator.remove();
      menu.remove();
      visibilityStyle.remove();
      editor.view.dom.removeEventListener("pointerover", onPointerOver);
      document.removeEventListener("pointermove", onPointerMove);
      document.removeEventListener("pointerup", onPointerUp);
      document.removeEventListener("pointercancel", cancelDrag);
      document.removeEventListener("keydown", onKeyDown, true);
      document.removeEventListener("pointerdown", onDocumentPointerDown, true);
      window.removeEventListener("resize", render);
    },
  };
}
