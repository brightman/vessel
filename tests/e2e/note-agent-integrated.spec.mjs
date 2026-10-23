import { test, expect } from '@playwright/test';

const live = process.env.VESSEL_AGENT_LIVE === '1';
test.setTimeout(live ? 240_000 : 90_000);

async function prepare(page) {
  await page.goto('/register');
  await page.getByLabel('Name', { exact: true }).fill('Note Agent Acceptance');
  await page.getByLabel('Email', { exact: true }).fill(`agent-${crypto.randomUUID()}@example.test`);
  await page.getByLabel('Password', { exact: true }).fill('isolated-agent-e2e-password');
  const registered = page.waitForResponse(r => r.url().endsWith('/v1/auth/register'));
  await page.getByRole('button', { name: 'Create account', exact: true }).click();
  expect((await registered).status()).toBe(201);
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  const created = page.waitForResponse(r => r.request().method() === 'POST' && /\/v1\/spaces\/[^/]+\/notes$/.test(new URL(r.url()).pathname));
  await page.getByRole('button', { name: 'New Note', exact: true }).click();
  const creation = await (await created).json();
  const noteId = creation.note.note_id;
  await page.getByLabel('Note title', { exact: true }).fill('Original acceptance title');
  await page.getByLabel('Note document', { exact: true }).fill('Original acceptance text');
  await page.getByRole('button', { name: 'Save Note', exact: true }).click();
  await expect(page.getByRole('status', { name: 'Note save status' })).toContainText('Saved');
  return noteId;
}

async function send(page, prompt) {
  await expect(page.getByLabel('Message Note Agent')).toBeEnabled({ timeout: 15_000 });
  await page.getByLabel('Message Note Agent').fill(prompt);
  const completed = page.waitForResponse(r => /\/agent\/runs\/[^/]+$/.test(new URL(r.url()).pathname) && r.request().method() === 'GET', { timeout: live ? 180_000 : 30_000 });
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const result = await (await completed).json();
  expect(result.failure_code, JSON.stringify({ status: result.status, failure: result.failure_code })).toBeNull();
  expect(result.status).toBe('completed');
  return result;
}

async function reloadNote(page, title) {
  await page.reload();
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await page.getByRole('button', { name: title, exact: true }).click();
}

test('real Vessel HTTP: automatic answer, inline proposal preview, rejection, acceptance and reload', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const noteId = await prepare(page);
  const agent = page.getByRole('complementary', { name: 'Note Agent', exact: true });
  await expect(agent.getByRole('button', { name: 'Ask', exact: true })).toHaveCount(0);
  await expect(agent.getByRole('button', { name: 'Edit', exact: true })).toHaveCount(0);
  const answer = await send(page, live ? '请只回答：当前笔记的标题和正文分别是什么？不要修改笔记。' : 'What does this Note say?');
  expect(answer.response.type).toBe('answer');
  await expect(agent.getByLabel('Agent activity')).toContainText('Working');
  await expect(page.getByLabel('Note document', { exact: true })).toContainText('Original acceptance text');
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toHaveCount(0);
  const prompt = live
    ? '请修改当前笔记：标题改成 Agent preview title，将正文全部替换为一句 Agent preview body，并附上两列两行的简单表格，内容是 City / Score 和 Test city / 6-4 6-3。请实际生成编辑提案。'
    : 'Please edit this Note';
  const edit = await send(page, prompt);
  expect(edit.response.type).toBe('edit');
  await expect(page.getByLabel('Note document', { exact: true })).toContainText('Agent preview body');
  await expect(page.getByLabel('Note document', { exact: true }).locator('table')).toBeVisible();
  await expect(page.getByLabel('Note title', { exact: true })).toHaveValue('Agent preview title');
  await expect(page.getByLabel('Note document', { exact: true })).toHaveAttribute('contenteditable', 'false');
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Reject', exact: true }).last().click();
  await expect(page.getByLabel('Note document', { exact: true })).toContainText('Original acceptance text');
  await expect(page.getByLabel('Note title', { exact: true })).toHaveValue('Original acceptance title');
  await send(page, prompt);
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toBeVisible();
  await page.screenshot({ path: `var/note-agent-${live ? 'live' : 'integrated'}-preview.png`, fullPage: true });
  const acceptance = page.waitForResponse(r => r.url().includes(`/v1/notes/${noteId}/proposals/`) && r.url().endsWith('/accept'));
  await page.getByRole('button', { name: 'Accept changes', exact: true }).click();
  expect((await acceptance).status()).toBe(200);
  await expect(page.getByRole('button', { name: 'Accept changes', exact: true })).toHaveCount(0);
  await reloadNote(page, 'Agent preview title');
  await expect(page.getByLabel('Note document', { exact: true })).toContainText('Agent preview body');
  await expect(page.getByLabel('Note document', { exact: true }).locator('table')).toBeVisible();
  expect(errors).toEqual([]);
});

test('real Vessel HTTP: clarification selection continues task and survives reload', async ({ page }) => {
  await prepare(page);
  const result = await send(page, live
    ? '我想记录比赛，但还没确定是哪位选手和哪个赛季。请先澄清，不要编辑，提供至少两个可选范围。'
    : 'Please clarify the season before making changes');
  expect(result.response.type).toBe('clarification');
  await expect(page.getByRole('complementary', { name: 'Note Agent', exact: true }).getByLabel('Agent activity')).toContainText('Working');
  const option = result.response.options[0];
  await page.reload();
  await page.getByRole('button', { name: 'Notes', exact: true }).click();
  await expect(page.getByRole('button', { name: option.label, exact: true })).toBeVisible();
  const completion = page.waitForResponse(r => /\/agent\/runs\/[^/]+$/.test(new URL(r.url()).pathname) && r.request().method() === 'GET', { timeout: live ? 180_000 : 30_000 });
  await page.getByRole('button', { name: option.label, exact: true }).click();
  const continued = await (await completion).json();
  expect(continued.reply_to_run_id).toBe(result.run_id);
  expect(continued.failure_code).toBeNull();
  expect(continued.status).toBe('completed');
  await expect(page.getByRole('button', { name: option.label, exact: true })).toBeDisabled();
});
