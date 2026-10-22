/* Hardware interaction demo. In-memory state only; no Bluetooth or device access. */
window.createDaybookHardware=function(app){
  'use strict';
  const {$,icon,openSheet,toast}=app;
  const devices={
    watch:{name:'Apple Watch',model:'Apple Watch SE',icon:'Watch',connected:true,paired:true,pending:2,battery:68,lastSync:'14:30',failure:false,retryPending:false,description:'腕间录音，随时留住闪念。'},
    ring:{name:'EurekaRing',model:'EurekaRing',icon:'Ring',connected:false,battery:82,lastSync:'16:30',description:'指间记录，让想法随手留下。'}
  };
  const entries=()=>Object.entries(devices);
  const watchStatus=()=>!devices.watch.paired?'未配对 Apple Watch':devices.watch.pending>0?'已配对 · 待同步 2 条':devices.watch.lastSync?'已配对 · 最近同步 14:30':'已配对';
  const badge=device=>`<span class="device-state ${device.connected?'is-connected':''}"><span class="status-dot"></span><span>${device===devices.watch?watchStatus():device.connected?'已连接':'未连接'}</span></span>`;
  const note='<p class="source-footnote hardware-demo-note">连接、电量与同步信息均为演示，不操作真实硬件。</p>';
  function deviceRows(){
    return entries().map(([id,device])=>`<button class="device-row" data-hardware="${id}"><span class="device-avatar">${icon(device.icon)}</span><span class="device-row-copy"><strong>${device.name}</strong>${badge(device)}<span class="device-description">${id==='watch'?'轻点录音 · 按住闪念':device.connected?`<span>电量</span> ${device.battery}% <span>·</span> <span>录音已同步</span>`:device.description}</span></span>${icon('ChevronRight')}</button>`).join('');
  }
  function render(){
    const connected=entries().filter(([,device])=>device.connected);
    const button=$('watchButton');
    button.classList.toggle('disconnected',connected.length===0);
    button.setAttribute('aria-label',watchStatus());
    button.innerHTML=`<span class="status-dot"></span><span class="hardware-pill-icons">${connected.length?connected.map(([,device])=>icon(device.icon)).join(''):icon('Link2')}</span><span id="watchLabel">${devices.watch.pending?'待同步2条':devices.watch.lastSync?'最近同步14:30':'已配对'}</span>`;
    $('hardwareList').innerHTML=deviceRows();
  }
  function open(){
    openSheet('连接硬件',`<p class="sheet-intro">选择你的随身设备，查看连接与同步状态。</p><div class="device-list">${deviceRows()}</div><section class="hardware-compatibility" aria-labelledby="hardwareCompatibilityTitle"><h3 id="hardwareCompatibilityTitle">最低兼容要求</h3><dl><div><dt>系统版本</dt><dd>watchOS 10.0 或更高版本</dd></div><div><dt>设备型号</dt><dd>Apple Watch Series 4 及更新机型；SE（第 1 代）及更新机型；Ultra（第 1 代）及更新机型</dd></div><div><dt>配对 iPhone</dt><dd>iOS 26 或更高版本；Series 12 和 Ultra 4 需要 iOS 27</dd></div></dl><p>兼容下限不代表每个型号都已完成真机测试。</p></section><p class="hardware-multiple-hint">可以同时连接 Apple Watch 和 EurekaRing。</p>${note}`);
  }
  function openDevice(id){
    const device=devices[id];if(!device)return;
    if(id==='watch'){
      openSheet('硬件状态',`
        <button class="device-back" data-hardware-action="list">${icon('ChevronLeft')}<span>全部硬件</span></button>
        <div class="watch-status-large">${icon(device.icon)}</div>
        <div class="watch-copy"><h3>${device.model}</h3>${badge(device)}<p>录音结束后由系统安排传输，无需保持手表亮屏。</p></div>
        <div class="watch-facts device-facts"><div><span>配对状态</span><strong>已配对</strong></div><div><span>最近同步</span><strong>${device.lastSync||'—'}</strong></div><div><span>待同步录音</span><strong>${device.pending} <span>条</span></strong></div></div>
        <p class="hardware-retention">显示最近收到的同步状态，后台更新可能延迟。最近同步时间以 iPhone 成功保存录音为准。</p>
        ${device.failure?'<p class="watch-sync-error" role="status">1 条录音上次传输失败，可重试同步。</p>':''}
        ${device.retryPending?'<p class="hardware-retention" role="status">重试请求已提交，等待手表处理。后台传输时间由系统安排。</p>':''}
        <button class="primary-button wide" data-hardware-action="retry-sync" data-device="watch"><span>重试同步</span></button>
        <p class="hardware-retention">Apple Watch 的配对与取消配对请在 iPhone 的 Watch App 中管理。</p>
        <details class="hardware-retention"><summary>演示状态</summary>
          <button class="secondary-button wide" data-hardware-action="simulate-sync" data-device="watch"><span>${device.pending?'模拟完成同步':'模拟新增 2 条录音'}</span></button>
          <button class="secondary-button wide" data-hardware-action="simulate-paired" data-device="watch"><span>模拟首次配对</span></button>
          <button class="secondary-button wide" data-hardware-action="simulate-failure" data-device="watch"><span>模拟传输失败</span></button>
        </details>${note}`);
      return;
    }
    openSheet('硬件状态',`<button class="device-back" data-hardware-action="list">${icon('ChevronLeft')}<span>全部硬件</span></button><div class="watch-status-large ${device.connected?'':'device-offline'}">${icon(device.icon)}</div><div class="watch-copy"><h3>${device.model}</h3>${badge(device)}<p>${device.connected?'录音按需开始，结束后同步到 iPhone。':'连接后可查看电量和录音同步状态。'}</p></div><div class="watch-facts device-facts"><div><span>上次同步</span><strong>${device.connected?device.lastSync:'—'}</strong></div><div><span>设备电量</span><strong>${device.connected?device.battery+'%':'—'}</strong></div><div><span>待同步录音</span><strong>${device.connected?'0 <span>条</span>':'—'}</strong></div></div><button class="${device.connected?'secondary':'primary'}-button wide" data-hardware-action="${device.connected?'disconnect':'connect'}" data-device="${id}">${icon(device.connected?'Unlink':'Link2')}<span>${device.connected?'断开连接':'连接设备'}</span></button><p class="hardware-retention">断开连接后，已有记录仍保留。</p>${note}`);
  }
  function handleClick(button){
    if(button.dataset.hardware){openDevice(button.dataset.hardware);return true;}
    const action=button.dataset.hardwareAction;
    if(!action)return false;
    if(action==='list'){open();return true;}
    if(action==='simulate-sync'){
      if(devices.watch.pending){devices.watch.pending=0;devices.watch.lastSync='14:30';devices.watch.failure=false;devices.watch.retryPending=false;}
      else{devices.watch.pending=2;}
      render();openDevice('watch');return true;
    }
    if(action==='simulate-paired'){
      devices.watch.pending=0;devices.watch.lastSync=null;
      devices.watch.failure=false;devices.watch.retryPending=false;
      render();openDevice('watch');return true;
    }
    if(action==='simulate-failure'){
      devices.watch.pending=2;devices.watch.failure=true;devices.watch.retryPending=false;
      render();openDevice('watch');return true;
    }
    if(action==='retry-sync'){
      devices.watch.retryPending=true;
      render();openDevice('watch');return true;
    }
    const id=button.dataset.device,device=devices[id];
    if(!device||!['connect','disconnect'].includes(action))return true;
    device.connected=action==='connect';
    if(device.connected)device.lastSync='16:30';
    render();openDevice(id);
    document.querySelector('[data-hardware-action][data-device]')?.focus({preventScroll:true});
    toast(device.connected?'示例硬件已连接。':'示例硬件已断开，历史记录保留。');
    return true;
  }
  render();
  return {open,handleClick};
};

