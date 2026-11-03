const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../assets/miyin_v5/miyin-chat-voice.js'), 'utf8');
const settle = async () => { for (let i=0; i<8; i++) await Promise.resolve(); };
function harness(request) {
  const listeners = new Map(), calls = [], states = [], timers = new Map();
  let draft = '', activeScreen = true, timerId = 0, reading = null;
  const data = new Map();
  const on = (name, fn) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); };
  const document = {hidden: false, addEventListener: (name, fn) => on('doc:' + name, fn),
    querySelector: () => ({classList: {contains: () => activeScreen}})};
  const window = {MiyinApp: {}, addEventListener: on,
    MiyinNativeBridge: {request: async (method, params) => { calls.push({method, params}); return request ? request(method, params) : {status:'ok'}; }},
    MiyinChatUI: {announce: () => {}, setReading: id => { reading=id; },
      sendVoice: () => undefined, normalizeTranscript: text => text},
    MiyinChat: {isGenerating: false, cancel: (conversationId,messageId) => calls.push({method:'cancel',conversationId,messageId})},
    MiyinVoiceUI: {open: () => {}, state: (...args) => states.push(args), refresh: () => {},
      draft: text => {draft=text;}, close: () => {void window.MiyinChatVoice.shutdown();}},
  };
  vm.runInNewContext(source, {window, document,
    localStorage: {getItem: key => data.get(key) || null, setItem: (key,value) => data.set(key,value)},
    setTimeout: fn => {timers.set(++timerId,fn);return timerId;}, clearTimeout: id => timers.delete(id)});
  return {voice: window.MiyinChatVoice, window, calls, states, timers, preferences:data,
    get draft(){return draft;}, get reading(){return reading;},
    emit(name,detail){for(const fn of listeners.get(name)||[])fn({detail});},
    leave(){activeScreen=false;this.emit('miyin:surface-visibility-change');},
    returnToChat(){activeScreen=true;this.emit('miyin:surface-visibility-change');}};
}
test('opening voice does not start a microphone or contact a model', () => {
  const h=harness(); h.voice.open(); assert.equal(h.calls.length,1); assert.equal(h.calls[0].method,'voice.prepare');
  assert.equal(h.calls[0].params.languageTag,'zh-Hans');assert.equal(h.voice.isOpen,true);
});

test('AI Chinese warmup, preparation and reading use the single fast voice without changing saved translation settings', async () => {
  const h=harness();
  h.preferences.set('miyin.full.preview.v5.tts-provider',JSON.stringify('supertonic'));
  h.preferences.set('miyin.full.preview.v5.tts-speaker',JSON.stringify(8));
  h.voice.open();
  const warm=h.calls.find(row=>row.method==='voice.prepare').params;
  assert.equal(warm.provider,'matcha');assert.equal(warm.speakerId,0);
  await h.voice.shutdown();
  h.voice.prepareMessage('你好，这是中文测试。');await settle();
  const prepared=h.calls.find(row=>row.method==='voice.prepareUtterance').params;
  await h.voice.read('你好，这是中文测试。','fast-chinese');await settle();
  const spoken=h.calls.find(row=>row.method==='voice.speak').params;
  for(const params of [prepared,spoken]) {
    assert.equal(params.languageTag,'zh-Hans');assert.equal(params.provider,'matcha');assert.equal(params.speakerId,0);
  }
  assert.equal(h.preferences.get('miyin.full.preview.v5.tts-provider'),JSON.stringify('supertonic'));
  assert.equal(h.preferences.get('miyin.full.preview.v5.tts-speaker'),JSON.stringify(8));
});

test('AI English warmup, preparation and reading use multilingual speech even when translation selects Melo', async () => {
  const h=harness();
  h.preferences.set('miyin.full.preview.v5.ai-tts-language',JSON.stringify('en'));
  h.preferences.set('miyin.full.preview.v5.tts-provider',JSON.stringify('melo'));
  h.preferences.set('miyin.full.preview.v5.tts-speaker',JSON.stringify(3));
  h.voice.open();assert.equal(h.calls[0].params.provider,'supertonic');
  assert.equal(h.calls[0].params.languageTag,'en');assert.equal(h.calls[0].params.speakerId,3);
  await h.voice.shutdown();h.voice.prepareMessage('Hello, how are you?');await settle();
  await h.voice.read('Hello, how are you?','fast-english');await settle();
  for(const row of h.calls.filter(row=>['voice.prepareUtterance','voice.speak'].includes(row.method))) {
    assert.equal(row.params.provider,'supertonic');assert.equal(row.params.languageTag,'en');assert.equal(row.params.speakerId,3);
  }
  assert(h.calls.some(row=>row.method==='voice.prepareUtterance'));
});

