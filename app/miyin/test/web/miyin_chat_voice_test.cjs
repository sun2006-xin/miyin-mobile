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
  return {voice: window.MiyinChatVoice, window, calls, states, timers,
    get draft(){return draft;}, get reading(){return reading;},
    emit(name,detail){for(const fn of listeners.get(name)||[])fn({detail});},
    leave(){activeScreen=false;this.emit('miyin:surface-visibility-change');}};
}
test('opening voice does not start a microphone or contact a model', () => {
  const h=harness(); h.voice.open(); assert.equal(h.calls.length,0); assert.equal(h.voice.isOpen,true);
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
test('interrupt cancels generation and discards queued speech, ignoring stale completion', async () => {
  const h=harness();h.voice.open();await h.voice.beforeGeneration({conversationId:'c',messageId:'m'});
  h.voice.delta('第一句。第二句。');await settle();const id=h.calls.find(row=>row.method==='voice.speak').params.sessionId;
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
