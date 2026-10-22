import Foundation

/// A half-open range of one input buffer assigned to a single physical chunk.
struct RecordingFrameSlice: Equatable {
    let ordinal: Int
    let inputOffset: Int64
    let frameCount: Int64
    let chunkOffset: Int64
}

enum RecordingFramePartition {
    enum PartitionError: Error, Equatable {
        case invalidFrameRange
        case invalidChunkCapacity
        case overflow
    }

    /// Work is proportional to the number of chunks touched, never to the frame count.
    static func split(inputStartFrame: Int64, frameCount: Int64,
                      framesPerChunk: Int64) throws -> [RecordingFrameSlice] {
        guard inputStartFrame >= 0, frameCount >= 0 else { throw PartitionError.invalidFrameRange }
        guard framesPerChunk > 0 else { throw PartitionError.invalidChunkCapacity }
        guard !inputStartFrame.addingReportingOverflow(frameCount).overflow else { throw PartitionError.overflow }
        var cursor = inputStartFrame
        var inputOffset: Int64 = 0
        var remaining = frameCount
        var slices: [RecordingFrameSlice] = []
        while remaining > 0 {
            guard let ordinal = Int(exactly: cursor / framesPerChunk) else { throw PartitionError.overflow }
            let chunkOffset = cursor % framesPerChunk
            let take = min(framesPerChunk - chunkOffset, remaining)
            slices.append(.init(ordinal: ordinal, inputOffset: inputOffset, frameCount: take, chunkOffset: chunkOffset))
            cursor += take
            inputOffset += take
            remaining -= take
        }
        return slices
    }
}
