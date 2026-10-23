import { test, expect } from "@playwright/test";

const apiOrigin = process.env.VESSEL_E2E_ORIGIN ?? "http://api.127.0.0.1.nip.io:52013";
const releaseOrigin = process.env.VESSEL_RELEASE_ORIGIN ?? "http://apps.127.0.0.1.nip.io:52013";

function appReleaseOrigin(appId) {
  const origin = new URL(releaseOrigin);
  origin.hostname = `${appId}.${origin.hostname}`;
  return origin.origin;
}

async function registerTestUser(page) {
  await page.goto("/register");
  await page.getByLabel("Name").fill("Console Regression");
  await page.getByLabel("Email").fill(`console-${crypto.randomUUID()}@example.test`);
  await page.getByLabel("Password").fill("vessel-e2e-password");
  const [response] = await Promise.all([
    page.waitForResponse(item => item.url().endsWith("/v1/auth/register")),
    page.getByRole("button", { name: "Create account" }).click(),
  ]);
  expect(response.status()).toBe(201);
  await expect(page.getByRole("heading", { name: "Karama.Cloud" })).toBeVisible();
  return (await response.json()).access_token;
}

test("selecting a Note folder creates the new Note inside that folder", async ({ page }) => {
  await registerTestUser(page);
  await page.getByRole("button", { name: "Notes", exact: true }).click();

  await page.getByRole("button", { name: "＋ New folder" }).click();
  await page.getByRole("dialog").getByRole("textbox").fill("Research");
  await page.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();

  await page.getByRole("button", { name: "Select folder Research" }).click();
  const createResponse = page.waitForResponse(response => response.request().method() === "POST" && /\/v1\/spaces\/[^/]+\/notes$/.test(new URL(response.url()).pathname));
  await page.getByRole("button", { name: "New Note" }).click();

  const created = await (await createResponse).json();
  await expect(page.getByLabel("Note folder")).toHaveValue(created.page.directory_id);
  expect(created.page.directory_id).toBeTruthy();
});

