const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../assets/miyin_v5/miyin-chat-voice.js'), 'utf8');
const settle = async () => { for (let i=0; i<8; i++) await Promise.resolve(); };
function harness() {
  const listeners = new Map(), calls = [], states = [], timers = new Map();
  let draft = '', activeScreen = true, timerId = 0, reading = null;
  const data = new Map();
  const on = (name, fn) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); };
  const document = {hidden: false, addEventListener: (name, fn) => on('doc:' + name, fn),
    querySelector: () => ({classList: {contains: () => activeScreen}})};
  const window = {MiyinApp: {}, addEventListener: on,
    MiyinNativeBridge: {request: async (method, params) => { calls.push({method, params}); return {status:'ok'}; }},
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
