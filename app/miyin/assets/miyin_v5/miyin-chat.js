/* Real mobile chat transport. The page never receives an API credential. */
(() => {
  const native = !!window.MiyinApp;
  const rpc = (method, params = {}) => window.MiyinNativeBridge.request(method, params);
  const ui = () => window.MiyinChatUI;
  let ready = false, status = {configured: false}, serial = 0, active = null;
  let saveTimer = 0, saveQueue = Promise.resolve(), pendingSnapshot = null;
  let importing = false, imported = null;
  let imageJob = null;
  let webRequest = null;
  let warming = null, warmedAt = 0;
  let nativeContextRows = [], nativeContextOffset = 0;
  const notify = text => ui()?.announce(text);

  function setStatus(next) {
    status = next;
    ui()?.setModel(next.model || '配置模型');
    if (next.privacy) ui()?.setHistorySaving(next.privacy.saveLocalHistory !== false);
    void warmLocal();
    prepareVisibleReply();
  }
  function prepareVisibleReply() {
    if (!native || !ready || active || document.hidden ||
        !document.querySelector('#screen-chat')?.classList?.contains('active')) return;
    const row = ui()?.get?.(ui()?.getActiveId?.());
    const reply = row?.messages?.at(-1);
    if (reply?.role === 'assistant' && reply.status === 'complete' && reply.text) {
      window.MiyinChatVoice?.prepareMessage(reply.text);
    }
  }
  function warmLocal() {
    if (!native || !ready || status.providerId !== 'phone' || active ||
        !document.querySelector('#screen-chat')?.classList?.contains('active')) return Promise.resolve();
    if (warming) return warming;
    if (Date.now() - warmedAt < 30000) return Promise.resolve();
    let button = null, label = '';
    warming = (async () => {
      const local = await rpc('chat.local.status');
      if (local.ready) { warmedAt = Date.now(); return; }
      if (active || status.providerId !== 'phone') return;
      button = document.querySelector('#screen-chat .model-select');
      if (button?.dataset) {
        label = button.textContent; button.textContent = '本机准备中⌄';
        button.setAttribute('aria-busy', 'true');
      }
      await rpc('chat.local.prepare');
      warmedAt = Date.now();
    })().catch(() => {
      // A speculative warm-up never blocks sending; the real request reports errors.
      warmedAt = 0;
    }).finally(() => {
      if (button?.dataset) {
        if (button.textContent === '本机准备中⌄') button.textContent = label;
        button.removeAttribute('aria-busy');
      }
      warming = null;
    });
    return warming;
  }
  window.addEventListener('miyin:surface-visibility-change', () => { void warmLocal(); prepareVisibleReply(); });
  window.addEventListener('miyin:app-paused', () => { warmedAt = 0; });
  window.addEventListener('miyin:app-resumed', () => { void warmLocal(); prepareVisibleReply(); });
  async function configure(page = 'provider') {
    if (active) { notify('请先停止当前回答，再更改模型配置。'); return; }
    if(window.MiyinChatSettings){await window.MiyinChatSettings.open(page);return;}
    try {
      const result = await rpc('chat.configure', {page});
      setStatus(result);
      if (page !== 'privacy' && result.settingsSaved && ui().getActiveId()) {
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
    if (status.providerId !== 'phone' && !status.privacy?.allowNetwork) {
      notify('请先在 AI 隐私设置中允许发送至所选模型服务。');
      void configure('privacy'); return false;
    }
    if (active) { notify('请先等待或停止当前回答。'); return false; }
    if (importing) { notify('正在读取资料，请稍候。'); return false; }
    try {
      const pending = ui().getPending();
      if(status.providerId==='phone' && status.phoneVision!==true && pending.files.some(file=>file.imageId)) {
        notify('当前手机模型包尚未包含看图组件。请切换支持图片的模型，或在图片预览中选择“仅提取文字”。');return false;
      }
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
  function finish(entry, type, notice, code) {
    flushText(entry);
    if (active !== entry) return;
    const current = ui().find(entry.conversationId, entry.messageId);
    active = null;
    if (current?.status !== 'pending') return;
    const limited = code === 'output_limit' && !!entry.text;
    if (limited) type = 'complete';
    const text = entry.text + (!limited && notice ? (entry.text ? '\n\n' : '') + notice : '');
    ui().update(entry.conversationId, entry.messageId, {
      status: type, text: text || '模型未返回文字，请重试。',
      generation: {...current.generation, status: type, finishReason: limited ? 'length' : null},
      ...(limited ? {contextNotice:(current.contextNotice ? current.contextNotice+'\n' : '')+'回答达到本次长度上限，已保留内容。可点击“继续回答”接着写。'} : {}),
    });
    window.MiyinChatVoice?.finish(type === 'complete', entry.text);
    persist(ui().getHistory(), true);
  }
  function continueAnswer(messageId) {
    const conversation = ui().get(ui().getActiveId()), message = conversation?.messages.at(-1);
    if (!message || message.id !== messageId || message.generation?.finishReason !== 'length') {
      notify('请在当前会话最新一条未完成的回答上继续。'); return;
    }
    if (status.privacy?.sendHistory === false) { notify('继续回答需要携带当前上下文，请先在隐私设置中开启。'); return; }
    const pending = ui().getPending();
    if (pending.files.length || pending.contexts.length) { notify('请先发送或移除待附加资料，再继续这条回答。'); return; }
    if (!canSend(false, false, '继续回答')) return;
    const tail = Array.from(message.text).slice(-600).join('');
    ui().sendVoice('请继续上一条未完成的回答，从断点接着写。以下是该回答的末尾片段（不是完整回答）：\n\n'+tail);
  }
  async function start(conversationId, messageId) {
    const conversation = ui().get(conversationId);
    const index = conversation.messages.findIndex(message => message.id === messageId);
    const requestId = 'deepseek-' + Date.now() + '-' + (++serial);
    const entry = {conversationId, messageId, requestId, text: '', timer: 0};
    if (active) { notify('请先停止当前回答。'); return; }
    active = entry;
    const initial = ui().find(conversationId, messageId);
    ui().update(conversationId, messageId, {contextNotice:'', webSources:[], generation:{...initial.generation,finishReason:null}});
    await window.MiyinChatVoice?.beforeGeneration(entry);
    if (active !== entry) return;
    let messages;
    try {
      let selected = conversation.messages.slice(0, index).filter(message => message.status === 'complete');
      if (status.privacy?.sendHistory === false) selected = selected.slice(-1);
      messages = selected.map(message => {
        const imageIds=message.role==='user'&&message.attachments?.some(file=>file.imageId)?window.MiyinChatContext.imageIds(message):[];
        return {role:message.role,content:message.role==='user'?window.MiyinChatContext.assemble(message):message.text,...(imageIds.length?{imageIds}:{})};
      });
    } catch (error) { finish(entry, 'failed', error.message); return; }
    if (status.privacy?.sendHistory === false) messages = messages.slice(-1);
    // Old preview replies must not masquerade as context from a real model.
    if (messages.some(message => /这是本地模拟回复|没有调用模型 API/.test(message.content))) {
      finish(entry, 'failed', '这段会话含有早期演示回答，请新建对话后使用真实模型。');
      return;
    }
    try {
      const searchQuery=conversation.messages.slice(0,index).filter(message=>message.role==='user').at(-1)?.text||'';
      const result = await rpc('chat.start', {requestId, messages, conversationId,searchQuery});
      if (active !== entry) { await rpc('chat.cancel', {requestId}); return; }
      ui().pinModel(conversationId, result.model);
      if (result.contextOmitted > 0) {
        const note = '本轮使用最近的对话，较早的 ' + result.contextOmitted + ' 条消息未发送；完整记录仍保留。';
        ui().update(conversationId, messageId, {contextNotice:note});
        notify(note);
      }
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
    } else if (data.type === 'progress') {
      ui().update(entry.conversationId, entry.messageId, {text:String(data.text || '正在整理会话记忆…')});
    } else if (data.type === 'sources') {
      try {const sources=JSON.parse(data.text);if(Array.isArray(sources))ui().update(entry.conversationId,entry.messageId,{webSources:sources});} catch(_) {}
    } else if (data.type === 'memory') {
      ui().update(entry.conversationId, entry.messageId, {contextNotice:String(data.text || ''), memoryAvailable:true});
    } else if (data.type === 'context') {
      ui().update(entry.conversationId, entry.messageId, {contextNotice:String(data.text || ''), memoryAvailable:false});
    } else if (data.type === 'completed') finish(entry, 'complete');
    else if (data.type === 'failed') finish(entry, 'failed', data.text || '回答中断，请重试。', data.code);
  });
  document.addEventListener('click', event => {
    if (!native) return;
    const picture=event.target.closest('[data-chat-image]');
    if(picture){event.preventDefault();event.stopImmediatePropagation();void viewImage(picture.dataset.chatImage);return;}
    const ocr=event.target.closest('[data-modal-action="chat-image-ocr"]');
    if(ocr){event.preventDefault();event.stopImmediatePropagation();void extractImageText();return;}
    const webSource=event.target.closest('[data-chat-web-url]');
    if(webSource){event.preventDefault();event.stopImmediatePropagation();void rpc('chat.openUrl',{url:webSource.dataset.chatWebUrl}).catch(error=>notify(error.message));return;}
    const webOpen = event.target.closest('[data-modal-action="chat-web-open"]');
    if (webOpen) {
      event.preventDefault(); event.stopImmediatePropagation();
      if (active || importing) { notify('请先停止当前操作。'); return; }
      ui().showWebImport(); return;
    }
    const webRead = event.target.closest('[data-modal-action="chat-web-read"]');
    if (webRead) {
      event.preventDefault(); event.stopImmediatePropagation();
      void readWebPage(); return;
    }
    const webCancel = event.target.closest('[data-modal-action="chat-web-cancel"]');
    if (webCancel) {
      event.preventDefault(); event.stopImmediatePropagation();
      cancelWebPage(); ui().closeModal(); return;
    }
    const memory = event.target.closest('[data-chat-memory], [data-modal-action="chat-memory-view"]');
    if (memory) {
      event.preventDefault(); event.stopImmediatePropagation();
      void showMemory(memory.dataset.chatMemory || ui().getActiveId()); return;
    }
    const clearMemory = event.target.closest('[data-modal-action="chat-memory-clear"]');
    if (clearMemory) {
      event.preventDefault(); event.stopImmediatePropagation();
      if (active) { notify('请先停止当前回答，再清除记忆。'); return; }
      const conversationId = clearMemory.dataset.value;
      void rpc('chat.memory.clear', {conversationId}).then(() => showMemory(conversationId))
        .catch(error => notify(error.message || '清除未完成。')); return;
    }
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
      const chooseModel=!!imported?.imageId && status.providerId==='phone' && status.phoneVision!==true;
      if (imported) { ui().addAttachment(imported); imported = null; }
      imageJob=null;ui().closeModal();
      if(chooseModel) document.querySelector('#screen-chat .model-select')?.click();
      return;
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
  function cancelWebPage() {
    const entry = webRequest;
    if (!entry) return;
    webRequest = null;
    importing = false;
    void rpc('chat.web.cancel', {requestId:entry.requestId}).catch(() => {});
  }
  async function readWebPage() {
    if (importing || active) return;
    if (ui().getPending().files.length >= 4) { notify('一次最多附加 4 个资料文件。'); return; }
    const input = document.querySelector('#chat-web-url');
    const url = input?.value.trim() || '';
    try {
      const value = new URL(url);
      if (value.protocol !== 'https:' || value.username || value.password || url.length > 2048) throw new Error();
    } catch (_) { notify('请填写完整的 HTTPS 网页链接。'); return; }
    const entry = {requestId:'web-' + Date.now() + '-' + (++serial), conversationId:ui().getActiveId()};
    webRequest = entry;
    importing = true;
    imported = null;
    ui().showWebReading();
    try {
      const result = await rpc('chat.web.read', {url, allowOnce:true, requestId:entry.requestId});
      if (webRequest !== entry || entry.conversationId !== ui().getActiveId()) return;
      const text = '网页标题：' + result.title + '\n来源网址：' + result.url +
        '\n网页标注发布时间：' + (result.publishedAt || '未知') + '\n读取时间：' + result.fetchedAt +
        '\n读取范围：' + (result.truncated ? '仅正文前段，未读取完全文' : '提取到的静态正文，可能遗漏网页内容') +
        '\n\n' + result.text;
      if (!result.text || text.length > 10000) throw new Error('网页资料过长或没有正文，请复制需要的段落。');
      imported = {id:entry.requestId, name:result.title || '网页资料', type:'text/plain',
        extraction:result.truncated ? '公开网页 · 部分正文' : '公开网页 · 静态正文', text};
      ui().previewAttachment(imported);
    } catch (error) {
      if (webRequest === entry && entry.conversationId === ui().getActiveId()) {
        ui().showWebImport(url, error.message || '网页读取失败，可以复制正文后发送。');
        notify(error.message || '网页读取失败，可以复制正文后发送。');
      }
    } finally {
      if (webRequest === entry) { webRequest = null; importing = false; }
    }
  }
  window.addEventListener('pagehide', cancelWebPage);
  function watchWebDialog() {
    const dialog = document.querySelector('#modal-scrim');
    if (!dialog) return;
    new MutationObserver(() => {
      if (webRequest && !dialog.classList.contains('open')) cancelWebPage();
      if(imageJob && imageJob.phase!=='picking' && !dialog.classList.contains('open')) {
        imageJob.canceled=true;
        if(imported?.imageId) {void rpc('chat.image.discard',{imageId:imported.imageId}).catch(()=>{});imported=null;}
      }
    }).observe(dialog, {attributes:true, attributeFilter:['class']});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watchWebDialog, {once:true});
  else watchWebDialog();
  async function showMemory(conversationId) {
    if (!conversationId) { notify('开始对话后可以查看本会话记忆。'); return; }
    try {
      const result = await rpc('chat.memory.get', {conversationId});
      ui().showMemory(conversationId, result.memory, result.context);
    } catch (error) { notify(error.message || '无法读取会话记忆。'); }
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
    notify(kind === 'document' ? '请选择 TXT 或 Markdown 文件' : '请选择图片，发送时由所选模型查看');
    const job={owner:ui().getActiveId(),phase:'picking',canceled:false};if(kind!=='document')imageJob=job;
    try {
      const result = await rpc(kind === 'document' ? 'attachment.pickArticle' : 'chat.image.pick', {kind});
      if (!result || result.canceled) return;
      if(kind!=='document') {
        if(job.canceled || job.owner!==ui().getActiveId() || !document.querySelector('#screen-chat')?.classList.contains('active')) {void rpc('chat.image.discard',{imageId:result.id}).catch(()=>{});return;}
        imported={imageId:result.id,name:result.name,type:result.mimeType,bytes:result.bytes,thumbnailDataUrl:result.thumbnailDataUrl};
        job.phase='preview';ui().previewImageAttachment(imported,status.providerId==='phone'&&status.phoneVision!==true);return;
      }
      const text = String(result.text || result.recognizedText || '').trim();
      if (!text || text.length > 10000) throw new Error('资料为空或超过 10,000 字符，请分段导入。');
      if (result.truncated || result.omittedBlockCount > 0) throw new Error('图片文字超出完整提取范围，请裁小图片后重试，避免遗漏资料。');
      imported = {id: 'file-' + Date.now() + '-' + (++serial), name: String(result.name || '资料'),
        type: 'text/plain', extraction: kind === 'document' ? '本机读取的文件正文' : '图片文字 · 本机 OCR', text};
      ui().previewAttachment(imported);
    } catch (error) { notify(error.message || '读取资料失败。'); }
    finally { importing = false; }
  }
  async function viewImage(imageId) {
    const owner=ui().getActiveId();
    try {
      const result=await rpc('chat.image.preview',{imageId});
      if(owner!==ui().getActiveId()||!document.querySelector('#screen-chat')?.classList.contains('active'))return;
      if(typeof result.dataUrl!=='string'||!/^data:image\/(png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(result.dataUrl)||result.dataUrl.length>12*1024*1024)throw Error('图片无法打开。');
      const image=document.createElement('img');image.src=result.dataUrl;image.dataset.imageMode='original';
      window.miyinOpenImageViewer?.(image);
    } catch(error){notify(error.message||'图片无法打开，请重新选择。');}
  }
  async function extractImageText() {
    if(importing || !imported?.imageId || !imageJob)return;
    const picture=imported,job=imageJob;imported=null;job.phase='ocr';importing=true;
    try {
      const result=await rpc('chat.image.extract',{imageId:picture.imageId});
      if(job.canceled||job.owner!==ui().getActiveId()||!document.querySelector('#screen-chat')?.classList.contains('active'))return;
      imageJob=null;imported={id:'text-'+picture.imageId,name:picture.name+'（文字）',type:'text/plain',extraction:'用户选择提取的图片文字',text:result.text};
      ui().previewAttachment(imported);
    } catch(error){if(!job.canceled){imageJob=null;ui().closeModal();notify(error.message||'图片文字提取失败，请重新选择。');}}
    finally {importing=false;void rpc('chat.image.discard',{imageId:picture.imageId}).catch(()=>{});}
  }
  window.addEventListener('miyin:chat-image-removed',event=>{if(native)void rpc('chat.image.discard',{imageId:event.detail?.imageId}).catch(()=>{});});
  window.addEventListener('miyin:native-host-ready', () => { void initialize(); });
  window.MiyinChat = Object.freeze({native, start, cancel, continueAnswer, warmLocal, canSend, persist, pickAttachment, share,applyStatus:setStatus,
    saveHistoryPreference(value) {
      if (native && ready) void rpc('chat.privacy', {saveLocalHistory: !!value})
        .then(next => { status = next; }).catch(error => notify(error.message));
    },
    get ready() { return ready; },
    get isGenerating() { return !!active; },
    get model() { return status.model; }});
})();