test('explicit AI French selection stays on multilingual speech for warmup and playback', async () => {
  const h=harness();h.preferences.set('miyin.full.preview.v5.ai-tts-language',JSON.stringify('fr'));
  h.voice.open();assert.equal(h.calls[0].params.provider,'supertonic');assert.equal(h.calls[0].params.languageTag,'fr');
  await h.voice.read('Bonjour, comment allez-vous ?','french');await settle();
  const speech=h.calls.find(row=>row.method==='voice.speak').params;
  assert.equal(speech.languageTag,'fr');assert.equal(speech.provider,'supertonic');
});

for(const withVoiceOpen of [false,true]) {
  test(`returning from translation refreshes AI warmup once within the TTL (voice open: ${withVoiceOpen})`, async () => {
    const h=harness();
    if(withVoiceOpen) h.voice.open(); else h.returnToChat();
    h.returnToChat();
    assert.equal(h.calls.filter(row=>row.method==='voice.prepare').length,1);
    h.leave();await settle();
    // Another page may now have warmed/spoken Melo; returning must ask native
    // to restore Matcha even though less than 30 seconds have elapsed.
    h.returnToChat();h.returnToChat();
    const prepares=h.calls.filter(row=>row.method==='voice.prepare');
    assert.equal(prepares.length,2);
    assert(prepares.every(row=>row.params.provider==='matcha'));
    await h.voice.read('你好，这是返回后的回答。','after-return');await settle();
    assert.equal(h.calls.filter(row=>row.method==='voice.prepare').length,2);
  });
}

test('one answer queues the next segment after buffering without ending the shared track', async () => {
  const h=harness();await h.voice.read('这是测试连续朗读的完整中文句子。'.repeat(9),'continuous');await settle();
  const first=h.calls.find(row=>row.method==='voice.speak');const group=first.params.groupId;
  assert(group);h.emit('miyin:voice-event',{sessionId:first.params.sessionId,type:'tts_buffered'});await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,2);
  for(let i=1;i<20;i++) {
    const speech=h.calls.filter(row=>row.method==='voice.speak')[i];if(!speech)break;
    assert.equal(speech.params.groupId,group);
    h.emit('miyin:voice-event',{sessionId:speech.params.sessionId,type:'tts_buffered'});await settle();
  }
  assert.equal(h.reading,'continuous');
  assert.equal(h.calls.filter(row=>row.method==='voice.finishSpeech').length,1);
  h.emit('miyin:voice-event',{sessionId:group,type:'tts_done'});await settle();assert.equal(h.reading,null);
});

test('synchronous buffered events before speak admission resolves retain all three segments and finish once', async () => {
  let h;
  h=harness((method,params)=>{
    if(method==='voice.speak') {
      // Native synthesis may finish and notify JS before the admission RPC
      // response reaches it. Do not defer this event to a later microtask.
      h.emit('miyin:voice-event',{sessionId:params.sessionId,type:'tts_buffered'});
      return {status:'started'};
    }
    return {};
  });
  const text='同步回调不会丢失后续语音片段'.repeat(8).slice(0,100);
  await h.voice.read(text,'synchronous-buffered');await settle();
  const spoken=h.calls.filter(row=>row.method==='voice.speak');
  assert.equal(spoken.length,3);
  assert.equal(spoken.map(row=>row.params.text).join(''),text);
  const group=spoken[0].params.groupId;
  assert(spoken.every(row=>row.params.groupId===group&&row.params.streamAudio===true));
  const finishes=h.calls.filter(row=>row.method==='voice.finishSpeech');
  assert.equal(finishes.length,1);assert.equal(finishes[0].params.groupId,group);
  assert.equal(h.reading,'synchronous-buffered');
  h.emit('miyin:voice-event',{sessionId:group,type:'tts_done'});await settle();
  assert.equal(h.reading,null);assert.equal(h.timers.size,0);
});

