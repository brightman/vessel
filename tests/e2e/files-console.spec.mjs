import { test, expect } from "@playwright/test";

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
  await ownerPage.getByRole("button", { name: "共享给我" }).click();
  await expect(ownerPage.getByRole("row", { name: /Shared research/ })).toBeVisible();
  await expect(ownerPage.getByText("Private sibling")).toHaveCount(0);
  await ownerContext.close();
  await sharerContext.close();
});