test("registration, team sharing, Notes editing and Apps records use Vessel API", async ({ browser }) => {
  const suffix = Date.now().toString(36);
  const ownerEmail = `owner-${suffix}@example.test`;
  const owner = await browser.newContext();
  const ownerPage = await owner.newPage();
  await ownerPage.goto("/register");
  await expect(ownerPage.getByRole("heading", { name: "Create your Karama.Cloud account" })).toBeVisible();
  await ownerPage.getByLabel("Name").fill("Vessel Owner");
  await ownerPage.getByLabel("Email").fill(ownerEmail);
  await ownerPage.getByLabel("Password").fill("vessel-e2e-password");
  const [ownerRegistration] = await Promise.all([
    ownerPage.waitForResponse(response => response.url().endsWith("/v1/auth/register")),
    ownerPage.getByRole("button", { name: "Create account" }).click(),
  ]);
  expect(ownerRegistration.status()).toBe(201);
  const ownerToken = (await ownerRegistration.json()).access_token;
  await expect(ownerPage.getByRole("heading", { name: "Karama.Cloud" })).toBeVisible();
  const ownerId = await ownerPage.getByTestId("current-user-id").textContent();
  expect(ownerId).toMatch(/^[0-9a-f-]{36}$/);

  await ownerPage.getByRole("button", { name: "Teams" }).click();
  await ownerPage.getByLabel("Team name").fill("Research Team");
  await ownerPage.getByRole("button", { name: "Create team" }).click();
  await expect(ownerPage.getByRole("heading", { name: "Research Team" })).toBeVisible();

  const viewer = await browser.newContext();
  const viewerPage = await viewer.newPage();
  await viewerPage.goto("/register");
  await viewerPage.getByLabel("Name").fill("Vessel Viewer");
  await viewerPage.getByLabel("Email").fill(`viewer-${suffix}@example.test`);
  await viewerPage.getByLabel("Password").fill("vessel-e2e-password");
  const [viewerRegistration] = await Promise.all([
    viewerPage.waitForResponse(response => response.url().endsWith("/v1/auth/register")),
    viewerPage.getByRole("button", { name: "Create account" }).click(),
  ]);
  expect(viewerRegistration.status()).toBe(201);
  const viewerToken = (await viewerRegistration.json()).access_token;
  await expect(viewerPage.getByRole("heading", { name: "Karama.Cloud" })).toBeVisible();
  const viewerId = await viewerPage.getByTestId("current-user-id").textContent();

  await ownerPage.getByLabel("Invitee user ID").fill(viewerId);
  await ownerPage.getByLabel("Invitation role").selectOption("viewer");
  await ownerPage.getByRole("button", { name: "Send invitation" }).click();
  await expect(ownerPage.getByText(viewerId, { exact: true })).toBeVisible();
  let revokeWarning = "";
  await ownerPage.getByRole("button", { name: "Revoke" }).click();
  revokeWarning = await ownerPage.getByRole("dialog").innerText();
  await ownerPage.getByRole("dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  expect(revokeWarning).toContain("Revoke");
  await expect(ownerPage.getByText(viewerId, { exact: true })).toBeVisible();
  await viewerPage.getByRole("button", { name: "Teams" }).click();
  await viewerPage.getByRole("button", { name: "Accept invitation" }).click();
  await viewerPage.getByLabel("Current space").selectOption({ label: "Research Team" });
  await expect(viewerPage.getByRole("heading", { name: "Research Team" })).toBeVisible();

  await ownerPage.getByRole("button", { name: "Notes", exact: true }).click();
  await ownerPage.getByRole("button", { name: "New Note" }).click();
  await ownerPage.getByLabel("Note title").fill("Team Notes");
  const body = ownerPage.getByLabel("Note document");
  await body.click();
  await body.pressSequentially("Shared note");
  await ownerPage.getByRole("button", { name: "Save Note" }).click();
  await expect(ownerPage.getByRole("status", { name: "Note save status" })).toContainText("Saved");
  if (process.env.VESSEL_E2E_SCREENSHOTS_DIR) await ownerPage.screenshot({ path: `${process.env.VESSEL_E2E_SCREENSHOTS_DIR}/notes.png`, fullPage: true });
  await ownerPage.reload();
  await ownerPage.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(ownerPage.getByLabel("Note document")).toContainText("Shared note");

  await viewerPage.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(viewerPage.getByLabel("Note document")).toContainText("Shared note");
  await expect(viewerPage.getByRole("button", { name: "Save Note" })).toBeDisabled();

  await ownerPage.getByRole("button", { name: "Apps" }).click();
  await ownerPage.getByLabel("App name").fill("Contacts");
  await ownerPage.getByLabel("Table name").fill("contacts");
  await ownerPage.getByLabel("Field name").fill("name");
  await ownerPage.getByRole("button", { name: "Create App" }).click();
  await expect(ownerPage.getByRole("heading", { name: "Contacts", exact: true })).toBeVisible();
  await ownerPage.getByRole("button", { name: "New record", exact: true }).click();
  await ownerPage.getByLabel("name", { exact: true }).fill("Ada");
  await ownerPage.getByRole("button", { name: "Add record" }).click();
  await expect(ownerPage.locator(".record-cell-value").filter({ hasText: /^Ada$/ })).toBeVisible();
  if (process.env.VESSEL_E2E_SCREENSHOTS_DIR) await ownerPage.screenshot({ path: `${process.env.VESSEL_E2E_SCREENSHOTS_DIR}/apps.png`, fullPage: true });

  await viewerPage.getByRole("button", { name: "Apps" }).click();
  await expect(viewerPage.locator(".record-cell-value").filter({ hasText: /^Ada$/ })).toBeVisible();
  await expect(viewerPage.getByRole("button", { name: "New record", exact: true })).toBeDisabled();

  const appList = await ownerPage.request.get("/v1/spaces", { headers: { Authorization: `Bearer ${ownerToken}` } });
  const teamId = (await appList.json()).spaces.find(item => item.name === "Research Team").space_id;
  const appsResponse = await ownerPage.request.get(`/v1/spaces/${teamId}/apps`, { headers: { Authorization: `Bearer ${ownerToken}` } });
  const appId = (await appsResponse.json()).apps.find(item => item.name === "Contacts").app_id;
  const rejectedWrite = await viewerPage.request.post(`/v1/apps/${appId}/tables/contacts/records`, {
    headers: { Authorization: `Bearer ${viewerToken}` }, data: { values: { name: "Denied" } },
  });
  expect(rejectedWrite.status()).toBe(403);

  await ownerPage.getByRole("button", { name: "Teams" }).click();
  await ownerPage.getByLabel(`Role for member ${viewerId}`).selectOption("editor");
  await expect(ownerPage.getByLabel(`Role for member ${viewerId}`)).toHaveValue("editor");
  await expect.poll(async () => {
    const response = await viewerPage.request.get(`/v1/spaces/${teamId}/permissions`, { headers: { Authorization: `Bearer ${viewerToken}` } });
    return (await response.json()).can_write;
  }).toBe(true);
  await viewerPage.reload();
  await viewerPage.getByRole("button", { name: "Apps" }).click();
  await expect(viewerPage.getByRole("button", { name: "New record", exact: true })).toBeEnabled();

  const notesResponse = await ownerPage.request.get(`/v1/spaces/${teamId}/notes`, { headers: { Authorization: `Bearer ${ownerToken}` } });
  const savedPage = (await notesResponse.json()).notes.find(item => item.title === "Team Notes");
  await ownerPage.getByRole("button", { name: "Notes", exact: true }).click();
  await expect(ownerPage.getByLabel("Note title")).toHaveValue("Team Notes");
  const concurrentChange = await ownerPage.request.patch(`/v1/notes/${savedPage.note_id}`, {
    headers: { Authorization: `Bearer ${ownerToken}` },
    data: { expected_revision: savedPage.revision, title: "Team Notes on server" },
  });
  expect(concurrentChange.status()).toBe(200);
  await ownerPage.getByLabel("Note title").fill("Team Notes local draft");
  await ownerPage.getByRole("button", { name: "Save Note" }).click();
  await expect(ownerPage.getByRole("status", { name: "Note save status" })).toContainText("Save conflict");
  await expect(ownerPage.getByLabel("Note title")).toHaveValue("Team Notes local draft");
  await ownerPage.getByRole("button", { name: "Discard draft and reload" }).click();
  await expect(ownerPage.getByLabel("Note title")).toHaveValue("Team Notes on server");

  await ownerPage.getByRole("button", { name: "Sign out" }).click();
  await expect(ownerPage.getByRole("heading", { name: "Sign in to Karama.Cloud" })).toBeVisible();
  await ownerPage.getByLabel("Email").fill(ownerEmail);
  await ownerPage.getByLabel("Password").fill("vessel-e2e-password");
  await ownerPage.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(ownerPage.getByRole("heading", { name: "Karama.Cloud" })).toBeVisible();

  await owner.close();
  await viewer.close();
});

test("mobile console keeps account controls visible", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto("/register");
  await page.getByLabel("Name").fill("Mobile User");
  await page.getByLabel("Email").fill(`mobile-${Date.now()}@example.test`);
  await page.getByLabel("Password").fill("vessel-e2e-password");
  await page.getByRole("button", { name: "Create account" }).click();
  await expect(page.getByTestId("current-user-id")).toBeVisible();
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("heading", { name: "Sign in to Karama.Cloud" })).toBeVisible();
  await context.close();
});