test('late buffered events cannot enqueue more speech after interrupt', async () => {
  const h=harness();await h.voice.read('连续朗读测试。'.repeat(20),'stop');await settle();
  const first=h.calls.find(row=>row.method==='voice.speak');await h.voice.interrupt();
  h.emit('miyin:voice-event',{sessionId:first.params.sessionId,type:'tts_buffered'});
  h.emit('miyin:voice-event',{sessionId:first.params.groupId,type:'tts_done'});await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);assert.equal(h.reading,null);
});

test('generic voice warmup cannot replace an exact prepared reply with another language', async () => {
  const h=harness();h.voice.prepareMessage('Hello yesterday.');await settle();h.voice.open();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,1);
  assert.equal(h.calls.filter(row=>row.method==='voice.prepare').length,0);
});

test('automatic warmup follows the visible reply language', () => {
  const h=harness();h.window.MiyinChatUI.getActiveId=()=> 'en';
  h.window.MiyinChatUI.get=()=>({messages:[{role:'assistant',status:'complete',text:'Hello yesterday.'}]});
  h.voice.open();assert.equal(h.calls[0].params.languageTag,'en');
});
test('microphone uses local chat mode and shutdown cancels the exact session', async () => {
  const h=harness();h.voice.open();await h.voice.toggleMicrophone();
  const start=h.calls.find(row=>row.method==='voice.startListening');
  assert.equal(start.params.mode,'chat');
  await h.voice.shutdown();
  assert.ok(h.calls.some(row=>row.method==='voice.cancelListening'&&row.params.sessionId===start.params.sessionId));
  assert.equal(h.voice.isOpen,false);
});
test('recognized text is preserved when model configuration prevents sending', async () => {
  const h=harness();h.voice.open();await h.voice.toggleMicrophone();
  const id=h.calls.find(row=>row.method==='voice.startListening').params.sessionId;
  h.emit('miyin:voice-event',{sessionId:id,type:'recognition_final',text:'Hello yesterday'});
  await settle();assert.equal(h.draft,'Hello yesterday');
  assert.ok(!h.calls.some(row=>row.method==='chat.start'));
});
test('speech sentences drain serially and punctuation-free final tail is retained', async () => {
  const h=harness();h.voice.open();await h.voice.beforeGeneration({conversationId:'c',messageId:'m'});
  h.voice.delta('第一句。第二句没有句号');h.voice.finish(true);await settle();
  const first=h.calls.filter(row=>row.method==='voice.speak');assert.equal(first.length,1);assert.equal(first[0].params.text,'第一句。');
  h.emit('miyin:voice-event',{sessionId:first[0].params.sessionId,type:'tts_done'});await settle();
  const second=h.calls.filter(row=>row.method==='voice.speak');assert.equal(second.length,2);assert.equal(second[1].params.text,'第二句没有句号');
});

