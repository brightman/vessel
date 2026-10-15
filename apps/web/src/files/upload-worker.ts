import { createSha256 } from "./hash";

self.onmessage = async (event: MessageEvent<{ file: File }>) => {
  const file = event.data.file;
  const hasher = createSha256();
  try {
    for (let offset = 0; offset < file.size; offset += 4 * 1024 * 1024) {
      const bytes = new Uint8Array(await file.slice(offset, offset + 4 * 1024 * 1024).arrayBuffer());
      hasher.update(bytes);
      self.postMessage({ type: "progress", bytesDone: Math.min(file.size, offset + bytes.byteLength), bytesTotal: file.size });
    }
    self.postMessage({ type: "done", sha256: hasher.digestHex() });
  } catch { self.postMessage({ type: "error", code: "HASH_FAILED" }); }
};
