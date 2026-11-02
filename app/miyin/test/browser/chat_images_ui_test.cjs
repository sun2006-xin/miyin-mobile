// Synthetic images and a local native-bridge fixture; no model or cloud calls.
const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),http=require('node:http');
let browser,server;
const id='a'.repeat(32);
before(async()=>{
 const root=path.resolve(__dirname,'../../assets/miyin_v5');
 server=http.createServer(async(req,res)=>{
  const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);
  if(!file.startsWith(root+path.sep)){res.writeHead(403);return res.end();}
  try{const body=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(body);}catch{res.writeHead(404);res.end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch({headless:true});
});
after(async()=>{await browser?.close();await new Promise(r=>server?.close(r));});
async function fixture(providerId='openai',width=390,phoneVision){
 const page=await browser.newPage({viewport:{width,height:844}});
 await page.route('**/*',route=>new URL(route.request().url()).hostname==='127.0.0.1'?route.continue():route.abort());
 await page.addInitScript(()=>{window.MiyinApp={postMessage(){}};});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
 await page.waitForFunction(()=>!!window.MiyinChatUI&&window.MiyinChat?.native);
 await page.evaluate(({providerId,id,phoneVision})=>{
  document.querySelectorAll('.screen').forEach(n=>n.classList.remove('active'));document.querySelector('#screen-chat').classList.add('active');
  window.MiyinChatVoice=undefined;window.MiyinChatSettings=undefined;
  const canvas=document.createElement('canvas');canvas.width=240;canvas.height=160;const ctx=canvas.getContext('2d');ctx.fillStyle='#d4f5ed';ctx.fillRect(0,0,240,160);ctx.fillStyle='#176e64';ctx.beginPath();ctx.arc(80,80,40,0,Math.PI*2);ctx.fill();
  window.imageFixture={id,name:'测试图片.png',bytes:1200,mimeType:'image/png',thumbnailDataUrl:canvas.toDataURL()};
  window.calls=[];window.MiyinNativeBridge={request:async(method,params)=>{
   calls.push({method,params});
   if(method==='chat.history.load')return{conversations:[{id:'image-fixture',updatedAt:Date.now(),messages:[]}]};
   if(method==='chat.status')return{configured:true,providerId,model:'fixture-vision',...(phoneVision===undefined?{}:{phoneVision}),privacy:{allowNetwork:true,sendHistory:true,saveLocalHistory:true}};
   if(method==='chat.local.status')return{ready:true};
   if(method==='chat.image.pick')return imageFixture;
   if(method==='chat.image.extract')return{text:'用户明确请求提取的文字'};
   if(method==='chat.image.preview')return{dataUrl:imageFixture.thumbnailDataUrl};
   if(method==='chat.start')return{model:'fixture-vision'};
   return{};
  }};
  window.dispatchEvent(new Event('miyin:native-host-ready'));
 },{providerId,id,phoneVision});
 await page.waitForFunction(()=>MiyinChat.ready);return page;
}
async function pick(page){await page.evaluate(()=>MiyinChat.pickAttachment('image'));await page.locator('#modal-scrim.open .chat-image-preview').waitFor();}
async function methods(page){return page.evaluate(()=>calls.map(c=>c.method));}
async function click(page,selector){await page.locator(selector).evaluate(n=>n.click());}

test('native picture import previews original, with explicit OCR and no automatic text extraction',async()=>{
 const page=await fixture();try{
  await pick(page);assert.equal(await page.locator('.chat-image-preview img').count(),1);
  assert.match(await page.locator('#modal-copy').innerText(),/发送后由所选模型查看图片/);
  assert.equal(await page.locator('#modal-options textarea').count(),0);
  assert.equal(await page.locator('[data-modal-action="chat-image-ocr"]').innerText(),'仅提取文字');
  assert((await methods(page)).includes('chat.image.pick'));assert(!(await methods(page)).includes('attachment.recognizeImage'));assert(!(await methods(page)).includes('chat.image.extract'));
  await click(page,'[data-modal-action="chat-confirm-import"]');
  const file=await page.evaluate(()=>MiyinChatUI.getPending().files[0]);assert.equal(file.imageId,id);assert.equal(file.text,undefined);
  assert.equal(await page.locator('#chat-file-chips img').count(),1);
 }finally{await page.close();}
});
test('phone preview explains missing component; selection is preserved and sending is blocked',async()=>{
 for(const capability of [undefined,false]){
 const page=await fixture('phone',390,capability);try{
  await pick(page);assert.match(await page.locator('#modal-copy').innerText(),/尚未包含看图组件/);
  assert.equal(await page.locator('[data-modal-action="chat-confirm-import"]').innerText(),'添加后选模型');
  await click(page,'[data-modal-action="chat-confirm-import"]');
  await page.waitForFunction(()=>calls.some(c=>c.method==='chat.configure'));
  assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),1);
  assert.equal(await page.evaluate(()=>MiyinChat.canSend(true,false,'这是什么？')),false);
  assert(!(await methods(page)).includes('chat.start'));assert(!(await methods(page)).includes('chat.image.extract'));
 }finally{await page.close();}
 }
});
test('vision-capable phone adds and sends original image without OCR or model-picker detour',async()=>{
 const page=await fixture('phone',390,true);try{
  await pick(page);
  assert.equal(await page.locator('[data-modal-action="chat-confirm-import"]').innerText(),'添加图片');
  assert.doesNotMatch(await page.locator('#modal-copy').innerText(),/尚未包含看图组件/);
  await click(page,'[data-modal-action="chat-confirm-import"]');
  assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files[0].imageId),id);
  assert.equal(await page.evaluate(()=>MiyinChat.canSend(true,false,'图片中是什么？')),true);
  await page.evaluate(()=>MiyinChatUI.sendVoice('图片中是什么？'));
  await page.waitForFunction(()=>calls.some(c=>c.method==='chat.start'));
  const request=await page.evaluate(()=>calls.find(c=>c.method==='chat.start').params);
  const message=request.messages.find(m=>m.role==='user');assert.deepEqual(message.imageIds,[id]);assert.match(message.content||message.text,/图片中是什么/);
  assert.equal(await page.locator('#chat-messages [data-chat-image]').count(),1);
  const invoked=await methods(page);
  assert(!invoked.includes('chat.image.extract'));assert(!invoked.includes('attachment.recognizeImage'));
  assert(!invoked.includes('chat.configure'));assert(!invoked.includes('chat.image.discard'));
  assert(!JSON.stringify(request).includes('base64'));
 }finally{await page.close();}
});
test('explicit OCR creates a text attachment and discards the unsent original',async()=>{
 const page=await fixture();try{
  await pick(page);await click(page,'[data-modal-action="chat-image-ocr"]');
  await page.locator('#modal-options textarea').waitFor();assert.equal(await page.locator('#modal-options textarea').inputValue(),'用户明确请求提取的文字');
  await click(page,'[data-modal-action="chat-confirm-import"]');
  const file=await page.evaluate(()=>MiyinChatUI.getPending().files[0]);assert.equal(file.imageId,undefined);assert.equal(file.text,'用户明确请求提取的文字');
  assert.equal((await methods(page)).filter(m=>m==='chat.image.extract').length,1);assert((await methods(page)).includes('chat.image.discard'));
 }finally{await page.close();}
});
test('image-only send carries an opaque image ID, no base64 or OCR in the text prompt',async()=>{
 const page=await fixture();try{
  await pick(page);await click(page,'[data-modal-action="chat-confirm-import"]');await page.evaluate(()=>MiyinChatUI.sendVoice(''));
  await page.waitForFunction(()=>calls.some(c=>c.method==='chat.start'));
  const request=await page.evaluate(()=>calls.find(c=>c.method==='chat.start').params);
  const message=request.messages.find(m=>m.role==='user');assert.deepEqual(message.imageIds,[id]);assert.match(message.content||message.text,/请分析这张图片/);
  assert(!JSON.stringify(request).includes('base64'));assert(!JSON.stringify(request).includes('用户明确请求提取'));
  assert.equal(await page.locator('#chat-messages [data-chat-image]').count(),1);
  assert(!(await methods(page)).includes('chat.image.discard'),'sending transfers ownership to saved message, never discards its image');
 }finally{await page.close();}
});
test('saved snapshot reopens thumbnails, suppresses unsafe thumbnail URLs and keeps image routing',async()=>{
 const page=await fixture();try{
  const result=await page.evaluate(({id})=>{
   const safe={imageId:id,name:'原图.png',thumbnailDataUrl:imageFixture.thumbnailDataUrl};
   const unsafe={imageId:'b'.repeat(32),name:'<img src=x onerror=alert(1)>',thumbnailDataUrl:'https://example.com/private.png'};
   const rows=JSON.parse(JSON.stringify([{id:'restored-image',updatedAt:Date.now(),messages:[{id:'saved-image-message',role:'user',status:'complete',createdAt:Date.now(),text:'原图问题',attachments:[safe,unsafe]}]}]));
   MiyinChatUI.replaceHistory(rows);
   return{images:document.querySelectorAll('#chat-messages .chat-image-card img').length,cards:document.querySelectorAll('#chat-messages [data-chat-image]').length,sources:document.querySelectorAll('#chat-messages [data-chat-source]').length,text:document.querySelector('#chat-messages').textContent};
  },{id});
  assert.equal(result.images,1);assert.equal(result.cards,2);assert.equal(result.sources,0);assert.match(result.text,/<img src=x/);
  await page.evaluate(()=>{window.viewerCalls=[];window.miyinOpenImageViewer=image=>viewerCalls.push({src:image.src,mode:image.dataset.imageMode});});
  await click(page,`#chat-messages [data-chat-image="${id}"]`);await page.waitForFunction(()=>viewerCalls.length===1);
  const viewer=await page.evaluate(()=>viewerCalls[0]);assert.equal(viewer.mode,'original');assert.match(viewer.src,/^data:image\/png;base64,/);
 }finally{await page.close();}
});
test('canceling preview and removing a pending picture each discard their native original',async()=>{
 const page=await fixture();try{
  await pick(page);await click(page,'#modal-footer [data-modal-action="close"]');await page.waitForFunction(()=>calls.some(c=>c.method==='chat.image.discard'));
  await pick(page);await click(page,'[data-modal-action="chat-confirm-import"]');await click(page,'[data-remove-chat-attachment="0"]');
  await page.waitForFunction(()=>calls.filter(c=>c.method==='chat.image.discard').length===2);
  assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),0);
 }finally{await page.close();}
});
test('image preview remains rounded and bounded at 320 and 390 pixels',async()=>{
 for(const width of [320,390]){
  const page=await fixture('phone',width);try{
   await pick(page);await page.waitForTimeout(250);
   const box=await page.locator('.chat-image-card').evaluate(n=>{const r=n.getBoundingClientRect();return{left:r.left,right:r.right,radius:parseFloat(getComputedStyle(n).borderRadius),width:r.width};});
   assert(box.left>=0&&box.right<=width);assert.equal(box.radius,18);assert(box.width>=44);
   const out=path.resolve(__dirname,'../../../../output/ai51');await fs.mkdir(out,{recursive:true});await page.screenshot({path:path.join(out,`image-preview-fixture-${width}.png`)});
  }finally{await page.close();}
 }
});
test('programmatic pending removal and starting a new conversation release unsent originals',async()=>{
 const page=await fixture();try{
  await pick(page);await click(page,'[data-modal-action="chat-confirm-import"]');
  await page.evaluate(()=>MiyinChatUI.removePending(0));
  await page.waitForFunction(()=>calls.filter(c=>c.method==='chat.image.discard').length===1);
  assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),0);
  await pick(page);await click(page,'[data-modal-action="chat-confirm-import"]');
  await page.evaluate(()=>{const button=document.createElement('button');button.id='image-test-new-chat';button.dataset.newChat='';button.textContent='新对话';document.body.append(button);button.click();button.remove();});
  await page.waitForFunction(()=>calls.filter(c=>c.method==='chat.image.discard').length===2);
  assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),0);
  assert.equal(await page.evaluate(()=>MiyinChatUI.getActiveId()),null);
  assert.equal(await page.locator('#chat-file-chips img').count(),0);
 }finally{await page.close();}
});
test('late picker result is discarded after switching conversation',async()=>{
 const page=await fixture();try{
  await page.evaluate(()=>{
   const original=MiyinNativeBridge.request;MiyinNativeBridge.request=(method,params)=>method==='chat.image.pick'?new Promise(resolve=>{window.releaseImagePick=()=>resolve(imageFixture);}):original(method,params);
   window.pendingImagePick=MiyinChat.pickAttachment('image');
  });
  await page.waitForFunction(()=>!!window.releaseImagePick);
  await page.evaluate(()=>{MiyinChatUI.replaceHistory([{id:'different-conversation',updatedAt:Date.now(),messages:[]}]);releaseImagePick();});
  await page.evaluate(()=>pendingImagePick);
  assert.equal(await page.locator('.chat-image-preview').count(),0);assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),0);
  assert((await methods(page)).includes('chat.image.discard'));
 }finally{await page.close();}
});
test('closing preview during explicit OCR ignores its late text and discards original',async()=>{
 const page=await fixture();try{
  await pick(page);await page.evaluate(()=>{
   const original=MiyinNativeBridge.request;MiyinNativeBridge.request=(method,params)=>method==='chat.image.extract'?new Promise(resolve=>{window.releaseOcr=()=>resolve({text:'不应恢复的旧文字'});}):original(method,params);
  });
  await click(page,'[data-modal-action="chat-image-ocr"]');await page.waitForFunction(()=>!!window.releaseOcr);
  await click(page,'#modal-footer [data-modal-action="close"]');await page.evaluate(()=>new Promise(resolve=>setTimeout(resolve,0)));
  await page.evaluate(()=>releaseOcr());await page.waitForFunction(()=>calls.some(c=>c.method==='chat.image.discard'));
  assert.equal(await page.locator('#modal-scrim.open').count(),0);assert.equal(await page.evaluate(()=>MiyinChatUI.getPending().files.length),0);
 }finally{await page.close();}
});
test('unsafe original preview response is rejected without opening an external URL',async()=>{
 const page=await fixture();try{
  await pick(page);await page.evaluate(()=>{
   const original=MiyinNativeBridge.request;MiyinNativeBridge.request=(method,params)=>method==='chat.image.preview'?Promise.resolve({dataUrl:'https://example.com/private-photo.png'}):original(method,params);
   window.viewerCalls=[];window.miyinOpenImageViewer=image=>viewerCalls.push(image.src);
  });
  await click(page,'.chat-image-preview [data-chat-image]');await page.evaluate(()=>new Promise(resolve=>setTimeout(resolve,0)));
  assert.deepEqual(await page.evaluate(()=>viewerCalls),[]);
 }finally{await page.close();}
});
