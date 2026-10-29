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
  let opened = false, micId = null, micBusy = false, sequence = 0, epoch = 0, lifecycle = 0;
  let turn = null, buffer = '', queue = [], ttsId = null, speaking = false, finished = false;
  let timer = 0, lastReadId = null, playbackStarted = false, hasSpoken = false, preparation = null;
  let voiceWarmAt = 0, voiceWarmKey = '';
  let speechGroup = null, groupEnding = false;
  function state(value, mic = false) { if (opened) ui().state(value, mic); }
  function language(text) {
    const selected = load('ai-tts-language', 'auto');
    if (selected !== 'auto') return selected;
    if (/[\u3040-\u30ff]/u.test(text)) return 'ja';
    if (/[\uac00-\ud7af]/u.test(text)) return 'ko';
    if (/[\u0400-\u04ff]/u.test(text)) return 'ru';
    return /[\u3400-\u9fff]/u.test(text) ? 'zh-Hans' : 'en';
  }
  function speechParams(text) {
    return {text, languageTag:language(text), provider:load('tts-provider', 'melo'),
      speed:Number(load('tts-speed', 1)), speakerId:Number(load('tts-speaker', 0))};
  }
  function warmVoice() {
    // A visible reply already prepares the exact first utterance. A generic
    // warm-up queued afterwards must not unload that reply's language worker.
    if (preparation?.generation === epoch) return;
    const selected = load('ai-tts-language', 'auto');
    const row=chat()?.get?.(chat()?.getActiveId?.());
    const reply=row?.messages?.at(-1);
    const params={languageTag:selected === 'auto' ? (reply?.text ? language(reply.text) : 'zh-Hans') : selected,
      provider:load('tts-provider','melo'),speakerId:Number(load('tts-speaker',0))};
    const key=JSON.stringify(params);
    if (Date.now() - voiceWarmAt < 30000 && voiceWarmKey === key) return;
    voiceWarmAt = Date.now();voiceWarmKey=key;
    void rpc('voice.prepare', params)
      .catch(() => {voiceWarmAt=0;});
  }
  // Combine adjacent sentences instead of paying synthesis startup after every
  // full stop. Keep a short first segment and bounded, word-aligned successors.
  function speechChunks(text, firstLimit = 120) {
    const chunks = [], sentences = String(text || '').match(/[\s\S]*?(?:[。！？!?\n]|\.(?:\s|$))|[\s\S]+$/gu) || [];
    // For a long answer, start with its first complete sentence rather than
    // delaying the first sound while synthesizing several sentences together.
    const chinese = language(text) === 'zh-Hans';
    const nextLimit = chinese ? 64 : 240;
    let current = '', limit = chinese ? (firstLimit === 120 ? 24 : 64) : Array.from(String(text || '')).length > 240 && firstLimit === 120
      ? Math.min(120, Math.max(1, Array.from(sentences[0] || '').length)) : firstLimit;
    const flush = () => {if (current.trim()) {chunks.push(current.trim()); limit=nextLimit;} current='';};
    for (const sentence of sentences) {
      // Formatting-only lines have no spoken content and must not switch the
      // synthesis model between two Chinese segments.
      if (!/[\p{L}\p{N}]/u.test(sentence)) continue;
      if (current && (Array.from(current + sentence).length > limit || language(current) !== language(sentence))) flush();
      let rest = Array.from(sentence);
      while (rest.length > limit) {
        flush();
        let cut = limit;
        for (let i=limit-1; i>limit/2; i--) {if (/[\s，、；：,;:]/u.test(rest[i] || '')) {cut=i+1;break;}}
        current=rest.splice(0,cut).join('');flush();
      }
      current += rest.join('');
    }
    flush();return chunks;
  }
  function prepare(text) {
    const params=speechParams(text), key=JSON.stringify(params), generation=epoch;
    if (preparation?.generation === generation && preparation.key === key) return;
    const job={generation,key,text};preparation=job;
    void rpc('voice.prepareUtterance',params).catch(() => {
      // Preparation is speculative; a normal speak request still reports errors.
      if (preparation === job) preparation=null;
    });
  }
  function prepareMessage(text) {
    if (ttsId || speaking || opened || window.MiyinChat.isGenerating) return;
    const first=speechChunks(text)[0];if (first) prepare(first);
  }
  async function stopSpeech() {
    epoch++;
    buffer = ''; queue = []; finished = false; speaking = false;
    playbackStarted = false; hasSpoken = false; preparation = null;
    clearTimeout(timer); timer = 0;
    const old = ttsId;
    const oldGroup = speechGroup;
    speechGroup = null;groupEnding = false;
    ttsId = null;
    lastReadId = null;
    chat().setReading(null);
    if (old || oldGroup) { try { await rpc('voice.stopSpeaking'); } catch (_) {} }
  }
  async function cancelMic() {
    const old = micId;
    micId = null;
    if (old) { try { await rpc('voice.cancelListening', {sessionId: old}); } catch (_) {} }
  }
  async function toggleMicrophone() {
    if (micBusy || !opened) return;
    micBusy = true;
    let session = lifecycle;
    try {
      if (micId) {
        state('processing');
        await rpc('voice.stopListening', {sessionId: micId});
        return;
      }
      session = await interrupt();
      if (!opened || session !== lifecycle) return;
      const id = 'chat-asr-' + Date.now() + '-' + (++sequence);
      micId = id;
      state('processing');
      await rpc('voice.startListening', {sessionId: id, mode: 'chat'});
      if (micId !== id || !opened || session !== lifecycle) {
        await rpc('voice.cancelListening', {sessionId: id}); return;
      }
      state('listening', true);
    } catch (error) {
      if (opened && session === lifecycle) {
        micId = null; state('error'); notify(error.message || '本机语音识别未能开始。');
      }
    } finally { micBusy = false; }
  }
  async function submit(text) {
    text = String(text || '').trim();
    if (!text || !opened) return;
    if (window.MiyinChat.isGenerating) { notify('请先中断当前回答。'); return; }
    const session = ++lifecycle;
    await cancelMic();
    if (!opened || session !== lifecycle) return;
    await stopSpeech();
    if (!opened || session !== lifecycle) return;
    const result = chat().sendVoice(text);
    if (!result) { ui().draft(text); state('paused'); return; }
    ui().draft('');
    turn = result;
    state('processing');
  }
  function splitSentences(final = false) {
    let cut=final ? buffer.length : 0;
    if (!final) {
      const boundaries=buffer.matchAll(/[。！？!?\n]|\.(?:\s|$)/gu);
      for (const match of boundaries) cut=match.index+match[0].length;
      // Start a bounded phrase while text is still arriving instead of waiting
      // for a final full stop. Keep English words together.
      const chinese = language(buffer) === 'zh-Hans';
      const phraseLimit = chinese ? (hasSpoken ? 32 : 12) : (hasSpoken ? 120 : 48);
      if (!cut && Array.from(buffer).length >= phraseLimit) {
        if (chinese) cut=Array.from(buffer).slice(0,phraseLimit).join('').length;
        else {
          const space=buffer.lastIndexOf(' ',phraseLimit);
          if (space>phraseLimit/2) cut=space+1;
          else if (buffer.length>=240) cut=200;
        }
      }
    }
    if (cut) {
      const text=buffer.slice(0,cut);buffer=buffer.slice(cut);
      for (const chunk of speechChunks(text,hasSpoken?240:120)) {
        const last=queue.length-1, previous=queue[last];
        const locked=last===0 && preparation?.generation===epoch && preparation.text===previous;
        const limit=language(chunk)==='zh-Hans'?64:240;
        if (previous && !locked && language(previous)===language(chunk) && Array.from(previous+chunk).length+1<=limit) queue[last]=previous+' '+chunk;
        else queue.push(chunk);
      }
    }
    void drain();
  }
  async function drain() {
    if (speaking || ttsId) return;
    if (!queue.length) {
      if (finished && speechGroup && !groupEnding) {
        groupEnding=true;
        const group=speechGroup;
        try {await rpc('voice.finishSpeech',{groupId:group});}
        catch (error) {if(speechGroup===group) {void stopSpeech();state('error');notify(error.message||'朗读结束失败。');}}
      } else if (finished && !speechGroup) {
        lastReadId = null; chat().setReading(null);
        if (opened) state('paused');
      }
      return;
    }
    const text = queue.shift(), generation = epoch;
    preparation = null;playbackStarted = false;hasSpoken = true;
    const id = 'chat-tts-' + Date.now() + '-' + (++sequence);
    if (!speechGroup) {speechGroup='chat-audio-'+Date.now()+'-'+(++sequence);groupEnding=false;}
    ttsId = id; speaking = true;
    state('speaking');
    timer = setTimeout(() => {
      if (ttsId !== id) return;
      void stopSpeech(); state('error'); notify('朗读超时，文字已保留，可以重新点按朗读。');
    }, 60000);
    try {
      const result = await rpc('voice.speak', {sessionId:id,groupId:speechGroup,...speechParams(text),streamAudio:true});
      if (epoch !== generation || ttsId !== id) return;
      if (result?.status === 'cancelled') {await stopSpeech();state('paused');return;}
      playbackStarted = true;
    } catch (error) {
      if (epoch !== generation || ttsId !== id) return;
      const session = lifecycle, stopping = stopSpeech(), stoppedEpoch = epoch;
      await stopping;
      if (session !== lifecycle || stoppedEpoch !== epoch) return;
      state('error'); notify(error.message || '朗读失败，文字已保留。');
    }
  }
  async function interrupt() {
    const session = ++lifecycle, previous = turn;
    turn = null;
    if (previous) window.MiyinChat.cancel(previous.conversationId, previous.messageId);
    await stopSpeech();
    if (session === lifecycle) state('paused');
    return session;
  }
  async function shutdown() {
    opened = false;
    lifecycle++;
    await Promise.all([cancelMic(), interrupt()]);
  }
  async function read(text, id) {
    if (window.MiyinChat.isGenerating) { notify('请先停止当前回答，再朗读其他消息。'); return; }
    if (lastReadId === id && (ttsId || queue.length || speechGroup)) { await stopSpeech(); notify('已停止朗读'); return; }
    const session = ++lifecycle;
    await cancelMic();
    if (session !== lifecycle) return;
    await stopSpeech();
    if (session !== lifecycle) return;
    lastReadId = id; queue = speechChunks(text); finished = true;
    chat().setReading(id);
    void drain();
  }
  window.addEventListener('miyin:voice-event', event => {
    const data = event.detail || {};
    if (speechGroup && data.sessionId === speechGroup) {
      if (data.type === 'tts_done') {
        clearTimeout(timer);timer=0;ttsId=null;speaking=false;playbackStarted=false;
        speechGroup=null;groupEnding=false;lastReadId=null;chat().setReading(null);
        if(opened) state('paused');
      } else if (data.type === 'tts_error' || data.type === 'tts_stopped') {
        void stopSpeech();state(data.type==='tts_error'?'error':'paused');
        if(data.type==='tts_error') notify(data.message||'朗读失败，文字已保留。');
      }
      return;
    }
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
      if (['tts_buffered', 'tts_done', 'tts_stopped', 'tts_error'].includes(data.type)) {
        clearTimeout(timer); timer = 0; ttsId = null; speaking = false; playbackStarted = false;
        if (data.type === 'tts_error') {
          void stopSpeech(); state('error'); notify(data.message || '朗读失败，文字已保留。');
        } else {
          // Legacy non-group completion remains supported by older hosts.
          if(data.type==='tts_done' && finished && !queue.length) {speechGroup=null;groupEnding=false;}
          void drain();
        }
      }
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) suspend();
  });
  function suspend() {
    if (opened) ui().close(); else { lifecycle++; void stopSpeech(); }
  }
  window.addEventListener('miyin:app-paused', suspend);
  window.addEventListener('miyin:surface-visibility-change', () => {
    if (!document.querySelector('#screen-chat')?.classList.contains('active')) suspend();
    else if (!document.hidden && !ttsId && !window.MiyinChat.isGenerating) warmVoice();
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
    open() { if (!opened) lifecycle++; opened = true; ui().open(); state('paused'); warmVoice(); },
    get isOpen() { return opened; }, toggleMicrophone, submit, interrupt, shutdown, read, prepareMessage,
    async beforeGeneration(entry) {
      const session = lifecycle;
      // Register ownership before any awaited cleanup, so closing can cancel
      // a generation that is still waiting for microphone/TTS cleanup.
      if (opened) turn = {conversationId: entry.conversationId, messageId: entry.messageId};
      await cancelMic();
      if (session !== lifecycle) return;
      await stopSpeech();
      if (opened && session === lifecycle) state('processing');
    },
    delta(text) { if (opened) { buffer += text; splitSentences(); ui().refresh(); } },
    finish(success, text) {
      if (!opened) {if (success && text) prepareMessage(text);return;}
      if (success) { finished = true; splitSentences(true); }
      else { void stopSpeech(); state('paused'); }
      ui().refresh();
    },
  });
})();
