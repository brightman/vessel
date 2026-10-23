import { test, expect } from "@playwright/test";
const origin = process.env.VESSEL_NOTE_UI_ORIGIN ?? "http://127.0.0.1:52004";
const document = (text) => ({
  type: "doc",
  content: [
    {
      type: "paragraph",
      attrs: { "block-id": "b1" },
      content: [{ type: "text", text }],
    },
  ],
});
async function setup(page, { viewer = false, stale = false } = {}) {
  let note = {
    note_id: "n1",
    space_id: "s1",
    title: "Original title",
    document: document("Original content"),
    markdown: "Original content",
    revision: 1,
    directory_id: null,
    status: "active",
    updated_at: "",
  };
  let proposal = null,
    latest = null,
    starts = [];
  await page.route("**/v1/**", async (route) => {
    const path = new URL(route.request().url()).pathname,
      method = route.request().method();
    let body = {};
    if (path.endsWith("/auth/refresh"))
      body = {
        access_token: "test",
        user: {
          user_id: "u1",
          name: "Tester",
          email: "test@example.test",
          roles: [],
        },
      };
    else if (path.endsWith("/auth/options"))
      body = { registration_enabled: false };
    else if (path === "/v1/spaces")
      body = {
        spaces: [
          {
            space_id: "s1",
            kind: "personal",
            name: "Test space",
            role: viewer ? "viewer" : "owner",
            status: "active",
          },
        ],
      };
    else if (path.endsWith("/permissions"))
      body = {
        can_read: true,
        can_write: !viewer,
        can_manage_members: false,
        can_delete: !viewer,
        role: viewer ? "viewer" : "owner",
      };
    else if (path.endsWith("/directories")) body = { directories: [] };
    else if (path.endsWith("/notes"))
      body = {
        notes:
          new URL(route.request().url()).searchParams.get("status") ===
          "archived"
            ? []
            : [note],
      };
    else if (path.endsWith("/agent/status"))
      body = {
        configured: true,
        edit_configured: true,
        online: true,
        active_run: null,
        latest_run: latest,
      };
    else if (path.endsWith("/proposals"))
      body = { proposals: proposal ? [proposal] : [] };
    else if (path.endsWith("/agent/runs") && method === "POST") {
      const input = route.request().postDataJSON();
      starts.push(input);
      const response = input.message.includes("question")
        ? {
            schema_version: 1,
            type: "answer",
            message: "A grounded answer",
            sources: [
              { title: "Source document", url: "https://example.com/source" },
            ],
          }
        : input.message.includes("clarify")
          ? {
              schema_version: 1,
              type: "clarification",
              message: "Which tone?",
              options: [{ id: "short", label: "Concise" }],
            }
          : { schema_version: 1, type: "edit", message: "Prepared your edit" };
      latest = {
        run_id: `r${starts.length}`,
        mode: "auto",
        prompt: input.message,
        status: "completed",
        failure_code: null,
        reply: null,
        response,
      };
      if (response.type === "edit")
        proposal = {
          proposal_id: "p1",
          note_id: "n1",
          run_id: latest.run_id,
          base_revision: stale ? 0 : note.revision,
          status: "ready",
          summary: "Rewrite",
          preview: {
            title: "Improved title",
            document: document("Improved content"),
            markdown: "Improved content",
          },
          operation_count: 2,
          failure_code: null,
        };
      body = { run_id: latest.run_id, status: "running" };
    } else if (path.endsWith("/events"))
      return route.fulfill({
        contentType: "text/event-stream",
        body: 'event: done\ndata: {"event_type":"done","payload":{}}\n\n',
      });
    else if (/\/agent\/runs\/[^/]+$/.test(path)) body = latest;
    else if (path.endsWith("/accept")) {
      note = { ...note, ...proposal.preview, revision: note.revision + 1 };
      proposal = null;
      body = { note };
    } else if (path.endsWith("/reject")) {
      proposal = null;
      body = {};
    }
    await route.fulfill({ json: body });
  });
  await page.goto(`${origin}/console/`);
  await page.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(page.getByLabel("Note title")).toHaveValue("Original title");
  return { starts, getNote: () => note };
}
async function send(page, text) {
  await page.getByLabel("Message Note Agent").fill(text);
  await page.getByRole("button", { name: "Send", exact: true }).click();
}
test("unified composer answers with source cards and recovers response after reload", async ({
  page,
}) => {
  const state = await setup(page);
  await expect(
    page.getByRole("button", { name: "Ask", exact: true }),
  ).toHaveCount(0);
  await send(page, "question");
  await expect(
    page.getByText("A grounded answer", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Source document" }),
  ).toHaveAttribute("href", "https://example.com/source");
  expect(state.starts[0].mode).toBe("auto");
  await page.reload();
  await page.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(
    page.getByText("A grounded answer", { exact: true }),
  ).toBeVisible();
});
test("clarification option continues the originating run", async ({ page }) => {
  const state = await setup(page);
  await send(page, "clarify");
  await page.getByRole("button", { name: "Concise", exact: true }).click();
  await expect(page.getByLabel("Note title")).toHaveValue("Improved title");
  expect(state.starts[1]).toMatchObject({
    reply_to_run_id: "r1",
    option_id: "short",
    mode: "auto",
  });
});
test("proposal previews on the Note, rejects without saving, accepts and survives reload", async ({
  page,
}) => {
  const state = await setup(page);
  await send(page, "rewrite");
  await expect(page.getByLabel("Note title")).toHaveValue("Improved title");
  await expect(page.getByLabel("Note title")).toHaveAttribute("readonly", "");
  expect(state.getNote().title).toBe("Original title");
  await page.screenshot({ path: "var/note-agent-ui-preview.png", fullPage: true });
  await page.getByRole("button", { name: "View changes", exact: true }).click();
  await expect(page.getByLabel("Before changes")).toContainText(
    "Original content",
  );
  await page.getByRole("button", { name: "Reject", exact: true }).click();
  await expect(page.getByLabel("Note title")).toHaveValue("Original title");
  await send(page, "rewrite again");
  await page
    .getByRole("button", { name: "Accept changes", exact: true })
    .click();
  await expect(page.getByLabel("Note title")).toHaveValue("Improved title");
  expect(state.getNote().revision).toBe(2);
  await page.reload();
  await page.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(page.getByLabel("Note title")).toHaveValue("Improved title");
});
test("stale proposals cannot overlay or be accepted", async ({ page }) => {
  await setup(page, { stale: true });
  await send(page, "rewrite");
  await expect(page.getByText(/out of date/i)).toBeVisible();
  await expect(page.getByLabel("Note title")).toHaveValue("Original title");
  await expect(
    page.getByRole("button", { name: "Accept changes", exact: true }),
  ).toBeDisabled();
});
test("viewers can ask but cannot preview or accept edits", async ({ page }) => {
  await setup(page, { viewer: true });
  await send(page, "rewrite");
  await expect(
    page.getByText("Read-only access: changes cannot be applied."),
  ).toBeVisible();
  await expect(page.getByLabel("Note title")).toHaveValue("Original title");
  await expect(
    page.getByRole("button", { name: "Accept changes", exact: true }),
  ).toBeDisabled();
});
test("server revision conflict clears the preview without mutating saved draft", async ({
  page,
}) => {
  await setup(page);
  await send(page, "rewrite");
  await expect(page.getByLabel("Note title")).toHaveValue("Improved title");
  await page.route("**/proposals/p1/accept", (route) =>
    route.fulfill({
      status: 409,
      json: { detail: { code: "NOTE_REVISION_CONFLICT" } },
    }),
  );
  await page
    .getByRole("button", { name: "Accept changes", exact: true })
    .click();
  await expect(page.getByLabel("Note title")).toHaveValue("Original title");
});
test("draft edits made while Agent works are preserved and prevent overlay", async ({
  page,
}) => {
  await setup(page);
  let finish;
  const gate = new Promise((resolve) => {
    finish = resolve;
  });
  await page.route("**/agent/runs/*/events", async (route) => {
    await gate;
    await route.fulfill({
      contentType: "text/event-stream",
      body: 'event: done\ndata: {"status":"completed"}\n\n',
    });
  });
  await send(page, "rewrite");
  await page.getByLabel("Note title").fill("My unsaved title");
  finish();
  await expect(
    page.getByText("Save your draft to preview these changes."),
  ).toBeVisible();
  await expect(page.getByLabel("Note title")).toHaveValue("My unsaved title");
  await expect(
    page.getByRole("button", { name: "Accept changes", exact: true }),
  ).toBeDisabled();
});
test("recovered answered clarification does not offer duplicate choices", async ({
  page,
}) => {
  await setup(page);
  await page.route("**/agent/status", (route) =>
    route.fulfill({
      json: {
        configured: true,
        edit_configured: true,
        online: true,
        active_run: null,
        latest_run: {
          run_id: "clarified",
          mode: "auto",
          status: "completed",
          prompt: "Choose style",
          failure_code: null,
          reply: null,
          answered_by_run_id: "child",
          response: {
            schema_version: 1,
            type: "clarification",
            message: "Which style?",
            options: [{ id: "short", label: "Concise" }],
          },
        },
      },
    }),
  );
  await page.reload();
  await page.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Concise", exact: true }),
  ).toBeDisabled();
});

