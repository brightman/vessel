/* Sign in with ChatGPT interaction prototype. Memory only; no OAuth, tokens or network calls. */
window.createDaybookChatGPT=function(app){
  'use strict';
  const {$,icon,onChange}=app;
  let state='disconnected',revision=0,acknowledged=false,confirmDisconnect=false,outcome='success';
  const messages={
    disconnected:['连接你的 ChatGPT','用已有账号选择可用模型，无需填写 API Key。'],
    authorizing:['等待 ChatGPT 授权','正式 App 将打开 ChatGPT 授权页面，WiseLife 不会接收你的密码。此处仅演示授权返回。'],
    connected:['已连接 · 示例账号','demo@example.com'],
    cancelled:['已取消授权','没有连接账号，可以随时重新开始。'],
    error:['暂时无法连接','请检查网络后重试，当前模型不会自动更换。'],
    unavailable:['暂不支持此账号或应用','实际可用性取决于 OpenAI 对应用的开放范围及账号资格。'],
    expired:['授权已过期','重新授权后才能继续使用 ChatGPT。'],
    limited:['ChatGPT 用量已达上限','请前往 ChatGPT 管理用量，或主动选择 Apple 本地模型。']
  };
  const usageLink=(primary=false)=>`<a class="${primary?'primary-button':'chatgpt-usage'}" href="https://chatgpt.com/settings/usage" target="_blank" rel="noopener noreferrer"><span>管理用量</span>${icon('ArrowUpRight')}</a>`;
  function snapshot(){return {state,revision,ready:state==='connected'&&acknowledged};}
  function change(next){state=next;revision++;confirmDisconnect=false;render();onChange();}
  function render(){
    const host=$('dayChatGPTCard');if(!host)return;
    const [title,description]=messages[state],hasAccount=['connected','expired','limited'].includes(state);
    let content='';
    if(confirmDisconnect){
      content=`<h3>断开 ChatGPT 连接？</h3><p>后续任务将停止使用此账号，已有笔记和示例对话保留。你可以重新连接，或主动切换模型。</p><div class="chatgpt-actions"><button class="secondary-button" data-chatgpt-action="keep">保留连接</button><button class="secondary-button chatgpt-danger" data-chatgpt-action="confirm-disconnect">确认断开</button></div>`;
    }else if(state==='connected'&&!acknowledged){
      content=`<div class="chatgpt-status">${icon('CheckCheck')}<span>授权成功 · 演示</span></div><h3>使用你的 ChatGPT 套餐</h3><p>此连接使用 ChatGPT 套餐的可用额度。WiseLife 的购买费用不包含 ChatGPT 订阅，也不代表无限用量。</p><button class="primary-button wide" data-chatgpt-action="acknowledge">知道了</button>`;
    }else{
      content=`<div class="chatgpt-status" data-state="${state}">${icon(state==='connected'?'CheckCheck':'MessageCircle')}<strong>${title}</strong></div><p>${description}</p>`;
      if(state==='authorizing')content+=`<div class="chatgpt-actions"><button class="secondary-button" data-chatgpt-action="cancel-auth">取消授权</button><button class="primary-button" data-chatgpt-action="complete-auth">模拟授权返回</button></div>`;
      else if(state==='connected')content+=`<p class="chatgpt-plan">使用 ChatGPT 套餐</p><p>账号与模型为虚构示例，刷新后清空。</p>${usageLink()}`;
      else if(state==='limited')content+=usageLink(true);
      else content+=`<button class="chatgpt-continue" data-chatgpt-action="connect">Continue with ChatGPT</button>`;
      if(hasAccount)content+=`<button class="text-button chatgpt-disconnect" data-chatgpt-action="disconnect">断开连接</button>`;
    }
    host.innerHTML=`<div class="chatgpt-card" aria-live="polite">${content}</div>`;
    const picker=$('dayChatGPTModelField');if(picker)picker.hidden=!(state==='connected'&&acknowledged);
  }
  function demoMarkup(){return `<details class="model-demo-options"><summary>授权演示选项</summary><label class="model-field"><span>模拟授权结果</span><select id="dayChatGPTOutcome"><option value="success">成功</option><option value="cancelled">取消授权</option><option value="error">网络失败</option><option value="unavailable">账号或应用暂不支持</option></select></label><div class="chatgpt-demo-actions"><button class="text-button" data-chatgpt-action="expire">模拟授权过期</button><button class="text-button" data-chatgpt-action="limit">模拟用量上限</button><button class="text-button" data-chatgpt-action="restore">模拟额度恢复</button></div></details>`;}
  function cancelAuthorization(){if(state==='authorizing')change('cancelled');}
  document.addEventListener('click',event=>{
    const action=event.target.closest('[data-chatgpt-action]')?.dataset.chatgptAction;if(!action)return;
    if(action==='connect'){outcome=$('dayChatGPTOutcome')?.value||'success';change('authorizing');}
    if(action==='cancel-auth')cancelAuthorization();
    if(action==='complete-auth'&&state==='authorizing')change(outcome==='success'?'connected':outcome);
    if(action==='acknowledge'&&state==='connected'){acknowledged=true;change('connected');}
    if(action==='disconnect'){confirmDisconnect=true;render();}
    if(action==='keep'){confirmDisconnect=false;render();}
    if(action==='confirm-disconnect'){acknowledged=false;change('disconnected');}
    if(action==='expire'&&['connected','limited'].includes(state))change('expired');
    if(action==='limit'&&state==='connected')change('limited');
    if(action==='restore'&&state==='limited')change('connected');
  });
  $('sheet').addEventListener('close',cancelAuthorization);
  return {snapshot,render,demoMarkup,usageLink,cancelAuthorization};
};

