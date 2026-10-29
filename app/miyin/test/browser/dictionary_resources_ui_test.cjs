const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),http=require('node:http');
let browser,server,page;
before(async()=>{
 const root=path.resolve(__dirname,'../../assets/miyin_v5');
 server=http.createServer(async(req,res)=>{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep)){res.writeHead(403);return res.end();}try{const body=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(body);}catch{res.writeHead(404);res.end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch({headless:true});page=await browser.newPage({viewport:{width:390,height:844}});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>!!document.querySelector('#screen-dictionary'));
 await page.evaluate(()=>{
  document.documentElement.dataset.nativeHost='true';window.resourceTestCalls=[];
  window.MiyinNativeBridge={request:async(method,params={})=>{
   resourceTestCalls.push({method,params});
   if(method==='dictionary.browse')return {offset:params.offset,words:Array.from({length:24},(_,i)=>params.letter.toLowerCase()+'word'+String(params.offset+i).padStart(3,'0')),ipaByWord:{},hasMore:params.offset<96};
   if(method==='dictionary.lookup')return {found:true,entries:[{word:params.query,ipa:'/test/',senses:Array.from({length:8},(_,i)=>({partOfSpeech:'n',translations:['词义'+i],definition:'A readable definition for the selected word.',examples:['This is an example.']}))}]};
   if(method==='translation.supportedLanguages')return [{tag:'zh-Hans',name:'简体中文'},{tag:'en',name:'English'},{tag:'ja',name:'日语'},{tag:'ru',name:'俄语'}];
   if(method==='translation.installedModels')return [{tag:'ja',name:'日语'}];
   if(method==='translation.modelInfo')return {status:'notDownloaded'};
   if(method==='history.list')return [];
   return {};
  }};
  window.dispatchEvent(new Event('miyin:native-host-ready'));
  document.querySelectorAll('.screen').forEach(n=>n.classList.remove('active'));document.querySelector('#screen-dictionary').classList.add('active');window.dispatchEvent(new Event('miyin:surface-visibility-change'));
 });
 await page.waitForSelector('[data-v6-dictionary-word]');
});
after(async()=>{await browser?.close();await new Promise(r=>server?.close(r));});
async function assertShellStationary(){
 const geometry=await page.evaluate(()=>{const app=document.querySelector('#app'),header=document.querySelector('#screen-dictionary .settings-head').getBoundingClientRect();return{top:app.scrollTop,left:app.scrollLeft,headerTop:header.top,headerLeft:header.left,headerBottom:header.bottom,headerRight:header.right,width:innerWidth,height:innerHeight};});
 assert.equal(geometry.top,0,'the application shell must not scroll vertically');assert.equal(geometry.left,0,'the application shell must not scroll horizontally');
 assert(geometry.headerTop>=0&&geometry.headerLeft>=0,'the dictionary header must remain on screen');assert(geometry.headerBottom<=geometry.height&&geometry.headerRight<=geometry.width+1);
}

test('dictionary pagination and browsing remain within a bounded pane and preserve the page position',async()=>{
 const main=page.locator('#screen-dictionary .v6-app-content'),list=page.locator('.v6-dictionary-scroll');
 const initial=await main.evaluate(n=>({top:n.scrollTop,height:n.scrollHeight,client:n.clientHeight}));
 for(let i=0;i<3;i++){await list.evaluate(n=>n.scrollTop=n.scrollHeight);await page.locator('[data-v6-dictionary-load-more]').click();await page.waitForFunction(count=>document.querySelectorAll('[data-v6-dictionary-word]').length===count,48+24*i);}
 assert.equal(await page.locator('[data-v6-dictionary-word]').count(),96);
 const after=await main.evaluate(n=>({top:n.scrollTop,height:n.scrollHeight,client:n.clientHeight}));
 assert.equal(after.top,initial.top);assert(after.height<=after.client+1);assert(after.height<=initial.height+1);
 assert(await list.evaluate(n=>n.scrollHeight>n.clientHeight*3));
 const box=await list.boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.wheel(0,-200);await page.waitForTimeout(100);
 assert.equal(await main.evaluate(n=>n.scrollTop),initial.top);
 await assertShellStationary();
});

