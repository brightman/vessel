/* Fictional place context only. No geolocation, maps, EXIF reads or network requests. */
window.createDaybookPlaces = function(app) {
  'use strict';
  const {$, esc, icon, openSheet, getDay, getRecords, isEnabled} = app;
  const labels = {watch:'录音开始位置',recordingPhone:'录音开始位置',photo:'照片原始位置',phone:'拍摄时的位置'};
  const place = (name, area, source, time, accuracy) => ({name,area,source,time,accuracy});
  function seed(records) {
    const samples = {
      'thought-morning':place('街角咖啡店','上海 · 徐汇区','watch','08:36',35),
      meeting:place('办公室','上海 · 徐汇区','watch','09:40',20),
      'walk-followup':place('街边小公园','上海 · 徐汇区','watch','12:40',45),
      review:place('办公室','上海 · 徐汇区','watch','14:00',18),
      'yesterday-note':place('街边小公园','上海 · 徐汇区','watch','17:30',30)
    };
    records.forEach(record => {if(samples[record.id]) record.place=samples[record.id];});
    records.push({id:'board-photo',day:19,kind:'image',start:14+28/60,end:14+28/60,time:'14:28',duration:0,
      title:'讨论结束，留一张白板',preview:'把今天确定的首版范围留下来。',source:'iPhone · 相册',captureDevice:'iphone',importMethod:'相册',
      images:[{url:'assets/moment-board.svg',name:'讨论白板示例图',demo:true}],caption:'把今天确定的首版范围留下来。',
      ocr:'首版范围\n要做：录音 → 转写 → 回顾',summary:'白板记录了今天讨论的首版范围。',text:'首版范围：录音、转写、回顾。',tags:['1 张图片'],
      place:{...place('办公室','上海 · 徐汇区','photo','14:28',null),importedAt:'10月19日 16:10'}});
    records.push({id:'ring-thought',day:19,kind:'thought',start:16+2/60,end:16+2/60+36/3600,time:'16:02',duration:36,
      title:'把今天的决定留给明天',preview:'“明天开始前，先回看今天白板上确定的三件事。”',source:'EurekaRing',
      summary:'明天开始前，回看今天白板上确定的三件事。',text:'明天开始前，先回看今天白板上确定的三件事。先把最重要的一件做完，再决定要不要加新的事情。',
      tags:['闪念','明日计划']});
  }
  const located = list => list.filter(record=>record.place);
  function line(record) {
    if(record.place) return `<span class="moment-place">${icon('MapPin')}<span translate="no">${esc(record.place.name)}</span><span class="place-origin">${labels[record.place.source]}</span></span>`;
    return '';
  }
  function detail(record) {
    if(record.place) return `<button class="record-place-link" data-place-record="${esc(record.id)}">${icon('MapPin')}<span><strong translate="no">${esc(record.place.name)}</strong><small>${labels[record.place.source]} · ${esc(record.place.time)}</small></span>${icon('ChevronRight')}</button>`;
    return '';
  }
  function rhythm(list) {
    if(!isEnabled()&&!located(list).length) return '';
    return `<button class="rhythm-track places-track" data-place-action="day" aria-label="查看当天地点">${located(list).map(record=>`<span class="place-timepoint" style="left:${record.start/24*100}%" aria-hidden="true"><span></span></span>`).join('')}</button>`;
  }
  function render(list) {
    const items=located(list),names=[...new Set(items.map(record=>record.place.name))];
    $('dayPlaces').innerHTML=items.length?`<button class="day-places-summary" data-place-action="day">${icon('MapPin')}<span><strong><span>地点</span> <span>${names.length}</span> <span>处</span></strong><small translate="no">${names.map(esc).join(' · ')}</small></span><span class="place-summary-count"><span>${items.length}</span> <span>条记录</span>${icon('ChevronRight')}</span></button>`:
      `<button class="day-places-empty" ${isEnabled()?'data-place-action="day"':'data-source="places"'}>${icon('MapPin')}<span>${isEnabled()?'这一天还没有地点记录':'开启地点，让片段多一点背景'}</span>${icon('ChevronRight')}</button>`;
  }
  function openDay() {
    const items=located(getRecords().filter(record=>record.day===getDay())).sort((a,b)=>b.start-a.start);
    openSheet('这一天的地点',`<div class="places-day-heading"><span class="places-emblem">${icon('MapPin')}</span><div><h3><span>10月${getDay()}日</span></h3><p>${isEnabled()?'地点记录已开启':'地点记录已暂停 · 历史保留'}</p></div></div><p class="sheet-intro">录音与照片留下的地点，让回忆有处可寻。</p>${items.length?`<div class="places-day-list">${items.map(record=>`<button class="place-visit" data-place-record="${esc(record.id)}"><time>${esc(record.time)}</time><span><strong translate="no">${esc(record.place.name)}</strong><small>${icon(record.kind==='image'?'Images':'Watch')}<span translate="no">${esc(record.title)}</span></small><small>${labels[record.place.source]}</small></span>${icon('ChevronRight')}</button>`).join('')}</div>`:`<div class="empty-state">${icon('MapPin')}<h3>这一天还没有地点记录</h3><p>有位置的录音与照片会出现在这里。</p></div>`}<p class="source-footnote">仅展示记录发生时的位置，不据此推断停留时长或完整行程。</p><button class="secondary-button wide" data-place-action="settings">${icon('Settings2')}地点设置</button>`);
  }
  function openRecord(id) {
    const record=getRecords().find(item=>item.id===id);if(!record?.place)return;
    const p=record.place;
    openSheet('片段的地点',`<div class="place-detail-heading"><span class="places-emblem">${icon('MapPin')}</span><p>${labels[p.source]}</p><h3 translate="no">${esc(p.name)}</h3><span translate="no">${esc(p.area)}</span></div><dl class="place-facts"><div><dt>位置来源</dt><dd>${p.source==='photo'?'照片位置信息':p.source==='watch'?'Apple Watch 定位':'iPhone 定位'}</dd></div><div><dt>${p.source==='photo'?'拍摄时间':'定位时间'}</dt><dd>10月${record.day}日 ${esc(p.time)}</dd></div>${p.importedAt?`<div><dt>导入时间</dt><dd>${esc(p.importedAt)}</dd></div>`:''}<div><dt>位置精度</dt><dd>${p.accuracy?`<span>约</span> ${p.accuracy} <span>米</span>`:'原照片未提供'}</dd></div></dl><p class="place-context-note">${p.source==='photo'?'按照片原始拍摄时间与位置展示，导入不会改成当前位置。':'这是开始录音时获取的位置，不代表整段录音期间都在这里。'}</p><button class="place-related-record" data-record="${esc(record.id)}">${icon(record.kind==='image'?'Images':'AudioLines')}<span><small>关联片段</small><strong translate="no">${esc(record.title)}</strong></span>${icon('ChevronRight')}</button><p class="source-footnote">地点与精度均为示例，未获取你的真实位置。</p>`);
  }
  function openSettings() {
    openSheet('地点',`<div class="places-day-heading"><span class="places-emblem">${icon('MapPin')}</span><div><h3>为片段留住地点</h3><p>${isEnabled()?'地点记录已开启':'地点记录已暂停 · 历史保留'}</p></div></div><div class="place-methods"><div>${icon('Watch')}<span><strong>录音开始时</strong><p>保存手表或手机当时的位置，定位不影响录音。</p></span></div><div>${icon('Camera')}<span><strong>拍照时</strong><p>为新照片附上拍摄地点。</p></span></div><div>${icon('Images')}<span><strong>从相册导入</strong><p>保留照片自带的位置与拍摄时间；没有位置时留空。</p></span></div></div><p class="source-footnote">仅在记录时获取位置，不持续追踪。暂停后，已有地点保留在时间轴中。</p><button class="${isEnabled()?'secondary-button':'primary-button'} wide" ${isEnabled()?'data-source="places"':'data-connect-source="places"'}>${icon(isEnabled()?'Pause':'MapPin')}${isEnabled()?'暂停地点记录':'开启地点示例'}</button><p class="source-footnote">原型仅演示界面，不请求定位或相册权限。</p>`);
  }
  function handleClick(button) {
    if(button.dataset.placeRecord){openRecord(button.dataset.placeRecord);return true;}
    if(button.dataset.placeAction==='day'){openDay();return true;}
    if(button.dataset.placeAction==='settings'){openSettings();return true;}
    return false;
  }
  const forDemoRecording=()=>isEnabled()?place('办公室','上海 · 徐汇区','recordingPhone','16:30',25):undefined;
  return {seed,line,detail,rhythm,render,openSettings,handleClick,forDemoRecording};
};