test('clicking the current Note retains inline proposal controls', async ({ page }) => {
  await setup(page);
  await send(page, 'rewrite');
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Original title', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toBeVisible();
  await expect(page.getByLabel('Note title')).toHaveValue('Improved title');
});

test('late Accept completion cannot overwrite another Note draft', async ({ page }) => {
  await setup(page);
  const other = { note_id:'n2', space_id:'s1', title:'Other Note', document:document('Other content'), markdown:'Other content', revision:1, directory_id:null, status:'active', updated_at:'' };
  // Override only the list with both Notes; all mutations still use the fixture.
  await page.route('**/v1/spaces/s1/notes?status=active', route => route.fulfill({json:{notes:[{...other,note_id:'n1',title:'Original title',document:document('Original content'),markdown:'Original content'},other]}}));
  await page.route('**/v1/notes/n2/proposals',route=>route.fulfill({json:{proposals:[]}}));
  await page.route('**/v1/notes/n2/agent/status',route=>route.fulfill({json:{configured:true,online:true,active_run:null,latest_run:null}}));
  await page.reload();
  await page.getByRole('button',{name:'Notes',exact:true}).click();
  await send(page,'rewrite');
  await expect(page.getByRole('button',{name:'Accept changes',exact:true})).toBeVisible();
  let finish;
  const gate=new Promise(resolve=>{finish=resolve;});
  await page.route('**/proposals/p1/accept',async route=>{
    await gate;
    await route.fallback();
  });
  await page.getByRole('button',{name:'Accept changes',exact:true}).click();
  await page.getByRole('button',{name:'Other Note',exact:true}).click();
  await page.getByLabel('Note title').fill('My other draft');
  const accepted = page.waitForResponse(r=>r.url().endsWith('/proposals/p1/accept'));
  finish();
  await accepted;
  await expect(page.getByLabel('Note title')).toHaveValue('My other draft');
  await expect(page.getByLabel('Note document')).toContainText('Other content');
  await expect(page.getByRole('status',{name:'Note save status'})).toContainText('Unsaved');
});

