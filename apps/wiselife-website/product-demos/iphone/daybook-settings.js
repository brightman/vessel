/* Settings navigation prototype. Resource, index and Face ID states are in-memory demos only. */
window.createDaybookSettings = function(app) {
  'use strict';
  const {icon, openSheet, toast} = app;
  const languageNames = {'zh-Hans':'简体中文',en:'English','zh-Hant':'繁體中文',ja:'日本語'};
  const vectors = new Set(['zh-Hans']);
  let language = 'zh-Hans', translationReady = false, indexReady = true;
  const note = '<p class="source-footnote">交互演示，不下载资源，不更改系统设置或真实数据。</p>';
  const row = (title, text, symbol, action) => `<button class="capture-option" data-settings-action="${action}">${icon(symbol)}<div><strong>${title}</strong><p>${text}</p></div>${icon('ChevronRight')}</button>`;
  const detail = content => `<div class="settings-detail">${content}</div>${note}`;
  function shortcuts() {
    openSheet('快捷设置', detail(`<p>用适合你的方式，快速开始和保存录音。</p><h3>快捷录音</h3>${row('操作按钮','长按开始，再次长按停止并保存','SlidersHorizontal','action-button')}${row('锁屏小组件','从锁屏快速开始录音','Mic','lockscreen')}${row('实时活动','查看录音时长，停止并保存','Activity','live-activity')}<p>录音由你主动开始，先保存在本机，再按所选模型转写。</p>`));
  }
  function instructions(kind) {
    const contents = {
      'action-button':['操作按钮','打开 iPhone 设置，选择「操作按钮」。','选择「快捷指令」→「选取快捷指令」。','选择 WiseLife 的「开始／停止录音」。'],
      lockscreen:['锁屏小组件','长按锁屏，选择「自定」→「锁定屏幕」。','轻点「添加小组件」→ WiseLife →「快捷录音」。','轻点开始录音，通过实时活动中的「停止并保存」结束。'],
      'live-activity':['实时活动','在系统设置中允许 WiseLife 使用实时活动。','录音时，在锁屏或灵动岛查看录音时长。','轻点「停止并保存」结束录音。锁屏操作可能需要解锁。']
    }[kind];
    openSheet(contents[0], detail(`<button class="device-back" data-settings-action="shortcuts">${icon('ChevronLeft')}<span>快捷设置</span></button><h3>${contents[0]}</h3><ol>${contents.slice(1).map(text=>`<li>${text}</li>`).join('')}</ol>`));
  }
  function retrieval() {
    const bilingual = language === 'zh-Hans' || language === 'en';
    openSheet('AI 检索', detail(`<p>在本机查找相关记录，管理检索语言与资源。</p><h3>本地语义检索</h3><label class="model-field"><span>记录主要语言</span><select id="settingsRetrievalLanguage">${Object.entries(languageNames).map(([id,name])=>`<option value="${id}" ${language===id?'selected':''}>${name}</option>`).join('')}</select></label><div class="model-resource"><strong>Apple 上下文向量</strong><p>${vectors.has(language)?'当前语言资源已就绪':'当前语言资源尚未下载'}</p>${vectors.has(language)?'':`<button class="secondary-button" data-settings-action="download-vector">下载语言资源</button>`}</div><h3>中英跨语言检索</h3><p>中文、英文及混合问题先在端上翻译，再匹配原文。姓名、日期和关键词仍使用原问题。</p><div class="model-resource"><strong>中英翻译语言包</strong><p>${bilingual?(translationReady?'已就绪，可在本机翻译问题':'尚未下载，暂时使用原问题检索'):'跨语言翻译目前支持简体中文与英文。'}</p>${bilingual&&!translationReady?'<button class="secondary-button" data-settings-action="download-translation">准备翻译语言包</button>':''}</div><h3>索引管理</h3><p>${indexReady?'当前示例记录已建立索引。':'索引已清除，原始记录保留。'}</p><div class="settings-inline-actions"><button class="secondary-button" data-settings-action="refresh">刷新状态</button><button class="secondary-button" data-settings-action="rebuild">重建索引</button><button class="secondary-button" data-settings-action="clear-index">清除索引</button></div><p>清除仅移除可重建的索引，不删除原始录音、图片和文字。回答仍使用你选择的 AI 模型。</p>`));
  }
  function privacy() {
    openSheet('数据与隐私', detail(`<h3>记录留在本机</h3><p>录音、图片、转写与笔记默认保存在你的 iPhone。由你决定 AI 可以读取哪些来源。</p><h3>本机检索</h3><p>语义索引与问题翻译在本机处理；清除索引不会删除原始记录。</p><h3>自选 AI 服务</h3><p>使用外部 AI 时，按你的发送确认偏好处理允许使用的文字。原始录音、图片和声音档案留在本机。</p>`));
  }
  document.addEventListener('click', event => {
    const button = event.target.closest('[data-settings-action]');
    if (!button) return;
    const action = button.dataset.settingsAction;
    if (['action-button','lockscreen','live-activity'].includes(action)) { instructions(action); return; }
    switch (action) {
      case 'shortcuts': shortcuts(); break;
      case 'retrieval': retrieval(); break;
      case 'privacy': privacy(); break;
      case 'face-id': {
        const enabled = button.getAttribute('aria-checked') !== 'true';
        button.setAttribute('aria-checked', String(enabled));
        toast(enabled?'Face ID 已开启（演示）':'Face ID 已关闭（演示）');
        break;
      }
      case 'download-vector': vectors.add(language); retrieval(); toast('语言资源已就绪（演示）'); break;
      case 'download-translation': translationReady = true; retrieval(); toast('翻译语言包已就绪（演示）'); break;
      case 'refresh': retrieval(); toast('资源状态已刷新（演示）'); break;
      case 'rebuild': indexReady = true; retrieval(); toast('索引已重建（演示）'); break;
      case 'clear-index':
        openSheet('清除索引？', detail('<p>只清除计算出的索引，原始记录与已下载语言包保留。</p><div class="settings-inline-actions"><button class="secondary-button" data-settings-action="retrieval">取消</button><button class="secondary-button" data-settings-action="confirm-clear">清除索引</button></div>'));
        break;
      case 'confirm-clear': indexReady = false; retrieval(); break;
    }
  });
  document.addEventListener('change', event => {
    if (event.target.id !== 'settingsRetrievalLanguage' || !Object.hasOwn(languageNames,event.target.value)) return;
    language = event.target.value; indexReady = false; retrieval();
  });
  return {shortcuts, retrieval};
};
window.daybookSettingsCopy = [
  ['通用设置','General','一般設定'],
  ['语言与AI','Language & AI','言語とAI'],
  ['硬件','Hardware','ハードウェア'],
  ['隐私与安全','Privacy & security','プライバシーとセキュリティ'],
  ['快捷设置','Quick settings','クイック設定'],
  ['操作按钮、锁屏小组件与实时活动','Action button, Lock Screen widgets and Live Activities','アクションボタン・ロック画面・ライブアクティビティ'],
  ['AI 检索','AI search','AI 検索'],
  ['本地语义检索、语言包与索引','Local search, language packs and index','ローカル検索・言語パック・インデックス'],
  ['暂停来源后，已有记录仍保留。录音始终由你主动开始。','Pausing a source keeps existing records. Recording always starts with you.','データソースを停止しても既存の記録は残ります。録音は自分で開始します。'],
  ['重新打开 App 时验证身份','Verify when reopening the app','アプリを開き直すときに本人確認'],
  ['数据与隐私','Data & privacy','データとプライバシー'],
  ['了解本机存储与 AI 数据使用范围','Local storage and how AI uses your data','ローカル保存とAIのデータ利用範囲'],
  ['查看新版设置','Explore the new settings','新しい設定を見る'],
  ['用适合你的方式，快速开始和保存录音。','Start and save recordings in the way that suits you.','自分に合う方法で、すばやく録音して保存。'],
  ['快捷录音','Quick recording','クイック録音'],
  ['操作按钮','Action button','アクションボタン'],
  ['长按开始，再次长按停止并保存','Hold to start; hold again to stop and save','長押しで開始、もう一度長押しで停止して保存'],
  ['锁屏小组件','Lock Screen widget','ロック画面ウィジェット'],
  ['从锁屏快速开始录音','Start recording from the Lock Screen','ロック画面から録音を開始'],
  ['实时活动','Live Activities','ライブアクティビティ'],
  ['查看录音时长，停止并保存','View duration, stop and save','録音時間を確認し、停止して保存'],
  ['交互演示，不下载资源，不更改系统设置或真实数据。','Interactive demo. No downloads, system changes or real data changes.','操作デモです。ダウンロード、システム設定や実データの変更は行いません。'],
  ['本地语义检索','Local semantic search','ローカル意味検索'],
  ['记录主要语言','Main language of records','記録の主な言語'],
  ['中英跨语言检索','Chinese–English search','中国語・英語の言語横断検索'],
  ['索引管理','Index management','インデックス管理'],
  ['Apple 上下文向量','Apple contextual embeddings','Apple 文脈埋め込み'],
  ['中英翻译语言包','Chinese–English translation pack','中国語・英語の翻訳パック'],
  ['准备翻译语言包','Prepare translation pack','翻訳パックを準備'],
  ['刷新状态','Refresh status','状態を更新'],
  ['重建索引','Rebuild index','インデックスを再構築'],
  ['清除索引','Clear index','インデックスを削除'],
  ['当前语言资源已就绪','Language resources are ready','言語リソースの準備完了'],
  ['当前语言资源尚未下载','Language resources are not downloaded','言語リソース未ダウンロード'],
  ['下载语言资源','Download language resources','言語リソースをダウンロード']
];
