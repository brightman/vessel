import { Extension } from "@tiptap/core";

export const CodeBlockTab = Extension.create({
  name: "codeBlockTab",
  priority: 1000,
  addKeyboardShortcuts() {
    return {
      Tab: () => this.editor.isActive("codeBlock") && this.editor.commands.insertContent("  "),
    };
  },
});
