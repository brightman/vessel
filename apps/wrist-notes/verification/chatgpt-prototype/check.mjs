import {chromium,expect} from '@playwright/test';
import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const output=fileURLToPath(new URL('./',import.meta.url));
const browser=await chromium.launch({headless:true});
const page=await browser.newPage({viewport:{width:1280,height:1000},reducedMotion:'reduce'});
const errors=[],external=[],checks=[];
page.on('pageerror',error=>errors.push(error.message));
page.on('request',request=>{if(!request.url().startsWith('http://127.0.0.1:8766')&&!request.url().startsWith('data:')&&!request.url().startsWith('blob:'))external.push(request.url());});
const action=name=>page.locator(`[data-chatgpt-action="${name}"]`);
const aiAction=name=>page.locator(`[data-ai-action="${name}"]:visible`).last();
async function capture(name){
  await page.locator('#sheet').evaluate(el=>el.scrollTop=0);await page.waitForTimeout(1000);
  const clip=await page.locator('#sheet').boundingBox();
  assert.ok(clip.y>=0&&clip.y+clip.height<=page.viewportSize().height+1,'sheet stays within viewport');
  for(const button of await page.locator('#sheet .model-actions button').all()){
    const r=await button.boundingBox();assert.ok(r.y>=clip.y&&r.y+r.height<=clip.y+clip.height+1,'footer button is fully visible');
  }
  await page.screenshot({path:`${output}${name}.png`,clip});
}
async function openSettings(){await page.locator('#settingsButton').click();await page.locator('#aiModelSettingsButton').click();}
async function chooseChatGPT(){await page.locator('[name="dayAIMode"][value="chatgpt"]').check();}
async function connect(){if(await action('connect').count()){await action('connect').click();await action('complete-auth').click();}if(await action('acknowledge').count())await action('acknowledge').click();}
async function close(){await page.locator('#closeSheet').click();await expect(page.locator('#sheet')).not.toBeVisible();}
async function ask(question){await page.locator('.bottom-nav [data-view="ai"]').click();await page.locator('#aiQuestion').fill(question);await page.locator('#aiSend').click();}
try{
  await page.goto('http://127.0.0.1:8766/iphone-day.html#demo');
  await openSettings();
  assert.deepEqual(await page.locator('[name="dayAIMode"]').evaluateAll(els=>els.map(e=>e.value)),['local','chatgpt','custom']);
  await capture('01-model-order');checks.push('ChatGPT immediately below Apple and above custom');
  await chooseChatGPT();await expect(page.locator('#daySaveAI')).toBeDisabled();
  await capture('02-disconnected');
  await action('connect').click();await capture('03-authorizing');
  await action('cancel-auth').click();await expect(page.locator('#dayChatGPTCard')).toContainText('已取消授权');
  await expect(page.locator('#daySaveAI')).toBeDisabled();checks.push('cancel authorization does not enable save');
  await action('connect').click();await close();
  await openSettings();await chooseChatGPT();await expect(page.locator('#dayChatGPTCard')).toContainText('已取消授权');
  checks.push('closing authorization cancels pending connection');
  for(const [outcome,message] of [['error','暂时无法连接'],['unavailable','暂不支持此账号或应用'],['cancelled','已取消授权']]){
    await page.locator('#dayChatGPTAI details summary').click();await page.locator('#dayChatGPTOutcome').selectOption(outcome);
    await connect();await expect(page.locator('#dayChatGPTCard')).toContainText(message);await expect(page.locator('#daySaveAI')).toBeDisabled();
    await page.locator('#dayChatGPTAI details summary').click();
  }
  checks.push('network, eligibility and returned-cancel errors block save');
  await page.locator('#dayChatGPTAI details summary').click();await page.locator('#dayChatGPTOutcome').selectOption('success');
  await page.locator('#dayChatGPTAI details summary').click();
  await action('connect').click();await action('complete-auth').click();
  await expect(page.locator('#daySaveAI')).toBeDisabled();await capture('04-plan-notice');
  await action('acknowledge').click();await expect(page.locator('#daySaveAI')).toBeEnabled();
  await capture('05-connected');
  await page.locator('#dayChatGPTModel').selectOption('reasoning');await close();
  await expect(page.locator('#dayAIModelLabel')).toHaveText('Apple 本地模型');
  await openSettings();await chooseChatGPT();await expect(page.locator('#dayChatGPTModel')).toHaveValue('default');
  await expect(page.locator('#dayChatGPTCard')).toContainText('已连接');checks.push('connected account stays; cancelling draft preserves saved provider and model');
  await page.locator('#daySaveAI').click();
  await expect(page.locator('#dayAIModelLabel')).toHaveText('ChatGPT');
  await ask('这一天最值得跟进什么？');
  await expect(page.locator('#aiOutgoingQuestion')).toHaveText('这一天最值得跟进什么？');
  assert.deepEqual((await page.locator('[data-outgoing-record]').evaluateAll(els=>els.map(e=>e.dataset.outgoingRecord))).sort(),['review','thought-morning','thought-noon']);
  await page.locator('[data-outgoing-record]').first().locator('summary').click();await capture('06-send-preview');
  await aiAction('cancel-send').click();await expect(page.locator('#aiQuestion')).toHaveValue('这一天最值得跟进什么？');
  await expect(page.locator('.ai-turn')).toHaveCount(0);
  await page.locator('#aiSend').click();await aiAction('confirm-send').click();
  await expect(page.locator('.ai-provider-provenance')).toContainText('ChatGPT');await expect(page.locator('.ai-thinking')).toHaveCount(0);
  checks.push('exact question/evidence preview, cancel keeps draft, confirmed answer attributes ChatGPT');
  await page.locator('.phone-shell').screenshot({path:`${output}07-chatgpt-answer.png`});
  await ask('最近的睡眠有什么变化？');
  assert.deepEqual((await page.locator('[data-outgoing-record]').evaluateAll(els=>els.map(e=>e.dataset.outgoingRecord))).sort(),['sleep','yesterday-sleep']);
  await page.keyboard.press('Escape');await page.locator('#aiSend').click();await aiAction('cancel-send').click();
  checks.push('cross-day sleep evidence and Escape cancellation');
  await aiAction('preferences').click();await page.locator('[data-ai-pref="audio"]').click();await close();
  await ask('帮我回顾这一天');
  const limitedEvidence=await page.locator('[data-outgoing-record]').evaluateAll(els=>els.map(e=>e.dataset.outgoingRecord));
  assert.deepEqual(limitedEvidence.sort(),['sleep','walk-morning','walk-noon']);
  await aiAction('cancel-send').click();await aiAction('preferences').click();await page.locator('[data-ai-pref="audio"]').click();await close();
  checks.push('disabling audio scope removes all transcript records from remote preview');
  await aiAction('models').click();
  await page.locator('#dayChatGPTAI details summary').click();await action('expire').click();
  await expect(page.locator('#daySaveAI')).toBeDisabled();await close();
  await ask('帮我回顾这一天');await expect(page.locator('#sheetTitle')).toHaveText('检查 ChatGPT 连接');
  await aiAction('models').click();await connect();await expect(action('acknowledge')).toHaveCount(0);
  await page.locator('#dayChatGPTAI details summary').click();await action('limit').click();
  await close();await ask('帮我回顾这一天');await expect(page.locator('#sheetBody')).toContainText('ChatGPT 用量已达上限');
  await capture('08-usage-limit');
  await expect(page.locator('#sheetBody a')).toHaveAttribute('href','https://chatgpt.com/settings/usage');
  checks.push('expired and limited accounts block inference, usage management is primary');
  await aiAction('models').click();await action('disconnect').click();await action('keep').click();
  await expect(page.locator('#dayChatGPTCard')).toContainText('ChatGPT 用量已达上限');
  await action('disconnect').click();await action('confirm-disconnect').click();await close();
  await expect(page.locator('.ai-provider-provenance').first()).toContainText('ChatGPT');
  await expect(page.locator('#aiProvider')).toContainText('模型暂不可用');
  checks.push('disconnect confirmation, old answer provenance preserved, no silent fallback');
  await aiAction('models').click();await page.locator('[name="dayAIMode"][value="local"]').check();await page.locator('#daySaveAI').click();
  await ask('帮我回顾这一天');await expect(page.locator('.ai-provider-provenance').last()).toContainText('Apple 本地模型');
  await expect(page.locator('#sheet')).not.toBeVisible();
  checks.push('explicit local switch works without remote preview');
  await openSettings();await page.locator('[name="dayAIMode"][value="custom"]').check();
  await page.locator('#dayAIModel').fill('example-model');await page.locator('#dayAIURL').fill('https://api.example.com/v1');await page.locator('#dayAIKey').fill('fictional-demo-key');
  await expect(page.locator('#daySaveAI')).toBeDisabled();await page.locator('#dayTestAI').click();await expect(page.locator('#daySaveAI')).toBeEnabled();await page.locator('#daySaveAI').click();
  await ask('帮我回顾这一天');await expect(page.locator('#sheetBody')).toContainText('https://api.example.com');await aiAction('cancel-send').click();
  checks.push('custom configuration validation and simulated test/save still work');
  await page.locator('#settingsButton').click();await page.locator('#asrSettingsButton').click();await expect(page.locator('[name="dayASREngine"]')).toHaveCount(2);await close();
  await page.locator('#myVoiceSettingsButton').click();await expect(page.locator('#sheetBody')).toContainText('30');await close();
  checks.push('ASR and My Voice settings remain accessible');
  for(const [width,language,theme] of [[390,'zh-Hans','light'],[390,'en','dark'],[320,'ja','dark']]){
    await page.setViewportSize({width,height:900});
    await page.locator('#appearance').selectOption(theme);await page.locator('#interfaceLanguage').selectOption(language);
    await page.locator('#aiModelSettingsButton').click();await chooseChatGPT();await connect();
    await capture(`09-${width}-${language}-${theme}`);
    assert.equal(await page.locator('#sheet').evaluate(el=>el.scrollWidth<=el.clientWidth+1),true);
    assert.equal(await page.locator('#dayChatGPTAI').evaluate(el=>/连接你的|使用你的|已连接|账号可用|模型列表|选中的文字/.test(el.innerText)),language==='zh-Hans');
    await close();
  }
  checks.push('390px light Chinese, 390px dark English, 320px dark Japanese; translated new card and no sheet overflow');
  const persisted=await page.evaluate(()=>Object.keys(localStorage));
  assert.equal(persisted.some(k=>/chatgpt|token|account/i.test(k)),false);
  await page.reload();await openSettings();await chooseChatGPT();await expect(page.locator('#daySaveAI')).toBeDisabled();
  checks.push('refresh clears connection; no account/token persisted');
  assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
  checks.push('zero JavaScript errors; zero external requests');
  await writeFile(`${output}checks.json`,JSON.stringify({passed:checks,errors,externalRequests:external,persistedKeys:persisted},null,2));
  console.log(JSON.stringify({passed:checks.length,checks},null,2));
}finally{await browser.close();}
