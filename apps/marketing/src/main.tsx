import type React from "react";
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

function PrimaryLink({ children, className = "", href = "/register" }: { children: React.ReactNode; className?: string; href?: string }) {
  return <Button asChild className={`site-action button button-primary h-11 rounded-md px-5 text-xs font-semibold shadow-none bg-[var(--cta-bg)] hover:bg-[var(--cta-hover)] text-[var(--white)] focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--paper)] ${className}`.trim()}><a href={href}>{children}</a></Button>;
}

function SectionLabel({ children }: { children: React.ReactNode }) {
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
  return <div className="data-canvas" aria-label="A conceptual view of data organized in Memory on Cloud">
      <div className="canvas-topline"><span className="canvas-live"><i /> Concept preview</span><span>CLI connection</span></div>
    <div className="canvas-flow">
      <div className="prompt-card"><p>Codex prompt</p><strong>“Save the research and update my project plan.”</strong></div>
      <div className="flow-line" aria-hidden="true"><i /><i /><i /></div>
      <div className="space-card">
        <div className="space-card-head"><Mark /><span>Memory on Cloud</span><small>Your space</small></div>
        <div className="space-row"><span className="row-key">Files</span><span>Market-research.pdf</span></div>
        <div className="space-row"><span className="row-key">Pages</span><span>Product brief</span></div>
        <div className="space-row"><span className="row-key">Apps</span><span>Project tracker</span></div>
      </div>
    </div>
    <p className="canvas-caption">A coding agent uses the Vessel CLI to work with your personal data space.</p>
  </div>;
}

