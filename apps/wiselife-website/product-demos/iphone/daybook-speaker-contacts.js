/* Fictional contacts, page-memory bindings. No Contacts or voice identification APIs. */
window.createDaybookSpeakerContacts = function (app) {
  'use strict';
  const {$, esc, icon, openSheet, toast, getRecord, returnToRecord} = app;
  const contacts = [
    {id:'demo-chen', name:'陈一舟', detail:'同事 · 产品', initial:'陈', tone:'blue'},
    {id:'demo-lin', name:'林晓', detail:'同事 · 设计', initial:'林', tone:'sage'},
    {id:'demo-zhang', name:'张明', detail:'朋友', initial:'张', tone:'sand'},
    {id:'demo-zhou', name:'周予安', detail:'同事 · 研发', initial:'周', tone:'plum'}
  ];
  const bindings = new Map();
  let context = null, selected = null;
  const key = (recordID, speakerID) => `${recordID}:${speakerID}`;
  const binding = () => bindings.get(key(context.recordID, context.speakerID));
  const fallbackName = id => id === 'speaker-1' ? '说话人 1' : '说话人 2';
  const back = (action, title) => `<button type="button" class="people-back" data-people-action="${action}">${icon('ChevronLeft')}<span>${title}</span></button>`;
  const demo = () => '<p class="people-demo">交互原型 · 联系人为虚构示例，刷新后清空。</p>';
  function segments(record) {
    if (!['review','meeting'].includes(record.id)) return [];
    return (record.text.match(/[^。！？]+[。！？]?/g) || []).map((text, index) => ({
      speakerID: `speaker-${index % 2 + 1}`, text: text.trim(),
      time: `${String(Math.floor(index * 47 / 60)).padStart(2,'0')}:${String(index * 47 % 60).padStart(2,'0')}`
    }));
  }
  function identity(recordID, speakerID) {
    const current = bindings.get(key(recordID, speakerID));
    const contact = contacts.find(row => row.id === current?.contactID);
    return {name:contact?.name || current?.name || fallbackName(speakerID), contact};
  }
  const avatar = (contact, large = false) => `<span class="people-avatar ${contact?.tone || 'neutral'}${large?' large':''}" aria-hidden="true">${contact ? esc(contact.initial) : icon('Mic')}</span>`;
  function transcript(record) {
    const turns = segments(record);
    if (!turns.length) return esc(record.text);
    return `<div class="people-transcript"><p class="people-transcript-hint">点击说话人，可关联通讯录联系人</p>${turns.map(turn => {
      const who = identity(record.id, turn.speakerID);
      return `<article class="people-turn"><header><button type="button" class="people-speaker" data-people-record="${esc(record.id)}" data-people-speaker="${turn.speakerID}">${avatar(who.contact)}<span translate="${who.contact || bindings.get(key(record.id,turn.speakerID))?.name?'no':'yes'}">${esc(who.name)}</span><span class="people-sr-only">管理说话人</span>${icon(who.contact?'Link2':'ChevronDown')}</button><time>${turn.time}</time></header><p>${esc(turn.text)}</p></article>`;}).join('')}<p class="people-caption">说话人标签与时间仅为示例。关联仅用于当前录音。</p></div>`;
  }
  function overview(record) {
    if (!segments(record).length) return '';
    return `<button type="button" class="people-overview" data-people-transcript="${esc(record.id)}">${icon('MessageCircle')}<span>2 位说话人<span class="people-overview-names">${[1,2].map(number=>{const id=`speaker-${number}`,who=identity(record.id,id);return `<span translate="${who.contact || bindings.get(key(record.id,id))?.name?'no':'yes'}">${esc(who.name)}</span>`;}).join(' · ')}</span></span>${icon('ChevronRight')}</button>`;
  }
  function manage(recordID, speakerID) {
    if (!getRecord(recordID) || !['speaker-1','speaker-2'].includes(speakerID)) return;
    context = {recordID, speakerID}; selected = null;
    const record = getRecord(recordID), who = identity(recordID, speakerID);
    const turns = segments(record).filter(turn=>turn.speakerID===speakerID);
    openSheet('说话人',`${back('transcript','返回全文')}
      <div class="people-person">${avatar(who.contact,true)}<h3 translate="${who.contact || binding()?.name?'no':'yes'}">${esc(who.name)}</h3><span class="people-status">${who.contact?'已关联联系人':binding()?.name?'已手动命名':'尚未关联联系人'}</span></div>
      <div class="people-sample"><span>${turns[0]?.time || '00:00'} · <span>原文片段</span></span><blockquote>${esc(turns[0]?.text || '')}</blockquote></div>
      <div class="people-menu"><button type="button" class="people-row" data-people-action="contacts">${icon('Link2')}<span><strong>${who.contact?'更换联系人':'关联联系人'}</strong><small>${who.contact?'选择另一个人':'从通讯录中选择这位说话人'}</small></span>${icon('ChevronRight')}</button>
      ${who.contact?`<button type="button" class="people-row people-danger" data-people-action="unlink">${icon('Unlink')}<span>解除关联</span>${icon('ChevronRight')}</button>`:`<button type="button" class="people-row" data-people-action="rename">${icon('NotebookPen')}<span><strong>手动命名</strong><small>不在通讯录里，也可以记下名字</small></span>${icon('ChevronRight')}</button>`}</div>
      <p class="people-caption">应用于这条录音中该说话人的所有段落。其他录音不会改变，也不会自动识别此人的声音。</p>${demo()}`);
  }
  function contactRows(query = '') {
    const normalized = query.trim().toLocaleLowerCase();
    const matches = contacts.filter(contact=>`${contact.name} ${contact.detail}`.toLocaleLowerCase().includes(normalized));
    return matches.length ? matches.map(contact=>`<button type="button" class="people-contact" data-people-contact="${contact.id}">${avatar(contact)}<span><strong translate="no">${esc(contact.name)}</strong><small>${esc(contact.detail)}</small></span>${icon('ChevronRight')}</button>`).join('') : `<div class="people-empty">${icon('Search')}<h3>没有找到联系人</h3><p>换个名字搜索，或返回后手动命名。</p></div>`;
  }
  function picker() {
    selected = null;
    openSheet('选择联系人',`${back('manage','返回说话人')}<p class="people-system-label">系统联系人选择器 · 交互示意</p><label class="people-search">${icon('Search')}<input id="peopleSearch" type="search" placeholder="搜索示例联系人" aria-label="搜索示例联系人" autocomplete="off"></label><div id="peopleContactResults" class="people-contact-list">${contactRows()}</div><p class="people-caption">只获取你选中的联系人，无需开放整个通讯录。</p>${demo()}`);
  }
  function confirmContact(contactID) {
    selected = contacts.find(contact=>contact.id===contactID);
    if (!selected) return;
    openSheet('确认关联',`${back('contacts','重新选择')}<div class="people-person">${avatar(selected,true)}<h3 translate="no">${esc(selected.name)}</h3><p>${esc(selected.detail)}</p></div><div class="people-confirm"><span>${esc(fallbackName(context.speakerID))}</span>${icon('ArrowRight')}<strong translate="no">${esc(selected.name)}</strong></div><p class="people-caption">应用于这条录音中该说话人的所有段落。其他录音不会改变，也不会自动识别此人的声音。</p><button type="button" class="primary-button wide" data-people-action="confirm">${icon('Check')}确认关联</button><button type="button" class="people-cancel" data-people-action="manage">取消</button>${demo()}`);
  }
  function rename() {
    openSheet('手动命名',`${back('manage','返回说话人')}<form id="peopleNameForm"><label class="note-field"><span>说话人名称</span><input id="peopleName" maxlength="30" value="${esc(binding()?.name || '')}" placeholder="例如：同事、朋友" autocomplete="off"></label><p class="people-caption">仅修改当前录音。留空可恢复默认名称。</p><button type="submit" class="primary-button wide">保存名称</button></form>`);
  }
  function unlink() {
    openSheet('解除联系人关联？',`${back('manage','返回说话人')}<p class="sheet-intro">这条录音会恢复默认说话人名称。通讯录联系人和录音内容都会保留。</p><button type="button" class="primary-button wide" data-people-action="confirm-unlink">解除关联</button><button type="button" class="people-cancel" data-people-action="manage">保留关联</button>`);
  }
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');if(!button)return;
    if(button.dataset.peopleTranscript){returnToRecord(button.dataset.peopleTranscript);return;}
    if(button.dataset.peopleSpeaker){manage(button.dataset.peopleRecord,button.dataset.peopleSpeaker);return;}
    if(!context)return;
    if(button.dataset.peopleContact){confirmContact(button.dataset.peopleContact);return;}
    const action=button.dataset.peopleAction;
    if(action==='transcript'){returnToRecord(context.recordID);return;}
    if(action==='manage'){manage(context.recordID,context.speakerID);return;}
    if(action==='contacts'){picker();return;}
    if(action==='rename'){rename();return;}
    if(action==='unlink'){unlink();return;}
    if(action==='confirm'&&selected){
      bindings.set(key(context.recordID,context.speakerID),{contactID:selected.id});
      returnToRecord(context.recordID);toast('已关联，当前录音中的说话人名称已更新。');return;
    }
    if(action==='confirm-unlink'){
      bindings.delete(key(context.recordID,context.speakerID));returnToRecord(context.recordID);toast('已解除关联，通讯录联系人保持不变。');
    }
  });
  document.addEventListener('input',event=>{
    if(event.target.id==='peopleSearch') $('peopleContactResults').innerHTML=contactRows(event.target.value);
  });
  document.addEventListener('submit',event=>{
    if(event.target.id!=='peopleNameForm'||!context)return;
    event.preventDefault();const name=$('peopleName').value.trim();
    if(name)bindings.set(key(context.recordID,context.speakerID),{name});
    else bindings.delete(key(context.recordID,context.speakerID));
    returnToRecord(context.recordID);toast('当前录音中的名称已更新。');
  });
  return {transcript, overview};
};

