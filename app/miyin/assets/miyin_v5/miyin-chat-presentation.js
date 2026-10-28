/* Local-only Markdown rendering. Model output never becomes executable HTML. */
(() => {
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const cache = new Map();
  const parser = window.marked ? new window.marked.Marked({gfm:true, breaks:true}) : null;
  const box = document.querySelector('#chat-messages');
  const screen = document.querySelector('#screen-chat');
  let following = true, pending = null;
  const jump = document.createElement('button');
  jump.type = 'button'; jump.className = 'chat-jump-latest'; jump.textContent = '↓ 回到最新';
  jump.hidden = true; jump.setAttribute('aria-label', '回到最新消息');
  screen?.append(jump);
  function selected() {
    const selection = getSelection();
    return selection && !selection.isCollapsed &&
      (box?.contains(selection.anchorNode) || box?.contains(selection.focusNode));
  }
  function locateJump() {
    const composer = screen?.querySelector('.chat-compose');
    if (composer) jump.style.bottom = (composer.getBoundingClientRect().height + 12) + 'px';
    jump.hidden = following || !box || box.scrollHeight <= box.clientHeight + 8;
  }
  box?.addEventListener('scroll', () => {
    following = box.scrollHeight - box.scrollTop - box.clientHeight < 48;
    locateJump();
  }, {passive:true});
  jump.addEventListener('click', () => {
    following = true;
    if (pending) { const next = pending; pending = null; update(...next); }
    box.scrollTop = box.scrollHeight; locateJump();
  });
  if (window.ResizeObserver && screen) {
    new ResizeObserver(locateJump).observe(screen.querySelector('.chat-compose'));
  }
  document.addEventListener('selectionchange', () => {
    if (!selected() && pending) {
      const next = pending; pending = null; update(...next);
    }
  });

  function render(message) {
    if (message.role !== 'assistant') return escape(message.text);
    const key = String(message.id) + '\u0000' + String(message.text);
    if (cache.has(key)) return cache.get(key);
    let output;
    if (!parser || !window.DOMPurify) return escape(message.text);
    try {
      const fragment = DOMPurify.sanitize(parser.parse(String(message.text ?? '')), {
        RETURN_DOM_FRAGMENT:true,
        ALLOWED_TAGS:['p','br','strong','em','del','s','blockquote','h1','h2','h3','h4','h5','h6',
          'ul','ol','li','pre','code','table','thead','tbody','tr','th','td','hr','a'],
        ALLOWED_ATTR:['href','start'], ALLOW_DATA_ATTR:false, ALLOW_ARIA_ATTR:false,
        FORBID_TAGS:['style','script','img','iframe','svg','math','form','input','button'],
      });
      fragment.querySelectorAll('a').forEach(link => {
        try {
          const url = new URL(link.getAttribute('href'));
          if (!['https:','http:'].includes(url.protocol) || url.username || url.password) throw new Error();
          // Opening is wired separately; never navigate the privileged WebView.
          const button = document.createElement('button');
          button.type = 'button'; button.className = 'chat-web-link';
          button.dataset.chatWebUrl = url.href; button.textContent = link.textContent || url.hostname;
          link.replaceWith(button);
        } catch (_) { link.replaceWith(document.createTextNode(link.textContent)); }
      });
      const walker = document.createTreeWalker(fragment, NodeFilter.SHOW_TEXT);
      const textNodes = []; while (walker.nextNode()) textNodes.push(walker.currentNode);
      for (const node of textNodes) {
        if (node.parentElement?.closest('code,pre,button,a')) continue;
        const text = node.textContent, pattern = /\[资料([1-9]\d*)\]/g;
        let match, offset = 0; const replacement = document.createDocumentFragment();
        while ((match = pattern.exec(text))) {
          replacement.append(document.createTextNode(text.slice(offset, match.index)));
          const citation = document.createElement('button'); citation.type = 'button';
          citation.className = 'chat-source-citation'; citation.dataset.chatSource = String(message.id);
          citation.dataset.sourceIndex = match[1]; citation.textContent = match[0];
          replacement.append(citation); offset = pattern.lastIndex;
        }
        if (offset) { replacement.append(document.createTextNode(text.slice(offset))); node.replaceWith(replacement); }
      }
      fragment.querySelectorAll('pre').forEach(pre => {
        const container = document.createElement('div'); container.className = 'chat-code-block';
        const copy = document.createElement('button'); copy.type = 'button';
        copy.className = 'chat-code-copy'; copy.textContent = '复制代码';
        pre.replaceWith(container); container.append(copy, pre);
      });
      fragment.querySelectorAll('table').forEach(table => {
        const scroll = document.createElement('div'); scroll.className = 'chat-table-scroll';
        scroll.tabIndex = 0; scroll.setAttribute('aria-label','表格，可横向滚动');
        table.replaceWith(scroll); scroll.append(table);
      });
      const container = document.createElement('div'); container.append(fragment);
      output = '<div class="chat-rich-text">' + container.innerHTML + '</div>';
    } catch (_) { output = escape(message.text); }
    cache.set(key, output);
    if (cache.size > 64) cache.delete(cache.keys().next().value);
    return output;
  }

  function update(target, conversationId, html) {
    const changed = target.dataset.conversationId !== (conversationId || '');
    if (!changed && selected()) { pending = [target, conversationId, html]; return; }
    if (changed) { following = true; pending = null; }
    const previous = target.scrollTop;
    const anchor = [...target.querySelectorAll('[data-message-id]')].find(node =>
      node.getBoundingClientRect().bottom >= target.getBoundingClientRect().top);
    const anchorOffset = anchor?.getBoundingClientRect().top;
    const template = document.createElement('template'); template.innerHTML = html;
    // Reuse unchanged nodes: preserve selection, code scroll and stable history.
    const old = [...target.children], next = [...template.content.children];
    for (let i = 0; i < next.length; i++) {
      const before = old[i], after = next[i];
      if (before?.outerHTML === after.outerHTML) next[i] = before;
    }
    target.replaceChildren(...next); target.dataset.conversationId = conversationId || '';
    if (following) target.scrollTop = target.scrollHeight;
    else if (anchor?.isConnected) target.scrollTop = previous + anchor.getBoundingClientRect().top - anchorOffset;
    else target.scrollTop = previous;
    locateJump();
  }
  document.addEventListener('click', async event => {
    const copy = event.target.closest('.chat-code-copy');
    if (copy) {
      const text = copy.parentElement.querySelector('pre').textContent;
      try {
        if (window.MiyinApp) await window.MiyinNativeBridge.request('chat.copy', {text});
        else await navigator.clipboard.writeText(text);
        copy.textContent = '已复制'; setTimeout(() => { if(copy.isConnected) copy.textContent = '复制代码'; }, 1500);
      } catch (_) { window.MiyinChatUI?.announce('复制未完成，请长按选择代码。'); }
    }
    const link = event.target.closest('[data-chat-web-url]');
    if (link) {
      event.preventDefault();
      // Readable/copyable link until isolated browsing is available.
      const url = link.dataset.chatWebUrl;
      if (window.MiyinApp) {
        try { await window.MiyinNativeBridge.request('chat.openUrl', {url}); }
        catch (_) { window.MiyinChatUI?.announce('未能打开网页。'); }
      } else window.open(url, '_blank', 'noopener,noreferrer');
    }
  });
  window.MiyinChatPresentation = Object.freeze({render, update});
})();
