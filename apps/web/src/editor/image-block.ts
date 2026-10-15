import { Node } from "@tiptap/core";

export const ImageBlock = Node.create({
  name: "pagesImage",
  group: "block",
  content: "inline*",
  draggable: true,
  addOptions() {
    return {
      uploadAsset: null as ((file: File) => Promise<{ content_url: string }>) | null,
      resolveAsset: async (src: string) => src,
    };
  },
  addAttributes() {
    return {
      src: {
        default: null,
        parseHTML: element => element.querySelector("img")?.getAttribute("src") ?? null,
      },
      alt: {
        default: "Page image",
        parseHTML: element => element.querySelector("img")?.getAttribute("alt") ?? "Page image",
      },
    };
  },
  parseHTML() {
    return [{ tag: 'figure[data-block-type="image"]', contentElement: "figcaption" }];
  },
  renderHTML({ node }) {
    const content = node.attrs.src
      ? [["img", { src: node.attrs.src, alt: node.attrs.alt }], ["figcaption", 0]]
      : [["figcaption", 0]];
    return ["figure", { "data-block-type": "image" }, ...content];
  },
  addNodeView() {
    const uploadAsset = this.options.uploadAsset;
    const resolveAsset = this.options.resolveAsset;
    return ({ node, editor, getPos }) => {
      const figure = document.createElement("figure");
      figure.dataset.blockType = "image";
      const caption = document.createElement("figcaption");
      caption.dataset.placeholder = "Add a caption";
      let objectUrl: string | null = null;
      let renderId = 0;
      let destroyed = false;

      const clearPreviousImage = () => {
        figure.querySelector(".image-picker, img, .image-loading, .image-error")?.remove();
        if (objectUrl) URL.revokeObjectURL(objectUrl);
        objectUrl = null;
      };

      const addImage = (src: string, alt: string, resolved: boolean) => {
        const image = document.createElement("img");
        image.src = src;
        image.alt = alt;
        figure.prepend(image);
        if (resolved && src.startsWith("blob:")) objectUrl = src;
      };

      const render = (src: string | null, alt: string) => {
        const currentRender = ++renderId;
        clearPreviousImage();
        if (src) {
          if (!src.startsWith("/v1/assets/")) {
            addImage(src, alt, false);
            return;
          }
          const loading = document.createElement("span");
          loading.className = "image-loading";
          loading.textContent = "Loading image…";
          figure.prepend(loading);
          void resolveAsset(src).then(resolved => {
            if (destroyed || currentRender !== renderId) {
              if (resolved.startsWith("blob:")) URL.revokeObjectURL(resolved);
              return;
            }
            loading.remove();
            addImage(resolved, alt, true);
          }).catch(() => {
            if (destroyed || currentRender !== renderId) return;
            loading.remove();
            const error = document.createElement("span");
            error.className = "image-error";
            error.textContent = "This image could not be loaded.";
            figure.prepend(error);
          });
          return;
        }
        const picker = document.createElement("div");
        picker.className = "image-picker";
        picker.contentEditable = "false";
        const input = document.createElement("input");
        input.type = "url";
        input.placeholder = "Paste image URL";
        input.setAttribute("aria-label", "Image URL");
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = "Add image";
        button.addEventListener("click", () => {
          let url: URL;
          try {
            url = new URL(input.value.trim());
          } catch {
            input.setCustomValidity("Enter a valid image URL");
            input.reportValidity();
            return;
          }
          if (!['http:', 'https:'].includes(url.protocol)) {
            input.setCustomValidity("Use an HTTP or HTTPS image URL");
            input.reportValidity();
            return;
          }
          const pos = typeof getPos === "function" ? getPos() : undefined;
          if (typeof pos !== "number") return;
          editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...node.attrs, src: url.href }));
        });

        const fileInput = document.createElement("input");
        fileInput.type = "file";
        fileInput.accept = "image/png,image/jpeg,image/gif,image/webp";
        fileInput.setAttribute("aria-label", "Upload image");
        fileInput.className = "image-file-input";
        const uploadButton = document.createElement("button");
        uploadButton.type = "button";
        uploadButton.textContent = "Upload file";
        uploadButton.disabled = !uploadAsset;
        const uploadStatus = document.createElement("span");
        uploadStatus.className = "image-upload-status";
        uploadStatus.setAttribute("role", "status");
        uploadButton.addEventListener("click", () => fileInput.click());
        fileInput.addEventListener("change", () => {
          const file = fileInput.files?.[0];
          if (!file || !uploadAsset) return;
          const blockId = node.attrs["block-id"];
          uploadButton.disabled = true;
          uploadStatus.textContent = "Uploading image…";
          void uploadAsset(file).then(asset => {
            let pos = typeof getPos === "function" ? getPos() : undefined;
            const pointsToThisBlock = (candidatePos: number | undefined) => {
              if (typeof candidatePos !== "number") return false;
              const candidate = editor.state.doc.nodeAt(candidatePos);
              return candidate?.type.name === "pagesImage"
                && (!blockId || candidate.attrs["block-id"] === blockId);
            };
            if (!pointsToThisBlock(pos) && blockId) {
              pos = undefined;
              editor.state.doc.descendants((candidate, candidatePos) => {
                if (candidate.type.name === "pagesImage" && candidate.attrs["block-id"] === blockId) {
                  pos = candidatePos;
                  return false;
                }
                return undefined;
              });
            }
            if (!pointsToThisBlock(pos)) throw new Error("Image block is no longer available");
            if (typeof pos !== "number") throw new Error("Image block is no longer available");
            editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, {
              ...node.attrs,
              src: asset.content_url,
              alt: file.name,
            }));
          }).catch(error => {
            uploadStatus.textContent = error instanceof Error ? `Upload failed: ${error.message}` : "Upload failed";
          }).finally(() => {
            uploadButton.disabled = false;
            fileInput.value = "";
          });
        });
        picker.append(input, button, fileInput, uploadButton, uploadStatus);
        figure.prepend(picker);
      };

      figure.append(caption);
      render(node.attrs.src, node.attrs.alt);
      return {
        dom: figure,
        contentDOM: caption,
        stopEvent(event) {
          return event.target instanceof globalThis.Node && Boolean(figure.querySelector(".image-picker")?.contains(event.target));
        },
        ignoreMutation(mutation) {
          return mutation.type !== "selection" && !caption.contains(mutation.target);
        },
        update(updated) {
          if (updated.type.name !== "pagesImage") return false;
          const changed = updated.attrs.src !== node.attrs.src || updated.attrs.alt !== node.attrs.alt;
          node = updated;
          if (changed) render(updated.attrs.src, updated.attrs.alt);
          return true;
        },
        destroy() {
          destroyed = true;
          renderId += 1;
          if (objectUrl) URL.revokeObjectURL(objectUrl);
        },
      };
    };
  },
});
