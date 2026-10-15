import { test, expect } from "@playwright/test";

async function registerTestUser(page) {
  await page.goto("/register");
  await page.getByLabel("姓名").fill("Console Regression");
  await page.getByLabel("邮箱").fill(`console-${crypto.randomUUID()}@example.test`);
  await page.getByLabel("密码").fill("vessel-e2e-password");
  const [response] = await Promise.all([
    page.waitForResponse(item => item.url().endsWith("/v1/auth/register")),
    page.getByRole("button", { name: "注册" }).click(),
  ]);
  expect(response.status()).toBe(201);
  await expect(page.getByRole("heading", { name: "Vessel" })).toBeVisible();
  return (await response.json()).access_token;
}

test("registration, team sharing, Pages editing and Apps records use Vessel API", async ({ browser }) => {
  const suffix = Date.now().toString(36);
  const ownerEmail = `owner-${suffix}@example.test`;
  const owner = await browser.newContext();
  const ownerPage = await owner.newPage();
  await ownerPage.goto("/register");
  await expect(ownerPage.getByRole("heading", { name: "创建 Vessel 账号" })).toBeVisible();
  await ownerPage.getByLabel("姓名").fill("Vessel Owner");
  await ownerPage.getByLabel("邮箱").fill(ownerEmail);
  await ownerPage.getByLabel("密码").fill("vessel-e2e-password");
  const [ownerRegistration] = await Promise.all([
    ownerPage.waitForResponse(response => response.url().endsWith("/v1/auth/register")),
    ownerPage.getByRole("button", { name: "注册" }).click(),
  ]);
  expect(ownerRegistration.status()).toBe(201);
  const ownerToken = (await ownerRegistration.json()).access_token;
  await expect(ownerPage.getByRole("heading", { name: "Vessel" })).toBeVisible();
  const ownerId = await ownerPage.getByTestId("current-user-id").textContent();
  expect(ownerId).toMatch(/^[0-9a-f-]{36}$/);

  await ownerPage.getByRole("button", { name: "团队" }).click();
  await ownerPage.getByLabel("团队名称").fill("Research Team");
  await ownerPage.getByRole("button", { name: "创建团队" }).click();
  await expect(ownerPage.getByRole("heading", { name: "Research Team" })).toBeVisible();

  const viewer = await browser.newContext();
  const viewerPage = await viewer.newPage();
  await viewerPage.goto("/register");
  await viewerPage.getByLabel("姓名").fill("Vessel Viewer");
  await viewerPage.getByLabel("邮箱").fill(`viewer-${suffix}@example.test`);
  await viewerPage.getByLabel("密码").fill("vessel-e2e-password");
  const [viewerRegistration] = await Promise.all([
    viewerPage.waitForResponse(response => response.url().endsWith("/v1/auth/register")),
    viewerPage.getByRole("button", { name: "注册" }).click(),
  ]);
  expect(viewerRegistration.status()).toBe(201);
  const viewerToken = (await viewerRegistration.json()).access_token;
  await expect(viewerPage.getByRole("heading", { name: "Vessel" })).toBeVisible();
  const viewerId = await viewerPage.getByTestId("current-user-id").textContent();

  await ownerPage.getByLabel("受邀用户 ID").fill(viewerId);
  await ownerPage.getByLabel("邀请角色").selectOption("viewer");
  await ownerPage.getByRole("button", { name: "发送邀请" }).click();
  await expect(ownerPage.getByText(viewerId, { exact: true })).toBeVisible();
  let revokeWarning = "";
  ownerPage.once("dialog", dialog => { revokeWarning = dialog.message(); void dialog.dismiss(); });
  await ownerPage.getByRole("button", { name: "撤销" }).click();
  expect(revokeWarning).toContain("撤销");
  await expect(ownerPage.getByText(viewerId, { exact: true })).toBeVisible();
  await viewerPage.getByRole("button", { name: "团队" }).click();
  await viewerPage.getByRole("button", { name: "接受邀请" }).click();
  await viewerPage.getByLabel("当前空间").selectOption({ label: "Research Team" });
  await expect(viewerPage.getByRole("heading", { name: "Research Team" })).toBeVisible();

  await ownerPage.getByRole("button", { name: "Pages" }).click();
  await ownerPage.getByRole("button", { name: "新建 Page" }).click();
  await ownerPage.getByLabel("Page 标题").fill("Team Notes");
  const body = ownerPage.getByLabel("Page 文档");
  await body.click();
  await body.pressSequentially("Shared note");
  await ownerPage.getByRole("button", { name: "保存 Page" }).click();
  await expect(ownerPage.getByRole("status", { name: "Page 保存状态" })).toContainText("已保存");
  if (process.env.VESSEL_E2E_SCREENSHOTS_DIR) await ownerPage.screenshot({ path: `${process.env.VESSEL_E2E_SCREENSHOTS_DIR}/pages.png`, fullPage: true });
  await ownerPage.reload();
  await ownerPage.getByRole("button", { name: "Pages" }).click();
  await expect(ownerPage.getByLabel("Page 文档")).toContainText("Shared note");

  await viewerPage.getByRole("button", { name: "Pages" }).click();
  await expect(viewerPage.getByLabel("Page 文档")).toContainText("Shared note");
  await expect(viewerPage.getByRole("button", { name: "保存 Page" })).toBeDisabled();

  await ownerPage.getByRole("button", { name: "Apps" }).click();
  await ownerPage.getByLabel("App 名称").fill("Contacts");
  await ownerPage.getByLabel("表名").fill("contacts");
  await ownerPage.getByLabel("字段名").fill("name");
  await ownerPage.getByRole("button", { name: "创建 App" }).click();
  await expect(ownerPage.getByRole("heading", { name: "Contacts", exact: true })).toBeVisible();
  await ownerPage.getByLabel("name", { exact: true }).fill("Ada");
  await ownerPage.getByRole("button", { name: "新增记录" }).click();
  await expect(ownerPage.getByRole("cell", { name: "Ada" })).toBeVisible();
  if (process.env.VESSEL_E2E_SCREENSHOTS_DIR) await ownerPage.screenshot({ path: `${process.env.VESSEL_E2E_SCREENSHOTS_DIR}/apps.png`, fullPage: true });

  await viewerPage.getByRole("button", { name: "Apps" }).click();
  await expect(viewerPage.getByRole("cell", { name: "Ada" })).toBeVisible();
  await expect(viewerPage.getByRole("button", { name: "新增记录" })).toBeDisabled();

  const appList = await ownerPage.request.get("/v1/spaces", { headers: { Authorization: `Bearer ${ownerToken}` } });
  const teamId = (await appList.json()).spaces.find(item => item.name === "Research Team").space_id;
  const appsResponse = await ownerPage.request.get(`/v1/spaces/${teamId}/apps`, { headers: { Authorization: `Bearer ${ownerToken}` } });
  const appId = (await appsResponse.json()).apps.find(item => item.name === "Contacts").app_id;
  const rejectedWrite = await viewerPage.request.post(`/v1/apps/${appId}/tables/contacts/records`, {
    headers: { Authorization: `Bearer ${viewerToken}` }, data: { values: { name: "Denied" } },
  });
  expect(rejectedWrite.status()).toBe(403);

  await ownerPage.getByRole("button", { name: "团队" }).click();
  await ownerPage.getByLabel(`成员 ${viewerId} 的角色`).selectOption("editor");
  await expect(ownerPage.getByLabel(`成员 ${viewerId} 的角色`)).toHaveValue("editor");
  await expect.poll(async () => {
    const response = await viewerPage.request.get(`/v1/spaces/${teamId}/permissions`, { headers: { Authorization: `Bearer ${viewerToken}` } });
    return (await response.json()).can_write;
  }).toBe(true);
  await viewerPage.reload();
  await viewerPage.getByRole("button", { name: "Apps" }).click();
  await expect(viewerPage.getByRole("button", { name: "新增记录" })).toBeEnabled();

  const pagesResponse = await ownerPage.request.get(`/v1/spaces/${teamId}/pages`, { headers: { Authorization: `Bearer ${ownerToken}` } });
  const savedPage = (await pagesResponse.json()).pages.find(item => item.title === "Team Notes");
  await ownerPage.getByRole("button", { name: "Pages" }).click();
  await expect(ownerPage.getByLabel("Page 标题")).toHaveValue("Team Notes");
  const concurrentChange = await ownerPage.request.patch(`/v1/pages/${savedPage.page_id}`, {
    headers: { Authorization: `Bearer ${ownerToken}` },
    data: { expected_revision: savedPage.revision, title: "Team Notes on server" },
  });
  expect(concurrentChange.status()).toBe(200);
  await ownerPage.getByLabel("Page 标题").fill("Team Notes local draft");
  await ownerPage.getByRole("button", { name: "保存 Page" }).click();
  await expect(ownerPage.getByRole("status", { name: "Page 保存状态" })).toContainText("保存冲突");
  await expect(ownerPage.getByLabel("Page 标题")).toHaveValue("Team Notes local draft");
  await ownerPage.getByRole("button", { name: "丢弃草稿并载入服务器版本" }).click();
  await expect(ownerPage.getByLabel("Page 标题")).toHaveValue("Team Notes on server");

  await ownerPage.getByRole("button", { name: "退出登录" }).click();
  await expect(ownerPage.getByRole("heading", { name: "登录 Vessel" })).toBeVisible();
  await ownerPage.getByLabel("邮箱").fill(ownerEmail);
  await ownerPage.getByLabel("密码").fill("vessel-e2e-password");
  await ownerPage.getByRole("button", { name: "登录", exact: true }).click();
  await expect(ownerPage.getByRole("heading", { name: "Vessel" })).toBeVisible();

  await owner.close();
  await viewer.close();
});

