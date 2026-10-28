// Run with Node.js and Playwright installed: node --test test/browser/chat_web_sources_test.cjs
const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const http = require('node:http');
let browser, server, page;
before(async () => {
  const root = path.resolve(__dirname, '../../assets/miyin_v5');
  server = http.createServer(async (req, res) => {
    const file = path.resolve(root, '.' + new URL(req.url, 'http://localhost').pathname);
    if (!file.startsWith(root + path.sep)) { res.writeHead(403); res.end(); return; }
    try {
      const body = await fs.readFile(file);
      res.setHeader('Content-Type', file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html');
      res.end(body);
    } catch (_) { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  browser = await chromium.launch({headless:true});
  page = await browser.newPage({viewport:{width:390, height:844}});
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction(() => !!window.MiyinChatPresentation);
});
after(async () => { await browser?.close(); await new Promise(resolve => server?.close(resolve)); });
async function rendered(message) {
  return page.evaluate(message => {
    const area = document.createElement('div');
    area.innerHTML = window.MiyinChatPresentation.render(message);
    return {text:area.textContent, links:[...area.querySelectorAll('button')].map(button => ({
      text:button.textContent, web:button.dataset.chatWebUrl || null,
      material:button.dataset.chatSource || null, index:button.dataset.sourceIndex || null,
    }))};
  }, message);
}
test('web citations use this answer source while material citations retain their own route', async () => {
  const result = await rendered({id:'answer-a',role:'assistant',text:'事实[网页1]，附件[资料1]。',
    webSources:[{title:'来源甲',url:'https://example.com/first'}]});
  assert.deepEqual(result.links, [
    {text:'[网页1]',web:'https://example.com/first',material:null,index:null},
    {text:'[资料1]',web:null,material:'answer-a',index:'1'},
  ]);
});
test('late sources and changed sources invalidate the rendered answer cache', async () => {
  const message={id:'late-answer',role:'assistant',text:'信息[网页1]。'};
  assert.equal((await rendered(message)).links.length,0);
  for (const url of ['https://example.com/old','https://example.com/new']) {
    const result=await rendered({...message,webSources:[{url}]});
    assert.equal(result.links[0]?.web,url);
  }
  assert.equal((await rendered({...message,webSources:[]})).links.length,0);
});
test('missing and unsafe web references remain readable text without clickable actions', async () => {
  for (const url of ['javascript:alert(1)','file:///private','https://user:password@example.com/', 'https://example.com/\nwrong']) {
    const result=await rendered({id:url,role:'assistant',text:'内容[网页1] [网页2]',webSources:[{url}]});
    assert.equal(result.links.length,0,url);assert.equal(result.text.trim(),'内容[网页1] [网页2]');
  }
});
test('citations inside code stay literal and separate messages never share a source', async () => {
  const text='`[网页1]`\n\n正文[网页1]';
  for (const [id,url] of [['first','https://example.com/a'],['second','https://example.com/b']]) {
    const result=await rendered({id,role:'assistant',text,webSources:[{url}]});
    assert.equal(result.links.filter(link=>link.web).length,1);
    assert.equal(result.links.find(link=>link.web).web,url);
  }
});
test('clicking a web citation opens the browser once without navigating the chat', async () => {
  const initial=page.url();
  await page.evaluate(() => {
    window.webCitationCalls=[];window.MiyinApp={};
    window.MiyinNativeBridge={request:async (method,params)=>webCitationCalls.push({method,params})};
    const area=document.createElement('div');area.id='citation-click-target';
    area.innerHTML=MiyinChatPresentation.render({id:'click-answer',role:'assistant',text:'来源[网页1]',webSources:[{url:'https://example.com/read'}]});
    document.body.append(area);
  });
  await page.locator('#citation-click-target [data-chat-web-url]').evaluate(button=>button.click());
  const calls=await page.evaluate(()=>webCitationCalls);
  assert.deepEqual(calls,[{method:'chat.openUrl',params:{url:'https://example.com/read'}}]);
  assert.equal(page.url(),initial);
});
test('regeneration clears old sources and ignores sources from a superseded request', async () => {
  const result=await page.evaluate(async () => {
    const previousUI=window.MiyinChatUI, previousVoice=window.MiyinChatVoice, previousBridge=window.MiyinNativeBridge;
    const answer={id:'regenerated-answer',role:'assistant',status:'pending',text:'旧回答',generation:{},webSources:[{url:'https://example.com/old'}]};
    const conversation={id:'regenerated-conversation',messages:[{id:'question',role:'user',status:'complete',text:'搜索新资料'},answer]};
    let requestId;
    window.MiyinChatUI={get:()=>conversation,find:()=>answer,update:(_c,_m,patch)=>Object.assign(answer,patch),
      pinModel(){},getHistory:()=>[],announce(){}};
    window.MiyinChatVoice=undefined;
    window.MiyinNativeBridge={request:async (method,params)=>{
      if(method==='chat.start'){requestId=params.requestId;return{model:'test-model'};}return{};
    }};
    try {
      await MiyinChat.start(conversation.id,answer.id);
      const cleared=answer.webSources.length===0;
      const emit=(id,url)=>window.dispatchEvent(new CustomEvent('miyin:chat-event',{detail:{requestId:id,type:'sources',text:JSON.stringify([{url}])}}));
      emit('old-request','https://example.com/wrong');
      const ignored=answer.webSources.length===0;
      emit(requestId,'https://example.com/current');
      const current=answer.webSources[0]?.url;
      MiyinChat.cancel(conversation.id,answer.id);
      emit(requestId,'https://example.com/too-late');
      return {cleared,ignored,current,afterCancel:answer.webSources[0]?.url};
    } finally {window.MiyinChatUI=previousUI;window.MiyinChatVoice=previousVoice;window.MiyinNativeBridge=previousBridge;}
  });
  assert.deepEqual(result,{cleared:true,ignored:true,current:'https://example.com/current',afterCancel:'https://example.com/current'});
});
test('reopened conversation snapshots render their original answer source', async () => {
  const result=await page.evaluate(() => {
    const snapshot=JSON.parse(JSON.stringify([{id:'restored-web',title:'已保存的搜索',updatedAt:Date.now(),messages:[
      {id:'restored-answer',role:'assistant',status:'complete',createdAt:Date.now(),text:'来源[网页1]',
        webSources:[{title:'已保存来源',url:'https://example.com/saved',kind:'pageExcerpt'}]},
    ]}]));
    MiyinChatUI.replaceHistory(snapshot);
    return [...document.querySelectorAll('#chat-messages [data-chat-web-url]')].map(button=>button.dataset.chatWebUrl);
  });
  assert(result.length>=1);assert(result.every(url=>url==='https://example.com/saved'));
});
test('native capture handler and presentation handler open one source only once', async () => {
  const nativePage=await browser.newPage({viewport:{width:390,height:844}});
  try {
    await nativePage.addInitScript(()=>{window.MiyinApp={postMessage(){}};});
    await nativePage.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await nativePage.waitForFunction(()=>!!window.MiyinChatPresentation&&window.MiyinChat?.native);
    await nativePage.evaluate(()=>{
      window.webCitationCalls=[];
      window.MiyinNativeBridge={request:async(method,params)=>webCitationCalls.push({method,params})};
      const area=document.createElement('div');area.id='native-citation-target';
      area.innerHTML=MiyinChatPresentation.render({id:'native-answer',role:'assistant',text:'来源[网页1]',webSources:[{url:'https://example.com/native'}]});
      document.body.append(area);
    });
    await nativePage.locator('#native-citation-target button').evaluate(button=>button.click());
    assert.deepEqual(await nativePage.evaluate(()=>webCitationCalls),[{method:'chat.openUrl',params:{url:'https://example.com/native'}}]);
    assert(nativePage.url().endsWith('/index.html'));
  } finally {await nativePage.close();}
});