test('answer card renders Markdown lists and tables without running HTML', async ({ page }) => {
  await setup(page);
  await page.route('**/agent/runs/*',route=>route.fulfill({json:{run_id:'r1',mode:'auto',status:'completed',failure_code:null,prompt:'question',response:{schema_version:1,type:'answer',message:'## Result\n\n- First item\n- Second item\n\n| City | Score |\n| --- | --- |\n| Test city | 6-4 |\n\n<script>window.injected=true</script>'}}}));
  await send(page,'question');
  const agent=page.getByRole('complementary',{name:'Note Agent',exact:true});
  await expect(agent.getByRole('heading',{name:'Result',exact:true})).toBeVisible();
  await expect(agent.getByRole('listitem')).toHaveCount(2);
  await expect(agent.getByRole('table')).toBeVisible();
  await expect(agent.locator('script')).toHaveCount(0);
});

test('Agent activity shows safe tool milestones without exposing arguments', async ({ page }) => {
  await setup(page);
  await page.route('**/agent/runs/*/events', route => route.fulfill({
    contentType: 'text/event-stream',
    body: [
      'event: progress\ndata: {"payload":{"phase":"thinking"}}\n\n',
      'event: progress\ndata: {"payload":{"phase":"tool_started","tool":"web_search"}}\n\n',
      'event: progress\ndata: {"payload":{"phase":"tool_completed","tool":"web_search"}}\n\n',
      'event: done\ndata: {"status":"completed"}\n\n',
    ].join(''),
  }));
  await send(page, 'question');
  const agent = page.getByRole('complementary', { name: 'Note Agent', exact: true });
  const activity = agent.getByLabel('Agent activity');
  await expect(activity).toContainText('Thinking');
  await expect(activity).toContainText('Searching the web');
  await expect(activity).toContainText('Web search complete');
  await expect(activity).not.toContainText('private query');
});

test('Agent failure explains the round limit and retains the error code', async ({ page }) => {
  await setup(page);
  await page.route('**/agent/runs/r1', route => route.fulfill({json: {
    run_id: 'r1', mode: 'auto', prompt: 'question', status: 'interrupted_max_rounds',
    failure_code: 'AGENT_RUN_TERMINATED', reply: null, response: null,
  }}));
  await send(page, 'question');
  const agent = page.getByRole('complementary', { name: 'Note Agent', exact: true });
  await expect(agent).toContainText('Note Agent · Failed');
  await expect(agent).toContainText('round limit');
  await expect(agent).toContainText('AGENT_RUN_TERMINATED');
});

test('Agent failure explains malformed JSON without showing the raw reply', async ({ page }) => {
  await setup(page);
  await page.route('**/agent/runs/r1', route => route.fulfill({json: {
    run_id: 'r1', mode: 'auto', prompt: 'question', status: 'failed',
    failure_code: 'INVALID_AGENT_RESPONSE_JSON', reply: 'private malformed output', response: null,
  }}));
  await send(page, 'question');
  const agent = page.getByRole('complementary', { name: 'Note Agent', exact: true });
  await expect(agent).toContainText('malformed JSON');
  await expect(agent).toContainText('INVALID_AGENT_RESPONSE_JSON');
  await expect(agent).not.toContainText('private malformed output');
});