window.daybookHardwareCopy=[
  ['重试同步','Retry sync','同期を再試行'],
  ['演示状态','Demo states','デモの状態'],
  ['模拟传输失败','Simulate transfer failure','転送失敗をシミュレート'],
  ['1 条录音上次传输失败，可重试同步。','The last transfer of 1 recording failed. You can retry sync.','1 件の録音の前回の転送に失敗しました。同期を再試行できます。'],
  ['重试请求已提交，等待手表处理。后台传输时间由系统安排。','Retry requested, waiting for Watch. The system schedules background transfers.','再試行をリクエストしました。Watch の処理待ちです。転送時刻はシステムが決定します。'],
  ['模拟首次配对','Simulate initial pairing','初回ペアリングをシミュレート'],
  ['待同步2条','2 pending','未同期2件'],
  ['最近同步14:30','Synced 14:30','最終同期14:30'],
  ['已配对 · 待同步 2 条','Paired · 2 pending','ペアリング済み · 未同期 2 件'],
  ['已配对 · 最近同步 14:30','Paired · Last sync 14:30','ペアリング済み · 最終同期 14:30'],
  ['未配对 Apple Watch','No paired Apple Watch','Apple Watch 未ペアリング'],
  ['已配对','Paired','ペアリング済み'],
  ['配对状态','Pairing','ペアリング状態'],
  ['最近同步','Last sync','最終同期'],
  ['轻点录音 · 按住闪念','Tap to record · Hold for a thought','タップで録音 · 長押しでひらめき'],
  ['录音结束后由系统安排传输，无需保持手表亮屏。','The system transfers finished recordings. The Watch screen can stay off.','録音終了後、システムが転送します。画面を点灯し続ける必要はありません。'],
  ['显示最近收到的同步状态，后台更新可能延迟。最近同步时间以 iPhone 成功保存录音为准。','Shows the latest received status; background updates may be delayed. Last sync is when iPhone saved a recording.','最後に受信した状態です。バックグラウンド更新には遅延があります。最終同期は iPhone が録音を保存した時刻です。'],
  ['模拟完成同步','Simulate completed sync','同期完了をシミュレート'],
  ['模拟新增 2 条录音','Simulate 2 new recordings','新しい録音 2 件をシミュレート'],
  ['Apple Watch 的配对与取消配对请在 iPhone 的 Watch App 中管理。','Manage Apple Watch pairing in the Watch app on iPhone.','Apple Watch のペアリングは iPhone の Watch アプリで管理してください。'],
  ['连接硬件','Connect hardware','デバイスを接続'],
  ['连接硬件与查看状态','Connect hardware and view status','デバイスの接続と状態を確認'],
  ['2 台已连接','2 connected','2 台接続中'],
  ['硬件状态','Hardware status','デバイスの状態'],
  ['全部硬件','All hardware','すべてのデバイス'],
  ['选择你的随身设备，查看连接与同步状态。','Choose a device to view its connection and sync status.','デバイスを選んで、接続と同期の状態を確認できます。'],
  ['可以同时连接 Apple Watch 和 EurekaRing。','Apple Watch and EurekaRing can be connected at the same time.','Apple Watch と EurekaRing を同時に接続できます。'],
  ['腕间录音，随时留住闪念。','Capture recordings and thoughts from your wrist.','手首から音声やひらめきを記録。'],
  ['指间记录，让想法随手留下。','Capture ideas right from your finger.','指先から、思いついたことを記録。'],
  ['电量','Battery','バッテリー'],
  ['录音已同步','Recordings synced','録音は同期済み'],
  ['录音按需开始，结束后同步到 iPhone。','Start recording when you choose. Sync to iPhone when finished.','必要なときに録音し、終了後に iPhone へ同期します。'],
  ['连接后可查看电量和录音同步状态。','Connect to view battery and recording sync status.','接続するとバッテリーと録音の同期状態を確認できます。'],
  ['上次同步','Last sync','前回の同期'],
  ['设备电量','Device battery','デバイスのバッテリー'],
  ['待同步录音','Pending recordings','未同期の録音'],
  ['条','recordings','件'],
  ['断开连接','Disconnect','接続を解除'],
  ['连接设备','Connect device','デバイスを接続する'],
  ['断开连接后，已有记录仍保留。','Existing records remain after disconnecting.','接続を解除しても、既存の記録は残ります。'],
  ['连接、电量与同步信息均为演示，不操作真实硬件。','Connection, battery and sync information are simulated. No real hardware is accessed.','接続・バッテリー・同期はデモ表示です。実際のデバイスにはアクセスしません。'],
  ['最低兼容要求','Minimum requirements','最低互換要件'],
  ['系统版本','OS version','OSバージョン'],
  ['watchOS 10.0 或更高版本','watchOS 10.0 or later','watchOS 10.0以降'],
  ['设备型号','Supported models','対応モデル'],
  ['Apple Watch Series 4 及更新机型；SE（第 1 代）及更新机型；Ultra（第 1 代）及更新机型','Apple Watch Series 4 or later; Apple Watch SE (1st generation) or later; Apple Watch Ultra (1st generation) or later','Apple Watch Series 4以降、SE（第1世代）以降、Ultra（第1世代）以降'],
  ['配对 iPhone','Paired iPhone','ペアリングするiPhone'],
  ['iOS 26 或更高版本；Series 12 和 Ultra 4 需要 iOS 27','iOS 26 or later; Series 12 and Ultra 4 require iOS 27','iOS 26以降。Series 12とUltra 4にはiOS 27が必要です'],
  ['兼容下限不代表每个型号都已完成真机测试。','Meeting the minimum requirements does not mean every model has been tested on a physical device.','最低要件を満たしていても、すべてのモデルで実機テスト済みとは限りません。'],
  ['示例硬件已连接。','Demo hardware connected.','デモのデバイスを接続しました。'],
  ['示例硬件已断开，历史记录保留。','Demo hardware disconnected. Existing records kept.','デモの接続を解除しました。既存の記録は残ります。']
];
