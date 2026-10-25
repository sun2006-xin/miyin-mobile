/* Real mobile chat transport. The page never receives an API credential. */
(() => {
  const native = !!window.MiyinApp;
  const rpc = (method, params = {}) => window.MiyinNativeBridge.request(method, params);
  const ui = () => window.MiyinChatUI;
  let ready = false, status = {configured: false}, serial = 0, active = null;
  let saveTimer = 0, saveQueue = Promise.resolve(), pendingSnapshot = null;
  let importing = false, imported = null;
  let nativeContextRows = [], nativeContextOffset = 0;
  const notify = text => ui()?.announce(text);

  function setStatus(next) {
    status = next;
    ui()?.setModel(next.model || 'DeepSeek · 待配置');
    if (next.privacy) ui()?.setHistorySaving(next.privacy.saveLocalHistory !== false);
  }
  async function configure(page = 'provider') {
    if (active) { notify('请先停止当前回答，再更改模型配置。'); return; }
    try {
      const result = await rpc('chat.configure', {page});
      setStatus(result);
      if (page === 'models' && result.settingsSaved && ui().getActiveId()) {
        ui().pinModel(ui().getActiveId(), result.model);
      }
    }
    catch (error) { notify(error.message || '打开模型设置失败。'); }
  }
  function persist(rows, immediate = false) {
    if (!native || !ready) return;
    // Snapshot now, not after a later conversation edit. Serialize native writes.
    pendingSnapshot = JSON.parse(JSON.stringify(rows));
    if (active && !rows.some(row => row.id === active.conversationId)) cancel(active.conversationId, active.messageId);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flush, immediate ? 0 : 500);
  }
  function flush() {
    if (!pendingSnapshot) return;
    const rows = pendingSnapshot;
    pendingSnapshot = null;
    saveQueue = saveQueue.catch(() => {}).then(() => rpc('chat.history.save', {conversations: rows}))
      .catch(error => { if (!pendingSnapshot) pendingSnapshot = rows;
        notify(error.message || '聊天记录未能保存，请保留页面后重试。'); });
  }
  async function initialize() {
    if (!native || ready) return;
    try {
      const result = await rpc('chat.history.load', {legacy: ui().getHistory()});
      const rows = result.conversations.map(row => ({...row, messages: row.messages.map(message =>
        message.status === 'pending' ? {...message, status: 'failed', generation: {...message.generation, status: 'failed'}, text:
          (message.text && !/^正在/.test(message.text) ? message.text + '\n\n' : '') +
          '上次回答已中断，可以重新回答。'} : message)}));
      ui().replaceHistory(rows);
      localStorage.removeItem('miyin.full.preview.v5.conversations');
      ready = true;
      persist(rows, true);
      try { setStatus(await rpc('chat.status', {saveHistory: ui().getHistorySaving()})); }
      catch (_) { setStatus({configured: false}); notify('模型配置需要重新填写，请打开模型设置。'); }
    } catch (error) { notify(error.message || '聊天历史尚未就绪，请重新打开软件。'); }
  }
  function canSend(hasFiles, hasContexts, prompt) {
    if (!native) return true;
    if (!ready) { notify('正在读取聊天记录，请稍候。'); return false; }
    if (!status.configured) { void configure(); return false; }
    if (!status.privacy?.allowNetwork) {
      notify('请先在 AI 隐私设置中允许发送至远程模型。');
      void configure('privacy'); return false;
    }
    if (active) { notify('请先等待或停止当前回答。'); return false; }
    if (importing) { notify('正在读取资料，请稍候。'); return false; }
    try {
      const pending = ui().getPending();
      window.MiyinChatContext.assemble({text: prompt ?? document.querySelector('#chat-input')?.value,
        attachments: pending.files, contextAttachments: pending.contexts});
    } catch (error) { notify(error.message); return false; }
    return true;
  }
  function flushText(entry) {
    clearTimeout(entry.timer);
    entry.timer = 0;
    const message = ui().find(entry.conversationId, entry.messageId);
    if (active !== entry || message?.status !== 'pending') return;
    ui().update(entry.conversationId, entry.messageId, {text: entry.text || '正在生成回答…'});
  }
  function finish(entry, type, notice) {
    flushText(entry);
    if (active !== entry) return;
    const current = ui().find(entry.conversationId, entry.messageId);
    active = null;
    if (current?.status !== 'pending') return;
    const text = entry.text + (notice ? (entry.text ? '\n\n' : '') + notice : '');
    ui().update(entry.conversationId, entry.messageId, {
      status: type, text: text || '模型未返回文字，请重试。',
      generation: {...current.generation, status: type},
    });
    window.MiyinChatVoice?.finish(type === 'complete');
    persist(ui().getHistory(), true);
  }
  async function start(conversationId, messageId) {
    const conversation = ui().get(conversationId);
    const index = conversation.messages.findIndex(message => message.id === messageId);
    const requestId = 'deepseek-' + Date.now() + '-' + (++serial);
    const entry = {conversationId, messageId, requestId, text: '', timer: 0};
    if (active) { notify('请先停止当前回答。'); return; }
    active = entry;
    await window.MiyinChatVoice?.beforeGeneration(entry);
    if (active !== entry) return;
    let messages;
    try {
      let selected = conversation.messages.slice(0, index).filter(message => message.status === 'complete');
      if (status.privacy?.sendHistory === false) selected = selected.slice(-1);
      messages = selected.map(message => ({role: message.role, content: message.role === 'user'
        ? window.MiyinChatContext.assemble(message) : message.text}));
    } catch (error) { finish(entry, 'failed', error.message); return; }
    if (status.privacy?.sendHistory === false) messages = messages.slice(-1);
    // Old preview replies must not masquerade as context from a real model.
    if (messages.some(message => /这是本地模拟回复|没有调用模型 API/.test(message.content))) {
      finish(entry, 'failed', '这段会话含有早期演示回答，请新建对话后使用真实模型。');
      return;
    }
    try {
      const result = await rpc('chat.start', {requestId, messages});
      if (active !== entry) { await rpc('chat.cancel', {requestId}); return; }
      ui().pinModel(conversationId, result.model);
    } catch (error) {
      finish(entry, 'failed', error.message || '发送失败，请重试。');
    }
  }
  function cancel(conversationId, messageId) {
    if (active?.conversationId !== conversationId || active?.messageId !== messageId) return;
    const entry = active;
    finish(entry, 'stopped', entry.text ? '已停止生成。' : '已停止生成，可以重新回答。');
    void rpc('chat.cancel', {requestId: entry.requestId}).catch(() => {});
  }
  window.addEventListener('miyin:chat-event', event => {
    const data = event.detail, entry = active;
    if (!entry || data?.requestId !== entry.requestId) return;
    if (data.type === 'delta') {
      entry.text += String(data.text || '');
      window.MiyinChatVoice?.delta(String(data.text || ''));
      if (!entry.timer) entry.timer = setTimeout(() => flushText(entry), 80);
    } else if (data.type === 'completed') finish(entry, 'complete');
    else if (data.type === 'failed') finish(entry, 'failed', data.text || '回答中断，请重试。');
  });
  document.addEventListener('click', event => {
    if (!native) return;
    const category = event.target.closest('[data-modal-action="select-context-category"]');
    if (category?.dataset.value === 'translation') {
      event.preventDefault(); event.stopImmediatePropagation(); void nativeHistory(0); return;
    }
    const nativeItem = event.target.closest('[data-modal-action="chat-native-context"]');
    if (nativeItem) {
      event.preventDefault(); event.stopImmediatePropagation();
      const row = nativeContextRows.find(item => String(item.id) === nativeItem.dataset.value);
      if (row) ui().addNativeContext(row);
      ui().closeModal(); return;
    }
    const nativePage = event.target.closest('[data-modal-action="chat-native-context-page"]');
    if (nativePage) {
      event.preventDefault(); event.stopImmediatePropagation(); void nativeHistory(Number(nativePage.dataset.value)); return;
    }
    const source = event.target.closest('[data-chat-source]');
    if (source) { event.preventDefault(); event.stopImmediatePropagation();
      ui().showSource(source.dataset.chatSource, Number(source.dataset.sourceIndex) || 0); return; }
    const confirm = event.target.closest('[data-modal-action="chat-confirm-import"]');
    if (confirm) {
      event.preventDefault(); event.stopImmediatePropagation();
      if (imported) { ui().addAttachment(imported); imported = null; }
      ui().closeModal(); return;
    }
    const shareButton = event.target.closest('[data-chat-action="share"]');
    if (shareButton) {
      event.preventDefault(); event.stopImmediatePropagation();
      const message = ui().find(ui().getActiveId(), shareButton.dataset.messageId);
      if (message) void share(message.text); return;
    }
    const read = event.target.closest('[data-chat-action="read"]');
    if (read) {
      event.preventDefault(); event.stopImmediatePropagation();
      const message = ui().find(ui().getActiveId(), read.dataset.messageId);
      if (message) void window.MiyinChatVoice?.read(message.text, message.id);
      return;
    }
    const button = event.target.closest('[data-action]');
    if (!button || !['model-picker', 'provider-picker', 'chat-privacy', 'chat-voice'].includes(button.dataset.action)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (button.dataset.action === 'chat-voice') {
      window.MiyinChatVoice?.open(); return;
    }
    void configure(button.dataset.action === 'model-picker' ? 'models' :
      button.dataset.action === 'chat-privacy' ? 'privacy' : 'provider');
  }, true);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { clearTimeout(saveTimer); flush(); }
  });
  async function share(text) {
    try { await rpc('chat.share', {text}); }
    catch (error) { notify(error.message || '分享未完成。'); }
  }
  async function nativeHistory(offset) {
    try {
      nativeContextRows = await rpc('history.list', {limit: 20, offset: Math.max(0, offset)});
      nativeContextOffset = Math.max(0, offset);
      ui().showNativeContextPicker(nativeContextRows, nativeContextOffset);
    } catch (error) { notify(error.message || '无法读取翻译历史。'); }
  }
  async function pickAttachment(kind) {
    if (importing) return;
    if (ui().getPending().files.length >= 4) { notify('一次最多附加 4 个文件。'); return; }
    importing = true;
    imported = null;
    ui().closeModal();
    notify(kind === 'document' ? '请选择 TXT 或 Markdown 文件' : '在本机提取图片文字，不上传图片');
    try {
      const result = await rpc(kind === 'document' ? 'attachment.pickArticle' : 'attachment.recognizeImage', {kind});
      if (!result || result.canceled) return;
      const text = String(result.text || result.recognizedText || '').trim();
      if (!text || text.length > 10000) throw new Error('资料为空或超过 10,000 字符，请分段导入。');
      if (result.truncated || result.omittedBlockCount > 0) throw new Error('图片文字超出完整提取范围，请裁小图片后重试，避免遗漏资料。');
      imported = {id: 'file-' + Date.now() + '-' + (++serial), name: String(result.name || '资料'),
        type: 'text/plain', extraction: kind === 'document' ? '本机读取的文件正文' : '图片文字 · 本机 OCR', text};
      ui().previewAttachment(imported);
    } catch (error) { notify(error.message || '读取资料失败。'); }
    finally { importing = false; }
  }
  window.addEventListener('miyin:native-host-ready', () => { void initialize(); });
  window.MiyinChat = Object.freeze({native, start, cancel, canSend, persist, pickAttachment, share,
    saveHistoryPreference(value) {
      if (native && ready) void rpc('chat.privacy', {saveLocalHistory: !!value})
        .then(next => { status = next; }).catch(error => notify(error.message));
    },
    get ready() { return ready; },
    get isGenerating() { return !!active; },
    get model() { return status.model; }});
})();
