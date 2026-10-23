import { useEffect, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import "./site.css";
import "../../web/src/ui.css";
import { Button } from "../../web/src/components/ui/button";

type StorageCardProps = {
  index: string;
  name: string;
  eyebrow: string;
  title: string;
  description: string;
  examples: string[];
};

function Mark() {
  return <span className="mark" aria-hidden="true"><i /><i /><i /></span>;
}

function PrimaryLink({ children, className = "", href = "/register" }: { children: ReactNode; className?: string; href?: string }) {
  return <Button asChild className={`site-action button button-primary h-11 rounded-md px-5 text-xs font-semibold shadow-none bg-[var(--cta-bg)] hover:bg-[var(--cta-hover)] text-[var(--white)] focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--paper)] ${className}`.trim()}><a href={href}>{children}</a></Button>;
}

function SectionLabel({ children }: { children: ReactNode }) {
  return <p className="section-label">{children}</p>;
}

function StorageCard({ index, name, eyebrow, title, description, examples }: StorageCardProps) {
  return <article className="storage-card">
    <div className="storage-card-head"><span>{index}</span></div>
    <h3>{name}</h3>
    <p className="storage-eyebrow">{eyebrow}</p>
    <p className="storage-title">{title}</p>
    <p className="storage-copy">{description}</p>
    <ul>{examples.map(example => <li key={example}>{example}</li>)}</ul>
  </article>;
}

function DataCanvas() {
  return <div className="data-canvas" aria-label="A conceptual view of data organized in Karama.Cloud">
      <div className="canvas-topline"><span className="canvas-live"><i /> Concept preview</span><span>CLI connection</span></div>
    <div className="canvas-flow">
      <div className="prompt-card"><p>Codex prompt</p><strong>“Save the research and update my project plan.”</strong></div>
      <div className="flow-line" aria-hidden="true"><i /><i /><i /></div>
      <div className="space-card">
        <div className="space-card-head"><Mark /><span>Karama.Cloud</span><small>Your space</small></div>
        <div className="space-row"><span className="row-key">Files</span><span>Market-research.pdf</span></div>
        <div className="space-row"><span className="row-key">Notes</span><span>Product brief</span></div>
        <div className="space-row"><span className="row-key">Apps</span><span>Project tracker</span></div>
      </div>
    </div>
    <p className="canvas-caption">A coding agent uses the Vessel CLI to work with your personal data space.</p>
  </div>;
}

function App() {
  const [accountName, setAccountName] = useState<string | null>(null);
  const [sessionReady, setSessionReady] = useState(false);
  const cliDownloadPath = "/assets/downloads/vessel_cli-0.1.2-py3-none-any.whl";
  const serviceOrigin = window.location.origin;
  const cliEnvironment = window.location.protocol === "https:" ? "production" : "local";

  useEffect(() => {
    let live = true;
    let latestRequest = 0;
    async function loadSession() {
      const request = ++latestRequest;
      try {
        const response = await fetch("/v1/auth/session", { credentials: "same-origin", cache: "no-store" });
        if (!response.ok) throw new Error("No active session");
        const payload = await response.json() as { user?: { name?: string } };
        if (live && request === latestRequest) setAccountName(payload.user?.name?.trim() || null);
      } catch {
        if (live && request === latestRequest) setAccountName(null);
      } finally {
        if (live && request === latestRequest) setSessionReady(true);
      }
    }
    void loadSession();
    const onPageShow = (event: PageTransitionEvent) => { if (event.persisted) void loadSession(); };
    const onVisibilityChange = () => { if (document.visibilityState === "visible") void loadSession(); };
    window.addEventListener("pageshow", onPageShow);
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => { live = false; window.removeEventListener("pageshow", onPageShow); document.removeEventListener("visibilitychange", onVisibilityChange); };
  }, []);

  const destination = accountName ? "/console" : "/register";
  const actionLabel = accountName ? "Open console" : "Sign up";

  return <div className="site-shell">
    <a className="skip-link" href="#main-content">Skip to content</a>
    <header className="site-header">
      <a className="brand" href="#top" aria-label="Karama.Cloud home"><Mark /><span>Karama.Cloud</span></a>
      <nav aria-label="Primary navigation">
        <a href="#storage">Storage</a>
        <a href="#how-it-works">How it works</a>
        <a href="#cli">CLI</a>
        <a href="#use-cases">Use cases</a>
        <a href="#faq">FAQ</a>
      </nav>
      <div className="header-actions">{accountName
        ? <a className="account-link" href="/console" aria-label={`${accountName}, open console`}><span className="account-avatar" aria-hidden="true">{accountName.charAt(0).toLocaleUpperCase()}</span><span className="account-name">{accountName}</span><span className="account-arrow" aria-hidden="true">↗</span></a>
        : sessionReady ? <><Button asChild variant="ghost" className="console-link h-9 rounded-md px-2 text-xs focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)]"><a href="/console">Sign in</a></Button><PrimaryLink>Sign up</PrimaryLink></> : <span className="account-placeholder" aria-hidden="true" />}</div>
    </header>

    <main id="main-content">
      <section className="hero section-wrap" id="top">
        <div className="hero-copy">
          <p className="brand-kicker"><span /> Personal AI Data Cloud</p>
          <h1>Your Data.<br /><em>Any AI.</em></h1>
          <p className="hero-statement">Your AI may change. Your data stays.</p>
          <p className="hero-description">A personal cloud space for the files, knowledge, and structured data you create with AI. Keep it organized once, then carry it forward across your work.</p>
          <div className="hero-actions"><PrimaryLink href={destination}>{actionLabel}</PrimaryLink><Button asChild variant="outline" className="site-action button button-secondary h-11 rounded-md border-[#9caeac] bg-transparent px-5 text-xs font-semibold text-[var(--night)] shadow-none hover:bg-[#e8efec] hover:text-[var(--night)] focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--paper)]"><a href="#how-it-works">How it works</a></Button></div>
          <p className="hero-note">Your personal data space for Files, Notes, and Apps.<br />Available in the Karama.Cloud console and CLI for coding agents.</p>
        </div>
        <DataCanvas />
      </section>

      <section className="why-band">
        <div className="section-wrap why-grid">
          <div><SectionLabel>Why Karama.Cloud</SectionLabel><h2>AI creates the work.<br />You keep the value.</h2></div>
          <div className="why-copy"><p>Research, plans, documents, and everyday records often disappear into separate conversations and tools. Karama.Cloud gives them one durable home that belongs to you.</p><p>AI memory can remember preferences. Your cloud should hold the actual work: files, structured Notes, and living data in Apps.</p><p className="chinese-support">Keep the data you create with AI, not only the context it remembers.</p></div>
        </div>
      </section>

      <section className="section-wrap storage-section" id="storage">
        <div className="section-heading"><div><SectionLabel>One personal cloud</SectionLabel><h2>Everything you create.<br />One place to continue from.</h2></div><p>Three durable data types form the foundation today. A future Memory layer will connect context and preferences across them.</p></div>
        <div className="storage-grid">
          <StorageCard index="01" name="Files" eyebrow="Keep every file within reach." title="Your personal cloud drive." description="Store reports, contracts, spreadsheets, images, audio, and the source material that matters to your work." examples={["Archive an AI-generated research report", "Share project files across your team", "Keep key documents out of chat history"]} />
          <StorageCard index="02" name="Notes" eyebrow="Turn conversations into lasting knowledge." title="Your knowledge, with structure." description="Turn important discussions, research, decisions, and plans into notes that grow over time with sections and blocks." examples={["A living product brief", "A travel plan you keep refining", "Research notes and key decisions"]} />
          <StorageCard index="03" name="Apps" eyebrow="Your life. Your data. Your way." title="Data shaped around you." description="Use AI to create and maintain structured data for the things you want to track over time." examples={["Meals, nutrients, and habits", "Expenses and personal budgets", "Reading, training, or project records"]} />
        </div>
        <p className="storage-footnote">Memory is a future capability for cross-category context and preferences. It is not a separate storage type today.</p>
      </section>

      <section className="process-section" id="how-it-works">
        <div className="section-wrap">
          <div className="section-heading process-heading"><div><SectionLabel>Your AI. Your Cloud. Just connect.</SectionLabel><h2>One place to start.<br />Three simple steps.</h2></div><p>Daily work should feel as natural as the conversation you already have with your AI.</p></div>
          <ol className="steps">
            <li><span>01</span><div><h3>Create your cloud</h3><p>Open a personal space for Files, Notes, and Apps. Create a team space when your work needs shared data and role-based access.</p><small>Create a personal or team data space.</small></div></li>
            <li><span>02</span><div><h3>Use the CLI with Codex <b className="step-available">Available</b></h3><p>Install the Vessel CLI, sign in once, and let Codex use JSON commands for Spaces, Files, Notes, and Apps.</p><small><a href="#cli">Download the CLI and follow the quick start.</a></small></div></li>
            <li><span>03</span><div><h3>Keep asking</h3><p>Save the useful parts of your work, update the records that matter, and return to an organized foundation for the next conversation.</p><small>Keep working naturally with AI while your important work accumulates.</small></div></li>
          </ol>
        </div>
      </section>

      <section className="section-wrap use-cases" id="use-cases">
        <div className="section-heading"><div><SectionLabel>One cloud. Endless possibilities.</SectionLabel><h2>Data becomes more useful<br />when it can keep working.</h2></div><p>Start with a personal routine, then carry the same habit from one AI workspace to the next.</p></div>
        <div className="case-grid">
          <article className="case case-large"><p className="case-index">01 / Personal knowledge</p><h3>Turn a useful conversation into a lasting starting point.</h3><p>Save a product brief as a Note, keep supporting material in Files, and return to the same source of truth whenever the project moves forward.</p><div className="case-art case-note"><span>Product brief</span><i>Research</i><i>Decisions</i><i>Next steps</i></div></article>
          <article className="case"><p className="case-index">02 / Personal finance</p><h3>Build a record you can ask about later.</h3><p>Keep expenses and budgets in an App. Future connected agents can help turn a conversation into structured records.</p></article>
          <article className="case"><p className="case-index">03 / Daily tracking</p><h3>Make small habits easier to revisit.</h3><p>Track meals, training, reading, or travel in data structures that make trends easier to understand over time.</p></article>
          <article className="case case-wide"><p className="case-index">04 / Team continuity</p><h3>One project. One shared workspace.</h3><p>Teams can keep shared files, knowledge, and structured records in one workspace. Members see the shared space by default, while their role controls what they can change.</p><span className="case-tag">Available in the Karama.Cloud console</span></article>
        </div>
      </section>

      <section className="integration-section">
        <div className="section-wrap integration-grid">
          <div><SectionLabel>Built for your AI</SectionLabel><h2>Data that can outlast<br />a single AI product.</h2><p>The Vessel CLI and HTTP API are available now. Additional agent integrations are being developed with clear account authorization and data access.</p><p className="chinese-support">Change AI tools without leaving your data behind.</p></div>
          <div className="integration-panel"><div className="panel-top"><span>Connection layer</span><h3>Available &amp; planned</h3></div><div className="integration-line"><strong>MCP</strong><span>Standard agent tool interface</span><small>Planned</small></div><div className="integration-line"><strong>CLI</strong><span>Codex workflows with JSON output</span><small className="integration-available">Available</small></div><div className="integration-line"><strong>API</strong><span>Core HTTP data endpoints</span><small className="integration-available">Available</small></div><div className="integration-line"><strong>Skills</strong><span>Guidance for connected agents</span><small>Planned</small></div><p>Use the CLI today to work with your Karama.Cloud data from Codex.</p></div>
        </div>
      </section>

      <section className="cli-section" id="cli">
        <div className="section-wrap cli-grid">
          <div className="cli-copy">
            <SectionLabel>Vessel CLI / For Codex</SectionLabel>
            <h2>Your cloud data,<br />one command away.</h2>
            <p>Give Codex a clear, machine-readable way to work with your Karama.Cloud space. The CLI supports Spaces, Files, Notes, and Apps through your signed-in account.</p>
            <div className="cli-capabilities"><span>JSON output</span><span>Private local credentials</span><span>Permission-aware API</span></div>
            <a className="button button-primary cli-download" href={cliDownloadPath} download>Download the CLI wheel <span aria-hidden="true">↓</span></a>
            <p className="cli-requirements">Python 3.11+ and uv required. Download the wheel and install it with the command shown here.</p>
          </div>
          <div className="cli-quickstart">
            <div className="cli-quickstart-head"><span>Quick start</span><small>Python 3.11+ · uv</small></div>
            <pre><code>{[
              `uv tool install ${serviceOrigin}${cliDownloadPath}`,
              `vessel env set ${cliEnvironment} ${serviceOrigin}`,
              `vessel auth login --env ${cliEnvironment} --email you@example.com`,
              `vessel spaces list --env ${cliEnvironment}`,
            ].join("\n")}</code></pre>
            <p>Login prompts for your password without echo. Session credentials are stored in a private local environment file; command results are JSON.</p>
          </div>
        </div>
      </section>

      <section className="section-wrap faq-section" id="faq">
        <div className="section-heading"><div><SectionLabel>FAQ</SectionLabel><h2>Questions about your data.</h2></div><p>Clear boundaries help people decide what belongs in their cloud.</p></div>
        <div className="faq-list">
          <details open><summary>What does Karama.Cloud store?</summary><p>Karama.Cloud stores the files, notes, and structured data created in your conversations with AI. Research materials, project plans, important decisions, and everyday records can live in your personal or team space for continued use.</p></details>
          <details><summary>Can Codex, Claude, and Gemini all use my data?</summary><p>Your data lives in one Karama.Cloud space. Once you authorize and connect an AI tool, it can work with that same data. Codex can use the Vessel CLI today; Claude, Gemini, and other AI tools can also use it through the CLI or API when configured and authorized.</p></details>
          <details><summary>Why not use an AI tool's memory and storage?</summary><p>AI tools use memory to keep your preferences and conversation context. Karama.Cloud manages your files, knowledge you can keep editing, and structured records, so you can share this work across AI tools.</p></details>
          <details><summary>What are Files for?</summary><p>Files store source materials and finished work, including reports, contracts, spreadsheets, and images. Organize them in folders and share them with team members according to their permissions.</p></details>
          <details><summary>What are Notes for?</summary><p>Notes preserve knowledge that evolves over time, such as research findings, product plans, decisions, and travel plans. Organize content into sections and return to it to read or revise it later.</p></details>
          <details><summary>What are Apps for?</summary><p>Apps manage structured records you add, search, and update over time. Define fields to suit your needs and track expenses, habits, reading lists, or project progress.</p></details>
        </div>
      </section>

      <section className="final-cta section-wrap">
        <div><SectionLabel>Karama.Cloud</SectionLabel><h2>Don't leave your work<br />inside yesterday's conversation.</h2><p>Give every important file, record, and idea a place that stays with you.</p></div><div><PrimaryLink href={destination}>{actionLabel}</PrimaryLink>{!accountName && <Button asChild variant="ghost" className="console-link final-console-link h-9 rounded-md px-2 text-xs focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)]"><a href="/console">Open the console</a></Button>}<p>Files + Notes + Apps<br />Personal spaces and team workspaces</p></div>
      </section>
    </main>

    <footer className="site-footer section-wrap"><a className="brand" href="#top"><Mark /><span>Karama.Cloud</span></a><p>Personal AI Data Cloud</p><p>Karama.Cloud brings Files, Notes, and Apps together in one personal data space.</p></footer>
  </div>;
}

createRoot(document.getElementById("root")!).render(<App />);
