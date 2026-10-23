import Foundation
// Standalone support types avoid pulling platform UI into the macOS executable.
struct SpeechDownloadProgress: Sendable { let fraction: Double; let completedBytes: Int64; let totalBytes: Int64 }
enum TranscriptionResourceError: Error { case invalidFiles, missing, http(Int) }
enum TranscriptionConfiguration { enum WhisperSize: String { case tiny } }
@main struct VoiceIdentityInferenceSmoke {
 static func main() async throws {
  let args = CommandLine.arguments
  let store = VoiceIdentityModelStore(root: URL(fileURLWithPath: args[1]), catalogURL: URL(fileURLWithPath: args[2]))
  try await store.download { _ in }
  try store.validate()
  let engine = VoiceEmbeddingEngine(store: store)
  let signal = (0..<64_000).map { i in Float(0.1 * sin(Double(i)*2 * .pi * 170/16_000) + 0.05 * sin(Double(i)*2 * .pi * 340/16_000)) }
  let a = try await engine.extract(samples: signal)
  let b = try await engine.extract(samples: signal)
  precondition(a.count == 256 && a.allSatisfy(\.isFinite))
  let norm = sqrt(a.reduce(Float(0)) { $0 + $1*$1 }); precondition(abs(norm-1) < 0.0001)
  precondition(zip(a,b).reduce(Float(0)) { $0 + $1.0*$1.1 } > 0.999)
  do { _ = try await engine.extract(samples: [.nan]); fatalError("accepted invalid audio") } catch {}
  await engine.unload()
  let metadata = store.folder.appendingPathComponent("metadata.json")
  let original = try Data(contentsOf: metadata)
  defer { try? original.write(to: metadata) }
  var damaged = original; damaged[0] ^= 1; try damaged.write(to: metadata)
  do { try store.validate(); fatalError("accepted checksum corruption") } catch {}
  try original.write(to: metadata)
  try store.validate()
  print("Real pinned WeSpeaker inference PASS; bytes=\(store.downloadBytes), shape=256 norm=\(norm)")
 }
}
