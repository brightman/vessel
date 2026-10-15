import type React from "react";
import { createRoot } from "react-dom/client";
import "./site.css";

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
  return <a className={`button button-primary ${className}`.trim()} href={href}>{children}</a>;
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
    <div className="canvas-topline"><span className="canvas-live"><i /> Concept preview</span><span>Planned connection</span></div>
    <div className="canvas-flow">
      <div className="prompt-card"><p>Future agent prompt</p><strong>“Save the research and update my project plan.”</strong></div>
      <div className="flow-line" aria-hidden="true"><i /><i /><i /></div>
      <div className="space-card">
        <div className="space-card-head"><Mark /><span>Memory on Cloud</span><small>Your space</small></div>
        <div className="space-row"><span className="row-key">Files</span><span>Market-research.pdf</span></div>
        <div className="space-row"><span className="row-key">Pages</span><span>Product brief</span></div>
        <div className="space-row"><span className="row-key">Apps</span><span>Project tracker</span></div>
      </div>
    </div>
    <p className="canvas-caption">Conceptual flow for a planned agent connection to your personal data space.</p>
  </div>;
}

function App() {
  return <div className="site-shell">
    <a className="skip-link" href="#main-content">Skip to content</a>
    <header className="site-header">
      <a className="brand" href="#top" aria-label="Memory on Cloud home"><Mark /><span>Memory<br />on Cloud</span></a>
      <nav aria-label="Primary navigation">
        <a href="#storage">Storage</a>
        <a href="#how-it-works">How it works</a>
        <a href="#use-cases">Use cases</a>
        <a href="#faq">FAQ</a>
      </nav>
      <div className="header-actions"><a className="console-link" href="/console">Sign in</a><PrimaryLink>Get started</PrimaryLink></div>
    </header>

    <main id="main-content">
      <section className="hero section-wrap" id="top">
        <div className="hero-copy">
          <p className="brand-kicker"><span /> Personal AI Data Cloud</p>
          <h1>Your Data.<br /><em>Any AI.</em></h1>
          <p className="hero-statement">Your AI may change. Your data stays.</p>
          <p className="hero-description">A personal cloud space for the files, knowledge, and structured data you create with AI. Keep it organized once, then carry it forward across your work.</p>
          <div className="hero-actions"><PrimaryLink>Get started</PrimaryLink><a className="button button-secondary" href="#how-it-works">How it works</a></div>
          <p className="hero-note">个人云端数据空间，保存 Files、Pages 与 Apps。<br />Available now in the Vessel console. Agent connections are planned.</p>
        </div>
        <DataCanvas />
      </section>

      <section className="why-band">
        <div className="section-wrap why-grid">
          <div><SectionLabel>Why Memory on Cloud</SectionLabel><h2>AI creates the work.<br />You keep the value.</h2></div>
          <div className="why-copy"><p>Research, plans, documents, and everyday records often disappear into separate conversations and tools. Memory on Cloud gives them one durable home that belongs to you.</p><p>AI memory can remember preferences. Your cloud should hold the actual work: files, knowledge pages, and living structured data.</p><p className="chinese-support">不只是让 AI 记住你，而是让你留住与 AI 一起创造的数据。</p></div>
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
            <li><span>01</span><div><h3>Create your cloud</h3><p>Open a personal space for Files, Pages, and Apps. Create a team space when your work needs shared data and role-based access.</p><small>创建个人或团队数据空间</small></div></li>
            <li><span>02</span><div><h3>Connect your AI <b>Planned</b></h3><p>Memory on Cloud is designed for future connections through MCP, CLI, APIs, and agent skills. Availability will be announced with each supported integration.</p><small>未来支持通过开放连接层授权 AI 使用数据</small></div></li>
            <li><span>03</span><div><h3>Keep asking</h3><p>Save the useful parts of your work, update the records that matter, and return to an organized foundation for the next conversation.</p><small>继续自然地使用 AI，让重要内容沉淀下来</small></div></li>
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
          <div><SectionLabel>Built for your AI</SectionLabel><h2>Data that can outlast<br />a single AI product.</h2><p>Memory on Cloud is designed as an independent data layer. The connection layer is being developed deliberately so that data access stays clear and authorized.</p><p className="chinese-support">你的 AI 可以更换，数据仍然留在你自己的云端空间。</p></div>
          <div className="integration-panel"><div className="panel-top"><span>Connection layer</span><h3>Planned integrations</h3></div><div className="integration-line"><strong>MCP</strong><span>Standard agent tool interface</span><small>Coming soon</small></div><div className="integration-line"><strong>CLI</strong><span>Command line workflows</span><small>Coming soon</small></div><div className="integration-line"><strong>API</strong><span>Custom apps and automation</span><small>Coming soon</small></div><div className="integration-line"><strong>Skills</strong><span>Guidance for connected agents</span><small>Coming soon</small></div><p>Specific AI products and capabilities will be announced when their integrations are available.</p></div>
        </div>
      </section>

      <section className="section-wrap faq-section" id="faq">
        <div className="section-heading"><div><SectionLabel>FAQ</SectionLabel><h2>Questions about your data.</h2></div><p>Clear boundaries help people decide what belongs in their cloud.</p></div>
        <div className="faq-list">
          <details open><summary>How is this different from AI memory?</summary><p>AI memory usually helps one product remember preferences and context. Memory on Cloud is an independent data space for files, structured knowledge Pages, and Apps records.</p></details>
          <details><summary>Do I need a separate app?</summary><p>The product is designed API-first. A management console is available now, while additional agent connections are planned.</p></details>
          <details><summary>Can my data be used by different AIs?</summary><p>That is the intended direction. Future integrations will require explicit authorization and will be announced as they become available.</p></details>
          <details><summary>What is the difference between Files, Pages, and Apps?</summary><p>Files hold ordinary digital assets. Pages hold structured knowledge and notes. Apps hold ongoing structured records such as finances, habits, or project data.</p></details>
          <details><summary>Will I lose data if I change AI tools?</summary><p>Memory on Cloud stores data independently from an individual AI product. Your data remains subject to your account status and applicable service terms.</p></details>
        </div>
      </section>

      <section className="final-cta section-wrap">
        <div><SectionLabel>Memory on Cloud</SectionLabel><h2>Don't leave your work<br />inside yesterday's conversation.</h2><p>Give every important file, record, and idea a place that stays with you.</p></div><div><PrimaryLink>Get started</PrimaryLink><a className="console-link final-console-link" href="/console">Open the console</a><p>Files + Pages + Apps<br />Personal spaces and team workspaces</p></div>
      </section>
    </main>

    <footer className="site-footer section-wrap"><a className="brand" href="#top"><Mark /><span>Memory<br />on Cloud</span></a><p>Personal AI Data Cloud</p><p>Vessel is the current console and API implementation.</p></footer>
  </div>;
}

createRoot(document.getElementById("root")!).render(<App />);