test('selecting a browsed word reveals its definition without moving the browser or main page',async()=>{
 const list=page.locator('.v6-dictionary-scroll');await list.evaluate(n=>n.scrollTop=400);
 const visibleWord=await page.locator('[data-v6-dictionary-word]').evaluateAll(nodes=>nodes.find(n=>{const r=n.getBoundingClientRect(),p=n.closest('.v6-dictionary-scroll').getBoundingClientRect();return r.top>=p.top&&r.bottom<=p.bottom;}).dataset.v6DictionaryWord);
 const before=await list.evaluate(n=>n.scrollTop);await page.locator(`[data-v6-dictionary-word="${visibleWord}"]`).click();
 await page.waitForSelector('.v6-dictionary-entry-result h2');
 assert.equal(await page.locator('.v6-dictionary-entry-result h2').textContent(),visibleWord);
 assert.equal(await list.evaluate(n=>n.scrollTop),before);assert.equal(await page.locator('#screen-dictionary .v6-app-content').evaluate(n=>n.scrollTop),0);
 await assertShellStationary();
 assert.equal(await page.locator(`[data-v6-dictionary-word="${visibleWord}"]`).getAttribute('aria-pressed'),'true');
 const reader=await page.locator('.v6-dictionary-reader').boundingBox();assert(reader.y>0&&reader.y+reader.height<=844);
 const definitions=page.locator('.v6-dictionary-definition-scroll');assert(await definitions.evaluate(n=>n.scrollHeight>n.clientHeight));
 if(process.env.MIYIN_UI_CAPTURE_DIR){await fs.mkdir(process.env.MIYIN_UI_CAPTURE_DIR,{recursive:true});await fs.writeFile(path.join(process.env.MIYIN_UI_CAPTURE_DIR,'dictionary-geometry.json'),JSON.stringify(await page.evaluate(()=>({x:scrollX,y:scrollY,nodes:[...document.querySelectorAll('.workspace,.stage,.device,#app,#screen-dictionary,#screen-dictionary .settings-head,#screen-dictionary .v6-app-content')].map(n=>({class:n.className,rect:n.getBoundingClientRect().toJSON(),scrollTop:n.scrollTop,scrollLeft:n.scrollLeft,scrollWidth:n.scrollWidth,scrollHeight:n.scrollHeight}))})),null,2));await page.screenshot({path:path.join(process.env.MIYIN_UI_CAPTURE_DIR,'dictionary-bounded-reader.png')});}
 await definitions.evaluate(n=>n.scrollTop=1000);await page.locator('[data-v6-dictionary-letter="B"]').click();await page.waitForSelector('[data-v6-dictionary-word^="bword"]');assert.equal(await list.evaluate(n=>n.scrollTop),0);
});

test('dictionary uses two visible reading panes at narrow and short sizes',async()=>{
 for(const [width,height] of [[320,640],[390,844],[760,440]]){
  await page.setViewportSize({width,height});
  const result=await page.locator('.v6-dictionary-workspace').evaluate(n=>({client:n.clientHeight,scroll:n.scrollHeight,panes:[...n.children].map(x=>{const r=x.getBoundingClientRect();return{x:r.x,y:r.y,w:r.width,h:r.height,bottom:r.bottom,right:r.right};})}));
  assert(result.client>90);assert(result.scroll<=result.client+1);
  for(const pane of result.panes){assert(pane.h>60);assert(pane.bottom<=height+1);assert(pane.right<=width+1);}
  await assertShellStationary();
 }
 await page.setViewportSize({width:390,height:844});
});

test('resource language selection uses rounded themed controls and a custom material menu',async()=>{
 await page.evaluate(()=>{document.querySelectorAll('.screen').forEach(n=>n.classList.remove('active'));document.querySelector('#screen-resources').classList.add('active');window.dispatchEvent(new Event('miyin:surface-visibility-change'));document.querySelector('.v6-translation-add-model').open=true;});
 await page.waitForFunction(()=>!document.querySelector('[data-v6-translation-source]').disabled);
 const trigger=page.locator('[data-v6-translation-source] + .v6-select-trigger');await trigger.scrollIntoViewIfNeeded();await trigger.click();
 const popup=page.locator('.v6-select-popover');await popup.waitFor();
 assert.equal(await trigger.getAttribute('aria-expanded'),'true');
 for(const sel of ['.v6-translation-add-model > summary','.v6-select-trigger','.v6-select-popover'])assert(await page.locator(sel).first().evaluate(n=>parseFloat(getComputedStyle(n).borderRadius)>=12));
 if(process.env.MIYIN_UI_CAPTURE_DIR)await page.screenshot({path:path.join(process.env.MIYIN_UI_CAPTURE_DIR,'resource-language-picker.png')});
 await popup.locator('[data-value="ja"]').click();assert.equal(await page.locator('[data-v6-translation-source]').inputValue(),'ja');assert.equal(await trigger.innerText(),'日语');assert.equal(await popup.count(),0);
 await trigger.click();await page.keyboard.press('Escape');assert.equal(await popup.count(),0);assert.equal(await trigger.getAttribute('aria-expanded'),'false');
 await trigger.click();await page.evaluate(()=>MiyinV6Navigation.handleSystemBack());assert.equal(await popup.count(),0);assert(await page.locator('#screen-resources').evaluate(n=>n.classList.contains('active')));
});
