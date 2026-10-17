import { test, expect } from '@playwright/test';

test('registration requests a code, handles errors and binds it to the email', async ({ page }) => {
  await page.route('**/v1/auth/options', route => route.fulfill({ json: { registration_enabled: true, registration_email_verification_required: true, registration_email_resend_seconds: 60 } }));
  await page.route('**/v1/auth/refresh', route => route.fulfill({ status: 401, json: { detail: { code: 'INVALID_REFRESH_TOKEN' } } }));
  let requests = 0;
  await page.route('**/v1/auth/registration/email-code', route => {
    requests++;
    return route.fulfill({ status: 202, json: { challenge_id: `challenge-${requests}`, expires_in: 600, resend_after: 60 } });
  });
  let submitted;
  await page.route('**/v1/auth/register', route => {
    submitted = route.request().postDataJSON();
    return route.fulfill({ status: 422, json: { detail: { code: 'EMAIL_CODE_INVALID' } } });
  });
  await page.goto('/console/');
  await page.getByRole('link', { name: 'Create an account', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Email Test');
  await page.getByLabel('Email', { exact: true }).fill('first@example.test');
  await page.getByLabel('Password', { exact: true }).fill('vessel-email-test');
  await expect(page.getByRole('button', { name: 'Create account', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Send code', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('Check your inbox');
  await expect(page.getByRole('button', { name: /Resend in/ })).toBeDisabled();
  await page.getByLabel('Verification code', { exact: true }).fill('111111');
  await page.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(page.getByRole('alert')).toContainText('invalid or expired');
  expect(submitted).toMatchObject({ email: 'first@example.test', challenge_id: 'challenge-1', verification_code: '111111' });
  await page.getByLabel('Email', { exact: true }).fill('second@example.test');
  await expect(page.getByLabel('Verification code', { exact: true })).toHaveValue('');
  await expect(page.getByRole('button', { name: 'Create account', exact: true })).toBeDisabled();
  await page.getByRole('button', { name: 'Send code', exact: true }).click();
  expect(requests).toBe(2);
});

test('real HTTP verification creates an account and logs in', async ({ page }) => {
  test.skip(process.env.VESSEL_REGISTRATION_REAL_E2E !== '1', 'Requires the isolated PostgreSQL/test-mail HTTP harness');
  const email = `browser-verify-${crypto.randomUUID()}@example.test`;
  await page.goto('/register');
  await page.getByLabel('Name', { exact: true }).fill('Verified Browser');
  await page.getByLabel('Email', { exact: true }).fill(email);
  await page.getByLabel('Password', { exact: true }).fill('vessel-browser-verified-password');
  await page.getByRole('button', { name: 'Send code', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('Check your inbox');
  // This known code exists only in the explicitly isolated test mail harness.
  await page.getByLabel('Verification code', { exact: true }).fill('246810');
  const created = page.waitForResponse(response => response.request().method() === 'POST' && response.url().endsWith('/v1/auth/register'));
  await page.getByRole('button', { name: 'Create account', exact: true }).click();
  expect((await created).status()).toBe(201);
  await expect(page.getByRole('heading', { name: 'Vessel', exact: true })).toBeVisible();
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Vessel', exact: true })).toBeVisible();
});
