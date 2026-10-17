import { createContext, useContext, useRef, useState, type ReactNode } from "react";
import { Button, Input, Modal } from "./controls";

type Request = { message: string; kind: "confirm" | "prompt"; resolve: (value: string | boolean | null) => void };
type Dialogs = { confirm: (message: string) => Promise<boolean>; prompt: (message: string) => Promise<string | null> };
const Context = createContext<Dialogs | null>(null);
export function useDialogs() {
  const value = useContext(Context);
  if (!value) throw new Error("DialogsProvider is missing");
  return value;
}
export function DialogsProvider({ children }: { children: ReactNode }) {
  const [request, setRequest] = useState<Request | null>(null);
  const [value, setValue] = useState("");
  const pending = useRef(false);
  function ask(kind: Request["kind"], message: string) {
    if (pending.current) return Promise.resolve(null);
    pending.current = true;
    setValue("");
    return new Promise<string | boolean | null>(resolve => setRequest({ kind, message, resolve }));
  }
  function finish(result: string | boolean | null) {
    request?.resolve(result);
    pending.current = false;
    setRequest(null);
  }
  return <Context.Provider value={{ confirm: async message => (await ask("confirm", message)) === true, prompt: async message => { const result = await ask("prompt", message); return typeof result === "string" ? result : null; } }}>{children}{request && <Modal title={request.message} onClose={() => finish(null)}><h3>{request.message}</h3><form onSubmit={event => { event.preventDefault(); finish(request.kind === "prompt" ? value : true); }}>{request.kind === "prompt" && <Input aria-label={request.message} autoFocus value={value} onChange={event => setValue(event.target.value)} />}<div className="form-actions"><Button type="button" className="secondary" autoFocus={request.kind === "confirm"} onClick={() => finish(null)}>Cancel</Button><Button className="primary">Confirm</Button></div></form></Modal>}</Context.Provider>;
}
