/* Memory-only Apple Reminders interaction. No EventKit, storage, or network. */
window.daybookAppleRemindersCopy = [
 ['先确认，再替你记下','Review your reminder','確認してから保存'],
 ['选一个适合自己的时刻。确认前，不会创建提醒。','Choose a time that works for you. Nothing is created until you confirm.','都合のよい日時を選んでください。確認するまでリマインダーは作成されません。'],
 ['日期','Date','日付'],['时间','Time','時刻'],['来自你的记录','From your records','記録から'],
 ['我的提醒','My reminders','自分のリマインダー'],['修改提醒','Edit reminder','リマインダーを編集'],
 ['确认提醒','Confirm reminder','リマインダーを確定'],['已确认','Confirmed','確認済み'],
 ['保存修改','Save changes','変更を保存'],['新建提醒','New reminder','新規リマインダー'],
 ['修改时间 / 内容','Edit time / details','日時・内容を変更'],['标记完成','Mark complete','完了にする'],
 ['返回我的提醒','Back to my reminders','自分のリマインダーに戻る'],
 ['这是原型内的提醒，刷新后清空，不会发送系统通知。你确认的提醒与 AI 主动建议分别管理。','Prototype reminders reset on refresh and send no notifications. Confirmed reminders are managed separately from AI suggestions.','デモのリマインダーは再読み込みで消去され、通知は行いません。確認済みのリマインダーとAIの提案は別々に管理します。'],
 ['同时添加到 Apple 提醒事项','Also add to Apple Reminders','Appleのリマインダーにも追加'],
 ['选择 iCloud 列表','Choose an iCloud list','iCloudリストを選択'],
 ['返回提醒草稿','Back to reminder draft','リマインダーの下書きに戻る'],
 ['演示结果','Demo result','デモ結果'],
 ['可选 · 默认关闭','Optional · off by default','任意 · 初期設定はオフ'],
 ['Apple 提醒事项 · 权限演示','Apple Reminders · permission demo','Appleリマインダー · 権限デモ'],
 ['允许完整访问提醒事项？','Allow full access to reminders?','リマインダーへのフルアクセスを許可しますか？'],
 ['暂不允许 · 演示','Decline · demo','許可しない · デモ'],
 ['允许完整访问 · 演示','Allow full access · demo','フルアクセスを許可 · デモ'],
 ['未允许 Apple 提醒事项','Apple Reminders access declined','Appleリマインダーへのアクセス未許可'],
 ['仅保留在 WiseLife 草稿','Keep draft in WiseLife only','WiseLifeの下書きのみに保存'],
 ['查看系统设置预览 ›','View system settings preview ›','システム設定プレビューを見る ›'],
 ['系统设置 · 只读预览','System settings · read-only preview','システム設定 · 読み取り専用プレビュー'],
 ['模拟改为完整访问','Simulate granting full access','フルアクセスの許可をシミュレーション'],
 ['返回未允许状态','Return to declined state','未許可状態に戻る'],
 ['下一次 Apple 写入结果','Next Apple write result','次のApple書き込み結果'],
 ['成功','Success','成功'],['写入失败','Write failed','書き込み失敗'],
 ['权限已撤销','Permission revoked','権限取り消し済み'],
 ['没有可写列表','No writable lists','書き込み可能なリストなし'],
 ['Apple 只读预览','Apple read-only preview','Apple読み取り専用プレビュー'],
 ['重试添加 Apple','Retry adding to Apple','Appleへの追加を再試行'],
 ['Apple 提醒事项 · 只读预览','Apple Reminders · read-only preview','Appleリマインダー · 読み取り専用プレビュー'],
 ['← 返回我的提醒','← Back to my reminders','← 自分のリマインダーに戻る'],
 ['← 返回提醒草稿','← Back to reminder draft','← リマインダーの下書きに戻る'],
 ['提醒来源','Reminder source','リマインダーの参照元'],
 ['来源留在 WiseLife，不添加到 Apple 提醒事项。','Sources stay in WiseLife and are not added to Apple Reminders.','参照元はWiseLifeに残り、Appleリマインダーには追加されません。'],
 ['仅 WiseLife','WiseLife only','WiseLifeのみ'],
 ['已添加到 Apple · 演示','Added to Apple · demo','Appleに追加済み · デモ'],
 ['待重试 · 仅 WiseLife 提醒','Retry needed · WiseLife alerts only','再試行待ち · WiseLifeのみ通知']
];
window.daybookAppleRemindersCopy.push(...[["个人", "Personal", "個人"], ["工作", "Work", "仕事"], ["iCloud 列表通过 Apple 同步。默认只共享任务标题和日期时间；不共享转写或录音，来源记录保留在 WiseLife。", "iCloud lists sync through Apple. Only the task title, date and time are shared by default. Transcripts, audio and sources stay in WiseLife.", "iCloudリストはAppleを通じて同期します。初期設定ではタスク名と日時のみを共有し、文字起こし、音声、参照元はWiseLifeに残ります。"], ["关联后，修改、完成和删除会同时更新两处示例任务；WiseLife 不重复提醒。", "Linked edits, completion and deletion update both demo tasks. WiseLife suppresses duplicate alerts.", "連携後の変更、完了、削除は両方のデモタスクを更新し、WiseLifeからの重複通知は行いません。"], ["仅改变演示，不影响真实系统。", "Changes the demo only, with no effect on the real system.", "デモのみ変更し、実際のシステムには影響しません。"], ["以下为虚构的可写 iCloud 列表，由 Apple 同步。", "These are fictional writable iCloud lists synced through Apple.", "以下はAppleで同期する、架空の書き込み可能なiCloudリストです。"], ["用于选择可写列表、创建任务，以及保持关联任务的修改、完成和删除一致。真实产品会由系统请求完整访问；这里仅演示选择。", "Full access lets you select writable lists, create tasks and keep linked changes, completion and deletion consistent. The real product would request system permission; this only previews that choice.", "書き込み可能なリストの選択、タスク作成、連携タスクの変更・完了・削除の同期にフルアクセスを使います。実際の製品ではシステム権限を求めますが、ここでは選択を体験するだけです。"], ["仅共享标题和日期时间。来源、转写和录音留在 WiseLife。", "Only the title, date and time are shared. Sources, transcripts and audio stay in WiseLife.", "共有するのはタイトルと日時のみです。参照元、文字起こし、音声はWiseLifeに残ります。"], ["草稿仍在。你可以仅保留 WiseLife 提醒，或查看系统设置演示。", "Your draft is preserved. Keep a WiseLife-only reminder or preview system settings.", "下書きは保持されています。WiseLifeのみのリマインダーにするか、システム設定のデモを確認できます。"], ["设置 › App › WiseLife › 提醒事项", "Settings › Apps › WiseLife › Reminders", "設定 › アプリ › WiseLife › リマインダー"], ["当前演示权限：未允许。下面只改变原型状态，不会打开系统设置。", "Demo permission: declined. The control below only changes prototype state and does not open system settings.", "デモの権限：未許可。以下の操作はプロトタイプの状態のみを変更し、システム設定は開きません。"], ["交互演示：不会请求系统权限、访问 Apple 数据或发送通知。所有数据刷新后清空。", "Interaction demo: no system permission requests, Apple data access or notifications. Refreshing clears all data.", "操作デモです。システム権限の要求、Appleデータへのアクセス、通知は行いません。再読み込みですべてのデータが消去されます。"], ["完整访问未允许或已撤销", "Full access was declined or revoked", "フルアクセスが未許可または取り消されています"], ["没有可写的 iCloud 列表", "No writable iCloud lists", "書き込み可能なiCloudリストがありません"], ["Apple 写入失败", "Apple write failed", "Appleへの書き込みに失敗しました"], ["尚未添加到 Apple 示例列表。", "Not yet added to an Apple demo list.", "Appleのデモリストにはまだ追加されていません。"], ["只读镜像演示，没有打开真实 Apple App。关联任务从 WiseLife 修改、完成或删除时，两处示例同步更新；真实 Apple 外部变更未模拟。", "Read-only mirror demo; no real Apple app was opened. Editing, completing or deleting a linked task in WiseLife updates both demos. External Apple changes are not simulated.", "読み取り専用ミラーのデモで、実際のAppleアプリは開いていません。WiseLifeでの連携タスクの変更・完了・削除は両方のデモを更新します。Apple側での外部変更は再現していません。"], ["Apple 更新待重试 · 原任务可能仍提醒", "Apple update needs retry · the previous task may still alert", "Apple更新は再試行待ち · 元のタスクが通知する場合があります"], ["删除两处示例任务", "Delete both demo tasks", "両方のデモタスクを削除"], ["删除关联提醒？", "Delete linked reminder?", "連携リマインダーを削除しますか？"], ["确认后删除 WiseLife 和 Apple 中的两处示例任务。Apple 删除失败时，两处任务都会保留，可以重试。", "Confirm to delete both the WiseLife and Apple demo tasks. If Apple deletion fails, both tasks remain and you can retry.", "確認するとWiseLifeとAppleの両方のデモタスクを削除します。Apple側の削除に失敗した場合は両方を保持し、再試行できます。"], ["确认删除两处示例任务", "Confirm deletion of both demo tasks", "両方のデモタスクの削除を確認"], ["已删除两处示例任务。", "Both demo tasks deleted.", "両方のデモタスクを削除しました。"], ["Apple 删除失败，两处示例任务仍保留，请重试。", "Apple deletion failed. Both demo tasks remain; please retry.", "Apple側の削除に失敗しました。両方のデモタスクを保持しています。再試行してください。"], ["Apple 更新待重试，原任务可能仍提醒。", "Apple update needs retry. The previous task may still alert.", "Apple更新は再試行待ちです。元のタスクが通知する場合があります。"], ["已保留 WiseLife 提醒，可重试添加 Apple。", "WiseLife reminder kept. You can retry adding it to Apple.", "WiseLifeのリマインダーを保持しました。Appleへの追加を再試行できます。"], ["已保存示例提醒，不会发送系统通知。", "Demo reminder saved. No system notification will be sent.", "デモのリマインダーを保存しました。システム通知は送信しません。"], ["所有操作仅在本页内演示，刷新后清空。已添加 Apple 的任务仅由 Apple 提醒（概念演示），WiseLife 不重复提醒。修改、完成、删除会同步更新关联的两处示例；失败时保留 WiseLife 提醒并可重试。", "All actions are demos on this page and reset on refresh. Linked tasks use Apple alerts only (concept demo), avoiding duplicate WiseLife alerts. Linked edits, completion and deletion update both demos. Failed changes can be retried; a previous Apple task may still alert.", "操作はこのページ内のデモで、再読み込みで消去されます。連携タスクはAppleのみから通知する想定で、WiseLifeは重複通知しません。変更・完了・削除は両方のデモを更新します。失敗時は再試行できますが、元のAppleタスクが通知する場合があります。"]]);
window.createDaybookAppleReminders = function(app){
 'use strict';
 const {esc,openSheet}=app;
 let permission='unknown',result='success';
 const mirror=new Map();
 const lists=['WiseLife','个人','工作'];
 const back='<button type="button" class="text-button" data-apple-action="back">← 返回提醒草稿</button>';
 const disclosure='<p class="source-footnote">交互演示：不会请求系统权限、访问 Apple 数据或发送通知。所有数据刷新后清空。</p>';
 function controls(d){return `<section class="apple-reminder-card"><div class="ai-prefs-row"><div><strong>同时添加到 Apple 提醒事项</strong><p>可选 · 默认关闭</p></div><button type="button" class="switch" role="switch" aria-label="同时添加到 Apple 提醒事项" aria-checked="${!!d.appleEnabled}" data-apple-action="toggle"></button></div>${d.appleEnabled?`<button type="button" class="plain-row" data-apple-action="lists"><span>选择 iCloud 列表</span><strong><span>${esc(d.appleList||'WiseLife')}</span> ›</strong></button><p class="source-footnote">iCloud 列表通过 Apple 同步。默认只共享任务标题和日期时间；不共享转写或录音，来源记录保留在 WiseLife。</p><p class="source-footnote">关联后，修改、完成和删除会同时更新两处示例任务；WiseLife 不重复提醒。</p>`:''}<details class="apple-demo-results"><summary>演示结果</summary><label class="note-field"><span>下一次 Apple 写入结果</span><select id="appleDemoResult"><option value="success" ${result==='success'?'selected':''}>成功</option><option value="failure" ${result==='failure'?'selected':''}>写入失败</option><option value="revoked" ${result==='revoked'?'selected':''}>权限已撤销</option><option value="empty" ${result==='empty'?'selected':''}>没有可写列表</option></select></label><p class="source-footnote">仅改变演示，不影响真实系统。</p></details></section>`;}
 function choose(d){openSheet('选择 iCloud 列表',`${back}<p class="sheet-intro">以下为虚构的可写 iCloud 列表，由 Apple 同步。</p>${lists.map(name=>`<button class="plain-row" data-apple-list="${name}"><span>${name}</span><span>${(d.appleList||'WiseLife')===name?'✓':''}</span></button>`).join('')}${disclosure}`);}
 function permissionSheet(){openSheet('Apple 提醒事项 · 权限演示',`${back}<h3>允许完整访问提醒事项？</h3><p class="sheet-intro">用于选择可写列表、创建任务，以及保持关联任务的修改、完成和删除一致。真实产品会由系统请求完整访问；这里仅演示选择。</p><p class="source-footnote">仅共享标题和日期时间。来源、转写和录音留在 WiseLife。</p><div class="sheet-actions"><button class="secondary-button" data-apple-action="decline">暂不允许 · 演示</button><button class="primary-button" data-apple-action="allow">允许完整访问 · 演示</button></div>${disclosure}`);}
 function denied(){openSheet('未允许 Apple 提醒事项',`${back}<p class="sheet-intro">草稿仍在。你可以仅保留 WiseLife 提醒，或查看系统设置演示。</p><button class="primary-button wide" data-apple-action="local">仅保留在 WiseLife 草稿</button><button class="plain-row" data-apple-action="settings">查看系统设置预览 ›</button>${disclosure}`);}
 function settings(){openSheet('系统设置 · 只读预览',`${back}<p class="sheet-intro">设置 › App › WiseLife › 提醒事项</p><p>当前演示权限：未允许。下面只改变原型状态，不会打开系统设置。</p><button class="primary-button wide" data-apple-action="allow">模拟改为完整访问</button><button class="text-button" data-apple-action="decline">返回未允许状态</button>${disclosure}`);}
 function write(r){
  if(!r.appleEnabled&&!r.appleId){r.appleStatus='local';r.appleError='';return;}
  if(result==='revoked')permission='denied';
  if(permission!=='allowed'||result!=='success'){r.appleStatus=r.appleId?'pending':'failed';r.appleError=permission!=='allowed'?'完整访问未允许或已撤销':result==='empty'?'没有可写的 iCloud 列表':'Apple 写入失败';return;}
  if(!r.appleEnabled){mirror.delete(r.appleId);r.appleId=null;r.appleStatus='local';r.appleError='';return;}
  r.appleId=r.appleId||`apple-${r.id}`;r.appleStatus='linked';r.appleError='';mirror.set(r.appleId,{title:r.title,date:r.date,time:r.time,done:r.done,list:r.appleList||'WiseLife'});
 }
 function preview(r){const item=mirror.get(r.appleId);openSheet('Apple 提醒事项 · 只读预览',`<button class="text-button" data-ai-action="reminders">← 返回我的提醒</button>${item?`<div class="apple-reminder-card"><p>iCloud · <span>${esc(item.list)}</span></p><h3>${item.done?'✓ ':''}${esc(item.title)}</h3><p>${esc(item.date)} ${esc(item.time)}</p></div>`:'<p>尚未添加到 Apple 示例列表。</p>'}<p class="source-footnote">只读镜像演示，没有打开真实 Apple App。关联任务从 WiseLife 修改、完成或删除时，两处示例同步更新；真实 Apple 外部变更未模拟。</p>${disclosure}`);}
 return {controls,choose,permissionSheet,denied,settings,write,preview,permission:()=>permission,setPermission:value=>permission=value,setResult:value=>{if(['success','failure','revoked','empty'].includes(value))result=value;},remove:r=>{if(r.appleId&&(permission!=='allowed'||result!=='success'))return false;mirror.delete(r.appleId);return true;},status:r=>`<span>${r.appleStatus==='linked'?'已添加到 Apple · 演示':r.appleStatus==='pending'?'Apple 更新待重试 · 原任务可能仍提醒':r.appleStatus==='failed'?'待重试 · 仅 WiseLife 提醒':'仅 WiseLife'}</span>${r.appleError?`<br><span>${esc(r.appleError)}</span>`:''}`,needsPermission:()=>permission!=='allowed'};
};