function App() {
  const cliDownloadPath = "/assets/downloads/vessel_cli-0.1.0-py3-none-any.whl";
  const serviceOrigin = window.location.origin;
  const cliEnvironment = window.location.protocol === "https:" ? "production" : "local";

  return <div className="site-shell">
    <a className="skip-link" href="#main-content">Skip to content</a>
    <header className="site-header">
      <a className="brand" href="#top" aria-label="Memory on Cloud home"><Mark /><span>Memory<br />on Cloud</span></a>
      <nav aria-label="Primary navigation">
        <a href="#storage">Storage</a>
        <a href="#how-it-works">How it works</a>
        <a href="#cli">CLI</a>
        <a href="#use-cases">Use cases</a>
        <a href="#faq">FAQ</a>
      </nav>
      <div className="header-actions"><Button asChild variant="ghost" className="console-link h-9 rounded-md px-2 text-xs focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)]"><a href="/console">Sign in</a></Button><PrimaryLink>Sign up</PrimaryLink></div>
    </header>

    <main id="main-content">
      <section className="hero section-wrap" id="top">
        <div className="hero-copy">
          <p className="brand-kicker"><span /> Personal AI Data Cloud</p>
          <h1>Your Data.<br /><em>Any AI.</em></h1>
          <p className="hero-statement">Your AI may change. Your data stays.</p>
          <p className="hero-description">A personal cloud space for the files, knowledge, and structured data you create with AI. Keep it organized once, then carry it forward across your work.</p>
          <div className="hero-actions"><PrimaryLink>Sign up</PrimaryLink><Button asChild variant="outline" className="site-action button button-secondary h-11 rounded-md border-[#9caeac] bg-transparent px-5 text-xs font-semibold text-[var(--night)] shadow-none hover:bg-[#e8efec] hover:text-[var(--night)] focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--paper)]"><a href="#how-it-works">How it works</a></Button></div>
          <p className="hero-note">Your personal data space for Files, Pages, and Apps.<br />Available in the Vessel console and CLI for coding agents.</p>
        </div>
        <DataCanvas />
      </section>

      <section className="why-band">
        <div className="section-wrap why-grid">
          <div><SectionLabel>Why Memory on Cloud</SectionLabel><h2>AI creates the work.<br />You keep the value.</h2></div>
          <div className="why-copy"><p>Research, plans, documents, and everyday records often disappear into separate conversations and tools. Memory on Cloud gives them one durable home that belongs to you.</p><p>AI memory can remember preferences. Your cloud should hold the actual work: files, knowledge pages, and living structured data.</p><p className="chinese-support">Keep the data you create with AI, not only the context it remembers.</p></div>
        </div>
      </section>

      <section className="section-wrap storage-section" id="storage">
        <div className="section-heading"><div><SectionLabel>One personal cloud</SectionLabel><h2>Everything you create.<br />One place to continue from.</h2></div><p>Three durable data types form the foundation today. A future Memory layer will connect context and preferences across them.</p></div>
        <div className="storage-grid">
          <StorageCard index="01" name="Files" eyebrow="Keep every file within reach." title="Your personal cloud drive." description="Store reports, contracts, spreadsheets, images, audio, and the source material that matters to your work." examples={["Archive an AI-generated research report", "Share project files across your team", "Keep key documents out of chat history"]} />
          <StorageCard index="02" name="Pages" eyebrow="Turn conversations into lasting knowledge." title="Your knowledge, with structure." description="Turn important discussions, research, decisions, and plans into pages that grow over time with sections and blocks." examples={["A living product brief", "A travel plan you keep refining", "Research notes and key decisions"]} />
          <StorageCard index="03" name="Apps" eyebrow="Your life. Your data. Your way." title="Data shaped around you." description="Use AI to create and maintain structured data for the things you want to track over time." examples={["Meals, nutrients, and habits", "Expenses and personal budgets", "Reading, training, or project records"]} />
        </div>
        <p className="storage-footnote">Memory is a future capability for cross-category context and preferences. It is not a separate storage type today.</p>
      </section>

      <section className="process-section" id="how-it-works">
        <div className="section-wrap">
          <div className="section-heading process-heading"><div><SectionLabel>Your AI. Your Cloud. Just connect.</SectionLabel><h2>One place to start.<br />Three simple steps.</h2></div><p>Daily work should feel as natural as the conversation you already have with your AI.</p></div>
          <ol className="steps">
            <li><span>01</span><div><h3>Create your cloud</h3><p>Open a personal space for Files, Pages, and Apps. Create a team space when your work needs shared data and role-based access.</p><small>Create a personal or team data space.</small></div></li>
            <li><span>02</span><div><h3>Use the CLI with Codex <b className="step-available">Available</b></h3><p>Install the Vessel CLI, sign in once, and let Codex use JSON commands for Spaces, Files, Pages, and Apps.</p><small><a href="#cli">Download the CLI and follow the quick start.</a></small></div></li>
            <li><span>03</span><div><h3>Keep asking</h3><p>Save the useful parts of your work, update the records that matter, and return to an organized foundation for the next conversation.</p><small>Keep working naturally with AI while your important work accumulates.</small></div></li>
          </ol>
        </div>
      </section>

      <section className="section-wrap use-cases" id="use-cases">
        <div className="section-heading"><div><SectionLabel>One cloud. Endless possibilities.</SectionLabel><h2>Data becomes more useful<br />when it can keep working.</h2></div><p>Start with a personal routine, then carry the same habit from one AI workspace to the next.</p></div>
        <div className="case-grid">
          <article className="case case-large"><p className="case-index">01 / Personal knowledge</p><h3>Turn a useful conversation into a lasting starting point.</h3><p>Save a product brief as a Page, keep supporting material in Files, and return to the same source of truth whenever the project moves forward.</p><div className="case-art case-page"><span>Product brief</span><i>Research</i><i>Decisions</i><i>Next steps</i></div></article>
          <article className="case"><p className="case-index">02 / Personal finance</p><h3>Build a record you can ask about later.</h3><p>Keep expenses and budgets in an App. Future connected agents can help turn a conversation into structured records.</p></article>
          <article className="case"><p className="case-index">03 / Daily tracking</p><h3>Make small habits easier to revisit.</h3><p>Track meals, training, reading, or travel in data structures that make trends easier to understand over time.</p></article>
          <article className="case case-wide"><p className="case-index">04 / Team continuity</p><h3>One project. One shared workspace.</h3><p>Teams can keep shared files, knowledge, and structured records in one workspace. Members see the shared space by default, while their role controls what they can change.</p><span className="case-tag">Available in the Vessel console</span></article>
        </div>
      </section>

      <section className="integration-section">
        <div className="section-wrap integration-grid">
          <div><SectionLabel>Built for your AI</SectionLabel><h2>Data that can outlast<br />a single AI product.</h2><p>The Vessel CLI and HTTP API are available now. Additional agent integrations are being developed with clear account authorization and data access.</p><p className="chinese-support">Change AI tools without leaving your data behind.</p></div>
          <div className="integration-panel"><div className="panel-top"><span>Connection layer</span><h3>Available &amp; planned</h3></div><div className="integration-line"><strong>MCP</strong><span>Standard agent tool interface</span><small>Planned</small></div><div className="integration-line"><strong>CLI</strong><span>Codex workflows with JSON output</span><small className="integration-available">Available</small></div><div className="integration-line"><strong>API</strong><span>Core HTTP data endpoints</span><small className="integration-available">Available</small></div><div className="integration-line"><strong>Skills</strong><span>Guidance for connected agents</span><small>Planned</small></div><p>Use the CLI today to work with your Vessel data from Codex.</p></div>
        </div>
      </section>

      <section className="cli-section" id="cli">
        <div className="section-wrap cli-grid">
          <div className="cli-copy">
            <SectionLabel>Vessel CLI / For Codex</SectionLabel>
            <h2>Your cloud data,<br />one command away.</h2>
            <p>Give Codex a clear, machine-readable way to work with your Vessel space. The CLI supports Spaces, Files, Pages, and Apps through your signed-in account.</p>
            <div className="cli-capabilities"><span>JSON output</span><span>OS credential storage</span><span>Permission-aware API</span></div>
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
            <p>Login prompts for your password without echo. Session credentials stay in your operating system's credential manager; command results are JSON.</p>
          </div>
        </div>
      </section>

      <section className="section-wrap faq-section" id="faq">
        <div className="section-heading"><div><SectionLabel>FAQ</SectionLabel><h2>Questions about your data.</h2></div><p>Clear boundaries help people decide what belongs in their cloud.</p></div>
        <div className="faq-list">
          <details open><summary>How is this different from AI memory?</summary><p>AI memory usually helps one product remember preferences and context. Memory on Cloud is an independent data space for files, structured knowledge Pages, and Apps records.</p></details>
          <details><summary>Do I need a separate app?</summary><p>The management console is available now, and coding agents such as Codex can use the Vessel CLI. Additional agent integrations are planned.</p></details>
          <details><summary>Can my data be used by different AIs?</summary><p>Codex can access your authorized Vessel data through the CLI today. Each command uses your Vessel account and current permissions; additional integrations will roll out separately.</p></details>
          <details><summary>What is the difference between Files, Pages, and Apps?</summary><p>Files hold ordinary digital assets. Pages hold structured knowledge and notes. Apps hold ongoing structured records such as finances, habits, or project data.</p></details>
          <details><summary>Will I lose data if I change AI tools?</summary><p>Memory on Cloud stores data independently from an individual AI product. Your data remains subject to your account status and applicable service terms.</p></details>
        </div>
      </section>

      <section className="final-cta section-wrap">
        <div><SectionLabel>Memory on Cloud</SectionLabel><h2>Don't leave your work<br />inside yesterday's conversation.</h2><p>Give every important file, record, and idea a place that stays with you.</p></div><div><PrimaryLink>Sign up</PrimaryLink><Button asChild variant="ghost" className="console-link final-console-link h-9 rounded-md px-2 text-xs focus-visible:ring-2 focus-visible:ring-[var(--aqua-deep)]"><a href="/console">Open the console</a></Button><p>Files + Pages + Apps<br />Personal spaces and team workspaces</p></div>
      </section>
    </main>

    <footer className="site-footer section-wrap"><a className="brand" href="#top"><Mark /><span>Memory<br />on Cloud</span></a><p>Personal AI Data Cloud</p><p>Vessel is the current console and API implementation.</p></footer>
  </div>;
}

createRoot(document.getElementById("root")!).render(<App />);
