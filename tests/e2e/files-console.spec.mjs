import { test, expect } from "@playwright/test";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";

async function capture(page, name) {
  const directory = process.env.VESSEL_E2E_SCREENSHOTS_DIR;
  if (!directory) return;
  await mkdir(directory, { recursive: true });
  await page.screenshot({ path: join(directory, `${name}.png`), fullPage: true });
}

async function register(page, label) {
  await page.goto("/register");
  await page.getByLabel("姓名").fill(label);
  await page.getByLabel("邮箱").fill(`${label.toLowerCase().replace(/\s/g, "-")}-${crypto.randomUUID()}@example.test`);
  await page.getByLabel("密码").fill("vessel-files-e2e-password");
  const [response] = await Promise.all([
    page.waitForResponse(value => value.url().endsWith("/v1/auth/register")),
    page.getByRole("button", { name: "注册" }).click(),
  ]);
  expect(response.status()).toBe(201);
  const payload = await response.json();
  const spaces = await page.request.get("/v1/spaces", { headers: { Authorization: `Bearer ${payload.access_token}` } });
  expect(spaces.ok()).toBeTruthy();
  return { token: payload.access_token, userId: payload.user.user_id, spaceId: (await spaces.json()).spaces[0].space_id };
}

async function fileApi(page, actor, method, path, body) {
  const response = await page.request.fetch(path, {
    method,
    headers: { Authorization: `Bearer ${actor.token}`, "Idempotency-Key": crypto.randomUUID() },
    ...(body === undefined ? {} : { data: body }),
  });
  expect(response.ok(), `${method} ${path}: ${response.status()} ${await response.text()}`).toBeTruthy();
  return response.json();
}