test('incoming Chinese starts speaking a phrase before the model finishes a sentence', async () => {
  const h=harness();h.voice.open();await h.voice.beforeGeneration({conversationId:'c',messageId:'m'});
  h.voice.delta('这是正在逐字输出的一段聊天内容还没有句号');await settle();
  const speech=h.calls.find(row=>row.method==='voice.speak');
  assert(speech);assert.equal(speech.params.text,'这是正在逐字输出的一段聊');
  assert.equal(speech.params.streamAudio,true);
});
test('interrupt cancels generation and discards queued speech, ignoring stale completion', async () => {
  const h=harness();h.voice.open();await h.voice.beforeGeneration({conversationId:'c',messageId:'m'});
  h.voice.delta('第一句。');await settle();h.voice.delta('第二句。');await settle();const id=h.calls.find(row=>row.method==='voice.speak').params.sessionId;
  await h.voice.interrupt();h.emit('miyin:voice-event',{sessionId:id,type:'tts_done'});await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);
  assert.ok(h.calls.some(row=>row.method==='cancel'&&row.messageId==='m'));
  assert.ok(h.calls.some(row=>row.method==='voice.stopSpeaking'));
});
test('leaving chat closes the microphone, and manual read can be stopped by a second tap', async () => {
  const h=harness();h.voice.open();await h.voice.toggleMicrophone();h.leave();await settle();assert.equal(h.voice.isOpen,false);
  await h.voice.read('hello.','m');assert.equal(h.reading,'m');await h.voice.read('hello.','m');assert.equal(h.reading,null);
});
test('closing and reopening voice invalidates a submission waiting for microphone cancellation', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.cancelListening'?pending:{});let sends=0;
  h.window.MiyinChatUI.sendVoice=()=>{sends++;return{conversationId:'c',messageId:'late'};};
  h.voice.open();await h.voice.toggleMicrophone();
  const submit=h.voice.submit('Do not send after closing');await settle();
  await h.voice.shutdown();h.voice.open();release();await submit;
  assert.equal(sends,0);assert.equal(h.voice.isOpen,true);
});
test('interrupt also invalidates a pending voice submission', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.cancelListening'?pending:{});let sends=0;
  h.window.MiyinChatUI.sendVoice=()=>{sends++;return{conversationId:'c',messageId:'late'};};
  h.voice.open();await h.voice.toggleMicrophone();
  const submit=h.voice.submit('Stopped submission');await settle();
  await h.voice.interrupt();release();await submit;assert.equal(sends,0);
});
test('closing during generation preparation cancels the registered generation', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.stopSpeaking'?pending:{});
  h.voice.open();await h.voice.read('Hello.','old');
  const preparing=h.voice.beforeGeneration({conversationId:'c',messageId:'preparing'});await settle();
  await h.voice.shutdown();
  assert(h.calls.some(row=>row.method==='cancel'&&row.messageId==='preparing'));
  h.voice.open();release();await preparing;
  await h.voice.interrupt();
  assert.equal(h.calls.filter(row=>row.method==='cancel'&&row.messageId==='preparing').length,1);
});
test('closing while interruption awaits TTS cannot start a microphone in the next voice session', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.stopSpeaking'?pending:{});
  h.voice.open();await h.voice.read('Hello.','old');
  const opening=h.voice.toggleMicrophone();await settle();
  await h.voice.shutdown();h.voice.open();release();await opening;
  assert.equal(h.calls.filter(row=>row.method==='voice.startListening').length,0);
});
test('native TTS error clears the reading state and does not play queued sentences', async () => {
  const h=harness();await h.voice.read('Hello. More speech.','answer');
  const id=h.calls.find(row=>row.method==='voice.speak').params.sessionId;
  h.emit('miyin:voice-event',{sessionId:id,type:'tts_error',message:'TTS unavailable'});await settle();
  assert.equal(h.reading,null);assert.equal(h.timers.size,0);
  h.emit('miyin:voice-event',{sessionId:id,type:'tts_done'});await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);
});
test('an old generation cleanup cannot stop speech from a reopened voice session', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.cancelListening'?pending:{});
  h.voice.open();await h.voice.toggleMicrophone();
  const preparing=h.voice.beforeGeneration({conversationId:'c',messageId:'old'});await settle();
  await h.voice.shutdown();h.voice.open();await h.voice.read('New speech.','fresh');
  release();await preparing;
  assert.equal(h.calls.filter(row=>row.method==='voice.stopSpeaking').length,0);
  assert.equal(h.reading,'fresh');
});
test('a late shutdown does not erase the reading identity of new speech', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.stopSpeaking'?pending:{});
  h.voice.open();await h.voice.read('Old speech.','old');
  const closing=h.voice.shutdown();await settle();h.voice.open();
  await h.voice.read('New speech.','fresh');release();await closing;
  await h.voice.read('New speech.','fresh');
  assert.equal(h.reading,null);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,2);
});
test('app pause prevents an awaiting manual read from starting playback', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.stopSpeaking'?pending:{});
  await h.voice.read('Old speech.','old');
  const reading=h.voice.read('Delayed speech.','late');await settle();
  h.emit('miyin:app-paused');release();await reading;
  assert.equal(h.reading,null);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);
});

