const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),http=require('node:http');
let browser,server,page;
before(async()=>{
  const root=path.resolve(__dirname,'../../assets/miyin_v5');
  server=http.createServer(async(req,res)=>{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep)){res.writeHead(403);return res.end();}try{const bytes=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch({headless:true});page=await browser.newPage({viewport:{width:390,height:844}});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>!!window.MiyinChatSettings);
  await page.evaluate(()=>{
    window.voiceCalls=[];window.voiceSettings={mode:'local',allowCloud:false,region:'beijing',model:'qwen3-tts-flash-realtime',voice:'Cherry',hasKey:false};
    const status={configured:true,providerId:'phone',model:'local',privacy:{allowNetwork:false,sendHistory:true,saveLocalHistory:true,useMemory:true,webMode:'off'}};
    window.MiyinNativeBridge={request:async(method,params)=>{
      window.voiceCalls.push({method,params});
      if(method==='chat.settings')return{status,services:[{id:'phone',label:'本机模型',model:'local',models:['local'],visibleModels:['local']}]};
      if(method==='speech.settings')return {...window.voiceSettings};
      if(method==='speech.settings.save'){const old=window.voiceSettings;window.voiceSettings={...params,hasKey:old.region===params.region&&old.hasKey};return{...window.voiceSettings};}
      if(method==='speech.configure'){window.voiceSettings.hasKey=true;return{settingsSaved:true};}
      return status;
    }};
  });
});
after(async()=>{await browser?.close();await new Promise(r=>server?.close(r));});
async function openSpeech(){await page.evaluate(()=>MiyinChatSettings.open('provider'));await page.getByRole('button',{name:'AI 语音服务 →'}).click();await page.getByRole('heading',{name:'AI 语音服务',exact:true}).waitFor();}
test('voice settings default to local without uploading, use current material and return to model configuration',async()=>{
  await openSpeech();
  assert.equal(await page.getByRole('radio',{name:'本机离线语音 ✓'}).getAttribute('aria-checked'),'true');
  assert.equal(await page.getByRole('switch',{name:/允许在线合成/}).count(),0);
  for(const width of [320,390,768,1440]){
    await page.setViewportSize({width,height:844});
    const rows=await page.getByRole('radio').evaluateAll(nodes=>nodes.map(n=>{const r=n.getBoundingClientRect(),s=getComputedStyle(n);return{height:r.height,left:r.left,right:r.right,radius:parseFloat(s.borderRadius)};}));
    assert.equal(rows.length,2);for(const row of rows){assert(row.height>=44);assert(row.left>=0&&row.right<=width);assert(row.radius>=12);}
  }
  assert.equal((await page.evaluate(()=>window.voiceCalls)).filter(x=>x.method==='speech.open').length,0);
  if(process.env.UI_PREVIEW_DIR)await page.screenshot({path:path.join(process.env.UI_PREVIEW_DIR,'cloud-voice-local.png')});
  await page.locator('.chat-config-view .back-button').click();await page.getByRole('heading',{name:'模型设置',exact:true}).waitFor();
});
test('online configuration separates consent, custom pickers and regional credential setup',async()=>{
  await openSpeech();await page.getByRole('radio',{name:'在线流式语音 · 通义千问'}).click();
  assert.equal(await page.getByRole('switch',{name:/允许在线合成/}).getAttribute('aria-checked'),'false');
  assert.equal(await page.locator('.chat-config-view select').count(),0);
  await page.setViewportSize({width:390,height:844});
  assert((await page.getByRole('button',{name:'配置语音专用密钥',exact:true}).boundingBox()).height>=44);
  if(process.env.UI_PREVIEW_DIR)await page.screenshot({path:path.join(process.env.UI_PREVIEW_DIR,'cloud-voice-online.png')});
  await page.locator('.chat-config-view summary').filter({hasText:'服务地域'}).click();await page.getByRole('option',{name:'新加坡',exact:true}).click();
  await page.getByRole('button',{name:'配置语音专用密钥',exact:true}).click();
  await page.getByRole('button',{name:'更换语音专用密钥',exact:true}).waitFor();
  const calls=await page.evaluate(()=>window.voiceCalls),configure=calls.findLastIndex(x=>x.method==='speech.configure');
  assert.equal(calls[configure-1].method,'speech.settings.save');assert.equal(calls[configure-1].params.region,'singapore');
  assert(!calls.some(x=>['speech.open','chat.configure'].includes(x.method)));
  assert(!(await page.locator('.chat-config-view').textContent()).includes('sk-'));
  await page.getByRole('switch',{name:/允许在线合成/}).click();await page.getByRole('button',{name:'保存语音设置',exact:true}).click();
  await page.getByRole('heading',{name:'模型设置',exact:true}).waitFor();
  const saved=await page.evaluate(()=>window.voiceSettings);assert.equal(saved.mode,'qwen');assert.equal(saved.allowCloud,true);assert.equal(saved.region,'singapore');
});
test('speech page preserves the model picker return path and does not change selected chat model',async()=>{
  await page.evaluate(()=>MiyinChatSettings.open('models'));
  await page.getByRole('button',{name:'配置其他模型 →'}).click();await page.getByRole('button',{name:'AI 语音服务 →'}).click();
  await page.locator('.chat-config-view .back-button').click();await page.getByRole('heading',{name:'模型设置',exact:true}).waitFor();
  await page.locator('.chat-config-view .back-button').click();await page.getByRole('heading',{name:'选择 AI 模型',exact:true}).waitFor();
  assert(!(await page.evaluate(()=>window.voiceCalls)).some(x=>['chat.settings.save','chat.privacy'].includes(x.method)));
});