window.daybookChatGPTCopy=[
  ['用于笔记总结、跨记录洞察与 AI 对话。','For note summaries, insights across records and AI conversations.','ノートの要約、記録からの洞察、AI との対話に使用します。'],
  ['由 Apple Intelligence 提供，在 iPhone 上处理文本，无需 API Key。','Powered by Apple Intelligence. Process text on iPhone without an API key.','Apple Intelligence が iPhone 上でテキストを処理します。API キーは不要です。'],
  ['使用自己的服务与 Key，支持 OpenAI 或 Anthropic 兼容接口。','Use your own service and key with an OpenAI- or Anthropic-compatible API.','独自のサービスとキーを使用。OpenAI または Anthropic 互換 API に対応。'],
  ['需要 Apple Intelligence 可用','Requires Apple Intelligence','Apple Intelligence が必要です'],
  ['在系统设置中启用并下载。可用性取决于设备、语言和地区；不可用时不自动切换远程服务。','Enable and download in system settings. Availability depends on device, language and region. No automatic switch to a remote service.','システム設定で有効化しダウンロードします。対応は端末・言語・地域によります。リモートサービスには自動で切り替えません。'],
  ['配置仅保留在本页，刷新后清空。保存不连接真实 AI，示例对话仍使用预设回答。','Settings stay on this page and reset on refresh. Saving does not connect a real AI; conversations use preset examples.','設定はこのページ内のみで保持し、再読み込みで消去します。保存しても実際の AI には接続せず、会話は用意したサンプルです。'],
  ['ChatGPT 账号','ChatGPT account','ChatGPT アカウント'],
  ['使用已有 ChatGPT 账号，按套餐额度在云端处理。','Use your ChatGPT account and plan allowance for cloud processing.','ChatGPT アカウントとプランの利用枠でクラウド処理します。'],
  ['连接你的 ChatGPT','Connect your ChatGPT','ChatGPT に接続'],
  ['用已有账号选择可用模型，无需填写 API Key。','Choose available models with your account. No API key needed.','既存のアカウントで利用可能なモデルを選択。API キーは不要です。'],
  ['等待 ChatGPT 授权','Waiting for ChatGPT authorization','ChatGPT の認証を待っています'],
  ['正式 App 将打开 ChatGPT 授权页面，WiseLife 不会接收你的密码。此处仅演示授权返回。','The app will open ChatGPT authorization. WiseLife will not receive your password. This only simulates the return.','正式アプリは ChatGPT の認証画面を開きます。WiseLife はパスワードを受け取りません。ここでは認証結果を再現します。'],
  ['已连接 · 示例账号','Connected · example account','接続済み · サンプルアカウント'],
  ['已取消授权','Authorization cancelled','認証をキャンセルしました'],
  ['没有连接账号，可以随时重新开始。','No account connected. You can try again anytime.','アカウントは未接続です。いつでも再開できます。'],
  ['暂时无法连接','Unable to connect','接続できません'],
  ['请检查网络后重试，当前模型不会自动更换。','Check your network and retry. Your model will not change automatically.','接続を確認して再試行してください。モデルは自動変更されません。'],
  ['暂不支持此账号或应用','Account or app not eligible','アカウントまたはアプリは対象外です'],
  ['实际可用性取决于 OpenAI 对应用的开放范围及账号资格。','Availability depends on OpenAI app access and account eligibility.','利用可否は OpenAI のアプリ対応範囲とアカウント資格によります。'],
  ['授权已过期','Authorization expired','認証の有効期限が切れました'],
  ['重新授权后才能继续使用 ChatGPT。','Reconnect to continue using ChatGPT.','ChatGPT を使い続けるには再認証してください。'],
  ['ChatGPT 用量已达上限','ChatGPT usage limit reached','ChatGPT の利用上限に達しました'],
  ['请前往 ChatGPT 管理用量，或主动选择 Apple 本地模型。','Manage usage in ChatGPT, or choose the Apple on-device model.','ChatGPT で利用枠を管理するか、Apple のローカルモデルを選んでください。'],
  ['管理用量','Manage usage','利用状況を管理'],
  ['断开 ChatGPT 连接？','Disconnect ChatGPT?','ChatGPT の接続を解除しますか？'],
  ['后续任务将停止使用此账号，已有笔记和示例对话保留。你可以重新连接，或主动切换模型。','New tasks will stop using this account. Notes and example conversations stay. Reconnect or choose another model.','新しいタスクではこのアカウントを使用しません。ノートとサンプル会話は保持されます。再接続するかモデルを変更できます。'],
  ['保留连接','Stay connected','接続を維持'],['确认断开','Disconnect','接続を解除'],
  ['授权成功 · 演示','Authorized · demo','認証成功 · デモ'],
  ['使用你的 ChatGPT 套餐','Use your ChatGPT plan','ChatGPT プランを使用'],
  ['此连接使用 ChatGPT 套餐的可用额度。WiseLife 的购买费用不包含 ChatGPT 订阅，也不代表无限用量。','This connection uses your ChatGPT plan allowance. Your WiseLife purchase does not include a ChatGPT subscription or unlimited usage.','ChatGPT プランの利用枠を使用します。WiseLife の購入に ChatGPT の契約や無制限の利用は含まれません。'],
  ['知道了','Got it','了解'],['取消授权','Cancel authorization','認証をキャンセル'],
  ['模拟授权返回','Simulate authorization return','認証結果を再現'],
  ['使用 ChatGPT 套餐','Using ChatGPT plan','ChatGPT プランを使用中'],
  ['账号与模型为虚构示例，刷新后清空。','Account and models are fictional examples, cleared on refresh.','アカウントとモデルは架空の例です。再読み込みで消去されます。'],
  ['断开连接','Disconnect account','アカウントの接続を解除'],
  ['授权演示选项','Authorization demo options','認証デモのオプション'],
  ['模拟授权结果','Simulated authorization result','認証結果のデモ'],
  ['账号或应用暂不支持','Account or app unavailable','アカウントまたはアプリは利用不可'],
  ['模拟授权过期','Simulate expired authorization','認証期限切れを再現'],
  ['模拟用量上限','Simulate usage limit','利用上限を再現'],
  ['模拟额度恢复','Simulate restored allowance','利用枠の回復を再現'],
  ['账号可用模型','Models available to your account','アカウントで利用可能なモデル'],
  ['账号默认模型（示例）','Account default model (example)','アカウント既定モデル（例）'],
  ['推理模型（示例）','Reasoning model (example)','推論モデル（例）'],
  ['实际模型列表将在授权后由账号返回。','Available models will be returned by the account after authorization.','実際のモデル一覧は認証後にアカウントから取得します。'],
  ['选中的文字会发送至 OpenAI 云端。原始录音、图片文件和声音档案留在本机；不会读取你的 ChatGPT 聊天记录。','Selected text goes to OpenAI cloud. Original audio, image files and your voice profile stay on device. Your ChatGPT history is not accessed.','選択したテキストを OpenAI のクラウドに送信します。元の録音・画像ファイル・声のプロフィールは端末に残り、ChatGPT の会話履歴は読み取りません。'],
  ['原型演示 · 不会真正登录或发送数据','Prototype · no real sign-in or data sent','プロトタイプ · 実際のログインやデータ送信は行いません'],
  ['在本机处理','On-device processing','端末内で処理'],
  ['模型暂不可用','Model unavailable','モデルは利用できません'],
  ['先连接 ChatGPT 并确认套餐提示，再保存。','Connect ChatGPT and acknowledge the plan notice before saving.','ChatGPT に接続し、プランの案内を確認してから保存してください。'],
  ['检查 ChatGPT 连接','Check ChatGPT connection','ChatGPT の接続を確認'],
  ['当前选择不可用。请重新连接、管理用量，或在设置中主动切换模型。','Your selection is unavailable. Reconnect, manage usage, or choose another model in settings.','選択したモデルは利用できません。再接続、利用枠の管理、または設定でモデルを変更してください。'],
  ['打开 AI 模型设置','Open AI model settings','AI モデル設定を開く'],
  ["下次不再提示", "Don’t ask again", "次回から確認しない"],
  ["适用于外部 AI 问答、总结与长录音标题。开启免提示后，长录音标题会自动生成；可在「设置 → AI 模型」中恢复确认。", "Applies to external AI questions, summaries and recording titles. With confirmation off, recording titles are generated automatically. Restore confirmation in Settings → AI Models.", "外部 AI への質問・要約・録音タイトルに適用します。確認をオフにすると録音タイトルを自動生成します。「設定 → AI モデル」で確認を復元できます。"],
  ["发送给外部 AI 前确认", "Confirm before sending to external AI", "外部 AI への送信前に確認"],
  ["即时生效。关闭后，主动发起的外部 AI 问答与总结将直接发送允许使用的文字；可随时重新开启。", "Takes effect immediately. When off, questions and summaries you request send permitted text directly to external AI. You can turn confirmation back on anytime.", "すぐに反映されます。オフの場合、自分で依頼した外部 AI への質問と要約は、許可したテキストを直接送信します。いつでも確認を再び有効にできます。"],
  ["模型配置保存后用于下一次总结与问答。关闭会放弃未保存的模型修改，发送确认偏好即时保存。", "Saved model settings apply to the next summary or question. Closing discards unsaved model edits; the send-confirmation preference saves immediately.", "保存したモデル設定は次の要約や質問に適用されます。閉じると未保存のモデル変更は破棄されますが、送信確認の設定は即時保存されます。"],
  ["默认在 iPhone 上转写、总结和回答问题。使用外部 AI 时默认先确认发送内容，也可选择下次不再提示。", "Transcription, summaries and answers run on iPhone by default. External AI asks you to review the content first, with an option not to ask again.", "文字起こし・要約・回答は標準で iPhone 内で処理します。外部 AI の利用時は送信内容を確認し、次回から確認しない設定も選べます。"],
  ["仅使用你允许的记录 · 发送给所选外部 AI", "Only permitted records · Sent to your selected external AI", "許可した記録のみ使用 · 選択した外部 AI に送信"],
  ["即时生效，适用于外部 AI 问答与总结。原型仅在本页记住选择，刷新后恢复提示。", "Applies immediately to external AI questions and summaries. This prototype remembers the choice on this page only; reloading restores confirmation.", "外部 AI への質問と要約にすぐ適用されます。このプロトタイプではページ内でのみ記憶し、再読み込みで確認が復元されます。"],
  ["即时生效，适用于外部 AI 问答、总结与长录音自动标题。原型仅在本页记住选择，刷新后恢复提示。", "Applies immediately to external AI questions, summaries and automatic recording titles. This prototype remembers the choice only on this page; reloading restores confirmation.", "外部 AI への質問・要約・録音の自動タイトルにすぐ適用されます。このプロトタイプではページ内でのみ記憶し、再読み込みで確認が復元されます。"],
  ['发送前，确认这次使用的文字','Review the text before sending','送信するテキストを確認'],
  ['处理服务','Processing service','処理サービス'],['你的问题','Your question','あなたの質問'],
  ['本次引用的记录','Records for this request','今回使用する記録'],
  ['没有引用记录，仅使用你的问题。','No records included. Only your question is used.','記録は含まれません。質問のみを使用します。'],
  ['录音、图片文件和“我的声音”档案不会发送。原型仅模拟，不进行网络请求。','Audio, image files and My Voice profiles are not sent. This prototype simulates the request without network calls.','録音・画像ファイル・「私の声」のプロフィールは送信しません。この原型では通信せず処理を再現します。'],
  ['取消并保留问题','Cancel and keep question','キャンセルして質問を保持'],
  ['确认并模拟发送','Confirm and simulate send','確認して送信を再現'],
  ['模型或数据范围已变化，请重新预览后再发送。','The model or data scope changed. Review again before sending.','モデルまたはデータ範囲が変わりました。再確認してから送信してください。'],
  ['通过自定义服务处理','Using your custom service','カスタムサービスで処理'],
  ['服务或授权已变化，请重新提问。','The service or authorization changed. Please ask again.','サービスまたは認証が変わりました。もう一度質問してください。']
];
