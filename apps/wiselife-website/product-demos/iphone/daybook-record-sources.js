/* Capture hardware is distinct from the device used to import a record. */
window.createDaybookRecordSources = function(app) {
  'use strict';
  const {esc,icon}=app;
  function device(record) {
    if(record.captureDevice==='iphone')return {name:'iPhone',icon:record.kind==='image'?'Camera':'Mic'};
    if(record.captureDevice==='camera')return {name:'本机相机',icon:'Camera'};
    if(record.source==='Apple Watch')return {name:'Apple Watch',icon:'Watch'};
    if(record.source==='EurekaRing')return {name:'EurekaRing',icon:'Ring'};
    if(record.kind!=='image'&&record.source.startsWith('iPhone'))return {name:'iPhone',icon:'Mic'};
    return {name:'设备未知',icon:'CircleHelp'};
  }
  function line(record,fallbackIcon) {
    if(!['voice','thought','image'].includes(record.kind))return `<span>${icon(fallbackIcon)}${esc(record.source)}</span>`;
    const value=device(record);
    return `<span class="record-device-label">${icon(value.icon)}<span>${value.name}</span></span>${record.importMethod?`<span class="record-import-label">${esc(record.importMethod)}</span>`:''}`;
  }
  function detail(record) {
    if(!['voice','thought','image'].includes(record.kind))return '';
    const value=device(record);
    return `<div class="record-provenance"><span class="record-provenance-icon">${icon(value.icon)}</span><div><small>${record.kind==='image'?'拍摄设备':'录制设备'}</small><strong>${value.name}</strong></div>${record.importMethod?`<div class="record-import-detail"><small>导入方式</small><strong>${esc(record.importMethod)}</strong></div>`:''}</div>${value.name==='设备未知'?'<p class="record-provenance-note">图片未提供拍摄设备信息。</p>':''}`;
  }
  return {line,detail};
};
window.daybookRecordSourcesCopy = [
  ['录制设备','Recorded on','録音デバイス'],['拍摄设备','Captured on','撮影デバイス'],
  ['导入方式','Imported from','読み込み方法'],['设备未知','Unknown device','デバイス不明'],
  ['本机相机','This device’s camera','このデバイスのカメラ'],
  ['图片未提供拍摄设备信息。','The image does not provide capture device information.','画像に撮影デバイスの情報がありません。'],
];
