import Foundation

/// Offsets are Swift Character offsets into the unchanged original, including whitespace.
enum DaybookTextChunks {
    static let version = "sentence-600-overlap80-v1"
    struct Chunk { let start: Int; let end: Int; let snippet: String }
    static func plan(_ text: String) -> [Chunk] {
        let chars = Array(text)
        var chunks: [Chunk] = [], start = 0
        let punctuation: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n", "；", ";"]
        while start < chars.count {
            let ceiling = min(start + 600, chars.count)
            var end = ceiling
            if ceiling < chars.count, ceiling - start > 80,
               let boundary = (start + 80..<ceiling).last(where: { punctuation.contains(chars[$0]) }) {
                end = boundary + 1
            }
            chunks.append(Chunk(start: start, end: end, snippet: String(chars[start..<end])))
            if end == chars.count { break }
            start = max(start + 1, end - 80)
        }
        return chunks
    }
}
