const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const fs=require('node:fs/promises'),path=require('node:path'),http=require('node:http');
let browser,server,page,cdp;
before(async()=>{
  const root=path.resolve(__dirname,'../../assets/miyin_v5');
  server=http.createServer(async(req,res)=>{const file=path.resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!file.startsWith(root+path.sep)){res.writeHead(403);return res.end();}try{const bytes=await fs.readFile(file);res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.ttf')?'font/ttf':'text/html');res.end(bytes);}catch{res.writeHead(404);res.end();}});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));browser=await chromium.launch({headless:true});page=await browser.newPage({viewport:{width:390,height:844}});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);await page.waitForFunction(()=>!!window.MiyinChatSettings);
  await page.evaluate(async()=>{
    const status={configured:true,providerId:'phone',model:'local',privacy:{allowNetwork:false,sendHistory:true,saveLocalHistory:true,useMemory:true,webMode:'auto'}};
    window.MiyinNativeBridge={request:async method=>method==='chat.settings'?{status,services:[{id:'phone',label:'本机模型',model:'local',models:['local'],visibleModels:['local']}]}:status};
    await MiyinChatSettings.open('privacy');
  });
  cdp=await page.context().newCDPSession(page);await cdp.send('DOM.enable');await cdp.send('CSS.enable');
});
after(async()=>{await browser?.close();await new Promise(r=>server?.close(r));});
test('privacy rows are compact, rounded and keep readable text with operable targets',async()=>{
  const result=await page.locator('.chat-config-view.is-privacy').evaluate(view=>({rows:[...view.querySelectorAll('.chat-config-toggle,.chat-config-search')].map(n=>{const c=getComputedStyle(n),r=n.getBoundingClientRect();return{height:r.height,radius:parseFloat(c.borderRadius),overflow:n.scrollWidth>n.clientWidth};}),target:view.querySelector('.chat-search-select').getBoundingClientRect().height}));
  assert.equal(result.rows.length,5);assert(result.rows.reduce((n,r)=>n+r.height,0)<410);
  for(const row of result.rows){assert(row.height>=44&&row.height<90);assert(row.radius>=16);assert.equal(row.overflow,false);}
  assert(result.target>=44);
});
test('privacy search select and menu use resolved theme material and preserve selection/back behavior',async()=>{
  const select=page.locator('.chat-search-select');
  for(const material of ['liquid','crystal','ceramic','metal','soft','frost','pearl','satin']){
    await page.evaluate(material=>document.querySelector(`[data-appearance-kind=material][data-appearance-value=${material}]`).click(),material);
    const c=await select.evaluate(n=>{const s=getComputedStyle(n);return{border:parseFloat(s.borderWidth),radius:parseFloat(s.borderRadius),background:s.backgroundColor,image:s.backgroundImage};});
    assert(c.border>=1);assert(c.radius>=12);assert(c.background!=='rgba(0, 0, 0, 0)'||c.image!=='none');
  }
  await select.click();await page.getByRole('option',{name:'每次搜索'}).click();await assert.equal(await select.textContent(),'每次搜索 ⌄');
  await select.click();await page.keyboard.press('Escape');assert.equal(await select.getAttribute('aria-expanded'),'false');assert.equal(await page.locator('.chat-config-view').isVisible(),true);
});
async function platformFonts(selector){const {root}=await cdp.send('DOM.getDocument');const {nodeId}=await cdp.send('DOM.querySelector',{nodeId:root.nodeId,selector});return(await cdp.send('CSS.getPlatformFontsForNode',{nodeId})).fonts;}
test('typography choices use real bundled Chinese serif and rounded glyphs, including settings headings and controls',async()=>{
  await page.evaluate(async()=>{await Promise.all([document.fonts.load('400 18px "Miyin Chill Round"','觅音外观设置'),document.fonts.load('600 18px "Miyin Chill Round"','觅音外观设置'),document.fonts.load('600 18px "Miyin Noto Serif SC"','隐私设置')]);});
  await page.evaluate(()=>{document.documentElement.dataset.appearanceTypography='serif-head';});
  const serif=await platformFonts('.chat-config-view h1');assert(serif.some(f=>f.isCustomFont&&/Serif/i.test(f.familyName)&&f.glyphCount>0));
  if(process.env.UI_PREVIEW_DIR)await page.screenshot({path:path.join(process.env.UI_PREVIEW_DIR,'privacy-serif.png')});
  const body=await page.locator('.chat-search-select').evaluate(n=>getComputedStyle(n).fontFamily);assert(!body.includes('Miyin Noto Serif'));
  await page.evaluate(()=>{document.documentElement.dataset.appearanceTypography='sans';});
  const sans=await page.locator('.chat-config-view h1').evaluate(n=>getComputedStyle(n).fontFamily);assert(!sans.includes('Miyin Noto Serif'));
  if(process.env.UI_PREVIEW_DIR)await page.screenshot({path:path.join(process.env.UI_PREVIEW_DIR,'privacy-sans.png')});
  await page.evaluate(()=>{document.documentElement.dataset.appearanceTypography='rounded';});
  await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));const rounded=await platformFonts('.chat-config-view h1');assert(rounded.some(f=>f.isCustomFont&&/Chill/i.test(f.familyName)&&f.glyphCount>0));
  if(process.env.UI_PREVIEW_DIR)await page.screenshot({path:path.join(process.env.UI_PREVIEW_DIR,'privacy-rounded.png')});
  assert((await page.locator('.chat-search-select').evaluate(n=>getComputedStyle(n).fontFamily)).includes('Miyin Chill Round'));
});