test('native paused playback cancellation clears reading without starting the next segment', async () => {
  const h=harness(method=>method==='voice.speak'?{status:'cancelled'}:{});
  await h.voice.read('First sentence. '.repeat(35),'cancelled');await settle();
  assert.equal(h.reading,null);assert.equal(h.timers.size,0);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,0);
});
test('an old speech failure cannot replace the state of a newly opened voice session', async () => {
  let release, speaks=0;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>{
    if(method==='voice.stopSpeaking')return pending;
    if(method==='voice.speak'&&++speaks===1)throw new Error('Old failure');
    return{};
  });
  await h.voice.read('Old speech.','old');await settle();
  h.voice.open();await h.voice.read('New speech.','new');
  release();await settle();
  assert.equal(h.reading,'new');assert.equal(h.states.at(-1)[0],'speaking');
});
test('manual reading combines adjacent short sentences into one playback', async () => {
  const h=harness(), text='第一句。第二句！第三句没有句号';await h.voice.read(text,'answer');await settle();
  const speech=h.calls.filter(row=>row.method==='voice.speak');
  assert.equal(speech.length,1);assert.equal(speech[0].params.text,text);
});
test('Chinese reading starts with a small segment and bounds later preparation', async () => {
  const h=harness(),text='这是一段用于连续朗读验证的中文内容，确保长回复不会等待整段合成。'.repeat(16);
  await h.voice.read(text,'chinese');await settle();
  assert(h.calls.find(row=>row.method==='voice.speak').params.text.length<=24);
  for(let guard=0;guard<80&&h.reading;guard++) {
    const current=h.calls.filter(row=>row.method==='voice.speak').at(-1);
    h.emit('miyin:voice-event',{sessionId:current.params.sessionId,type:'tts_done'});await settle();
  }
  const spoken=h.calls.filter(row=>row.method==='voice.speak');
  assert(spoken.every(row=>row.params.text.length<=64));
  assert.equal(spoken.map(row=>row.params.text).join('').replace(/\s/g,''),text);
  assert.equal(h.reading,null);
});
test('long manual reading streams the next segment after buffering and retains all text', async () => {
  const h=harness(),text=Array.from({length:22},(_,i)=>`Sentence ${i+1} remains readable.`).join(' ');
  await h.voice.read(text,'long');await settle();
  const first=h.calls.find(row=>row.method==='voice.speak');
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,0);
  assert(first.params.text.length<=120);
  for(let guard=0;guard<30;guard++) {
    const current=h.calls.filter(row=>row.method==='voice.speak')[guard];if(!current)break;
    assert(current.params.text.length<=240);
    h.emit('miyin:voice-event',{sessionId:current.params.sessionId,type:'tts_buffered'});await settle();
  }
  assert.equal(h.reading,'long');
  h.emit('miyin:voice-event',{sessionId:first.params.groupId,type:'tts_done'});await settle();
  const spoken=h.calls.filter(row=>row.method==='voice.speak').map(row=>row.params.text).join(' ');
  assert.equal(spoken.replace(/\s/g,''),text.replace(/\s/g,''));assert.equal(h.reading,null);
  assert(h.calls.filter(row=>row.method==='voice.prepareUtterance').length<h.calls.filter(row=>row.method==='voice.speak').length);
});
test('completed reply prepares bounded lookahead serially and deduplicates notifications', async () => {
  const releases=[];
  const h=harness(method=>method==='voice.prepareUtterance'?new Promise(resolve=>releases.push(resolve)):{});
  const text='连续朗读要保留后面的声音。'.repeat(60);
  h.voice.finish(true,text);h.voice.prepareMessage(text);await settle();
  assert.equal(releases.length,1);
  releases[0]();await settle();assert.equal(releases.length,2);
  releases[1]();await settle();assert.equal(releases.length,3);
  releases[2]();await settle();
  const prepares=h.calls.filter(row=>row.method==='voice.prepareUtterance');
  assert.equal(prepares.length,3);assert(prepares.every(row=>row.params.text.length<=64));
  assert(prepares.reduce((sum,row)=>sum+Array.from(row.params.text).length,0)<=360);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,0);
});

test('leaving the page during preparation does not queue later segments', async () => {
  let release;const h=harness(method=>method==='voice.prepareUtterance'?new Promise(resolve=>{release=resolve;}):{});
  h.voice.prepareMessage('这是后台准备的语音内容。'.repeat(20));await settle();
  h.leave();release();await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,1);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,0);
});

