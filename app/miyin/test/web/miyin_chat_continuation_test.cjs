const fs=require('fs'),vm=require('vm'),assert=require('assert');
(async()=>{
 const listeners={},notices=[],sent=[],calls=[];
 let rows=[{id:'qa',messages:[{id:'u',role:'user',text:'test',status:'complete'},{id:'a',role:'assistant',text:'正在生成',status:'pending',generation:{status:'pending'}}]}];
 let settings={configured:true,model:'Qwen3.5-2B',providerId:'phone',privacy:{sendHistory:true,saveLocalHistory:true}};
 let pending={files:[],contexts:[]};
 const find=(c,m)=>rows.find(x=>x.id===c)?.messages.find(x=>x.id===m);
 const ui={announce:t=>notices.push(t),getHistorySaving:()=>true,getHistory:()=>rows,replaceHistory:r=>rows=r,setModel(){},setHistorySaving(){},getPending:()=>pending,getActiveId:()=> 'qa',get:c=>rows.find(x=>x.id===c),find,update:(c,m,v)=>Object.assign(find(c,m),v),pinModel(){},sendVoice:t=>sent.push(t)};
 const window={MiyinApp:{},MiyinChatUI:ui,MiyinChatContext:{assemble:m=>m.text},MiyinNativeBridge:{request:async(method,params)=>{calls.push({method,params});if(method==='chat.history.load')return {conversations:rows};if(method==='chat.status')return settings;if(method==='chat.start')return {model:settings.model,contextOmitted:0};return {}; }},addEventListener:(n,f)=>(listeners[n]??=[]).push(f)};
 const ctx={window,document:{addEventListener(){},querySelector(){return {value:''}}},localStorage:{removeItem(){}},setTimeout,clearTimeout,console,MutationObserver:class{observe(){}}};
 vm.runInNewContext(fs.readFileSync('assets/miyin_v5/miyin-chat.js','utf8'),ctx);
 listeners['miyin:native-host-ready'][0]();await new Promise(r=>setTimeout(r,20));
 // Initialization recovers old pending replies; emulate a fresh pending message.
 find('qa','a').status='pending';await window.MiyinChat.start('qa','a');
 const requestId=calls.findLast(x=>x.method==='chat.start').params.requestId;
 const event=data=>listeners['miyin:chat-event'][0]({detail:{requestId,...data}});
 event({type:'delta',text:'已收到的回答'});event({type:'context',text:'较早4条未发送'});
 assert.equal(find('qa','a').memoryAvailable,false);
 event({type:'failed',code:'output_limit',text:'到达上限'});
 assert.equal(find('qa','a').text,'已收到的回答');assert.equal(find('qa','a').status,'complete');assert.equal(find('qa','a').generation.finishReason,'length');
 window.MiyinChat.continueAnswer('a');assert.equal(sent.length,1,notices.join('|'));assert(sent[0].includes('断点'));assert(sent[0].includes('已收到的回答'));assert(sent[0].includes('末尾片段'));
 pending.files=[{name:'draft.txt'}];window.MiyinChat.continueAnswer('a');assert.equal(sent.length,1);pending.files=[];
 window.MiyinChat.applyStatus({...settings,privacy:{...settings.privacy,sendHistory:false}});window.MiyinChat.continueAnswer('a');assert.equal(sent.length,1);
 window.MiyinChat.applyStatus(settings);rows[0].messages.push({id:'new',role:'user',text:'new'});window.MiyinChat.continueAnswer('a');assert.equal(sent.length,1);
 // Late chunks after a finished request cannot overwrite its retained text.
 event({type:'delta',text:'迟到文字'});assert.equal(find('qa','a').text,'已收到的回答');
 await new Promise(r=>setTimeout(r,30));console.log('Continuation and context event checks passed');
})();



