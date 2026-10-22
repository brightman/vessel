/* Only user-selected files are opened, in this page's memory. No upload or OCR. */
window.createDaybookPhotos=function(app){
  'use strict';
  const {$,esc,icon,toast,openSheet,closeSheet,onSave}=app;
  let images=[],caption='',origin='相册',generation=0,serial=0,activeRecord=null;
  const urls=new Set(),limit=6;
  const demoText='首版范围\n要做：录音 → 转写 → 回顾\n暂缓：扩展更多数据来源\n完成：从洞察回到原始记录';
  const revoke=image=>{if(urls.has(image.url)){URL.revokeObjectURL(image.url);urls.delete(image.url);}};
  function discard(){generation++;images.forEach(revoke);images=[];caption='';}
  const saveCaption=()=>{if($('photoCaption'))caption=$('photoCaption').value;};
  function openCapture(){
    discard();
    openSheet('用图片记此刻',`<p class="sheet-intro">眼前的风景、讨论的白板，或一张值得留住的截图。</p><button class="capture-option" data-photo-action="camera">${icon('Camera')}<div><strong>拍照</strong><p>拍下眼前这一刻。</p></div>${icon('ChevronRight')}</button><button class="capture-option" data-photo-action="album">${icon('Images')}<div><strong>从相册选择</strong><p>一次最多 6 张，确认前可以移除。</p></div>${icon('ChevronRight')}</button><p class="source-footnote">仅预览你主动选择的图片，不会上传。拍照入口由手机浏览器打开相机；电脑可能显示文件选择器。</p><button class="secondary-button wide" data-photo-action="demo">${icon('ImagePlus')}用示例图体验</button>`);
  }
  function preview(){
    openSheet('留住这些画面',`<div class="photo-count"><span>${images.length} / ${limit} 张图片</span><button class="text-button" data-photo-action="album">${icon('Plus')}再选几张</button></div><div class="photo-grid">${images.map((p,i)=>`<div class="photo-tile"><img src="${esc(p.url)}" alt="${esc(p.name)}"><button data-photo-remove="${i}" aria-label="移除第 ${i+1} 张图片">${icon('X')}</button>${p.demo?'<span class="photo-demo-tag">示例图</span>':''}</div>`).join('')}</div><form id="photoSaveForm"><label class="note-field"><span>补充一句（选填）</span><textarea id="photoCaption" maxlength="500" placeholder="比如：这次讨论，决定先把范围收小">${esc(caption)}</textarea></label><p class="source-footnote">图片留在本页，刷新后清空。真实图片未做文字识别或 AI 分析。</p><div class="sheet-actions"><button type="button" class="secondary-button" data-photo-action="cancel">取消</button><button type="submit" class="primary-button">${icon('Check')}保存到今天</button></div></form>`);
  }
  function pick(kind){
    saveCaption();if(images.length>=limit){toast('最多保留 6 张，请先移除一张。');return;}
    origin=kind==='camera'?'拍照':'相册';
    const input=$(kind==='camera'?'momentCameraInput':'momentAlbumInput');input.value='';input.click();
  }
  function loadFile(file){
    return new Promise((resolve,reject)=>{
      if(!/^image\//.test(file.type)||file.type==='image/svg+xml'){reject(new Error('请选择照片或截图（JPEG、PNG、WebP 等）。'));return;}
      if(file.size>20*1024*1024){reject(new Error('单张图片请小于 20 MB。'));return;}
      const url=URL.createObjectURL(file);urls.add(url);const image=new Image();
      image.onload=()=>{if(image.naturalWidth*image.naturalHeight>60000000){revoke({url});reject(new Error('图片尺寸过大，请先缩小后选择。'));return;}resolve({url,name:file.name,demo:false});};
      image.onerror=()=>{revoke({url});reject(new Error('浏览器无法预览这张图片，请尝试 JPEG 或 PNG 格式。'));};
      image.src=url;
    });
  }
  async function receive(event){
    const files=Array.from(event.target.files||[]);if(!files.length)return;
    saveCaption();
    if(files.length+images.length>limit){toast('一次最多保留 6 张，请减少选择的数量。');return;}
    const token=++generation;
    openSheet('正在准备图片',`<div class="empty-state">${icon('Images')}<h3>正在打开你选择的图片…</h3><p>仅在本页预览，不会上传。</p></div>`);
    const results=await Promise.allSettled(files.map(loadFile));
    const loaded=results.filter(r=>r.status==='fulfilled').map(r=>r.value);
    if(token!==generation){loaded.forEach(revoke);return;}
    images.push(...loaded);
    const error=results.find(r=>r.status==='rejected');
    if(images.length)preview();else openCapture();
    if(error)toast(error.reason.message);
  }
  function save(event){
    event.preventDefault();if(!images.length)return;saveCaption();
    const photos=images;images=[];generation++;
    const description=caption.trim(),ocr=photos.filter(p=>p.demo).map(()=>demoText).join('\n\n');
    const record={id:`image-${Date.now()}-${++serial}`,kind:'image',title:description?description.slice(0,32):'留住的一刻',preview:description||`${photos.length} 张图片 · ${origin}`,source:origin,captureDevice:origin==='拍照'?'camera':undefined,importMethod:origin,images:photos,caption:description,ocr,summary:description||'还没有补充说明。',text:[description,ocr].filter(Boolean).join('\n\n'),tags:[`${photos.length} 张图片`]};
    caption='';onSave(record);
  }
  function openRecord(record){
    activeRecord=record;
    openSheet(record.title,`<div class="detail-meta">10月${record.day}日 ${record.time} · ${esc(record.source)} · ${record.images.length} 张图片</div>${app.sourceDetail?.(record)||''}${app.placeDetail?.(record)||''}<div class="photo-grid photo-detail-grid">${record.images.map((p,i)=>`<button class="photo-tile" data-photo-original="${i}" aria-label="查看第 ${i+1} 张原图"><img src="${esc(p.url)}" alt="${esc(p.name)}">${p.demo?'<span class="photo-demo-tag">示例图</span>':''}</button>`).join('')}</div><h3 class="sheet-section-title">补充说明</h3><p class="photo-caption">${esc(record.caption||'没有补充说明，也可以先留住画面。')}</p><h3 class="sheet-section-title">图片文字</h3><p class="photo-caption">${esc(record.ocr||'尚未识别。原型保留图片，不生成真实 OCR 或图片总结。')}</p>${record.ocr?'<p class="source-footnote">以上文字是示例图的预置内容；你选择的其他图片尚未识别。</p>':''}<button class="secondary-button wide" data-ai-ask="这一天的图片记录了什么？">${icon('MessageCircle')}问问 AI 这些图片</button>`);
  }
  function original(index){
    if(!activeRecord?.images[index])return;
    const image=activeRecord.images[index];
    openSheet('查看原图',`<div class="photo-original"><img src="${esc(image.url)}" alt="${esc(image.name)}"></div><div class="photo-pager"><button class="icon-button" data-photo-original="${index-1}" aria-label="上一张" ${index===0?'disabled':''}>${icon('ChevronLeft')}</button><span>${index+1} / ${activeRecord.images.length}</span><button class="icon-button" data-photo-original="${index+1}" aria-label="下一张" ${index===activeRecord.images.length-1?'disabled':''}>${icon('ChevronRight')}</button></div><button class="secondary-button wide" data-photo-action="back">回到图片记录</button>`);
  }
  const inputs=document.createElement('div');
  inputs.innerHTML='<input id="momentCameraInput" type="file" accept="image/*" capture="environment" hidden><input id="momentAlbumInput" type="file" accept="image/*" multiple hidden>';
  $('sheet').append(inputs);
  $('momentCameraInput').addEventListener('change',receive);$('momentAlbumInput').addEventListener('change',receive);
  document.addEventListener('click',event=>{
    const button=event.target.closest('button');if(!button)return;
    if(button.dataset.photoRemove!==undefined){saveCaption();const [image]=images.splice(Number(button.dataset.photoRemove),1);if(image)revoke(image);if(images.length)preview();else openCapture();return;}
    if(button.dataset.photoOriginal!==undefined){original(Number(button.dataset.photoOriginal));return;}
    const actions={camera:()=>pick('camera'),album:()=>pick('album'),cancel:()=>{discard();closeSheet();},demo:()=>{images=[{url:'assets/moment-board.svg',name:'首版范围示例图',demo:true}];origin='示例图';preview();},back:()=>openRecord(activeRecord)};
    actions[button.dataset.photoAction]?.();
  });
  document.addEventListener('submit',event=>{if(event.target.id==='photoSaveForm')save(event);});
  $('sheet').addEventListener('close',discard);
  window.addEventListener('pagehide',()=>{generation++;for(const url of urls)URL.revokeObjectURL(url);urls.clear();});
  return {openCapture,openRecord};
};