window.daybookPlacesCopy = [
  ['录音开始位置','Recording start location','録音開始時の場所'],
  ['照片原始位置','Original photo location','写真の元の位置'],
  ['拍摄时的位置','Location at capture','撮影時の場所'],
  ['地点时间点','Location timestamps','場所の記録時点'],
  ['查看当天地点','View places for this day','この日の場所を見る'],
  ['处','places','か所'],['条记录','records','件の記録'],
  ['这一天的地点','Places in this day','この日の場所'],
  ['地点记录已开启','Place recording is on','場所の記録はオンです'],
  ['地点记录已暂停 · 历史保留','Paused · saved places retained','一時停止中 · 過去の場所は保持'],
  ['这一天还没有地点记录','No places recorded this day','この日の場所の記録はありません'],
  ['开启地点，让片段多一点背景','Add places to your moments','場所をオンにして記録に背景を添える'],
  ['录音与照片留下的地点，让回忆有处可寻。','Places from recordings and photos give your memories context.','録音と写真の場所から、思い出をたどれます。'],
  ['有位置的录音与照片会出现在这里。','Recordings and photos with a location will appear here.','位置情報のある録音と写真がここに表示されます。'],
  ['仅展示记录发生时的位置，不据此推断停留时长或完整行程。','These are locations at capture time, not a route or a measure of time spent.','記録時点の場所です。滞在時間や移動経路は推測しません。'],
  ['地点设置','Place settings','場所の設定'],['片段的地点','Moment location','記録の場所'],
  ['位置来源','Location source','位置情報の取得元'],['照片位置信息','Photo metadata','写真の位置情報'],
  ['Apple Watch 定位','Apple Watch location','Apple Watch の位置'],['iPhone 定位','iPhone location','iPhone の位置'],
  ['拍摄时间','Captured at','撮影日時'],['定位时间','Located at','位置の取得日時'],['导入时间','Imported at','読み込み日時'],
  ['位置精度','Location accuracy','位置精度'],['约','About','約'],['米','m','メートル'],['原照片未提供','Not provided by the photo','元の写真に情報がありません'],
  ['按照片原始拍摄时间与位置展示，导入不会改成当前位置。','Uses the original capture time and location, not your location when importing.','元の撮影日時と場所を表示します。読み込み時の現在地には変わりません。'],
  ['这是开始录音时获取的位置，不代表整段录音期间都在这里。','Captured at the start of recording; it does not describe the entire recording.','録音開始時の場所です。録音中ずっとここにいたことは示しません。'],
  ['关联片段','Linked moment','関連する記録'],['地点与精度均为示例，未获取你的真实位置。','Example places and accuracy. Your actual location is not accessed.','場所と精度はサンプルです。実際の位置は取得しません。'],
  ['为片段留住地点','Keep places with your moments','記録に場所を残す'],['录音开始时','When recording starts','録音開始時'],
  ['保存手表或手机当时的位置，定位不影响录音。','Save the watch or phone location without delaying recording.','録音を待たせず、時計やスマートフォンの場所を保存します。'],
  ['拍照时','When taking a photo','写真撮影時'],['为新照片附上拍摄地点。','Attach the capture location to new photos.','新しい写真に撮影場所を添えます。'],
  ['从相册导入','When importing photos','写真を読み込むとき'],['保留照片自带的位置与拍摄时间；没有位置时留空。','Keep the original location and capture time; leave the location empty if missing.','元の場所と撮影日時を保持します。場所がなければ空欄にします。'],
  ['仅在记录时获取位置，不持续追踪。暂停后，已有地点保留在时间轴中。','Location is captured only with a moment. Pausing keeps saved places in your timeline.','記録時のみ位置を取得します。一時停止後も過去の場所はタイムラインに残ります。'],
  ['暂停地点记录','Pause place recording','場所の記録を一時停止'],['开启地点示例','Enable place demo','場所のデモをオンにする'],
  ['原型仅演示界面，不请求定位或相册权限。','Interface demo only. No location or photo permissions are requested.','画面のデモのみです。位置や写真のアクセス許可は求めません。'],
  ['录音与照片的地点，随片段一起保存','Keep locations with recordings and photos','録音や写真と一緒に場所を保存'],
  ['查看地点设置','View place settings','場所の設定を見る'],
  ['上至下：睡眠 · 活动 · 语音 · 地点，点击回看。','Top to bottom: sleep, activity, audio and places. Tap to revisit.','上から睡眠・活動・音声・場所。タップして振り返れます。'],
];
