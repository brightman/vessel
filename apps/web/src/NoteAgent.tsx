import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import {
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { Button } from "./components/controls";
import { PanelRightClose } from "lucide-react";
import {
  ApiError,
  getNoteAgentRun,
  acceptNoteProposal,
  cancelNoteAgentRun,
  listNoteProposals,
  noteAgentStatus,
  rejectNoteProposal,
  startNoteAgentRun,
  streamNoteAgentRun,
  type AgentMode,
  type NoteAgentRun,
  type NoteProposal,
  type NoteRecord,
} from "./api";
import { message } from "./App";
export type AgentPreview = { proposal: NoteProposal; controls: ReactNode };
type Props = {
  note: NoteRecord;
  dirty: boolean;
  canWrite: boolean;
  onSave: () => Promise<boolean>;
  onAccepted: (note: NoteRecord) => void;
  onError: (error: string) => void;
  onCollapse: () => void;
  onPreview: (preview: AgentPreview | null) => void;
};
type AgentProgress = { phase: "working" | "thinking" | "responding" | "tool_started" | "tool_completed"; tool?: "web_search" | "tool" };
function progressLabel(item: AgentProgress): string {
  if (item.phase === "thinking") return "Thinking";
  if (item.phase === "responding") return "Preparing a reply";
  if (item.phase === "tool_started") return item.tool === "web_search" ? "Searching the web" : "Using a tool";
  if (item.phase === "tool_completed") return item.tool === "web_search" ? "Web search complete" : "Tool complete";
  return "Working";
}
function failureDetail(item: NoteAgentRun): string | null {
  if (item.status === "connection_interrupted") return "The progress connection was interrupted. The Run may still be active; use Resume Run to check it.";
  if (item.status === "interrupted_max_rounds") return "The Agent reached its round limit before finishing. Try a smaller request or continue in a new message.";
  if (item.status === "interrupted_context_budget") return "The Note and conversation exceeded the model context. Shorten the request or work on a smaller section.";
  if (item.status === "interrupted_model_timeout") return "The model took too long to respond. Retry the request.";
  if (item.status === "cancelled" || item.failure_code === "AGENT_RUN_CANCELLED") return "The Run was stopped before it finished.";
  if (item.status === "timeout" || item.failure_code === "AGENT_RUN_TIMEOUT") return "The Agent timed out before finishing. Retry with a smaller request.";
  if (item.failure_code === "AGENT_THREAD_BUSY" || item.failure_code === "NOTE_AGENT_RUN_ACTIVE") return "Another Run is active for this Note. Resume or stop it before starting a new one.";
  if (item.failure_code === "NOTE_REVISION_CONFLICT") return "The Note changed while the Agent worked. Review the latest Note and ask again.";
  if (item.failure_code === "INVALID_AGENT_RESPONSE_JSON" || item.failure_code === "INVALID_AGENT_PROPOSAL_JSON") return "The Agent returned malformed JSON, so Vessel could not use the reply. Try asking again or make the request smaller.";
  if (item.failure_code === "INVALID_AGENT_RESPONSE_SCHEMA" || item.failure_code === "INVALID_AGENT_PROPOSAL_SCHEMA") return "The Agent reply did not match the required format. Try a more specific request.";
  if (item.failure_code === "AGENT_PLATFORM_RUN_START_FAILED" || item.failure_code === "AGENT_PLATFORM_RUN_UNAVAILABLE" || item.failure_code === "AGENT_EVENT_STREAM_INTERRUPTED") return "The Agent service could not complete this Run. Check the connection and retry.";
  if (item.failure_code || item.status === "failed") return "The Agent could not finish this request. Retry, or try a smaller request.";
  return null;
}
function safeSource(url: string) {
  try {
    return ["https:", "http:"].includes(new URL(url).protocol);
  } catch {
    return false;
  }
}
export function NoteAgent({
  note,
  dirty,
  canWrite,
  onSave,
  onAccepted,
  onError,
  onCollapse,
  onPreview,
}: Props) {
  const [input, setInput] = useState("");
  const [configured, setConfigured] = useState(false);
  const [online, setOnline] = useState<boolean | null>(null);
  const [loading, setLoading] = useState(true);
  const [conversation, setConversation] = useState<NoteAgentRun | null>(null);
  const [history, setHistory] = useState<NoteAgentRun[]>([]);
  const [proposals, setProposals] = useState<NoteProposal[]>([]);
  const [recoverable, setRecoverable] = useState<{
    run_id: string;
    mode: AgentMode;
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [showChanges, setShowChanges] = useState(false);
  const [invalidProposals, setInvalidProposals] = useState<string[]>([]);
  const [progress, setProgress] = useState<AgentProgress[]>([]);
  const runRef = useRef<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const keys = useRef(new Map<string, string>());
  const loaded = useRef(false);
  async function refreshProposals() {
    const result = await listNoteProposals(note.note_id);
    setProposals(result.proposals);
  }
  useEffect(() => {
    let alive = true;
    const refresh = async () => {
      try {
        const status = await noteAgentStatus(note.note_id);
        if (!alive) return;
        setConfigured(status.configured);
        setOnline(status.online);
        if (!runRef.current) {
          setRecoverable(status.active_run);
          if (!loaded.current) {
            setConversation(status.latest_run ?? null);
            loaded.current = true;
          }
          const list = await listNoteProposals(note.note_id);
          if (alive) setProposals(list.proposals);
        }
      } catch (error) {
        if (alive) {
          setOnline(false);
          onError(message(error));
        }
      } finally {
        if (alive) setLoading(false);
      }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 30000);
    return () => {
      alive = false;
      window.clearInterval(timer);
      abortRef.current?.abort();
    };
  }, [note.note_id, onError]);
  useEffect(() => {
    if (!busy) return;
    const start = Date.now();
    setElapsed(0);
    const timer = window.setInterval(
      () => setElapsed(Math.floor((Date.now() - start) / 1000)),
      1000,
    );
    return () => window.clearInterval(timer);
  }, [busy]);
  async function followRun(runId: string, controller: AbortController) {
    runRef.current = runId;
    setRecoverable(null);
    try {
      let finished = false;
      await streamNoteAgentRun(
        note.note_id,
        runId,
        (event) => {
          if (event.event_type === "done") finished = true;
          if (event.event_type === "progress") {
            const phase = event.payload.phase;
            if (["working", "thinking", "responding", "tool_started", "tool_completed"].includes(String(phase))) {
              const tool: AgentProgress["tool"] = event.payload.tool === "web_search" ? "web_search" : "tool";
              setProgress((items) => [...items, { phase: phase as AgentProgress["phase"], tool }].slice(-20));
            }
          }
        },
        controller.signal,
      );
      if (!finished && !controller.signal.aborted)
        throw new Error("Agent event stream ended before the Run finished");
      if (!controller.signal.aborted) {
        const result = await getNoteAgentRun(note.note_id, runId);
        setConversation(result);
        await refreshProposals();
      }
    } catch (error) {
      if (!controller.signal.aborted) {
        setRecoverable({ run_id: runId, mode: "auto" });
        setConversation((current) => current ? { ...current, status: "connection_interrupted", failure_code: error instanceof ApiError ? error.code : "AGENT_EVENT_STREAM_INTERRUPTED" } : current);
        onError(message(error));
      }
    } finally {
      runRef.current = null;
      if (abortRef.current === controller) abortRef.current = null;
      setBusy(false);
    }
  }
  async function send(prompt: string, optionId?: string) {
    if (
      !prompt.trim() ||
      busy ||
      recoverable ||
      !configured ||
      !online ||
      (dirty && !canWrite)
    )
      return;
    setBusy(true);
    if (dirty && !(await onSave())) {
      setBusy(false);
      return;
    }
    const continuation =
      conversation?.status === "completed" &&
      conversation.response?.type === "clarification" &&
      !conversation.answered_by_run_id
        ? {
            reply_to_run_id: conversation.run_id,
            ...(optionId ? { option_id: optionId } : {}),
          }
        : undefined;
    if (conversation) setHistory((items) => [...items, conversation]);
    setProgress([]);
    setConversation({
      run_id: "",
      mode: "auto",
      prompt,
      status: "starting",
      reply: null,
      response: null,
      failure_code: null,
    });
    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const result = await startNoteAgentRun(
        note.note_id,
        prompt,
        "auto",
        continuation,
      );
      setInput("");
      setConversation((current) =>
        current
          ? { ...current, run_id: result.run_id, status: "running" }
          : current,
      );
      await followRun(result.run_id, controller);
    } catch (error) {
      if (!controller.signal.aborted) {
        setConversation((current) =>
          current
            ? {
                ...current,
                status: "failed",
                failure_code: error instanceof ApiError ? error.code : "AGENT_PLATFORM_RUN_START_FAILED",
              }
            : current,
        );
        if (
          error instanceof ApiError &&
          error.code === "NOTE_AGENT_RUN_ACTIVE" &&
          error.detail &&
          typeof error.detail === "object" &&
          "run_id" in error.detail &&
          typeof error.detail.run_id === "string"
        )
          setRecoverable({ run_id: error.detail.run_id, mode: "auto" });
        onError(message(error));
      }
      setBusy(false);
    }
  }
  async function decide(proposal: NoteProposal, accept: boolean) {
    if (
      busy ||
      !canWrite ||
      (accept && (dirty || proposal.base_revision !== note.revision))
    )
      return;
    setBusy(true);
    try {
      if (accept) {
        const key =
          keys.current.get(proposal.proposal_id) ?? crypto.randomUUID();
        keys.current.set(proposal.proposal_id, key);
        const result = await acceptNoteProposal(
          note.note_id,
          proposal.proposal_id,
          key,
        );
        onPreview(null);
        onAccepted(result.note);
      } else {
        await rejectNoteProposal(note.note_id, proposal.proposal_id);
        onPreview(null);
      }
      keys.current.delete(proposal.proposal_id);
      setShowChanges(false);
      await refreshProposals();
    } catch (error) {
      onError(message(error));
      if (error instanceof ApiError && [403, 404, 409].includes(error.status)) {
        setInvalidProposals((items) => [...items, proposal.proposal_id]);
        onPreview(null);
      }
      await refreshProposals().catch(() => setProposals([]));
    } finally {
      setBusy(false);
    }
  }
  const proposal = proposals.find((item) => item.status === "ready") ?? null;
  const previewable =
    proposal &&
    canWrite &&
    !dirty &&
    !invalidProposals.includes(proposal.proposal_id) &&
    proposal.base_revision === note.revision;
  useEffect(() => {
    if (!previewable || !proposal) {
      onPreview(null);
      return;
    }
    onPreview({
      proposal,
      controls: (
        <>
          <div
            className="note-preview-actions"
            aria-label="Review proposed changes"
          >
            <span>Preview · unsaved</span>
            <Button
              className="secondary"
              disabled={busy}
              onClick={() => setShowChanges((value) => !value)}
            >
              {showChanges ? "Hide changes" : "View changes"}
            </Button>
            <Button
              className="secondary"
              disabled={busy || !canWrite}
              onClick={() => void decide(proposal, false)}
            >
              Reject
            </Button>
            <Button
              className="primary"
              disabled={
                busy ||
                dirty ||
                !canWrite ||
                proposal.base_revision !== note.revision
              }
              onClick={() => void decide(proposal, true)}
            >
              Accept changes
            </Button>
          </div>
          {showChanges && (
            <div className="note-change-comparison">
              <section aria-label="Before changes">
                <strong>Before</strong>
                <h3>{note.title}</h3>
                <pre>{note.markdown}</pre>
              </section>
              <section aria-label="After changes">
                <strong>After</strong>
                <h3>{proposal.preview.title}</h3>
                <pre>{proposal.preview.markdown}</pre>
              </section>
            </div>
          )}
        </>
      ),
    });
  }, [
    proposal,
    previewable,
    busy,
    dirty,
    canWrite,
    note.revision,
    note.title,
    note.markdown,
    showChanges,
    onPreview,
  ]);
  function card(item: NoteAgentRun, current: boolean) {
    const failure = failureDetail(item);
    return (
      <div className="note-agent-conversation" key={item.run_id || "new"}>
        <div className="note-agent-user">
          <span>You</span>
          <p>{item.prompt}</p>
        </div>
        <div className="note-agent-reply">
          <span>
            Note Agent ·{" "}
            {current && busy ? `Working · ${elapsed}s` : failure ? "Failed" : item.status === "completed" ? "Done" : item.status}
          </span>
          {current && progress.length > 0 && <ol className="note-agent-activity" aria-label="Agent activity" aria-live="polite">
            {progress.map((entry, index) => <li key={index}>{progressLabel(entry)}</li>)}
          </ol>}
          {failure ? <div className="note-agent-failure" role="alert"><p>{failure}</p>{item.failure_code && <code>{item.failure_code}</code>}</div> :
            <div className="note-agent-markdown"><ReactMarkdown remarkPlugins={[remarkGfm]} skipHtml>
              {item.response?.message || item.reply || (current && busy ? "Thinking…" : "")}
            </ReactMarkdown></div>}
          {item.response?.sources
            ?.filter((source) => safeSource(source.url))
            .map((source, index) => (
              <a
                className="note-agent-source"
                key={index}
                href={source.url}
                target="_blank"
                rel="noopener noreferrer"
              >
                {source.title} ↗
              </a>
            ))}
          {item.response?.type === "clarification" && (
            <div className="note-agent-options">
              {item.response.options?.map((option) => (
                <Button
                  className="secondary"
                  key={option.id}
                  disabled={
                    !current ||
                    busy ||
                    Boolean(recoverable) ||
                    Boolean(item.answered_by_run_id)
                  }
                  onClick={() => void send(option.label, option.id)}
                >
                  {option.label}
                </Button>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  }
  return (
    <aside className="note-agent" id="note-agent-panel" aria-label="Note Agent">
      <div className="note-agent-header">
        <div>
          <span className="eyebrow">NOTE AGENT</span>
          <div className="note-agent-status" role="status">
            <span
              className={`note-agent-status-dot ${online ? "online" : "offline"}`}
            />
            {online === null
              ? "Checking Agent…"
              : online
                ? "Agent online"
                : "Agent offline"}
          </div>
        </div>
        <Button
          className="note-agent-collapse"
          aria-label="Collapse Note Agent"
          onClick={onCollapse}
        >
          <PanelRightClose size={18} />
        </Button>
      </div>
      <div className="note-agent-scroll">
        {!conversation && (
          <div className="note-agent-intro">
            <p>
              Ask a question or describe an edit. Review changes directly in
              your Note before saving.
            </p>
          </div>
        )}
        {history.map((item) => card(item, false))}
        {conversation && card(conversation, true)}
        {busy && runRef.current && (
          <Button
            className="text-button"
            onClick={() =>
              void cancelNoteAgentRun(note.note_id, runRef.current!)
                .then(() => {
                  abortRef.current?.abort();
                  setBusy(false);
                  setConversation((current) =>
                    current ? { ...current, status: "cancelled" } : current,
                  );
                  void refreshProposals();
                })
                .catch((error) => onError(message(error)))
            }
          >
            Stop Run
          </Button>
        )}
        {recoverable && (
          <div className="note-agent-recover">
            <p>A previous Run may still be active.</p>
            <Button
              disabled={busy}
              onClick={() => {
                const controller = new AbortController();
                abortRef.current = controller;
                setBusy(true);
                void followRun(recoverable.run_id, controller);
              }}
            >
              Resume Run
            </Button>
            <Button
              disabled={busy}
              onClick={() =>
                void cancelNoteAgentRun(note.note_id, recoverable.run_id)
                  .then(() => {
                    setRecoverable(null);
                    void refreshProposals();
                  })
                  .catch((error) => onError(message(error)))
              }
            >
              Stop Run
            </Button>
          </div>
        )}
        {proposal && (
          <section
            className="note-agent-proposal"
            aria-label="Agent proposed changes"
          >
            <strong>Proposed changes</strong>
            <p>{proposal.summary}</p>
            {!previewable && (
              <>
                <p>
                  {dirty
                    ? "Save your draft to preview these changes."
                    : proposal.base_revision !== note.revision ||
                        invalidProposals.includes(proposal.proposal_id)
                      ? "This proposal is out of date. Ask the Agent to regenerate it."
                      : "Read-only access: changes cannot be applied."}
                </p>
                <Button className="primary" disabled>
                  Accept changes
                </Button>
                <Button
                  disabled={busy || !canWrite}
                  onClick={() => void decide(proposal, false)}
                >
                  Reject
                </Button>
              </>
            )}
          </section>
        )}
      </div>
      <form
        className="note-agent-composer"
        onSubmit={(event: FormEvent) => {
          event.preventDefault();
          void send(input.trim());
        }}
      >
        <textarea
          aria-label="Message Note Agent"
          value={input}
          onChange={(event) => setInput(event.target.value)}
          placeholder={
            proposal
              ? "Refine these changes or ask a question…"
              : "Ask anything or describe a change…"
          }
          disabled={
            busy || loading || !configured || !online || Boolean(recoverable)
          }
        />
        <div className="note-agent-composer-footer">
          <span>
            {dirty
              ? "Saves this Note before starting"
              : !configured
                ? "Agent gateway needs configuration"
                : !online
                  ? "Agent is offline"
                  : proposal
                    ? "Refinements use the current preview"
                    : "Changes need your approval"}
          </span>
          <Button
            className="primary"
            type="submit"
            disabled={
              !input.trim() ||
              busy ||
              loading ||
              !configured ||
              !online ||
              Boolean(recoverable) ||
              (dirty && !canWrite)
            }
          >
            {dirty ? "Save & Send" : "Send"}
          </Button>
        </div>
      </form>
    </aside>
  );
}
