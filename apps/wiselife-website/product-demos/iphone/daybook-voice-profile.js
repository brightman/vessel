/* Enrollment interaction demo: no microphone, audio, embeddings, network or storage.
   Saved metadata lives in this page only and is never used as an actual voice profile. */
window.createDaybookVoiceProfile = function(app) {
  'use strict';
  const {$, esc, icon, toast, openSheet, closeSheet} = app;
  const MIN_SECONDS = 30, MAX_SECONDS = 60;
  let profile = null, phase = 'closed', timer = null, startedAt = 0, seconds = 0;
  const clock = value => `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;
  const button = (action, text, style = 'secondary-button', glyph = '') => `<button type="button" class="${style}" data-voice-action="${action}">${glyph ? icon(glyph) : ''}${text}</button>`;
  const demo = '<span class="voice-profile-demo">交互演示 · 不采集声音</span>';
  const privacy = () => `<p class="voice-profile-privacy">${icon('ShieldCheck')}<span>声音档案仅保存在本机，不上传云端，可随时删除。</span></p>`;
  const prompt = () => '<div class="voice-profile-prompt"><strong>可以聊聊今天</strong><p>今天准备做些什么？最近有什么让你在意的小事？按平常的语速，接着说说自己的想法。</p></div>';
  const wave = running => `<div class="voice-profile-wave ${running ? 'is-recording' : ''}" aria-hidden="true">${Array.from({length:31}, (_, i) => `<span style="--height:${8 + ((i * 13 + 7) % 34)}px;--delay:-${(i % 7) * .17}s"></span>`).join('')}</div>`;
  function stopTimer() { clearInterval(timer); timer = null; }
  function label() {
    $('dayMyVoiceLabel').textContent = profile ? '已登记 · 在录音中识别我的发言' : '未登记 · 让笔记认出我说的话';
    $('dayMyVoiceLabel').dataset.enrolled = String(Boolean(profile));
  }
  function show(next, markup) {
    stopTimer(); phase = next;
    openSheet('我的声音', `<section id="myVoicePanel" data-phase="${next}">${demo}${markup}</section>`);
  }
  function intro() {
    seconds = 0;
    show('intro', `<div class="voice-profile-hero"><div class="voice-profile-mark">${icon('AudioLines')}</div><h3>让笔记认出你的声音</h3><p>录下 30～60 秒独立讲话，<br>在多人录音中，找到你说的话。</p><div class="voice-profile-facts"><span>${icon('Clock3')}30–60 秒</span><span>${icon('Mic')}iPhone 麦克风</span></div></div>
      <ol class="voice-profile-tips"><li><span>01</span><div><strong>找一个安静的地方</strong><p>避开音乐、电视和其他人的声音。</p></div></li><li><span>02</span><div><strong>只录你一个人讲话</strong><p>用平常的语气连续说话，不用刻意念得标准。</p></div></li></ol>
      ${prompt()}${privacy()}${profile ? '<p class="voice-profile-note">新录音保存后才会替换当前登记。</p>' : ''}
      <div class="voice-profile-actions">${profile ? button('open', '返回') : ''}${button('start', '开始录制', 'primary-button voice-profile-record', 'Mic')}</div>
      <p class="voice-profile-note">登记状态仅保留在当前页面，刷新后清空。</p>`);
  }
  function start() {
    if (phase !== 'intro') return;
    seconds = 0;
    show('recording', `<div class="voice-profile-hero"><h3>说说此刻的你</h3><p>按平常的语速，只录你一个人讲话。</p><output class="voice-profile-timer" id="myVoiceClock" aria-label="录制时长">00:00</output>${wave(true)}</div>
      <div class="voice-profile-progress" id="myVoiceProgress" role="progressbar" aria-label="声音登记录制进度" aria-valuemin="0" aria-valuemax="60" aria-valuenow="0"><span id="myVoiceProgressFill"></span></div><div class="voice-profile-scale"><span>0:00</span><span>0:30</span><span>1:00</span></div>
      <p class="voice-profile-status" id="myVoiceStatus" role="status">录满 30 秒后可结束，60 秒自动停止。</p>${prompt()}
      <div class="voice-profile-actions">${button('cancel', '取消')}${button('finish', '结束录音', 'primary-button voice-profile-record', 'Square')}</div>
      <p class="voice-profile-note">退出将放弃本次录音，已有登记不受影响。</p>
      <details class="voice-profile-demo-controls"><summary>原型演示控制</summary><div>${button('skip30', '快进至 30 秒')}${button('skip60', '快进至 60 秒')}</div></details>`);
    startedAt = performance.now();
    updateRecording();
    timer = setInterval(updateRecording, 200);
  }
  function updateRecording() {
    if (phase !== 'recording' || !$('sheet').open || !$('myVoiceClock')) { stopTimer(); return; }
    seconds = Math.min(MAX_SECONDS, Math.floor((performance.now() - startedAt) / 1000));
    const text = clock(seconds);
    if ($('myVoiceClock').textContent !== text) $('myVoiceClock').textContent = text;
    $('myVoiceProgress').setAttribute('aria-valuenow', String(seconds));
    $('myVoiceProgressFill').style.width = `${seconds / MAX_SECONDS * 100}%`;
    const finish = $('myVoicePanel').querySelector('[data-voice-action="finish"]');
    if (finish.disabled === (seconds >= MIN_SECONDS)) {
      finish.disabled = seconds < MIN_SECONDS;
      $('myVoiceStatus').textContent = seconds >= MIN_SECONDS ? '现在可以结束，也可以继续说到 60 秒。' : '录满 30 秒后可结束，60 秒自动停止。';
    }
    if (seconds >= MAX_SECONDS) review();
  }
  function skip(target) {
    if (phase !== 'recording') return;
    startedAt = Math.min(startedAt, performance.now() - target * 1000);
    updateRecording();
  }
  function review() {
    if (phase !== 'recording' || seconds < MIN_SECONDS) return;
    show('review', `<div class="voice-profile-hero"><div class="voice-profile-mark">${icon('Check')}</div><h3>这一段，是你的声音</h3><p>${seconds === MAX_SECONDS ? '已录满 60 秒，录音自动结束。' : '录音已结束，确认后保存声音档案。'}</p><span class="voice-profile-timer">${clock(seconds)}</span></div>
      <label class="voice-profile-confirm"><input type="checkbox" id="myVoiceSolo"><span>这段录音中只有我在讲话</span></label><p class="voice-profile-note">如果混入了其他人的声音，建议重新录制。</p>${privacy()}
      <div class="voice-profile-actions">${button('retry', '重新录制')}${button('save', '保存我的声音', 'primary-button', 'Check')}</div>
      <p class="voice-profile-note">演示不生成真实声音档案，也不会改变已有笔记。</p>`);
    $('myVoicePanel').querySelector('[data-voice-action="save"]').disabled = true;
  }
  function registered() {
    if (!profile) { intro(); return; }
    show('registered', `<div class="voice-profile-hero"><div class="voice-profile-mark voice-profile-success">${icon('CheckCheck')}</div><h3>我的声音已登记</h3><p>之后的录音，会尝试把你的发言标记为“我”。</p></div>
      <dl class="voice-profile-meta"><div><dt>登记时长</dt><dd>${clock(profile.seconds)}</dd></div><div><dt>最近登记</dt><dd><time datetime="${profile.date.toISOString()}">${esc(profile.date.getFullYear() + '-' + String(profile.date.getMonth()+1).padStart(2,'0') + '-' + String(profile.date.getDate()).padStart(2,'0'))}</time></dd></div><div><dt>保存位置</dt><dd>仅此 iPhone</dd></div></dl>
      <div class="voice-profile-sample"><strong>笔记中的显示效果 · 示例</strong><p><span>我</span><q>这件事，我想再花一点时间。</q></p><p><span>说话人 1</span><q>好，我们明天接着聊。</q></p></div>
      <p class="voice-profile-note">只把有把握的片段标记为“我”；不确定时保留说话人标签，可手动修改。</p>${privacy()}
      <div class="voice-profile-actions">${button('retry', '重新录制')}${button('done', '完成', 'primary-button')}</div>${button('delete', '删除我的声音', 'voice-profile-delete')}
      <p class="voice-profile-note">演示不生成真实声音档案，也不会改变已有笔记。</p>`);
  }
  function confirmDelete() {
    if (!profile) return;
    show('delete', `<div class="voice-profile-hero"><div class="voice-profile-mark">${icon('Mic')}</div><h3>删除我的声音？</h3><p>删除后，后续录音不再自动匹配“我”。<br>已有笔记和手动标注会保留。</p></div><div class="voice-profile-actions">${button('open', '保留登记')}${button('confirm-delete', '确认删除', 'primary-button voice-profile-record')}</div>`);
  }
  function open() { profile ? registered() : intro(); }
  $('sheetBody').addEventListener('click', event => {
    const target = event.target.closest('#myVoicePanel [data-voice-action]');
    if (!target || target.disabled) return;
    const actions = {
      open, start, finish:review, retry:intro, done:closeSheet,
      cancel:() => profile ? registered() : intro(),
      skip30:() => skip(30), skip60:() => skip(60), delete:confirmDelete,
      save:() => {
        if (phase !== 'review' || !$('myVoiceSolo')?.checked || seconds < MIN_SECONDS || seconds > MAX_SECONDS) return;
        profile = {seconds, date:new Date()}; label(); registered();
      },
      'confirm-delete':() => {
        if (phase !== 'delete') return;
        profile = null; label(); intro(); toast('声音登记已删除（演示）。');
      }
    };
    actions[target.dataset.voiceAction]?.();
  });
  $('sheetBody').addEventListener('change', event => {
    if (event.target.id === 'myVoiceSolo' && phase === 'review') $('myVoicePanel').querySelector('[data-voice-action="save"]').disabled = !event.target.checked;
  });
  function abandonDraft() { stopTimer(); phase = 'closed'; seconds = 0; }
  $('sheet').addEventListener('close', abandonDraft);
  $('sheet').addEventListener('cancel', abandonDraft);
  window.addEventListener('pagehide', abandonDraft);
  label();
  return {open};
};

window.daybookVoiceProfileCopy = [
  ['完成', 'Done', '完了'],
  ['返回', 'Back', '戻る'],
  ['我的声音', 'My voice', '自分の声'],
  ['未登记 · 让笔记认出我说的话', 'Not enrolled · Recognize my words', '未登録 · 自分の発言を見つける'],
  ['已登记 · 在录音中识别我的发言', 'Enrolled · Identify my speech', '登録済み · 自分の発言を識別'],
  ['交互演示 · 不采集声音', 'Interactive demo · No audio captured', '操作デモ · 音声は収集しません'],
  ['让笔记认出你的声音', 'Let your notes know your voice', 'ノートに、あなたの声を'],
  ['录下 30～60 秒独立讲话，', 'Record 30–60 seconds of just you,', '自分だけの声を30〜60秒録音して、'],
  ['在多人录音中，找到你说的话。', 'and find your words in conversations.', '会話の中から自分の発言を見つけます。'],
  ['30–60 秒', '30–60 sec', '30〜60秒'],
  ['iPhone 麦克风', 'iPhone microphone', 'iPhoneのマイク'],
  ['找一个安静的地方', 'Find a quiet place', '静かな場所で'],
  ['避开音乐、电视和其他人的声音。', 'Avoid music, TV and other voices.', '音楽やテレビ、他の人の声を避けましょう。'],
  ['只录你一个人讲话', 'Only you should be speaking', '話すのは自分だけ'],
  ['用平常的语气连续说话，不用刻意念得标准。', 'Speak naturally for a while. No need to sound formal.', 'いつもの声で続けて話しましょう。かしこまる必要はありません。'],
  ['可以聊聊今天', 'Talk about your day', '今日のことを話してみましょう'],
  ['今天准备做些什么？最近有什么让你在意的小事？按平常的语速，接着说说自己的想法。', 'What are your plans today? What has been on your mind? Keep going at your usual pace.', '今日は何をする予定ですか？最近気になったことは？いつもの速さで、思ったことを続けて話してください。'],
  ['声音档案仅保存在本机，不上传云端，可随时删除。', 'Your voice profile stays on this device, with no cloud upload. Delete it anytime.', '声のプロフィールは端末内だけに保存。クラウドに送信せず、いつでも削除できます。'],
  ['新录音保存后才会替换当前登记。', 'Your current profile stays until you save a new one.', '新しい録音を保存するまで、今の登録は残ります。'],
  ['开始录制', 'Start recording', '録音を始める'],
  ['登记状态仅保留在当前页面，刷新后清空。', 'Demo enrollment resets when you refresh this page.', '登録のデモ状態はページを再読み込みすると消えます。'],
  ['说说此刻的你', 'Tell us what’s on your mind', '今の自分について話す'],
  ['按平常的语速，只录你一个人讲话。', 'Speak at your usual pace, with no other voices.', 'いつもの速さで、自分だけが話してください。'],
  ['录制时长', 'Recording duration', '録音時間'],
  ['声音登记录制进度', 'Voice enrollment progress', '声の登録の録音状況'],
  ['录满 30 秒后可结束，60 秒自动停止。', 'Finish after 30 seconds. Stops automatically at 60.', '30秒で終了可能。60秒で自動停止します。'],
  ['现在可以结束，也可以继续说到 60 秒。', 'Finish now, or keep going up to 60 seconds.', 'ここで終了するか、60秒まで続けられます。'],
  ['结束录音', 'Finish recording', '録音を終了'],
  ['退出将放弃本次录音，已有登记不受影响。', 'Leaving discards this take and keeps your existing profile.', '閉じると今回の録音は破棄され、今の登録は残ります。'],
  ['原型演示控制', 'Prototype demo controls', 'プロトタイプのデモ操作'],
  ['快进至 30 秒', 'Skip to 30 seconds', '30秒まで進める'],
  ['快进至 60 秒', 'Skip to 60 seconds', '60秒まで進める'],
  ['这一段，是你的声音', 'A little of your voice', 'あなたの声を残しました'],
  ['已录满 60 秒，录音自动结束。', '60 seconds reached. Recording stopped automatically.', '60秒になり、録音を自動で終了しました。'],
  ['录音已结束，确认后保存声音档案。', 'Recording finished. Confirm to save your voice profile.', '録音が終了しました。確認して保存してください。'],
  ['这段录音中只有我在讲话', 'I am the only person speaking in this recording', 'この録音では自分だけが話しています'],
  ['如果混入了其他人的声音，建议重新录制。', 'If someone else spoke, please record again.', '他の人の声が入った場合は、録り直してください。'],
  ['重新录制', 'Record again', '録り直す'],
  ['保存我的声音', 'Save my voice', '自分の声を保存'],
  ['演示不生成真实声音档案，也不会改变已有笔记。', 'This demo creates no real voice profile and does not change your notes.', 'このデモは実際の声のプロフィールを作成せず、既存のノートも変更しません。'],
  ['我的声音已登记', 'Your voice is enrolled', '自分の声を登録しました'],
  ['之后的录音，会尝试把你的发言标记为“我”。', 'Future recordings will try to label your speech as “Me”.', '今後の録音で、自分の発言を「自分」と表示します。'],
  ['登记时长', 'Sample length', '登録した録音の長さ'],
  ['最近登记', 'Last enrolled', '最終登録日'],
  ['保存位置', 'Stored on', '保存先'],
  ['仅此 iPhone', 'This iPhone only', 'このiPhoneのみ'],
  ['笔记中的显示效果 · 示例', 'How it looks in a note · Example', 'ノートでの表示例'],
  ['我', 'Me', '自分'],
  ['说话人 1', 'Speaker 1', '話者1'],
  ['这件事，我想再花一点时间。', 'I’d like a little more time on this.', 'このことは、もう少し時間をかけたいです。'],
  ['好，我们明天接着聊。', 'Sure, let’s pick this up tomorrow.', 'では、また明日話しましょう。'],
  ['只把有把握的片段标记为“我”；不确定时保留说话人标签，可手动修改。', 'Only confident matches get “Me”. Uncertain segments keep a speaker label you can edit.', '確信のある発言だけを「自分」と表示。不確かな部分には話者名を残し、手動で変更できます。'],
  ['删除我的声音', 'Delete my voice', '自分の声を削除'],
  ['删除我的声音？', 'Delete your voice profile?', '自分の声を削除しますか？'],
  ['删除后，后续录音不再自动匹配“我”。', 'New recordings will no longer match your voice to “Me”.', '今後の録音で「自分」の自動識別が停止します。'],
  ['已有笔记和手动标注会保留。', 'Existing notes and manual labels will be kept.', '既存のノートや手動の話者名は残ります。'],
  ['保留登记', 'Keep my voice', '登録を残す'],
  ['确认删除', 'Confirm deletion', '削除する'],
  ['声音登记已删除（演示）。', 'Voice enrollment deleted (demo).', '声の登録を削除しました（デモ）。']
];