test('changing voice preferences stops the remaining speculative batch', async () => {
  let release;const h=harness(method=>method==='voice.prepareUtterance'?new Promise(resolve=>{release=resolve;}):{});
  h.voice.prepareMessage('这是后台准备的语音内容。'.repeat(20));await settle();
  h.preferences.set('miyin.full.preview.v5.tts-speed',JSON.stringify(1.25));release();await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,1);
});

test('a new model request prevents further speculative synthesis', async () => {
  let release;const h=harness(method=>method==='voice.prepareUtterance'?new Promise(resolve=>{release=resolve;}):{});
  h.voice.prepareMessage('这是后台准备的语音内容。'.repeat(20));await settle();
  h.window.MiyinChat.isGenerating=true;release();await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,1);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,0);
});

test('idle reply preparation waits for local model loading without blocking a real read', async () => {
  let loaded;const h=harness();
  h.window.MiyinChat.warmLocal=()=>new Promise(resolve=>{loaded=resolve;});
  h.voice.prepareMessage('你好，这是已有回复。');await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,0);
  await h.voice.read('你好，这是已有回复。','read-during-load');await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);
  loaded();await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,0);
});

test('local preparation completion cannot resume a reply batch after leaving chat', async () => {
  let loaded;const h=harness();
  h.window.MiyinChat.warmLocal=()=>new Promise(resolve=>{loaded=resolve;});
  h.voice.prepareMessage('你好，这是已有回复。');await settle();h.leave();
  loaded();await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.prepareUtterance').length,0);
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,0);
});

test('speculative lookahead stops before changing language workers', async () => {
  const h=harness();h.voice.prepareMessage('你好。Hello yesterday.');await settle();
  const prepares=h.calls.filter(row=>row.method==='voice.prepareUtterance');
  assert.equal(prepares.length,1);assert.equal(prepares[0].params.languageTag,'zh-Hans');
});
test('reading a completed reply does not cancel its in-flight first segment preparation', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.prepareUtterance'?pending:{}),text='First sentence. '+('More complete sentences. '.repeat(30));
  h.voice.finish(true,text);await settle();
  const prepared=h.calls.find(row=>row.method==='voice.prepareUtterance');
  await h.voice.read(text,'prepared');await settle();
  const spoken=h.calls.find(row=>row.method==='voice.speak');
  assert.equal(spoken.params.text,prepared.params.text);
  assert.equal(h.calls.filter(row=>row.method==='voice.stopSpeaking').length,0);
  release();await settle();
});
test('a pending streaming admission after interrupt never starts another playback', async () => {
  let release;const pending=new Promise(resolve=>{release=resolve;});
  const h=harness(method=>method==='voice.speak'?pending:{});
  await h.voice.read('A complete first sentence. '.repeat(20),'long');await settle();
  const current=h.calls.find(row=>row.method==='voice.speak').params.sessionId;
  await h.voice.interrupt();release();await settle();
  h.emit('miyin:voice-event',{sessionId:current,type:'tts_done'});await settle();
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').length,1);assert.equal(h.reading,null);
});
test('speech batching does not merge sentences routed to different TTS languages', async () => {
  const h=harness();await h.voice.read('你好。Hello.','mixed');await settle();
  const first=h.calls.find(row=>row.method==='voice.speak');assert.equal(first.params.languageTag,'zh-Hans');assert.equal(first.params.provider,'matcha');
  h.emit('miyin:voice-event',{sessionId:first.params.sessionId,type:'tts_done'});await settle();
  const second=h.calls.filter(row=>row.method==='voice.speak')[1];assert.equal(second.params.languageTag,'en');assert.equal(second.params.provider,'supertonic');
});

test('formatting-only lines do not trigger an English model between Chinese speech', async () => {
  const h=harness();await h.voice.read('你好。\n**\n继续交流。','formatting');await settle();
  for(let i=0;i<8;i++){
    const calls=h.calls.filter(row=>row.method==='voice.speak');
    const call=calls[i];if(!call)break;
    assert.equal(call.params.languageTag,'zh-Hans');
    assert(/[\p{L}\p{N}]/u.test(call.params.text));
    h.emit('miyin:voice-event',{sessionId:call.params.sessionId,type:'tts_done'});await settle();
  }
  assert.equal(h.calls.filter(row=>row.method==='voice.speak').map(row=>row.params.text).join('').replace(/\s/g,''),'你好。继续交流。');
});
