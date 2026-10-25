/* Native speech orchestration. Microphone -> local ASR -> shared conversation
   -> selected model -> local sentence TTS. No audio is sent to the provider. */
(() => {
  if (!window.MiyinApp) return;
  const rpc = (method, params = {}) => window.MiyinNativeBridge.request(method, params);
  const ui = () => window.MiyinVoiceUI;
  const chat = () => window.MiyinChatUI;
  const notify = text => chat().announce(text);
  const prefix = 'miyin.full.preview.v5.';
  const load = (key, fallback) => { try { return JSON.parse(localStorage.getItem(prefix + key)) ?? fallback; } catch (_) { return fallback; } };
  let opened = false, micId = null, micBusy = false, sequence = 0, epoch = 0;
  let turn = null, buffer = '', queue = [], ttsId = null, speaking = false, finished = false;
  let timer = 0, lastReadId = null;
  function state(value, mic = false) { if (opened) ui().state(value, mic); }
  function language(text) {
    const selected = load('ai-tts-language', 'auto');
    if (selected !== 'auto') return selected;
    if (/[\u3040-\u30ff]/u.test(text)) return 'ja';
    if (/[\uac00-\ud7af]/u.test(text)) return 'ko';
    if (/[\u0400-\u04ff]/u.test(text)) return 'ru';
    return /[\u3400-\u9fff]/u.test(text) ? 'zh-Hans' : 'en';
  }
  async function stopSpeech() {
    epoch++;
    buffer = ''; queue = []; finished = false; speaking = false;
    clearTimeout(timer); timer = 0;
    const old = ttsId;
    ttsId = null;
    lastReadId = null;
    chat().setReading(null);
    if (old) { try { await rpc('voice.stopSpeaking'); } catch (_) {} }
  }
  async function cancelMic() {
    const old = micId;
    micId = null;
    if (old) { try { await rpc('voice.cancelListening', {sessionId: old}); } catch (_) {} }
  }
  async function toggleMicrophone() {
    if (micBusy) return;
    micBusy = true;
    try {
      if (micId) {
        state('processing');
        await rpc('voice.stopListening', {sessionId: micId});
        return;
      }
      await interrupt();
      const id = 'chat-asr-' + Date.now() + '-' + (++sequence);
      micId = id;
      state('processing');
      await rpc('voice.startListening', {sessionId: id, mode: 'chat'});
      if (micId !== id || !opened) {
        await rpc('voice.cancelListening', {sessionId: id}); return;
      }
      state('listening', true);
    } catch (error) {
      micId = null; state('error'); notify(error.message || '本机语音识别未能开始。');
    } finally { micBusy = false; }
  }
  async function submit(text) {
    text = String(text || '').trim();
    if (!text) return;
    if (window.MiyinChat.isGenerating) { notify('请先中断当前回答。'); return; }
    await cancelMic();
    await stopSpeech();
    const result = chat().sendVoice(text);
    if (!result) { ui().draft(text); state('paused'); return; }
    ui().draft('');
    turn = result;
    state('processing');
  }
  function splitSentences(final = false) {
    for (;;) {
      let cut = -1;
      const match = buffer.match(/[。！？!?\n]|\.(?:\s|$)/u);
      if (match) cut = match.index + match[0].length;
      else if (buffer.length >= 240) {
        const space = buffer.lastIndexOf(' ', 220);
        cut = space > 60 ? space + 1 : 200;
      } else if (final) cut = buffer.length;
      if (cut <= 0) break;
      const sentence = buffer.slice(0, cut).trim();
      buffer = buffer.slice(cut);
      if (sentence) queue.push(sentence);
    }
    void drain();
  }
  async function drain() {
    if (speaking || ttsId) return;
    if (!queue.length) {
      if (finished) { lastReadId = null; chat().setReading(null); }
      if (finished && opened) state('paused');
      return;
    }
    const text = queue.shift(), generation = epoch;
    const id = 'chat-tts-' + Date.now() + '-' + (++sequence);
    ttsId = id; speaking = true;
    state('speaking');
    timer = setTimeout(() => {
      if (ttsId !== id) return;
      void stopSpeech(); state('error'); notify('朗读超时，文字已保留，可以重新点按朗读。');
    }, 60000);
    try {
      await rpc('voice.speak', {sessionId: id, text, languageTag: language(text),
        provider: load('tts-provider', 'melo'), speed: Number(load('tts-speed', 1)),
        speakerId: Number(load('tts-speaker', 0))});
      if (epoch !== generation || ttsId !== id) return;
    } catch (error) {
      if (epoch !== generation || ttsId !== id) return;
      await stopSpeech(); state('error'); notify(error.message || '朗读失败，文字已保留。');
    }
  }
  async function interrupt() {
    if (turn) window.MiyinChat.cancel(turn.conversationId, turn.messageId);
    turn = null;
    await stopSpeech();
    state('paused');
  }
  async function shutdown() {
    opened = false;
    await Promise.all([cancelMic(), interrupt()]);
    lastReadId = null;
  }
  async function read(text, id) {
    if (window.MiyinChat.isGenerating) { notify('请先停止当前回答，再朗读其他消息。'); return; }
    if (lastReadId === id && (ttsId || queue.length)) { await stopSpeech(); lastReadId = null; notify('已停止朗读'); return; }
    await cancelMic(); await stopSpeech();
    lastReadId = id; buffer = String(text); finished = true;
    chat().setReading(id);
    splitSentences(true);
  }
  window.addEventListener('miyin:voice-event', event => {
    const data = event.detail || {};
    if (data.sessionId === micId && micId) {
      if (data.type === 'recognition_partial') ui().draft(data.text || '');
      if (data.type === 'recognition_processing') state('processing');
      if (data.type === 'recognition_error' || data.type === 'recognition_cancelled') {
        micId = null; state(data.type === 'recognition_error' ? 'error' : 'paused');
        if (data.message) notify(data.message);
      }
      if (data.type === 'recognition_final') {
        micId = null;
        const text = chat().normalizeTranscript(String(data.text || '').trim(), data.languageTag);
        ui().draft(text);
        if (opened && text) void submit(text);
        else state('paused');
      }
    }
    if (ttsId && data.sessionId === ttsId) {
      if (['tts_done', 'tts_stopped', 'tts_error'].includes(data.type)) {
        clearTimeout(timer); timer = 0; ttsId = null; speaking = false;
        if (data.type === 'tts_error') {
          queue = []; buffer = ''; state('error'); notify(data.message || '朗读失败，文字已保留。');
        } else void drain();
      }
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      if (opened) { ui().close(); } else { void stopSpeech(); }
    }
  });
  function suspend() {
    if (opened) ui().close(); else void stopSpeech();
  }
  window.addEventListener('miyin:app-paused', suspend);
  window.addEventListener('miyin:surface-visibility-change', () => {
    if (!document.querySelector('#screen-chat')?.classList.contains('active')) suspend();
  });
  document.addEventListener('click', event => {
    const action = event.target.closest('[data-v5-voice-action]');
    if (action && ['camera', 'image', 'file', 'screen-share', 'tts-language', 'remove-file'].includes(action.dataset.v5VoiceAction)) {
      event.preventDefault(); event.stopImmediatePropagation();
      if (action.dataset.v5VoiceAction === 'remove-file') {
        chat().removePending(Number(action.dataset.fileIndex)); return;
      }
      if (action.dataset.v5VoiceAction === 'screen-share') {
        notify('当前模型通路不支持实时屏幕共享。可使用截屏翻译或附加图片文字。'); return;
      }
      if (action.dataset.v5VoiceAction === 'tts-language') { chat().speechLanguagePicker(); return; }
      void window.MiyinChat.pickAttachment(action.dataset.v5VoiceAction === 'file' ? 'document' :
        action.dataset.v5VoiceAction === 'camera' ? 'camera' : 'image');
    }
    const choice = event.target.closest('[data-modal-action="chat-tts-language"]');
    if (choice) {
      event.preventDefault(); event.stopImmediatePropagation();
      try { localStorage.setItem(prefix + 'ai-tts-language', JSON.stringify(choice.dataset.value)); } catch (_) {}
      chat().closeModal(); notify('已更新 AI 朗读语言');
    }
  }, true);
  window.addEventListener('miyin:chat-attachments-changed', () => { if (opened) ui().refreshFiles(); });
  window.MiyinChatVoice = Object.freeze({
    open() { opened = true; ui().open(); state('paused'); },
    get isOpen() { return opened; }, toggleMicrophone, submit, interrupt, shutdown, read,
    async beforeGeneration(entry) {
      await cancelMic(); await stopSpeech();
      if (opened) { turn = {conversationId: entry.conversationId, messageId: entry.messageId}; state('processing'); }
    },
    delta(text) { if (opened) { buffer += text; splitSentences(); ui().refresh(); } },
    finish(success) {
      if (!opened) return;
      if (success) { finished = true; splitSentences(true); }
      else { void stopSpeech(); state('paused'); }
      ui().refresh();
    },
  });
})();
