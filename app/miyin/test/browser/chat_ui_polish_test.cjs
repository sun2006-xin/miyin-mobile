const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),http=require('node:http');
let browser,server,page;
before(async()=>{
 const root=path.resolve(__dirname,'../../assets/miyin_v5');
 server=http.createServer(async(req,res)=>{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep)){res.writeHead(403);return res.end();}try{const b=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(b);}catch{res.writeHead(404);res.end();}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch({headless:true});page=await browser.newPage({viewport:{width:390,height:844}});
 await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>!!window.MiyinAppearance);
 await page.evaluate(()=>{document.querySelectorAll('.screen').forEach(n=>n.classList.remove('active'));document.querySelector('#screen-chat').classList.add('active');MiyinChatUI.replaceHistory([{id:'visual-test',updatedAt:Date.now(),messages:[{id:'visual-answer',role:'assistant',status:'complete',createdAt:Date.now(),text:'来源[网页1]，也可以查看[原网页](https://flutter.cn)。',webSources:[{title:'Flutter 官方文档与开发者网站，包含完整入门和各种平台的应用开发指南',url:'https://flutter.cn/',kind:'pageExcerpt'},{title:'这是另一项很长的来源标题，用于检查标题和摘要字号是否清楚且不堆叠',url:'https://example.com/',kind:'searchSnippet'}]}]}]);});
});
after(async()=>{await browser?.close();await new Promise(r=>server?.close(r));});
test('composer fields have one rounded parent surface without a rectangular fill or focus outline',async()=>{
 for(const material of ['liquid','crystal','ceramic','metal','soft','frost','pearl','satin']){
  await page.evaluate(material=>document.querySelector(`[data-appearance-kind=material][data-appearance-value=${material}]`).click(),material);
  for(const selector of ['#translation-input','#chat-input','#voice-input']){
   const result=await page.evaluate(selector=>{const n=document.querySelector(selector);if(!n)throw Error(selector);n.focus();const c=getComputedStyle(n);return{outline:c.outlineStyle,border:parseFloat(c.borderWidth),background:c.backgroundColor,image:c.backgroundImage,appearance:n.classList.contains('appearance-field')};},selector);
   assert.equal(result.outline,'none',`${material} ${selector}`);assert.equal(result.border,0);
   assert.equal(result.background,'rgba(0, 0, 0, 0)');assert.equal(result.image,'none');assert.equal(result.appearance,false);
  }
 }
});
test('web sources are compact rounded rows with readable title and metadata hierarchy',async()=>{
 const result=await page.locator('.chat-web-sources').evaluate(n=>({height:n.getBoundingClientRect().height,rows:[...n.querySelectorAll('[data-chat-web-url]')].map(b=>({radius:parseFloat(getComputedStyle(b).borderRadius),title:parseFloat(getComputedStyle(b.querySelector('strong')).fontSize),meta:parseFloat(getComputedStyle(b.querySelector('small')).fontSize),align:getComputedStyle(b).textAlign,scroll:b.scrollWidth,width:b.clientWidth}))}));
 assert.equal(result.rows.length,2);assert(result.height<200);
 for(const row of result.rows){assert(row.radius>=12);assert(row.title<=14&&row.title>row.meta);assert.equal(row.align,'left');assert(row.scroll<=row.width+1);}
});
test('inline links and citations stay inline without raised material boxes',async()=>{
 for(const selector of ['.chat-web-link','.chat-source-citation']){
  const result=await page.locator(selector).first().evaluate(n=>{const c=getComputedStyle(n);return{border:parseFloat(c.borderWidth),image:c.backgroundImage,raised:n.classList.contains('appearance-surface')};});
  assert.equal(result.border,0);assert.equal(result.image,'none');assert.equal(result.raised,false);
 }
});
test('caption toggle stays round, centered and visible in both modes and short viewports',async()=>{
 await page.evaluate(()=>{MiyinVoiceUI.open();document.querySelector('.voice-state-label').textContent='点麦克风继续 · 也可直接输入';});
 for(const width of [320,390])for(const height of [844,480,360]){
  await page.setViewportSize({width,height});
  for(const mode of ['orb','captions']){
   await page.evaluate(mode=>document.querySelector('#voice-overlay').dataset.displayMode=mode,mode);await page.waitForTimeout(450);
   const data=await page.locator('.voice-caption-toggle').evaluate(n=>{const r=n.getBoundingClientRect();const s=[...n.querySelectorAll('svg')].find(s=>getComputedStyle(s).display!=='none').getBoundingClientRect();return{w:r.width,h:r.height,cx:r.x+r.width/2,top:r.top,bottom:r.bottom,sw:s.width,sh:s.height,orb:(()=>{const b=document.querySelector('.voice-orb-row .ai-orb-renderer').getBoundingClientRect();return{top:b.top,bottom:b.bottom}})(),label:(()=>{const b=document.querySelector('.voice-state-label').getBoundingClientRect();return{top:b.top,bottom:b.bottom}})()};});
   assert.equal(data.w,44);assert.equal(data.h,44);assert.equal(data.sw,data.sh);assert(data.sw>=18);
   assert(Math.abs(data.cx-width/2)<1);assert(data.top>=0&&data.bottom<=height);
   if(mode==='orb'){assert(data.orb.top-data.bottom>=12,JSON.stringify(data));assert(data.label.top-data.orb.bottom>=12,JSON.stringify(data));}
   else {assert(data.orb.top-data.label.bottom>=4,JSON.stringify(data));assert(data.top-data.orb.bottom>=4,JSON.stringify(data));}
   const target=page.locator('.voice-caption-toggle');await target.hover();await page.mouse.down();
   const pressed=await target.evaluate(n=>{const r=n.getBoundingClientRect();return{cx:r.x+r.width/2,ratio:r.width/r.height};});
   assert(Math.abs(pressed.cx-width/2)<1);assert(Math.abs(pressed.ratio-1)<.01);await page.mouse.up();
  }
 }
});