test("mobile console keeps account controls visible", async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto("/register");
  await page.getByLabel("姓名").fill("Mobile User");
  await page.getByLabel("邮箱").fill(`mobile-${Date.now()}@example.test`);
  await page.getByLabel("密码").fill("vessel-e2e-password");
  await page.getByRole("button", { name: "注册" }).click();
  await expect(page.getByTestId("current-user-id")).toBeVisible();
  await page.getByRole("button", { name: "退出登录" }).click();
  await expect(page.getByRole("heading", { name: "登录 Vessel" })).toBeVisible();
  await context.close();
});

test("Page keeps a draft in memory, locks editing during save, and warns before discarding it", async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem("vessel.page.draft.v1:legacy", "old team secret"));
  await registerTestUser(page);
  expect(await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("vessel.page.draft")))).toEqual([]);
  await page.getByRole("button", { name: "新建 Page" }).click();
  const title = page.getByLabel("Page 标题");
  await title.fill("First draft");
  expect(await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("vessel.page.draft")))).toEqual([]);

  let releasePatch;
  const gate = new Promise(resolve => { releasePatch = resolve; });
  await page.route("**/v1/pages/*", async route => {
    if (route.request().method() === "PATCH") await gate;
    await route.continue();
  });
  await page.getByRole("button", { name: "保存 Page" }).click();
  try {
    await expect(page.getByRole("status", { name: "Page 保存状态" })).toContainText("保存中");
    await expect(title).toBeDisabled();
    await expect(page.getByLabel("Page 文档")).toHaveAttribute("contenteditable", "false");
  } finally { releasePatch(); }
  await expect(page.getByRole("status", { name: "Page 保存状态" })).toContainText("已保存");

  await title.fill("Unsaved changes");
  let warning = "";
  page.once("dialog", dialog => { warning = dialog.message(); void dialog.dismiss(); });
  await page.getByRole("button", { name: "归档", exact: true }).click();
  expect(warning).toContain("未保存");
  await expect(title).toHaveValue("Unsaved changes");
});

