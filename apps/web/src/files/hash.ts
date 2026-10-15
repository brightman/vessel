import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";

export function createSha256() {
  const hash = sha256.create();
  return { update: (bytes: Uint8Array<ArrayBuffer>) => { hash.update(bytes); }, digestHex: () => bytesToHex(hash.digest()) };
}
