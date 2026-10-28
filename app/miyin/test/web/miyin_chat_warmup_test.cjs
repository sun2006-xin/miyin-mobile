const fs=require('fs'),vm=require('vm'),assert=require('assert');
(async()=>{
 const events={},calls=[];let visible=false,loaded=false,resolveWarm,rejectWarm;
 const button={dataset:{},textContent:'本机 2B⌄',setAttribute(){},removeAttribute(){}};
 const ui={getHistory:()=>[],getHistorySaving:()=>true,replaceHistory(){},setModel(){},setHistorySaving(){},announce(){}};
 const win={MiyinApp:{},MiyinChatUI:ui,MiyinNativeBridge:{request:async(method)=>{calls.push(method);if(method==='chat.history.load')return {conversations:[]};if(method==='chat.status')return {configured:true,providerId:'phone',model:'Qwen3.5-2B',privacy:{}};if(method==='chat.local.status')return {ready:loaded};if(method==='chat.local.prepare')return new Promise((r,j)=>{resolveWarm=r;rejectWarm=j});return {}; }},addEventListener:(e,f)=>(events[e]??=[]).push(f)};
 const doc={addEventListener(){},querySelector:s=>s==='#screen-chat'?{classList:{contains:()=>visible}}:s==='#screen-chat .model-select'?button:null};
 vm.runInNewContext(fs.readFileSync('assets/miyin_v5/miyin-chat.js','utf8'),{window:win,document:doc,localStorage:{removeItem(){}},setTimeout,clearTimeout,MutationObserver:class{observe(){}}});
 events['miyin:native-host-ready'][0]();await new Promise(r=>setTimeout(r,20));assert(!calls.includes('chat.local.prepare'));
 visible=true;const first=win.MiyinChat.warmLocal(),second=win.MiyinChat.warmLocal();assert.strictEqual(first,second);await new Promise(r=>setTimeout(r,0));assert.equal(calls.filter(x=>x==='chat.local.prepare').length,1);assert.equal(button.textContent,'本机准备中⌄');
 loaded=true;resolveWarm({ready:true});await first;assert.equal(button.textContent,'本机 2B⌄');await win.MiyinChat.warmLocal();assert.equal(calls.filter(x=>x==='chat.local.prepare').length,1);
 events['miyin:app-paused'][0]();await win.MiyinChat.warmLocal();assert.equal(calls.filter(x=>x==='chat.local.prepare').length,1);assert.equal(button.textContent,'本机 2B⌄');
 loaded=false;events['miyin:app-paused'][0]();const failed=win.MiyinChat.warmLocal();await new Promise(r=>setTimeout(r,0));rejectWarm(Error('memory'));await failed;assert.equal(button.textContent,'本机 2B⌄');
 const retry=win.MiyinChat.warmLocal();await new Promise(r=>setTimeout(r,0));loaded=true;resolveWarm({ready:true});await retry;assert.equal(calls.filter(x=>x==='chat.local.prepare').length,3);
 win.MiyinChat.applyStatus({configured:true,providerId:'deepseek',model:'test',privacy:{}});events['miyin:app-paused'][0]();const before=calls.length;await win.MiyinChat.warmLocal();assert.equal(calls.length,before);
 console.log('6 automatic model warm-up checks passed');
})();