async function uploadFixture(page, actor, name, bytes) {
  const root = (await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/folders/root`)).folder;
  const upload = (await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/file-uploads`, {
    mode: "create", parent_folder_id: root.item_id, name, size_bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"), content_type: "text/plain",
  })).upload;
  const signed = await fileApi(page, actor, "POST", `/v1/file-uploads/${upload.upload_id}/parts/sign`, { part_numbers: [1] });
  const instruction = signed.instructions[0];
  const put = await page.request.put(instruction.url, { headers: instruction.headers, data: bytes });
  expect(put.ok(), `OSS PUT ${put.status()}`).toBeTruthy();
  await fileApi(page, actor, "POST", `/v1/file-uploads/${upload.upload_id}/complete`, {});
  await expect.poll(async () => (await fileApi(page, actor, "GET", `/v1/file-uploads/${upload.upload_id}`)).upload.status, { timeout: 30_000 }).toBe("ready");
  const listed = await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/file-items?parent_folder_id=${root.item_id}`);
  return listed.items.find(item => item.name === name);
}

test("root and shared navigation shows only granted descendants", async ({ browser }) => {
  const ownerContext = await browser.newContext();
  const ownerPage = await ownerContext.newPage();
  const owner = await register(ownerPage, "Files Owner");
  const ownerRoot = (await fileApi(ownerPage, owner, "GET", `/v1/spaces/${owner.spaceId}/folders/root`)).folder;
  await fileApi(ownerPage, owner, "POST", `/v1/spaces/${owner.spaceId}/folders`, { name: "Research", parent_folder_id: ownerRoot.item_id });

  const sharerContext = await browser.newContext();
  const sharerPage = await sharerContext.newPage();
  const sharer = await register(sharerPage, "Files Sharer");
  const sharerRoot = (await fileApi(sharerPage, sharer, "GET", `/v1/spaces/${sharer.spaceId}/folders/root`)).folder;
  const shared = (await fileApi(sharerPage, sharer, "POST", `/v1/spaces/${sharer.spaceId}/folders`, { name: "Shared research", parent_folder_id: sharerRoot.item_id })).folder;
  await fileApi(sharerPage, sharer, "POST", `/v1/spaces/${sharer.spaceId}/folders`, { name: "Private sibling", parent_folder_id: sharerRoot.item_id });
  const grants = await fileApi(sharerPage, sharer, "GET", `/v1/file-items/${shared.item_id}/grants`);
  await fileApi(sharerPage, sharer, "POST", `/v1/file-items/${shared.item_id}/grants`, { grantee_user_id: owner.userId, role: "viewer", expected_acl_revision: grants.acl_revision });

  await ownerPage.getByRole("button", { name: "Files" }).click();
  await expect(ownerPage.getByRole("heading", { name: "我的文件" })).toBeVisible();
  await expect(ownerPage.getByRole("row", { name: /Research/ })).toBeVisible();
  await capture(ownerPage, "files-desktop");
  await ownerPage.getByRole("button", { name: "共享给我" }).click();
  await expect(ownerPage.getByRole("row", { name: /Shared research/ })).toBeVisible();
  await expect(ownerPage.getByText("Private sibling")).toHaveCount(0);
  await ownerContext.close();
  await sharerContext.close();
});

test("Files uses a directory drawer at 390 px", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await register(page, "Files Mobile");
  await page.getByRole("button", { name: "Files" }).click();
  await expect(page.getByRole("button", { name: "目录" })).toBeVisible();
  await page.getByRole("button", { name: "目录" }).click();
  await expect(page.getByRole("complementary", { name: "Files 目录" })).toHaveClass(/open/);
  await page.waitForTimeout(250);
  await capture(page, "files-mobile-390");
  await context.close();
});

test("item capabilities show read controls for personal and team viewers", async ({ browser }) => {
  const ownerContext = await browser.newContext();
  const ownerPage = await ownerContext.newPage();
  const owner = await register(ownerPage, "Details Owner");
  const file = await uploadFixture(ownerPage, owner, "Shared report", Buffer.from("details fixture"));
  expect(file).toBeTruthy();
  const viewerContext = await browser.newContext();
  const viewerPage = await viewerContext.newPage();
  const viewer = await register(viewerPage, "Details Viewer");
  const grants = await fileApi(ownerPage, owner, "GET", `/v1/file-items/${file.item_id}/grants`);
  await fileApi(ownerPage, owner, "POST", `/v1/file-items/${file.item_id}/grants`, { grantee_user_id: viewer.userId, role: "viewer", expected_acl_revision: grants.acl_revision });

  await viewerPage.getByRole("button", { name: "Files" }).click();
  await viewerPage.getByRole("button", { name: "共享给我" }).click();
  await viewerPage.getByRole("row", { name: /Shared report/ }).click();
  await expect(viewerPage.getByRole("button", { name: "下载" })).toBeVisible();
  await expect(viewerPage.getByRole("button", { name: "重命名" })).toHaveCount(0);
  await expect(viewerPage.getByRole("tab", { name: "共享设置" })).toHaveCount(0);

  await ownerPage.getByRole("button", { name: "Files" }).click();
  await ownerPage.getByRole("row", { name: /Shared report/ }).click();
  await expect(ownerPage.getByRole("tab", { name: "共享设置" })).toBeVisible();
  await ownerContext.close();
  await viewerContext.close();
});

test("owner updates and revokes a personal file share through the console", async ({ browser }) => {
  const ownerContext = await browser.newContext();
  const ownerPage = await ownerContext.newPage();
  const owner = await register(ownerPage, "Share Console Owner");
  const file = await uploadFixture(ownerPage, owner, "share-console.txt", Buffer.from("share fixture"));
  const recipientContext = await browser.newContext();
  const recipientPage = await recipientContext.newPage();
  const recipient = await register(recipientPage, "Share Console Recipient");

  await ownerPage.getByRole("button", { name: "Files" }).click();
  await ownerPage.getByRole("row", { name: /share-console.txt/ }).click();
  await ownerPage.getByRole("tab", { name: "共享设置" }).click();
  await ownerPage.getByLabel("Vessel 用户 ID").fill(recipient.userId);
  await ownerPage.getByRole("button", { name: "添加共享" }).click();

  await recipientPage.getByRole("button", { name: "Files" }).click();
  await recipientPage.getByRole("button", { name: "共享给我" }).click();
  await recipientPage.getByRole("row", { name: /share-console.txt/ }).click();
  await expect(recipientPage.getByRole("button", { name: "重命名" })).toHaveCount(0);

  await ownerPage.getByLabel(`权限 ${recipient.userId}`).selectOption("editor");
  await expect.poll(async () => (await fileApi(ownerPage, owner, "GET", `/v1/file-items/${file.item_id}/grants`)).grants.find(grant => grant.grantee_user_id === recipient.userId)?.role).toBe("editor");
  await recipientPage.reload();
  await recipientPage.getByRole("button", { name: "Files" }).click();
  await recipientPage.getByRole("button", { name: "共享给我" }).click();
  await recipientPage.getByRole("row", { name: /share-console.txt/ }).click();
  await expect(recipientPage.getByRole("button", { name: "重命名" })).toBeVisible();
  await recipientPage.getByRole("button", { name: "上传新版本" }).click();
  await recipientPage.getByLabel("选择文件上传").setInputFiles({ name: "editor-replacement.txt", mimeType: "text/plain", buffer: Buffer.from("editor replacement") });
  await expect(recipientPage.getByRole("status", { name: "上传队列" })).toContainText("已完成", { timeout: 40_000 });
  await expect.poll(async () => (await fileApi(ownerPage, owner, "GET", `/v1/files/${file.item_id}/versions`)).versions).toHaveLength(2);

  ownerPage.once("dialog", dialog => void dialog.accept());
  await ownerPage.getByRole("button", { name: "撤销" }).click();
  await expect.poll(async () => (await fileApi(ownerPage, owner, "GET", `/v1/file-items/${file.item_id}/grants`)).grants.some(grant => grant.grantee_user_id === recipient.userId)).toBeFalsy();
  await recipientPage.reload();
  await recipientPage.getByRole("button", { name: "Files" }).click();
  await recipientPage.getByRole("button", { name: "共享给我" }).click();
  await expect(recipientPage.getByRole("row", { name: /share-console.txt/ })).toHaveCount(0);
  await ownerContext.close();
  await recipientContext.close();
});

test("browser OSS upload publishes and downloads matching bytes", async ({ page }) => {
  const actor = await register(page, "Upload Owner");
  await page.getByRole("button", { name: "Files" }).click();
  const bytes = Buffer.from("browser upload through Vessel and OSS\n");
  await page.getByLabel("选择文件上传").setInputFiles({ name: "browser-upload.txt", mimeType: "text/plain", buffer: bytes });
  await expect(page.getByRole("status", { name: "上传队列" })).toContainText("已完成", { timeout: 40_000 });
  await expect.poll(() => page.evaluate(userId => sessionStorage.getItem(`vessel.files.uploads.${userId}`), actor.userId)).toBeNull();
  await expect(page.getByRole("row", { name: /browser-upload.txt/ })).toBeVisible();
  await page.getByRole("row", { name: /browser-upload.txt/ }).click();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "下载", exact: true }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("browser-upload.txt");
  expect(createHash("sha256").update(await readFile(await download.path())).digest("hex")).toBe(createHash("sha256").update(bytes).digest("hex"));
});

test("an upload finishing after folder navigation does not replace the current directory", async ({ page }) => {
  await register(page, "Upload Navigation Owner");
  await page.getByRole("button", { name: "Files" }).click();
  for (const name of ["Upload source", "View target"]) {
    await page.getByRole("button", { name: "新建文件夹" }).click();
    await page.getByLabel("文件夹名称").fill(name);
    await page.getByRole("button", { name: "创建文件夹" }).click();
  }
  await page.getByRole("row", { name: /Upload source/ }).dblclick();
  let markStarted;
  const started = new Promise(resolve => { markStarted = resolve; });
  let releaseUpload;
  const release = new Promise(resolve => { releaseUpload = resolve; });
  await page.route(/\/v1\/spaces\/[^/]+\/file-uploads$/, async route => {
    markStarted();
    await release;
    await route.continue();
  });
  await page.getByLabel("选择文件上传").setInputFiles({ name: "delayed-source.txt", mimeType: "text/plain", buffer: Buffer.from("delayed upload") });
  await started;
  await page.locator(".files-breadcrumbs").getByRole("button", { name: "我的文件" }).click();
  await page.getByRole("row", { name: /View target/ }).dblclick();
  await expect(page.getByRole("heading", { name: "View target" })).toBeVisible();
  releaseUpload();
  await expect(page.getByRole("status", { name: "上传队列" })).toContainText("已完成", { timeout: 40_000 });
  await expect(page.getByRole("row", { name: /delayed-source.txt/ })).toHaveCount(0);
});

test("an upload finishing after logout does not reload a Files view", async ({ page }) => {
  await register(page, "Upload Logout Owner");
  await page.getByRole("button", { name: "Files" }).click();
  let releaseStatus;
  const statusHeld = new Promise(resolve => { releaseStatus = resolve; });
  let markStatusHeld;
  const statusIsHeld = new Promise(resolve => { markStatusHeld = resolve; });
  await page.route(/\/v1\/file-uploads\/[^/]+$/, async route => {
    if (route.request().method() !== "GET") return route.continue();
    markStatusHeld();
    await statusHeld;
    await route.continue();
  });
  let loggedOut = false;
  let requestsAfterLogout = 0;
  page.on("request", request => {
    if (loggedOut && request.method() === "GET" && (/\/v1\/spaces\/[^/]+\/file-items\?/.test(request.url()) || /\/v1\/shared-files(?:\?|$)/.test(request.url()))) requestsAfterLogout += 1;
  });
  await page.getByLabel("选择文件上传").setInputFiles({ name: "logout-pending.txt", mimeType: "text/plain", buffer: Buffer.from("logout while polling") });
  await statusIsHeld;
  await page.getByRole("button", { name: "退出登录" }).click();
  await expect(page.getByRole("heading", { name: "登录 Vessel" })).toBeVisible();
  loggedOut = true;
  releaseStatus();
  await page.waitForTimeout(2_000);
  expect(requestsAfterLogout).toBe(0);
});

test("upload queue describes a temporary Files storage outage", async ({ page }) => {
  await register(page, "Upload Storage Failure");
  await page.getByRole("button", { name: "Files" }).click();
  await page.route(/\/v1\/spaces\/[^/]+\/file-uploads$/, route => route.fulfill({
    status: 503,
    headers: { "content-type": "application/json", "x-request-id": "ui-storage-test" },
    body: JSON.stringify({ detail: { code: "FILE_STORAGE_UNAVAILABLE" } }),
  }));
  await page.getByLabel("选择文件上传").setInputFiles({ name: "storage-error.txt", mimeType: "text/plain", buffer: Buffer.from("retry later") });
  await expect(page.getByRole("status", { name: "上传队列" })).toContainText("文件存储暂时不可用，请稍后重试。", { timeout: 20_000 });
});

test("browser multipart upload receives exposed OSS ETags", async ({ page }) => {
  await register(page, "Multipart Owner");
  await page.getByRole("button", { name: "Files" }).click();
  const bytes = Buffer.alloc(17 * 1024 * 1024, "v");
  await page.getByLabel("选择文件上传").setInputFiles({ name: "multipart.bin", mimeType: "application/octet-stream", buffer: bytes });
  await expect(page.getByRole("status", { name: "上传队列" })).toContainText("已完成", { timeout: 90_000 });
  await expect(page.getByRole("row", { name: /multipart.bin/ })).toBeVisible();
});

test("new-version upload refreshes history and restores a prior version", async ({ page }) => {
  const actor = await register(page, "Version Restore Owner");
  const initial = await uploadFixture(page, actor, "versioned.txt", Buffer.from("first version"));
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("row", { name: /versioned.txt/ }).click();
  await page.getByRole("button", { name: "上传新版本" }).click();
  await page.getByLabel("选择文件上传").setInputFiles({ name: "replacement.txt", mimeType: "text/plain", buffer: Buffer.from("second version") });
  await expect(page.getByRole("status", { name: "上传队列" })).toContainText("已完成", { timeout: 40_000 });
  await page.getByRole("tab", { name: "历史版本" }).click();
  await expect(page.locator(".files-versions > div")).toHaveCount(2);
  page.once("dialog", dialog => void dialog.accept());
  await page.getByRole("button", { name: "恢复此版本" }).last().click();
  await expect(page.locator(".files-versions > div")).toHaveCount(3, { timeout: 30_000 });
  const versions = await fileApi(page, actor, "GET", `/v1/files/${initial.item_id}/versions`);
  expect(versions.versions).toHaveLength(3);
});

test("team Viewer remains read-only while Editor can create folders", async ({ browser }) => {
  const ownerContext = await browser.newContext();
  const ownerPage = await ownerContext.newPage();
  const owner = await register(ownerPage, "Team Files Owner");
  const viewerContext = await browser.newContext();
  const viewerPage = await viewerContext.newPage();
  const viewer = await register(viewerPage, "Team Files Viewer");
  const editorContext = await browser.newContext();
  const editorPage = await editorContext.newPage();
  const editor = await register(editorPage, "Team Files Editor");
  const team = (await fileApi(ownerPage, owner, "POST", "/v1/teams", { name: `File Roles ${Date.now()}` })).space;
  const viewerInvite = (await fileApi(ownerPage, owner, "POST", `/v1/teams/${team.space_id}/invitations`, { invitee_user_id: viewer.userId, role: "viewer" })).invitation;
  const editorInvite = (await fileApi(ownerPage, owner, "POST", `/v1/teams/${team.space_id}/invitations`, { invitee_user_id: editor.userId, role: "editor" })).invitation;
  await fileApi(viewerPage, viewer, "POST", `/v1/team-invitations/${viewerInvite.invitation_id}/accept`);
  await fileApi(editorPage, editor, "POST", `/v1/team-invitations/${editorInvite.invitation_id}/accept`);
  const root = (await fileApi(ownerPage, owner, "GET", `/v1/spaces/${team.space_id}/folders/root`)).folder;
  await fileApi(ownerPage, owner, "POST", `/v1/spaces/${team.space_id}/folders`, { name: "Team visible", parent_folder_id: root.item_id });

  await viewerPage.reload();
  await viewerPage.getByLabel("当前空间").selectOption(team.space_id);
  await viewerPage.getByRole("button", { name: "Files" }).click();
  await expect(viewerPage.getByRole("row", { name: /Team visible/ })).toBeVisible();
  await expect(viewerPage.getByRole("button", { name: "新建文件夹" })).toHaveCount(0);

  await editorPage.reload();
  await editorPage.getByLabel("当前空间").selectOption(team.space_id);
  await editorPage.getByRole("button", { name: "Files" }).click();
  await editorPage.getByRole("button", { name: "新建文件夹" }).click();
  await editorPage.getByLabel("文件夹名称").fill("Editor write");
  await editorPage.getByRole("button", { name: "创建文件夹" }).click();
  await expect(editorPage.getByRole("row", { name: /Editor write/ })).toBeVisible();
  await ownerContext.close();
  await viewerContext.close();
  await editorContext.close();
});

test("folder move preview requires explicit confirmation", async ({ page }) => {
  await register(page, "Move Owner");
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Source");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await expect(page.getByRole("row", { name: /Source/ })).toBeVisible();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Destination");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await page.getByRole("row", { name: /Source/ }).click();
  await page.getByRole("button", { name: "移动" }).click();
  await page.getByRole("button", { name: "选择 Destination" }).click();
  await page.getByRole("button", { name: "预览移动" }).click();
  await expect(page.getByRole("dialog", { name: "移动权限变化" })).toBeVisible();
  await page.getByRole("button", { name: "确认移动" }).click();
  await expect(page.getByRole("row", { name: /Source/ })).toHaveCount(0);
});

test("move picker rejects an item's own descendant", async ({ page }) => {
  await register(page, "Move Descendant Owner");
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Source parent");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await page.getByRole("row", { name: /Source parent/ }).dblclick();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Source child");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await page.locator(".files-breadcrumbs").getByRole("button", { name: "我的文件" }).click();
  await page.getByRole("row", { name: /Source parent/ }).click();
  await page.getByRole("button", { name: "移动" }).click();
  await page.getByRole("button", { name: "打开" }).click();
  await expect(page.getByRole("button", { name: "选择 Source child" })).toBeDisabled();
});

test("move picker loads later destination pages", async ({ page }) => {
  const actor = await register(page, "Move Pagination Owner");
  const root = (await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/folders/root`)).folder;
  for (let index = 0; index < 49; index += 1) await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/folders`, { name: `A destination ${String(index).padStart(2, "0")}`, parent_folder_id: root.item_id });
  await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/folders`, { name: "M move source", parent_folder_id: root.item_id });
  await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/folders`, { name: "Z later destination", parent_folder_id: root.item_id });
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("row", { name: /M move source/ }).click();
  await page.getByRole("button", { name: "移动" }).click();
  await expect(page.getByRole("button", { name: "选择 Z later destination" })).toHaveCount(0);
  await page.getByRole("button", { name: "加载更多目录" }).click();
  await expect(page.getByRole("button", { name: "选择 Z later destination" })).toBeVisible();
});

test("move retry reloads the item after a concurrent metadata update", async ({ page }) => {
  const actor = await register(page, "Move Retry Owner");
  const root = (await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/folders/root`)).folder;
  const source = (await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/folders`, { name: "Move retry source", parent_folder_id: root.item_id })).folder;
  await fileApi(page, actor, "POST", `/v1/spaces/${actor.spaceId}/folders`, { name: "Move retry destination", parent_folder_id: root.item_id });
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("row", { name: /Move retry source/ }).click();
  await expect(page.getByRole("heading", { name: "Move retry source" })).toBeVisible();
  await fileApi(page, actor, "PATCH", `/v1/file-items/${source.item_id}`, { name: "Move retry source updated", expected_metadata_version: source.metadata_version });
  await page.getByRole("button", { name: "移动" }).click();
  await page.getByRole("button", { name: "选择 Move retry destination" }).click();
  await page.getByRole("button", { name: "预览移动" }).click();
  await expect(page.getByRole("alert")).toContainText("FILE_METADATA_VERSION_CONFLICT");
  await page.getByRole("button", { name: "重新载入并再次预览" }).click();
  await expect(page.getByRole("dialog", { name: "移动权限变化" })).toBeVisible();
});

test("trash restore and purge use batch previews and job status", async ({ page }) => {
  const actor = await register(page, "Trash Owner");
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Recover me");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await page.getByRole("row", { name: /Recover me/ }).click();
  await page.getByRole("button", { name: "移入回收站" }).click();
  await page.getByRole("button", { name: "确认移入回收站" }).click();
  await page.getByRole("button", { name: "回收站", exact: true }).click();
  const batches = await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/file-trash`);
  await expect(page.getByText(batches.trash_batches[0].batch_id)).toBeVisible();
  await page.getByRole("button", { name: "恢复", exact: true }).click();
  await page.getByRole("button", { name: "预览恢复" }).click();
  await expect(page.getByRole("dialog", { name: "恢复权限变化" })).toBeVisible();
  await page.getByRole("button", { name: "确认恢复" }).click();
  await expect(page.getByRole("dialog", { name: "恢复权限变化" })).toHaveCount(0);
  const root = (await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/folders/root`)).folder;
  const restored = await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/file-items?parent_folder_id=${root.item_id}`);
  expect(restored.items.some(item => item.name === "Recover me")).toBeTruthy();
  await expect(page.getByRole("heading", { name: "我的文件" })).toBeVisible();
  await expect(page.getByRole("row", { name: /Recover me/ })).toBeVisible();
});

test("owner sees a purge job until it finishes", async ({ page }) => {
  const actor = await register(page, "Purge Owner");
  await page.getByRole("button", { name: "Files" }).click();
  await page.getByRole("button", { name: "新建文件夹" }).click();
  await page.getByLabel("文件夹名称").fill("Purge me");
  await page.getByRole("button", { name: "创建文件夹" }).click();
  await page.getByRole("row", { name: /Purge me/ }).click();
  await page.getByRole("button", { name: "移入回收站" }).click();
  await page.getByRole("button", { name: "确认移入回收站" }).click();
  await page.getByRole("button", { name: "回收站", exact: true }).click();
  const batches = await fileApi(page, actor, "GET", `/v1/spaces/${actor.spaceId}/file-trash`);
  const row = page.locator("article.files-trash-row").filter({ hasText: batches.trash_batches[0].batch_id });
  page.once("dialog", dialog => void dialog.accept());
  await row.getByRole("button", { name: "永久清理" }).click();
  await expect(page.getByRole("status")).toContainText("清理任务", { timeout: 10_000 });
  await expect(page.getByRole("status")).toContainText("已完成", { timeout: 30_000 });
});
