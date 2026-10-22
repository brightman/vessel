# WiseLife local speaker diarization

Approved scope: after recording, transcribe locally, identify speaker turns locally, show timestamped segments in Full text, rename speakers within one note. No cross-record identity, live diarization, server, or changes to Watch capture.

Implementation:
1. Backward-compatible optional transcript segments / speaker names / diarization state on VoiceNote. Preserve plain transcript for search and summaries. Editing a segment preserves timing; replacing whole text clears stale labels. Prevent asynchronous results overwriting edits.
2. Retain word timings from Whisper and Apple Speech. Align to local SpeakerKit turns by overlap, with unknown when unmatched; stable speaker numbering by first appearance. Keep diarization failure separate from successful ASR.
3. Pin WhisperKit/SpeakerKit 0.18.0 and swift-transformers 1.1.6. Share verified download machinery; ship immutable public model manifest for Pyannote W8A16 and PLDA. Existing ASR resource download bundles speaker models for both Apple and Whisper; no separate entry or toggle. Inference explicitly disables downloading.
4. Transcript sections in both detail views show time, speaker, text and allow renaming / segment text edits. Expose pending/processing/failure/retry messages. Preserve old notes and audio.
5. Verify migration, alignment, persistence/edit races/failure through Swift tests. Build iPhone/watch simulator workspace, exercise real model on a public short multi-speaker fixture, inspect simulator UI. Record physical iPhone performance as not tested.