test("Note keeps a draft in memory, locks editing during save, and warns before discarding it", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("vessel.page.draft.v1:legacy", "old team secret"));
  await registerTestUser(page);
  expect(await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("vessel.page.draft")))).toEqual([]);
  await page.getByRole("button", { name: "New Note" }).click();
  const title = page.getByLabel("Note title");
  await title.fill("First draft");
  expect(await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("vessel.page.draft")))).toEqual([]);

  let releasePatch;
  const gate = new Promise(resolve => { releasePatch = resolve; });
  await page.route("**/v1/notes/*", async route => {
    if (route.request().method() === "PATCH") await gate;
    await route.continue();
  });
  await page.getByRole("button", { name: "Save Note" }).click();
  try {
    await expect(page.getByRole("status", { name: "Note save status" })).toContainText("Saving");
    await expect(title).toBeDisabled();
    await expect(page.getByLabel("Note document")).toHaveAttribute("contenteditable", "false");
  } finally { releasePatch(); }
  await expect(page.getByRole("status", { name: "Note save status" })).toContainText("Saved");

  await title.fill("Unsaved changes");
  let warning = "";
  await page.getByRole("button", { name: "Archive", exact: true }).click();
  warning = await page.getByRole("dialog").innerText();
  await page.getByRole("dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  expect(warning).toContain("Unsaved");
  await expect(title).toHaveValue("Unsaved changes");
});

test("failed logout keeps the authenticated console visible", async ({ page }) => {
  await registerTestUser(page);
  await page.route("**/v1/auth/logout", route => route.fulfill({ status: 503, contentType: "application/json", body: '{"detail":{"code":"TEMPORARY_FAILURE"}}' }));
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("heading", { name: "Karama.Cloud" })).toBeVisible();
  await expect(page.getByRole("alert")).toContainText("Request failed");
});

