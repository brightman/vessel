// Platform-independent press rules. A native recorder must confirm start separately.
export class RecordingInteraction {
  constructor() { this.reset(); }
  reset() { this.phase = 'idle'; this.beganAt = 0; this.thoughtAt = 0; this.cancelOnRelease = false; }
  begin(time, isRecording) {
    if (this.phase !== 'idle') return;
    this.beganAt = time;
    this.cancelOnRelease = false;
    this.phase = isRecording ? 'longRecording' : 'arming';
  }
  move(x, y) {
    if (this.phase === 'thought') this.cancelOnRelease = y < -35;
    else if ((this.phase === 'arming' || this.phase === 'longRecording') && Math.sqrt(x * x + y * y) > 25) this.phase = 'moved';
  }
  hold(time) {
    if (this.phase !== 'arming' || time - this.beganAt < 450) return null;
    this.phase = 'thought'; this.thoughtAt = time;
    return 'startThought';
  }
  end(time) {
    let result = null;
    if (this.phase === 'arming' && time - this.beganAt < 450) result = 'startLong';
    else if (this.phase === 'longRecording' && time - this.beganAt < 450) result = 'stopLong';
    else if (this.phase === 'thought') result = this.cancelOnRelease ? 'cancelThought' : time - this.thoughtAt < 300 ? 'discardShortThought' : 'saveThought';
    this.reset();
    return result;
  }
  interrupt() { const result = this.phase === 'thought' ? 'cancelThought' : null; this.reset(); return result; }
}
