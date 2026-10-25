/* Real mobile chat transport. The page never receives an API credential. */
(() => {
  const native = !!window.MiyinApp;
  const rpc = (method, params = {}) => window.MiyinNativeBridge.request(method, params);
  const ui = () => window.MiyinChatUI;
  let ready = false, status = {configured: false}, serial = 0, active = null;
  let saveTimer = 0, saveQueue = Promise.resolve(), pendingSnapshot = null;
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
      .catch(error => { notify(error.message || '聊天记录未能保存，请保留页面后重试。'); });
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
  function canSend(hasFiles, hasContexts) {
    if (!native) return true;
    if (!ready) { notify('正在读取聊天记录，请稍候。'); return false; }
    if (!status.configured) { void configure(); return false; }
    if (!status.privacy?.allowNetwork) {
      notify('请先在 AI 隐私设置中允许发送至远程模型。');
      void configure('privacy'); return false;
    }
    if (active) { notify('请先等待或停止当前回答。'); return false; }
    if (hasFiles || hasContexts) {
      notify('首轮先支持文字对话，请移除附件；资料和会议上下文将在下一阶段接入。');
      return false;
    }
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
    persist(ui().getHistory(), true);
  }
  async function start(conversationId, messageId) {
    const conversation = ui().get(conversationId);
    const index = conversation.messages.findIndex(message => message.id === messageId);
    const requestId = 'deepseek-' + Date.now() + '-' + (++serial);
    const entry = {conversationId, messageId, requestId, text: '', timer: 0};
    if (active) { notify('请先停止当前回答。'); return; }
    active = entry;
    let messages = conversation.messages.slice(0, index)
      .filter(message => message.status === 'complete')
      .map(message => ({role: message.role, content: message.text}));
    if (status.privacy?.sendHistory === false) messages = messages.slice(-1);
    // Old preview replies must not masquerade as context from a real model.
    if (messages.some(message => /这是本地模拟回复|没有调用模型 API/.test(message.content))) {
      finish(entry, 'failed', '这段会话含有早期演示回答，请新建对话后使用真实模型。');
      return;
    }
    if (status.privacy?.sendHistory !== false && conversation.messages.slice(0, index).some(message =>
      message.attachments?.length || message.contextAttachments?.length)) {
      finish(entry, 'failed', '这段会话包含尚未接入的附件，请新建文字对话。'); return;
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
      if (!entry.timer) entry.timer = setTimeout(() => flushText(entry), 80);
    } else if (data.type === 'completed') finish(entry, 'complete');
    else if (data.type === 'failed') finish(entry, 'failed', data.text || '回答中断，请重试。');
  });
  document.addEventListener('click', event => {
    if (!native) return;
    const read = event.target.closest('[data-chat-action="read"]');
    if (read) {
      event.preventDefault(); event.stopImmediatePropagation();
      notify('AI 回答朗读将在语音对话阶段接入。'); return;
    }
    const button = event.target.closest('[data-action]');
    if (!button || !['model-picker', 'provider-picker', 'chat-privacy', 'chat-voice'].includes(button.dataset.action)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    if (button.dataset.action === 'chat-voice') {
      notify('真实语音对话将在文字聊天验收后接入。'); return;
    }
    void configure(button.dataset.action === 'model-picker' ? 'models' :
      button.dataset.action === 'chat-privacy' ? 'privacy' : 'provider');
  }, true);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { clearTimeout(saveTimer); flush(); }
  });
  window.addEventListener('miyin:native-host-ready', () => { void initialize(); });
  window.MiyinChat = Object.freeze({native, start, cancel, canSend, persist,
    saveHistoryPreference(value) {
      if (native && ready) void rpc('chat.privacy', {saveLocalHistory: !!value})
        .then(next => { status = next; }).catch(error => notify(error.message));
    },
    get ready() { return ready; },
    get model() { return status.model; }});
})();
