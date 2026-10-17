import { useEffect, useRef, useState } from "react";
import { ApiError, requestRegistrationCode } from "./api";
import { Button, Input } from "./components/controls";

type Props = { email: string; onChallenge: (id: string | null) => void; describeError: (error: unknown) => string };

export function RegistrationEmail({ email, onChallenge, describeError }: Props) {
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [retryAt, setRetryAt] = useState(0);
  const [remaining, setRemaining] = useState(0);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const generation = useRef(0);
  const normalized = email.trim().toLowerCase();

  useEffect(() => {
    generation.current++;
    setCode(""); setNotice(""); setError(""); setRetryAt(0); setRemaining(0); setBusy(false);
    onChallenge(null);
    return () => { generation.current++; };
  }, [normalized, onChallenge]);

  useEffect(() => {
    const tick = () => setRemaining(Math.max(0, Math.ceil((retryAt - Date.now()) / 1000)));
    tick();
    if (!retryAt) return;
    const timer = window.setInterval(tick, 1000);
    return () => window.clearInterval(timer);
  }, [retryAt]);

  async function sendCode() {
    if (busy || Date.now() < retryAt) return;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) { setError("Enter a valid email address first."); return; }
    const current = generation.current;
    setBusy(true); setError("");
    try {
      const result = await requestRegistrationCode(normalized);
      if (current !== generation.current) return;
      onChallenge(result.challenge_id);
      setCode("");
      setRetryAt(Date.now() + result.resend_after * 1000);
      setNotice(`Check your inbox for a 6-digit code. It expires in ${Math.ceil(result.expires_in / 60)} minutes.`);
    } catch (problem) {
      if (current !== generation.current) return;
      setError(describeError(problem));
      if (problem instanceof ApiError && (problem.status === 429 || problem.status === 503)) setRetryAt(Date.now() + (problem.retryAfter ?? 60) * 1000);
    } finally { if (current === generation.current) setBusy(false); }
  }

  return <div className="registration-email-fields">
    <label>Verification code<Input name="verification_code" value={code} onChange={event => setCode(event.target.value)} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" minLength={6} maxLength={6} required aria-describedby="registration-email-notice" /></label>
    <Button type="button" className="secondary" disabled={busy || remaining > 0} onClick={() => void sendCode()}>{busy ? "Sending…" : remaining > 0 ? `Resend in ${remaining}s` : notice ? "Resend code" : "Send code"}</Button>
    <p id="registration-email-notice" role="status" className="hint" aria-live="polite">{notice || "Verify your email before creating an account."}</p>
    {error && <p role="alert" className="error-banner">{error}</p>}
  </div>;
}
