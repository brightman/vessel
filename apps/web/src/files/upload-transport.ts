import type { Upload, UploadInstruction } from "./types";

export type PartReceipt = { part_number: number; etag: string };
export type Signer = (numbers: number[]) => Promise<UploadInstruction[]>;
export type Put = (url: string, init: RequestInit) => Promise<Response>;
export type Progress = (done: number, total: number) => void;

export async function putSignedParts(file: Blob, upload: Pick<Upload, "transfer_mode" | "part_count" | "part_size_bytes">, sign: Signer, put: Put, progress: Progress, signal: AbortSignal): Promise<PartReceipt[]> {
  const receipts: PartReceipt[] = [];
  let done = 0;
  for (let batchStart = 1; batchStart <= upload.part_count; batchStart += 20) {
    const numbers = Array.from({ length: Math.min(20, upload.part_count - batchStart + 1) }, (_, index) => batchStart + index);
    const instructions = await sign(numbers);
    const byNumber = new Map(instructions.map(instruction => [instruction.part_number, instruction]));
    for (let offset = 0; offset < numbers.length; offset += 3) {
      const group = numbers.slice(offset, offset + 3);
      const completed = await Promise.all(group.map(async partNumber => {
        const instruction = byNumber.get(partNumber);
        if (!instruction || instruction.method !== "PUT" || new Date(instruction.expires_at).getTime() <= Date.now()) throw new Error("UPLOAD_SIGNING_EXPIRED");
        const start = (partNumber - 1) * upload.part_size_bytes;
        const slice = file.slice(start, Math.min(file.size, start + upload.part_size_bytes));
        if (slice.size !== instruction.size_bytes) throw new Error("UPLOAD_PART_SIZE_MISMATCH");
        const response = await put(instruction.url, { method: "PUT", headers: instruction.headers, body: slice, credentials: "omit", signal });
        if (!response.ok) throw new Error(`OSS_UPLOAD_${response.status}`);
        const etag = response.headers.get("ETag");
        if (upload.transfer_mode === "multipart" && !etag) throw new Error("OSS_ETAG_NOT_EXPOSED");
        done += slice.size; progress(done, file.size);
        return { part_number: partNumber, etag: etag ?? "" };
      }));
      receipts.push(...completed);
    }
  }
  return receipts.sort((a, b) => a.part_number - b.part_number);
}
