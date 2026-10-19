/* Hardware interaction demo. In-memory state only; no Bluetooth or device access. */
window.createDaybookHardware=function(app){
  'use strict';
  const {$,icon,openSheet,toast}=app;
  const devices={
    watch:{name:'Apple Watch',model:'Apple Watch SE',icon:'Watch',connected:true,battery:68,lastSync:'16:28',description:'腕间录音，随时留住闪念。'},
    ring:{name:'EurekaRing',model:'EurekaRing',icon:'Ring',connected:false,battery:82,lastSync:'16:30',description:'指间记录，让想法随手留下。'}
  };
  const entries=()=>Object.entries(devices);
  const badge=device=>`<span class="device-state ${device.connected?'is-connected':''}"><span class="status-dot"></span><span>${device.connected?'已连接':'未连接'}</span></span>`;
  const note='<p class="source-footnote hardware-demo-note">连接、电量与同步信息均为演示，不操作真实硬件。</p>';
  function deviceRows(){
    return entries().map(([id,device])=>`<button class="device-row" data-hardware="${id}"><span class="device-avatar">${icon(device.icon)}</span><span class="device-row-copy"><strong>${device.name}</strong>${badge(device)}<span class="device-description">${device.connected?`<span>电量</span> ${device.battery}% <span>·</span> <span>录音已同步</span>`:device.description}</span></span>${icon('ChevronRight')}</button>`).join('');
  }
  function render(){
    const connected=entries().filter(([,device])=>device.connected);
    const button=$('watchButton');
    button.classList.toggle('disconnected',connected.length===0);
    button.setAttribute('aria-label','连接硬件与查看状态');
    button.innerHTML=`<span class="status-dot"></span><span class="hardware-pill-icons">${connected.length?connected.map(([,device])=>icon(device.icon)).join(''):icon('Link2')}</span><span id="watchLabel">${connected.length===2?'2 台已连接':connected.length===1?'已连接':'连接硬件'}</span>`;
    $('hardwareList').innerHTML=deviceRows();
  }
  function open(){
    openSheet('连接硬件',`<p class="sheet-intro">选择你的随身设备，查看连接与同步状态。</p><div class="device-list">${deviceRows()}</div><p class="hardware-multiple-hint">可以同时连接 Apple Watch 和 EurekaRing。</p>${note}`);
  }
  function openDevice(id){
    const device=devices[id];if(!device)return;
    openSheet('硬件状态',`<button class="device-back" data-hardware-action="list">${icon('ChevronLeft')}<span>全部硬件</span></button><div class="watch-status-large ${device.connected?'':'device-offline'}">${icon(device.icon)}</div><div class="watch-copy"><h3>${device.model}</h3>${badge(device)}<p>${device.connected?'录音按需开始，结束后同步到 iPhone。':'连接后可查看电量和录音同步状态。'}</p></div><div class="watch-facts device-facts"><div><span>上次同步</span><strong>${device.connected?device.lastSync:'—'}</strong></div><div><span>设备电量</span><strong>${device.connected?device.battery+'%':'—'}</strong></div><div><span>待同步录音</span><strong>${device.connected?'0 <span>条</span>':'—'}</strong></div></div><button class="${device.connected?'secondary':'primary'}-button wide" data-hardware-action="${device.connected?'disconnect':'connect'}" data-device="${id}">${icon(device.connected?'Unlink':'Link2')}<span>${device.connected?'断开连接':'连接设备'}</span></button><p class="hardware-retention">断开连接后，已有记录仍保留。</p>${note}`);
  }
  function handleClick(button){
    if(button.dataset.hardware){openDevice(button.dataset.hardware);return true;}
    const action=button.dataset.hardwareAction;
    if(!action)return false;
    if(action==='list'){open();return true;}
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
  ['示例硬件已连接。','Demo hardware connected.','デモのデバイスを接続しました。'],
  ['示例硬件已断开，历史记录保留。','Demo hardware disconnected. Existing records kept.','デモの接続を解除しました。既存の記録は残ります。']
];
