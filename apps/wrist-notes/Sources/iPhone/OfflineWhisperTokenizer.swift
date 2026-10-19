// Adapted from WhisperKit's WhisperTokenizerWrapper (MIT).
// Copyright (c) 2024 argmax, inc.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import NaturalLanguage
import Tokenizers
import WhisperKit

/// The public WhisperKit wrapper has no public initializer in 0.15.0.
/// This adapter accepts only a tokenizer already decoded from verified local files.
final class OfflineWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: any Tokenizer) throws {
        func token(_ name: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(name) else { throw TranscriptionResourceError.invalidFiles }
            return value
        }
        specialTokens = try SpecialTokens(
            endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
            whitespaceToken: token("Ġ"))
        allLanguageTokens = try Set(TranscriptionConfiguration.whisperLanguageCodes.map { try token("<|\($0)|>") })
        self.tokenizer = tokenizer
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decoded = decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decoded)
        let separateCharacters = ["zh", "ja", "th", "lo", "my", "yue"].contains(recognizer.dominantLanguage?.rawValue ?? "")
        let fullScalars = Array(decode(tokens: tokenIds).unicodeScalars)
        var scalarOffset = 0
        var pending: [Int] = [], words: [String] = [], wordTokens: [[Int]] = []
        for id in tokenIds {
            pending.append(id)
            let piece = decode(tokens: pending)
            let scalars = Array(piece.unicodeScalars)
            // Byte-level tokens can split a Unicode character. Wait until complete;
            // preserve an actual replacement character present in the full text.
            let complete = scalars.enumerated().allSatisfy { offset, scalar in
                scalar.value != 0xfffd || (scalarOffset + offset < fullScalars.count && fullScalars[scalarOffset + offset].value == 0xfffd)
            }
            guard complete else { continue }
            let stripped = piece.trimmingCharacters(in: .whitespaces)
            let punctuation = !stripped.isEmpty && stripped.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if separateCharacters || words.isEmpty || (pending.first ?? 0) >= specialTokens.specialTokenBegin || piece.hasPrefix(" ") || punctuation {
                words.append(piece); wordTokens.append(pending)
            } else {
                words[words.count - 1] += piece
                wordTokens[wordTokens.count - 1].append(contentsOf: pending)
            }
            scalarOffset += scalars.count
            pending = []
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); wordTokens.append(pending) }
        return (words, wordTokens)
    }
}