window.daybookSpeakerContactsCopy = [
  ['管理说话人','Manage speaker','話者を管理'],
  ['点击说话人，可关联通讯录联系人','Tap a speaker to link a contact','話者をタップして連絡先を関連付け'],
  ['说话人 1','Speaker 1','話者1'],['说话人 2','Speaker 2','話者2'],['说话人','Speaker','話者'],
  ['2 位说话人','2 speakers','2人の話者'],['返回全文','Back to transcript','全文に戻る'],
  ['说话人标签与时间仅为示例。关联仅用于当前录音。','Speaker labels and times are examples. Links apply only to this recording.','話者と時刻はサンプルです。関連付けはこの録音にのみ適用されます。'],
  ['交互原型 · 联系人为虚构示例，刷新后清空。','Interactive prototype · fictional contacts. Changes reset on refresh.','操作デモ・連絡先は架空です。再読み込みでリセットされます。'],
  ['已关联联系人','Contact linked','連絡先を関連付け済み'],['已手动命名','Named manually','手動で名前を設定済み'],['尚未关联联系人','No contact linked','連絡先は未設定'],
  ['原文片段','Transcript excerpt','原文の抜粋'],['更换联系人','Change contact','連絡先を変更'],['关联联系人','Link contact','連絡先を関連付け'],
  ['选择另一个人','Choose someone else','別の人を選択'],['从通讯录中选择这位说话人','Choose this speaker from your contacts','連絡先からこの話者を選択'],
  ['解除关联','Unlink contact','関連付けを解除'],['手动命名','Name manually','手動で名前を設定'],['不在通讯录里，也可以记下名字','Add a name even without a contact','連絡先になくても名前を記録できます'],
  ['应用于这条录音中该说话人的所有段落。其他录音不会改变，也不会自动识别此人的声音。','Applies to all this speaker’s segments in this recording. Other recordings stay unchanged; this does not enable voice identification.','この録音内の同じ話者の全発言に適用されます。他の録音は変わらず、声の自動識別も有効になりません。'],
  ['返回说话人','Back to speaker','話者に戻る'],['系统联系人选择器 · 交互示意','System contact picker · preview','システム連絡先選択・デモ'],['选择联系人','Choose a contact','連絡先を選択'],
  ['搜索示例联系人','Search example contacts','サンプルの連絡先を検索'],['没有找到联系人','No contacts found','連絡先が見つかりません'],
  ['换个名字搜索，或返回后手动命名。','Try another name, or go back to name manually.','別の名前を検索するか、戻って手動で名前を設定してください。'],
  ['只获取你选中的联系人，无需开放整个通讯录。','Only the contact you choose is shared. Full address book access is not needed.','選んだ連絡先のみを取得します。連絡先全体へのアクセスは不要です。'],
  ['同事 · 产品','Colleague · Product','同僚・プロダクト'],['同事 · 设计','Colleague · Design','同僚・デザイン'],['朋友','Friend','友人'],['同事 · 研发','Colleague · Engineering','同僚・開発'],
  ['确认关联','Confirm link','関連付ける'],['重新选择','Choose again','選び直す'],['说话人名称','Speaker name','話者の名前'],['例如：同事、朋友','For example: colleague, friend','例：同僚、友人'],
  ['仅修改当前录音。留空可恢复默认名称。','Changes this recording only. Leave blank to restore the default label.','この録音にのみ適用。空欄にすると既定の名前に戻ります。'],['保存名称','Save name','名前を保存'],
  ['解除联系人关联？','Unlink this contact?','連絡先の関連付けを解除しますか？'],['这条录音会恢复默认说话人名称。通讯录联系人和录音内容都会保留。','The default speaker label will be restored. The contact and recording are kept.','既定の話者名に戻します。連絡先と録音内容は保持されます。'],['保留关联','Keep link','関連付けを保持'],
  ['已关联，当前录音中的说话人名称已更新。','Linked. The speaker name in this recording has been updated.','関連付けました。この録音の話者名を更新しました。'],
  ['已解除关联，通讯录联系人保持不变。','Unlinked. Your contact is unchanged.','関連付けを解除しました。連絡先は変更されていません。'],['当前录音中的名称已更新。','Name updated in this recording.','この録音の名前を更新しました。'],
  ['新功能体验','Try the new flows','新機能を試す'],['说话人关联联系人','Link a speaker to a contact','話者と連絡先の関連付け'],['添加到 Apple 提醒事项','Add to Apple Reminders','Apple リマインダーに追加']
];
