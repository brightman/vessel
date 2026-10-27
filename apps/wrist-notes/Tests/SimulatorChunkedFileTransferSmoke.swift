import Foundation

@main struct SimulatorChunkedFileTransferSmoke {
    static func main() throws {
        let transferID = UUID()
        let envelope = Data(repeating: 0xE1, count: 384)
        let audio = Data((0..<130_000).map { UInt8($0 % 251) })
        let parts = try SimulatorChunkedFileTransfer.split(audio, envelope: envelope, transferID: transferID)
        precondition(parts.count == 3)
        precondition(parts.allSatisfy { $0.audio.count <= SimulatorChunkedFileTransfer.maximumPartSize })
        precondition(SimulatorChunkedFileTransfer.nextPart(afterAccepted: 0, total: 3) == 1,
                     "accepting a non-final part must advance to the next part")
        precondition(SimulatorChunkedFileTransfer.nextPart(afterAccepted: 2, total: 3) == nil,
                     "accepting the final part must complete the transfer")
        let wireParts = try parts.map { try SimulatorChunkedFileTransfer.Part(message: $0.message) }

        var assembler = SimulatorChunkedFileAssembler()
        let tail = try assembler.append(wireParts[2])
        let head = try assembler.append(wireParts[0])
        let duplicate = try assembler.append(wireParts[0])
        precondition(tail == nil && head == nil && duplicate == nil,
                     "out-of-order and identical duplicate parts must be harmless")
        let completed = try assembler.append(wireParts[1])
        precondition(completed?.envelope == envelope)
        precondition(completed?.audio == audio)
        let replay = try assembler.append(wireParts[1])
        precondition(replay == nil, "completed transfer state must be retired")

        let chunkID = UUID()
        let retryTransferID = SimulatorChunkedFileTransfer.transferID(for: chunkID)
        precondition(retryTransferID == chunkID, "a chunk retry must keep its transfer identity")
        let retryParts = try SimulatorChunkedFileTransfer.split(audio, envelope: envelope, transferID: retryTransferID)
        var retryAssembler = SimulatorChunkedFileAssembler()
        for part in retryParts.prefix(1) {
            let partial = try retryAssembler.append(part)
            precondition(partial == nil)
        }
        let retriedParts = try SimulatorChunkedFileTransfer.split(audio, envelope: envelope,
                                                                  transferID: SimulatorChunkedFileTransfer.transferID(for: chunkID))
        var resumed: (envelope: Data, audio: Data)?
        for part in retriedParts { resumed = try retryAssembler.append(part) ?? resumed }
        precondition(resumed?.envelope == envelope && resumed?.audio == audio,
                     "retrying an incomplete chunk must reuse the same assembler slot and complete")

        var renegotiatingAssembler = SimulatorChunkedFileAssembler()
        let oldBindingEnvelope = Data(repeating: 0x11, count: 384)
        let oldParts = try SimulatorChunkedFileTransfer.split(audio, envelope: oldBindingEnvelope,
                                                               transferID: retryTransferID)
        let oldPartial = try renegotiatingAssembler.append(oldParts[0])
        precondition(oldPartial == nil)
        renegotiatingAssembler.reset()
        let newBindingEnvelope = Data(repeating: 0x22, count: 384)
        let newParts = try SimulatorChunkedFileTransfer.split(audio, envelope: newBindingEnvelope,
                                                               transferID: retryTransferID)
        var renegotiated: (envelope: Data, audio: Data)?
        for part in newParts { renegotiated = try renegotiatingAssembler.append(part) ?? renegotiated }
        precondition(renegotiated?.envelope == newBindingEnvelope && renegotiated?.audio == audio,
                     "a new capability binding must discard stale partial parts for the same chunk ID")
        print("Simulator V2 file parts reassemble and deduplicate")
    }
}