test("failed logout keeps the authenticated console visible", async ({ page }) => {
  await registerTestUser(page);
  await page.route("**/v1/auth/logout", route => route.fulfill({ status: 503, contentType: "application/json", body: '{"detail":{"code":"TEMPORARY_FAILURE"}}' }));
  await page.getByRole("button", { name: "退出登录" }).click();
  await expect(page.getByRole("heading", { name: "Vessel" })).toBeVisible();
  await expect(page.getByRole("alert")).toContainText("请求失败");
});

test("App version conflicts offer a reload before retry", async ({ page }) => {
  const token = await registerTestUser(page);
  const headers = { Authorization: `Bearer ${token}` };
  await page.getByRole("button", { name: "Apps" }).click();
  await page.getByLabel("App 名称").fill("Conflict App");
  await page.getByLabel("表名").fill("contacts");
  await page.getByLabel("字段名").fill("name");
  await page.getByRole("button", { name: "创建 App" }).click();
  await expect(page.getByRole("heading", { name: "Conflict App" })).toBeVisible();
  await page.getByLabel("name", { exact: true }).fill("Ada");
  await page.getByRole("button", { name: "新增记录" }).click();
  await expect(page.getByRole("cell", { name: "Ada" })).toBeVisible();

  const spaces = await (await page.request.get("/v1/spaces", { headers })).json();
  const appResponse = await page.request.get(`/v1/spaces/${spaces.spaces[0].space_id}/apps`, { headers });
  const app = (await appResponse.json()).apps.find(item => item.name === "Conflict App");
  const recordsResponse = await page.request.get(`/v1/apps/${app.app_id}/tables/contacts/records`, { headers });
  const record = (await recordsResponse.json()).records[0];

  await page.getByRole("button", { name: "编辑" }).click();
  await page.getByLabel("name", { exact: true }).fill("Local Ada");
  const serverUpdate = await page.request.patch(`/v1/apps/${app.app_id}/tables/contacts/records/${record.id}`, {
    headers, data: { expected_row_version: record.row_version, values: { name: "Server Ada" } },
  });
  expect(serverUpdate.status()).toBe(200);
  await page.getByRole("button", { name: "保存记录" }).click();
  await expect(page.getByRole("button", { name: "丢弃编辑并重新载入记录" })).toBeVisible();
  await page.getByRole("button", { name: "丢弃编辑并重新载入记录" }).click();
  await expect(page.getByRole("cell", { name: "Server Ada" })).toBeVisible();

  await page.getByRole("button", { name: "查看 / 修改 Manifest" }).click();
  const serverManifest = await page.request.put(`/v1/apps/${app.app_id}/manifest`, {
    headers,
    data: { expected_version: app.manifest_version, manifest: { tables: { contacts: { fields: { name: { type: "text", nullable: false }, note: { type: "text", nullable: true } } } } } },
  });
  expect(serverManifest.status()).toBe(200);
  await page.getByRole("button", { name: "保存 Manifest" }).click();
  await expect(page.getByRole("button", { name: "丢弃更改并重新载入 Manifest" })).toBeVisible();
  await page.getByRole("button", { name: "丢弃更改并重新载入 Manifest" }).click();
  await page.getByRole("button", { name: "查看 / 修改 Manifest" }).click();
  await expect(page.getByLabel("Manifest JSON")).toContainText('"note"');
});
