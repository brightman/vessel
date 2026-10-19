import Foundation

@main
struct RecordingButtonInteractionSmoke {
    static func main() {
        var press = RecordingButtonInteraction()
        press.begin(at: 0, isRecording: false)
        precondition(press.end(at: 0.1) == .startLong)

        press.begin(at: 1, isRecording: true)
        precondition(press.recognizeHold(at: 1.5) == nil)
        precondition(press.end(at: 2) == nil, "Holding must not stop a long recording")
        press.begin(at: 3, isRecording: true)
        precondition(press.end(at: 3.1) == .stopLong)

        press.begin(at: 4, isRecording: false)
        precondition(press.recognizeHold(at: 4.45) == .startThought)
        precondition(press.end(at: 5.0) == .saveThought)
        precondition(press.end(at: 5.1) == nil, "Release cannot also start a long recording")

        press.begin(at: 6, isRecording: false)
        _ = press.recognizeHold(at: 6.5)
        precondition(press.end(at: 6.6) == .discardShortThought)

        press.begin(at: 7, isRecording: false)
        _ = press.recognizeHold(at: 7.5)
        press.move(x: 0, y: -40)
        precondition(press.end(at: 8) == .cancelThought)

        press.begin(at: 9, isRecording: false)
        press.move(x: 40, y: 0)
        precondition(press.recognizeHold(at: 9.5) == nil)
        precondition(press.end(at: 10) == nil, "Dragging before hold recognition cancels the press")

        press.begin(at: 11, isRecording: false)
        _ = press.recognizeHold(at: 11.5)
        precondition(press.interrupt() == .cancelThought)
        precondition(press.end(at: 12) == nil)
        print("Recording button interaction: 8 scenarios passed")
    }
}