test("App version conflicts offer a reload before retry", async ({ page }) => {
  const token = await registerTestUser(page);
  const headers = { Authorization: `Bearer ${token}` };
  await page.getByRole("button", { name: "Apps" }).click();
  await page.getByLabel("App name").fill("Conflict App");
  await page.getByLabel("Table name").fill("contacts");
  await page.getByLabel("Field name").fill("name");
  await page.getByRole("button", { name: "Create App" }).click();
  await expect(page.getByRole("heading", { name: "Conflict App" })).toBeVisible();
  await page.getByRole("button", { name: "New record", exact: true }).click();
  await page.getByLabel("name", { exact: true }).fill("Ada");
  await page.getByRole("button", { name: "Add record" }).click();
  await expect(page.locator(".record-cell-value").filter({ hasText: /^Ada$/ })).toBeVisible();

  const spaces = await (await page.request.get("/v1/spaces", { headers })).json();
  const appResponse = await page.request.get(`/v1/spaces/${spaces.spaces[0].space_id}/apps`, { headers });
  const app = (await appResponse.json()).apps.find(item => item.name === "Conflict App");
  const recordsResponse = await page.request.get(`/v1/apps/${app.app_id}/tables/contacts/records`, { headers });
  const record = (await recordsResponse.json()).records[0];

  await page.getByRole("button", { name: "Edit", exact: true }).click();
  await page.getByLabel("name", { exact: true }).fill("Local Ada");
  const serverUpdate = await page.request.patch(`/v1/apps/${app.app_id}/tables/contacts/records/${record.id}`, {
    headers, data: { expected_row_version: record.row_version, values: { name: "Server Ada" } },
  });
  expect(serverUpdate.status()).toBe(200);
  await page.getByRole("button", { name: "Save record", exact: true }).click();
  await expect(page.getByRole("button", { name: "Discard edits and reload record" })).toBeVisible();
  await page.getByRole("button", { name: "Discard edits and reload record" }).click();
  await expect(page.locator(".record-cell-value").filter({ hasText: /^Server Ada$/ })).toBeVisible();

  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.getByRole("button", { name: "View / edit Manifest" }).click();
  const serverManifest = await page.request.put(`/v1/apps/${app.app_id}/manifest`, {
    headers,
    data: { expected_version: app.manifest_version, manifest: { tables: { contacts: { fields: { name: { type: "text", nullable: false }, note: { type: "text", nullable: true } } } } } },
  });
  expect(serverManifest.status()).toBe(200);
  await page.getByRole("button", { name: "Save Manifest" }).click();
  await expect(page.getByRole("button", { name: "Discard changes and reload Manifest" })).toBeVisible();
  await page.getByRole("button", { name: "Discard changes and reload Manifest" }).click();
  await page.getByRole("button", { name: "View / edit Manifest" }).click();
  await expect(page.getByLabel("Manifest JSON")).toContainText('"note"');
});

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function staticZip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, content] of Object.entries(entries)) {
    const nameBytes = Buffer.from(name);
    const contentBytes = Buffer.from(content);
    const crc = crc32(contentBytes);
    const local = Buffer.alloc(30 + nameBytes.length + contentBytes.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(contentBytes.length, 18);
    local.writeUInt32LE(contentBytes.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    nameBytes.copy(local, 30);
    contentBytes.copy(local, 30 + nameBytes.length);
    locals.push(local);

    const central = Buffer.alloc(46 + nameBytes.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(contentBytes.length, 20);
    central.writeUInt32LE(contentBytes.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    nameBytes.copy(central, 46);
    centrals.push(central);
    offset += local.length;
  }
  const centralSize = centrals.reduce((size, item) => size + item.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, ...centrals, end]);
}

test("App managers publish a draft while Editors only edit typed data", async ({ browser }) => {
  const suffix = crypto.randomUUID();
  const owner = await browser.newContext();
  const editor = await browser.newContext();
  const viewer = await browser.newContext();
  const ownerPage = await owner.newPage();
  const editorPage = await editor.newPage();
  const viewerPage = await viewer.newPage();
  const ownerToken = await registerTestUser(ownerPage);
  const editorToken = await registerTestUser(editorPage);
  const viewerToken = await registerTestUser(viewerPage);
  const ownerId = await ownerPage.getByTestId("current-user-id").textContent();
  const editorId = await editorPage.getByTestId("current-user-id").textContent();
  const viewerId = await viewerPage.getByTestId("current-user-id").textContent();
  expect(ownerId).toBeTruthy(); expect(editorId).toBeTruthy(); expect(viewerId).toBeTruthy();
  const headers = { Authorization: `Bearer ${ownerToken}` };
  const teamResponse = await ownerPage.request.post("/v1/teams", { headers, data: { name: `Apps Team ${suffix}` } });
  expect(teamResponse.status()).toBe(201);
  const team = (await teamResponse.json()).space;
  for (const [userId, role] of [[editorId, "editor"], [viewerId, "viewer"]]) {
    const invitation = await ownerPage.request.post(`/v1/teams/${team.space_id}/invitations`, { headers, data: { invitee_user_id: userId, role } });
    expect(invitation.status()).toBe(201);
    const token = role === "editor" ? editorToken : viewerToken;
    const accept = await ownerPage.request.post(`/v1/team-invitations/${(await invitation.json()).invitation.invitation_id}/accept`, { headers: { Authorization: `Bearer ${token}` } });
    expect(accept.status()).toBe(200);
  }
  const appResponse = await ownerPage.request.post(`/v1/spaces/${team.space_id}/apps`, {
    headers, data: { name: "Lunch Log", manifest: { tables: { meals: { fields: { title: { type: "text", nullable: false }, amount: { type: "numeric", nullable: true } } } } } },
  });
  expect(appResponse.status()).toBe(201);
  const app = (await appResponse.json()).app;

  for (const page of [ownerPage, editorPage, viewerPage]) {
    await page.reload();
    await page.getByLabel("Current space").selectOption(team.space_id);
    await page.getByRole("button", { name: "Apps" }).click();
    await expect(page.getByRole("heading", { name: "Lunch Log", exact: true })).toBeVisible();
  }
  await ownerPage.getByRole("button", { name: "Settings" }).click();
  await expect(ownerPage.getByLabel("App description")).toBeVisible();
  await expect(ownerPage.getByRole("button", { name: "Save app settings" })).toBeEnabled();
  await ownerPage.getByLabel("App description").fill("Shared lunch records");
  const settingsSave = ownerPage.waitForResponse(r => r.request().method() === "PATCH" && r.url().endsWith(`/v1/apps/${app.app_id}`));
  await ownerPage.getByRole("button", { name: "Save app settings" }).click();
  expect((await settingsSave).status()).toBe(200);
  await ownerPage.getByLabel("New nullable field name").fill("note");
  const schemaSave = ownerPage.waitForResponse(r => r.request().method() === "PUT" && r.url().endsWith("/manifest"));
  await ownerPage.getByRole("button", { name: "Add nullable field" }).click();
  expect((await schemaSave).status()).toBe(200);
  await ownerPage.getByLabel("New table name").fill("notes");
  const tableSave = ownerPage.waitForResponse(r => r.request().method() === "PUT" && r.url().endsWith("/manifest"));
  await ownerPage.getByRole("button", { name: "Add table", exact: true }).click();
  const tableResult = await (await tableSave).json();
  expect(tableResult.app.manifest.tables.notes.fields.name).toEqual({ type: "text", nullable: true });

  await editorPage.getByRole("button", { name: "Settings" }).click();
  await expect(editorPage.getByRole("button", { name: "Save app settings" })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Add table", exact: true })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Add nullable field" })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Archive App" })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Create App", exact: true })).toBeDisabled();
  await editorPage.getByRole("button", { name: "Data" }).click();
  await expect(editorPage.getByRole("button", { name: "New record", exact: true })).toBeEnabled();
  await editorPage.getByRole("button", { name: "New record", exact: true }).click();
  await editorPage.getByLabel("title", { exact: true }).fill("Editor lunch");
  await editorPage.getByLabel("amount", { exact: true }).fill("12345678901234567890.123456789012345678");
  const createdResponse = editorPage.waitForResponse(r => r.request().method() === "POST" && r.url().endsWith("/meals/records"));
  await editorPage.getByRole("button", { name: "Add record", exact: true }).click();
  const created = await (await createdResponse).json();
  expect(created.record.values.amount).toBe("12345678901234567890.123456789012345678");
  await editorPage.getByLabel(`Edit title for record ${created.record.id}`).fill("Updated by editor");
  const inlineSave = editorPage.waitForResponse(r => r.request().method() === "PATCH" && r.url().endsWith(`/records/${created.record.id}`));
  await editorPage.getByRole("button", { name: `Save record ${created.record.id}`, exact: true }).click();
  expect((await inlineSave).status()).toBe(200);
  await expect(editorPage.getByLabel(`Edit title for record ${created.record.id}`)).toHaveValue("Updated by editor");
  await editorPage.getByLabel("Search records").fill("Updated by editor");
  await editorPage.getByLabel("Filter field", { exact: true }).selectOption("amount");
  await editorPage.getByLabel("Filter operator").selectOption("gte");
  await editorPage.getByLabel("Filter value").fill("12345678901234567890.123456789012345678");
  await editorPage.getByLabel("Sort field", { exact: true }).selectOption("amount");
  const queryResponse = editorPage.waitForResponse(r => r.url().endsWith("/records/query"));
  await editorPage.getByRole("button", { name: "Apply query" }).click();
  const filtered = await queryResponse;
  expect(filtered.status()).toBe(200);
  expect(filtered.request().postDataJSON().filter.value).toBe("12345678901234567890.123456789012345678");
  expect((await filtered.json()).records.map(item => item.id)).toContain(created.record.id);
  await editorPage.getByLabel("Filter operator").selectOption("in");
  await editorPage.getByLabel("Filter value").fill("[12345678901234567890.123456789012345678]");
  await editorPage.getByRole("button", { name: "Apply query" }).click();
  await expect(editorPage.getByRole("alert")).toContainText("Use quoted decimal strings in numeric filters");
  await editorPage.getByRole("button", { name: "Close", exact: true }).click();
  await editorPage.getByLabel("Filter value").fill('["12345678901234567890.123456789012345678"]');
  const inQuery = editorPage.waitForResponse(r => r.url().endsWith("/records/query"));
  await editorPage.getByRole("button", { name: "Apply query" }).click();
  const inResponse = await inQuery;
  expect(inResponse.request().postDataJSON().filter.value).toEqual(["12345678901234567890.123456789012345678"]);
  expect((await inResponse.json()).records.map(item => item.id)).toContain(created.record.id);
  await editorPage.getByRole("button", { name: "Publish" }).click();
  await expect(editorPage.getByRole("button", { name: "Create draft" })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Upload H5 ZIP" })).toBeDisabled();
  await expect(editorPage.getByRole("button", { name: "Publish draft", exact: true })).toBeDisabled();
  await ownerPage.getByRole("button", { name: "Publish" }).click();
  await ownerPage.getByRole("button", { name: "Create draft" }).click();
  await expect(ownerPage.getByLabel("H5 ZIP file")).toBeEnabled();
  await ownerPage.getByLabel("H5 ZIP file").setInputFiles({ name: "lunch-log.zip", mimeType: "application/zip", buffer: staticZip({ "index.html": "<h1>Lunch Log</h1>" }) });
  await expect(ownerPage.getByRole("button", { name: "Upload H5 ZIP" })).toBeEnabled();
  await ownerPage.getByRole("button", { name: "Upload H5 ZIP" }).click();
  const preview = ownerPage.getByRole("link", { name: "Preview draft" });
  await expect(preview).toBeVisible();
  const previewHref = await preview.getAttribute("href");
  expect(previewHref?.startsWith(`${appReleaseOrigin(app.app_id)}/v1/apps/`)).toBe(true);
  const previewResponse = await ownerPage.request.get(previewHref);
  expect(previewResponse.status()).toBe(200);
  expect(await previewResponse.text()).toContain("Lunch Log");
  await ownerPage.getByRole("button", { name: "Publish draft", exact: true }).click();
  await expect(ownerPage.getByText("Version 1 · published · Current", { exact: true })).toBeVisible();
  const publicRelease = `${appReleaseOrigin(app.app_id)}/apps/${app.app_id}/releases/1/index.html`;
  const published = await ownerPage.request.get(publicRelease);
  expect(published.status()).toBe(200);
  expect(await published.text()).toContain("Lunch Log");
  await expect(ownerPage.getByRole("button", { name: "Open version 1" })).toBeVisible();
  const releases = await (await ownerPage.request.get(`/v1/apps/${app.app_id}/releases`, { headers })).json();
  const launch = await ownerPage.request.post(`/v1/apps/${app.app_id}/releases/${releases.releases[0].release_id}/launch`, { headers });
  expect(launch.status()).toBe(200);
  const h5Page = await owner.newPage();
  await h5Page.goto((await launch.json()).launch_url);
  await expect(h5Page).toHaveURL(publicRelease);
  const h5Session = await h5Page.evaluate(async () => {
    const response = await fetch(`${window.location.pathname.replace(/\/[^/]+$/, "")}/h5/session`, { method: "POST" });
    return { status: response.status, payload: await response.json() };
  });
  expect(h5Session.status).toBe(200);
  const h5Record = await h5Page.evaluate(async ({ apiOrigin, appId, accessToken }) => {
    const response = await fetch(`${apiOrigin}/v1/apps/${appId}/tables/meals/records`, {
      method: "POST", headers: { "Authorization": `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ values: { title: "H5 lunch", amount: "10" } }),
    });
    return { status: response.status, payload: await response.json() };
  }, { apiOrigin, appId: app.app_id, accessToken: h5Session.payload.access_token });
  expect(h5Record.status).toBe(201);
  expect(h5Record.payload.record.values.title).toBe("H5 lunch");
  await h5Page.close();
  await ownerPage.getByRole("button", { name: "Create draft" }).click();
  await expect(ownerPage.getByLabel("H5 ZIP file")).toBeEnabled();
  await ownerPage.getByLabel("H5 ZIP file").setInputFiles({ name: "v2.zip", mimeType: "application/zip", buffer: staticZip({ "index.html": "<h1>Second release</h1>" }) });
  await ownerPage.getByRole("button", { name: "Upload H5 ZIP" }).click();
  await expect(preview).toBeVisible();
  await ownerPage.getByRole("button", { name: "Publish draft", exact: true }).click();
  await expect(ownerPage.getByText("Version 2 · published · Current", { exact: true })).toBeVisible();
  await ownerPage.getByRole("button", { name: "Rollback to version 1", exact: true }).click();
  await ownerPage.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
  await expect(ownerPage.getByText("Version 1 · published · Current", { exact: true })).toBeVisible();
  await viewerPage.getByRole("button", { name: "Publish" }).click();
  await expect(viewerPage.getByRole("button", { name: "Upload H5 ZIP" })).toBeDisabled();
  await expect(viewerPage.getByRole("button", { name: "Rollback to version 2", exact: true })).toBeDisabled();
  await viewerPage.getByRole("button", { name: "Data", exact: true }).click();
  await expect(viewerPage.getByRole("button", { name: "New record", exact: true })).toBeDisabled();
  await expect(viewerPage.getByLabel(`Edit title for record ${created.record.id}`)).toBeDisabled();
  await ownerPage.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(ownerPage.getByText("release.published", { exact: true })).toHaveCount(2);
  const latestApp = (await (await ownerPage.request.get(`/v1/apps/${app.app_id}`, { headers })).json()).app;
  const changedSettings = await ownerPage.request.patch(`/v1/apps/${app.app_id}`, { headers, data: { expected_settings_version: latestApp.settings_version, description: "Server description" } });
  expect(changedSettings.status()).toBe(200);
  await ownerPage.getByLabel("App description").fill("Local description");
  await ownerPage.getByRole("button", { name: "Save app settings" }).click();
  await expect(ownerPage.getByRole("button", { name: "Discard changes and reload settings" })).toBeVisible();
  await expect(ownerPage.getByLabel("App description")).toHaveValue("Local description");
  await ownerPage.getByRole("button", { name: "Discard changes and reload settings" }).click();
  await expect(ownerPage.getByLabel("App description")).toHaveValue("Server description");
  await ownerPage.getByRole("button", { name: "Archive App", exact: true }).click();
  await ownerPage.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
  await expect(ownerPage.getByRole("heading", { name: "Lunch Log", exact: true })).not.toBeVisible();
  await ownerPage.getByLabel("App status", { exact: true }).selectOption("archived");
  await expect(ownerPage.getByRole("button", { name: "Restore App", exact: true })).toBeEnabled();
  await ownerPage.getByRole("button", { name: "Restore App", exact: true }).click();
  await ownerPage.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
  await expect(ownerPage.getByLabel("App status", { exact: true })).toHaveValue("active");
  await expect(ownerPage.getByRole("heading", { name: "Lunch Log", exact: true })).toBeVisible();

  await owner.close(); await editor.close(); await viewer.close();
});


test("App data bulk conflicts reload explicitly and pagination survives deletion", async ({ page }) => {
  const token = await registerTestUser(page);
  const headers = { Authorization: `Bearer ${token}` };
  const spaces = (await (await page.request.get("/v1/spaces", { headers })).json()).spaces;
  const created = await page.request.post(`/v1/spaces/${spaces[0].space_id}/apps`, { headers, data: { name: "Paged records", manifest: { tables: { items: { fields: { title: { type: "text", nullable: false } } } } } } });
  expect(created.status()).toBe(201);
  const app = (await created.json()).app;
  const seed = await page.request.post(`/v1/apps/${app.app_id}/tables/items/records/bulk`, { headers, data: { records: Array.from({ length: 52 }, (_, i) => ({ values: { title: `Item ${String(i).padStart(2, "0")}` } })) } });
  expect(seed.status()).toBe(201);
  const records = (await seed.json()).records;
  await page.getByRole("button", { name: "Apps", exact: true }).click();
  await expect(page.getByLabel(`Select record ${records[0].id}`)).toBeVisible();
  await page.getByLabel(`Select record ${records[0].id}`).check();
  await page.getByLabel(`Select record ${records[1].id}`).check();
  const changed = await page.request.patch(`/v1/apps/${app.app_id}/tables/items/records/${records[0].id}`, { headers, data: { expected_row_version: 1, values: { title: "Server updated" } } });
  expect(changed.status()).toBe(200);
  await page.getByRole("button", { name: "Delete selected records", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
  await expect(page.getByRole("button", { name: "Discard edits and reload record" })).toBeVisible();
  const unchanged = await page.request.get(`/v1/apps/${app.app_id}/tables/items/records/${records[1].id}`, { headers });
  expect(unchanged.status()).toBe(200);
  await page.getByRole("button", { name: "Discard edits and reload record" }).click();
  await expect(page.getByLabel(`Edit title for record ${records[0].id}`)).toHaveValue("Server updated");
  await page.getByLabel(`Select record ${records[0].id}`).check();
  await page.getByLabel(`Select record ${records[1].id}`).check();
  await page.getByRole("button", { name: "Delete selected records", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByLabel(`Select record ${records[0].id}`)).toBeVisible();
  const deletion = page.waitForResponse(r => r.url().endsWith("/records/bulk-delete"));
  await page.getByRole("button", { name: "Delete selected records", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
  expect((await (await deletion).json()).deleted_count).toBe(2);
  await expect(page.getByLabel(`Select record ${records[0].id}`)).not.toBeVisible();
  // Refill the first page: after deleting two rows, all 50 remaining rows fit.
  await expect(page.getByRole("button", { name: "Next", exact: true })).toBeDisabled();
  const extra = await page.request.post(`/v1/apps/${app.app_id}/tables/items/records`, { headers, data: { values: { title: "Next page" } } });
  expect(extra.status()).toBe(201);
  await page.getByRole("button", { name: "Apply query", exact: true }).click();
  await expect(page.getByRole("button", { name: "Next", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Next", exact: true }).click();
  await expect(page.getByLabel(`Edit title for record ${(await extra.json()).record.id}`)).toHaveValue("Next page");
  await page.getByRole("button", { name: "Previous", exact: true }).click();
  await expect(page.getByLabel(`Select record ${records[2].id}`)).toBeVisible();
});

test("Note title and formatting dropdown retain typography, selection and keyboard focus", async ({ page }) => {
  await registerTestUser(page);
  await page.getByRole("button", { name: "Notes", exact: true }).click();
  await page.getByRole("button", { name: "New Note", exact: true }).click();
  const title = page.getByLabel("Note title");
  expect(parseFloat(await title.evaluate(element => getComputedStyle(element).fontSize))).toBeGreaterThanOrEqual(32);
  await expect(title).toHaveCSS("border-top-width", "0px");
  const body = page.getByLabel("Note document");
  await body.fill("Selected text");
  for (let i = 0; i < 13; i++) await body.press("Shift+ArrowLeft");
  const trigger = page.getByRole("button", { name: "Text", exact: true });
  await expect(trigger).toBeInViewport();
  await trigger.click();
  await expect(page.getByRole("menu", { name: "Text style" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(trigger).toBeFocused();
  await trigger.click();
  await page.getByRole("menuitem", { name: "Heading 1", exact: true }).click();
  await expect(body.locator("h1")).toHaveText("Selected text");
  await expect(body).toBeFocused();
});
