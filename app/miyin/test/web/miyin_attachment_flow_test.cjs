const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const appRoot = path.resolve(__dirname, '../..');
const shell = fs.readFileSync(path.join(appRoot, 'assets/miyin_v5/index.html'), 'utf8');
const attachments = fs.readFileSync(
  path.join(appRoot, 'assets/miyin_v5/miyin-translation-attachments.js'),
  'utf8',
);
const nativeOcr = fs.readFileSync(
  path.join(appRoot, 'android/app/src/main/kotlin/com/miyin/app/MiyinAttachmentOcrMethodHandler.kt'),
  'utf8',
);
const dartOcr = fs.readFileSync(
  path.join(appRoot, 'lib/features/miyin/translation_attachment_ocr.dart'),
  'utf8',
);
const translationRouter = fs.readFileSync(
  path.join(appRoot, 'lib/features/miyin/translation_rpc_router.dart'),
  'utf8',
);

class AttachmentFakeClassList {
  values = new Set();
  add(value) { this.values.add(value); }
  remove(...values) { values.forEach(value => this.values.delete(value)); }
  contains(value) { return this.values.has(value); }
  toggle(value, force) {
    const enabled = force === undefined ? !this.values.has(value) : Boolean(force);
    if (enabled) this.values.add(value);
    else this.values.delete(value);
    return enabled;
  }
}

class AttachmentFakeElement {
  constructor() {
    this.dataset = {};
    this.children = [];
    this.classList = new AttachmentFakeClassList();
    this.attributes = {};
    this.handlers = new Map();
    this.style = {};
    this.textContent = '';
    this.innerHTML = '';
    this.value = '';
  }
  append(...nodes) { this.children.push(...nodes); }
  appendChild(node) { this.children.push(node); return node; }
  insertBefore(node, before) {
    const index = this.children.indexOf(before);
    if (index < 0) this.children.push(node);
    else this.children.splice(index, 0, node);
    return node;
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(type, listener) {
    const listeners = this.handlers.get(type) || [];
    listeners.push(listener);
    this.handlers.set(type, listeners);
  }
  focus() {}
  closest() { return null; }
}

class FakeImage {
  complete = true;
  naturalWidth = 640;
  naturalHeight = 480;
}
function createCanvas() {
  const context = {
    drawImage() {}, getImageData(_x, _y, w, h) { return { data: new Uint8ClampedArray(w * h * 4).fill(255) }; },
    putImageData() {}, measureText(text) { return { width: text.length * (parseFloat(this.font) || 12) * .5 }; },
    save() {}, beginPath() {}, rect() {}, clip() {}, fillText() {}, restore() {},
  };
  return { getContext() { return context; }, toDataURL() { return 'data:image/jpeg;base64,AQ=='; } };
}
function findDescendant(node, className) {
  if (node.className === className) return node;
  for (const child of node.children || []) { const found = findDescendant(child, className); if (found) return found; }
}

async function runImageAttachmentFlow(selection, _legacyAction, options = {}) {
  const modal = new AttachmentFakeElement();
  const modalTitle = new AttachmentFakeElement();
  const modalCopy = new AttachmentFakeElement();
  const modalOptions = new AttachmentFakeElement();
  const modalFooter = new AttachmentFakeElement();
  const imageProgress = new AttachmentFakeElement();
  const blockList = new AttachmentFakeElement();
  const imageTextEditor = new AttachmentFakeElement();
  const imageTextStatus = new AttachmentFakeElement();
  const transcript = new AttachmentFakeElement();
  const sourceLanguage = new AttachmentFakeElement();
  sourceLanguage.textContent = '中文';
  const targetLanguage = new AttachmentFakeElement();
  targetLanguage.textContent = 'English';
  const actionButtons = new Map();
  const translationRequests = [];
  const pendingTranslations = [];
  const selectionQueue = Array.isArray(selection) ? selection.slice() : [selection];
  modalOptions.contains = node => node === imageProgress && modalOptions.innerHTML.includes('data-translation-attachment-progress');
  modal.querySelector = selector => {
    if (selector === '[data-translation-attachment-progress]') return imageProgress;
    if (selector === '[data-translation-attachment-block-list]') return blockList;
    if (selector === '[data-translation-attachment-status]') return imageTextStatus;
    if (selector === '[data-translation-attachment-image-text]') return imageTextEditor;
    if (selector.startsWith('[data-translation-attachment-action=')) {
      const action = selector.match(/"([^"]+)"/)?.[1];
      return actionButtons.get(action) || null;
    }
    return null;
  };
  modal.querySelectorAll = selector => {
    if (selector !== '[data-translation-attachment-block]') return [];
    const matching = [];
    const visit = node => {
      if (Object.prototype.hasOwnProperty.call(node.dataset, 'translationAttachmentBlock')) matching.push(node);
      node.children.forEach(visit);
    };
    blockList.children.forEach(visit);
    return matching;
  };
  const elements = new Map([
    ['#modal-scrim', modal],
    ['#modal-title', modalTitle],
    ['#modal-copy', modalCopy],
    ['#modal-options', modalOptions],
    ['#modal-footer', modalFooter],
    ['#app', new AttachmentFakeElement()],
    ['#home-transcript', transcript],
    ['#screen-home [data-action="source-language"]', sourceLanguage],
    ['#screen-home [data-action="target-language"]', targetLanguage],
  ]);
  const listeners = [];
  const document = {
    documentElement: { dataset: { nativeHost: 'true' } },
    querySelector: selector => elements.get(selector) || null,
    addEventListener: (_type, listener) => listeners.push(listener),
    createElement: tag => tag === 'canvas' ? createCanvas() : new AttachmentFakeElement(),
    createTextNode: text => Object.assign(new AttachmentFakeElement(), { textContent: text }),
  };
  const window = {
    addEventListener() {}, dispatchEvent() {},
    MiyinNativeBridge: {
      request: async (method, args) => {
        if (method === 'translation.downloadModel') throw Object.assign(new Error('离线语言包暂不可用'), { code: 'model_missing' });
        if (method === 'attachment.recognizeImage') return selectionQueue.shift() || null;
        if (method === 'translation.supportedLanguages') {
          return [
            { tag: 'zh-Hans', name: '简体中文' },
            { tag: 'en', name: 'English' },
          ];
        }
        if (method === 'translation.preview') {
          translationRequests.push(args.text);
          if (options.failTranslation) throw Object.assign(new Error('离线语言包暂不可用'), { code: 'model_missing' });
          if (options.deferTranslations) {
            return new Promise(resolve => pendingTranslations.push(() => resolve({ translatedText: `译文：${args.text}` })));
          }
          return { translatedText: `译文：${args.text}` };
        }
        throw new Error(`Unexpected attachment RPC: ${method}`);
      },
    },
  };
  vm.runInNewContext(attachments, { document, window, Element: AttachmentFakeElement, Image: FakeImage, Uint8ClampedArray, Event });
  const invoke = action => {
    const button = new AttachmentFakeElement();
    button.dataset.translationAttachmentAction = action;
    actionButtons.set(action, button);
    const target = new AttachmentFakeElement();
    target.closest = selector => selector === '[data-translation-attachment-action]' ? button : null;
    listeners[0]({ target, preventDefault() {}, stopImmediatePropagation() {} });
  };
  const invokeCardAction = (card, action) => {
    const button = new AttachmentFakeElement();
    button.dataset.translationAttachmentAction = action;
    button.closest = selector => selector === '.translation-attachment-image-card' ? card : null;
    const target = new AttachmentFakeElement();
    target.closest = selector => selector === '[data-translation-attachment-action]' ? button : null;
    listeners[0]({ target, preventDefault() {}, stopImmediatePropagation() {} });
  };
  const translateAnotherImage = async nextSelection => {
    blockList.children = [];
    const before = transcript.children.length;
    selectionQueue.push(nextSelection);
    invoke('photo');
    await waitFor(() => transcript.children.length > before || pendingTranslations.length > 0 || (modalTitle.textContent.includes('失败') || modalTitle.textContent.includes('无法')), 'automatic image translation did not finish');
    if (!options.deferTranslations) await waitFor(() => transcript.children.length > before || (modalTitle.textContent.includes('失败') || modalTitle.textContent.includes('无法')), 'automatic image translation did not append a card');
  };
  invoke('photo');
  await new Promise(resolve => setImmediate(resolve));
  if (options.deferSelection) {
    return {
      modal, modalTitle, modalCopy, modalOptions, transcript, blockList, imageTextEditor,
      translationRequests, invoke, invokeCardAction, translateAnotherImage,
      resolveSelection: options.resolveSelection,
      openExternalModal(title) {
        modalTitle.textContent = title;
        modalOptions.innerHTML = '';
        modalFooter.innerHTML = '<button>外部弹窗</button>';
      },
      releaseTranslations() {
        const batch = pendingTranslations.splice(0);
        batch.forEach(resolve => resolve());
        return batch.length;
      },
      pendingTranslations,
    };
  }
  if (options.deferTranslations) await waitFor(() => pendingTranslations.length > 0 || (modalTitle.textContent.includes('失败') || modalTitle.textContent.includes('无法')), 'automatic translation did not start');
  else await waitFor(() => transcript.children.length > 0 || (modalTitle.textContent.includes('失败') || modalTitle.textContent.includes('无法')) || modalTitle.textContent.includes('没有识别') || modalTitle.textContent.includes('过多'), 'automatic image translation did not finish');
  return {
    modal, modalTitle, modalCopy, modalOptions, transcript, blockList, imageTextEditor,
    translationRequests,
    invoke,
    invokeCardAction,
    translateAnotherImage,
    releaseTranslations() {
      const batch = pendingTranslations.splice(0);
      batch.forEach(resolve => resolve());
      return batch.length;
    },
    pendingTranslations,
    dismissByBackdrop() { listeners[1]({ target: modal }); },
  };
}

async function runArticleAttachmentFlow(articleText, options = {}) {
  const modal = new AttachmentFakeElement();
  const modalTitle = new AttachmentFakeElement();
  const modalCopy = new AttachmentFakeElement();
  const modalOptions = new AttachmentFakeElement();
  const modalFooter = new AttachmentFakeElement();
  const editor = new AttachmentFakeElement();
  const status = new AttachmentFakeElement();
  const transcript = new AttachmentFakeElement();
  const sourceLanguage = new AttachmentFakeElement();
  sourceLanguage.textContent = '中文';
  const targetLanguage = new AttachmentFakeElement();
  targetLanguage.textContent = 'English';
  const actionButtons = new Map();
  const translationRequests = [];
  const pendingTranslations = [];
  let activeTranslations = 0;
  let maxActiveTranslations = 0;
  let completedTranslations = 0;
  modal.querySelector = selector => {
    if (selector === '[data-translation-attachment-editor]') return editor;
    if (selector === '[data-translation-attachment-status]') return status;
    if (selector.startsWith('[data-translation-attachment-action=')) {
      const action = selector.match(/"([^"]+)"/)?.[1];
      return actionButtons.get(action) || null;
    }
    return null;
  };
  const elements = new Map([
    ['#modal-scrim', modal],
    ['#modal-title', modalTitle],
    ['#modal-copy', modalCopy],
    ['#modal-options', modalOptions],
    ['#modal-footer', modalFooter],
    ['#app', new AttachmentFakeElement()],
    ['#home-transcript', transcript],
    ['#screen-home [data-action="source-language"]', sourceLanguage],
    ['#screen-home [data-action="target-language"]', targetLanguage],
  ]);
  const listeners = [];
  const document = {
    documentElement: { dataset: { nativeHost: 'true' } },
    querySelector: selector => elements.get(selector) || null,
    addEventListener: (_type, listener) => listeners.push(listener),
    createElement: tag => tag === 'canvas' ? createCanvas() : new AttachmentFakeElement(),
    createTextNode: text => Object.assign(new AttachmentFakeElement(), { textContent: text }),
  };
  const window = {
    addEventListener() {}, dispatchEvent() {},
    MiyinNativeBridge: {
      request: async (method, args) => {
        if (method === 'translation.supportedLanguages') {
          return [
            { tag: 'zh-Hans', name: '简体中文' },
            { tag: 'en', name: 'English' },
          ];
        }
        if (method === 'translation.preview') {
          translationRequests.push(args.text);
          if (options.deferTranslations) {
            activeTranslations += 1;
            maxActiveTranslations = Math.max(maxActiveTranslations, activeTranslations);
            return new Promise(resolve => pendingTranslations.push(() => {
              activeTranslations -= 1;
              completedTranslations += 1;
              resolve({ translatedText: `译文：${args.text}` });
            }));
          }
          completedTranslations += 1;
          return { translatedText: `译文：${args.text}` };
        }
        throw new Error(`Unexpected attachment RPC: ${method}`);
      },
    },
  };
  vm.runInNewContext(attachments, { document, window, Element: AttachmentFakeElement, Image: FakeImage, Uint8ClampedArray, Event });
  const invoke = (action, button = new AttachmentFakeElement()) => {
    button.dataset.translationAttachmentAction = action;
    actionButtons.set(action, button);
    const target = new AttachmentFakeElement();
    target.closest = selector => selector === '[data-translation-attachment-action]'
      ? button
      : null;
    listeners[0]({ target, preventDefault() {}, stopImmediatePropagation() {} });
  };
  const invokeCardAction = (card, action) => {
    const button = new AttachmentFakeElement();
    button.dataset.translationAttachmentAction = action;
    button.closest = selector => selector === '.translation-attachment-article-card' ? card : null;
    invoke(action, button);
  };
  const translateAnotherArticle = async nextText => {
    invoke('article');
    editor.value = nextText;
    invoke('translate');
    if (!options.deferTranslations) {
      await new Promise(resolve => setImmediate(resolve));
      await new Promise(resolve => setImmediate(resolve));
    }
  };
  invoke('article');
  editor.value = articleText;
  invoke('translate');
  if (!options.deferTranslations) {
    await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));
  }
  return {
    modal, modalTitle, modalOptions, transcript, editor, invoke, invokeCardAction, translateAnotherArticle,
    pendingTranslations, translationRequests,
    get activeTranslations() { return activeTranslations; },
    get maxActiveTranslations() { return maxActiveTranslations; },
    get completedTranslations() { return completedTranslations; },
    releaseTranslations() {
      const batch = pendingTranslations.splice(0);
      batch.forEach(resolve => resolve());
      return batch.length;
    },
    dismissByBackdrop() { listeners[1]({ target: modal }); },
  };
}

async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.fail(message || 'condition did not become true');
}

test('translation attachment button opens its own icon menu without focusing or rewriting the input', () => {
  assert.match(shell, /data-action="open-input-tools"/);
  assert.match(attachments, /button\[data-action="open-input-tools"\]/);
  assert.match(shell, /window\.MiyinTranslationAttachmentFlow=\{/);
  assert.match(attachments, /stopImmediatePropagation\(\)/);
  assert.match(attachments, /\["camera", "拍照"\][\s\S]*?\["photo", "图片"\][\s\S]*?\["article", "文章"\]/);
  assert.doesNotMatch(attachments, /translation-input["'`]?\)\.value\s*=/);
  assert.doesNotMatch(attachments, /translation-input["'`]?\)\.focus\s*\(/);
});

test('camera and gallery actions show progress and automatically translate on-device OCR', () => {
  assert.match(attachments, /attachment\.recognizeImage/);
  assert.match(attachments, /recognizedText/);
  assert.match(attachments, /openImageProgress\(kind\)/);
  assert.match(attachments, /选择图片后会自动进行本机文字识别和翻译/);
  assert.match(attachments, /正在等待图片选择与本机识别完成/);
  assert.match(attachments, /modalOptions\.contains\(modalOwnershipAnchor\)/);
  assert.match(attachments, /await translateRecognizedImage\(revision, kind\)/);
  assert.doesNotMatch(attachments, /attachment\.pickSource/);
  assert.doesNotMatch(attachments, /recognizeImage[\s\S]{0,180}path\s*:/);
});

test('image translation preserves source photo and composes translated pixels from bounded OCR regions', () => {
  assert.match(attachments, /previewDataUrl/);
  assert.match(attachments, /MAX_IMAGE_PREVIEW_LENGTH/);
  assert.match(attachments, /translation-attachment-block-list/);
  assert.match(attachments, /translate-image/);
  assert.match(attachments, /translation\.preview/);
  assert.match(attachments, /image_ocr_geometry_missing/);
  assert.match(attachments, /translation-attachment-conversation-card translation-attachment-image-card/);
  assert.match(attachments, /appendConversationCard\(card(?:,\s*expectedRevision)?\)/);
  assert.match(attachments, /composeTranslatedImage\(imageRecognition\.previewDataUrl, rows\)/);
  assert.match(attachments, /row\.left\s*\*\s*100/);
  assert.match(attachments, /row\.top\s*\*\s*100/);
  assert.match(attachments, /row\.translatedText/);
  assert.match(attachments, /imageRecognition\.geometryComplete/);
  assert.match(attachments, /stage\.dataset\.imageMode/);
  assert.match(attachments, /识别区域过密或彼此重叠/);
});

test('image OCR without complete coordinates refuses image generation and offers a clear retry path', () => {
  const recognizer = attachments.match(/async function recognizeImage\(kind, capturedImage\) \{([\s\S]*?)\n  \}/);
  assert.ok(recognizer, 'image recognizer must exist');
  assert.doesNotMatch(recognizer[1], /openImageTextReview|openImageReview/);
  assert.match(attachments, /geometryComplete\s*=/);
  assert.match(attachments, /data-translation-attachment-image-text/);
  assert.match(attachments, /if \(!hasGeometry\)/);
  assert.match(attachments, /showImageFailure\(kind, "无法生成译图", "未取得文字在图片中的可靠位置/);
  assert.match(attachments, /hasGeometry:\s*false/);
});

test('image with usable bounds appears as translated pixels with separate zoom and comparison controls', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'street.jpg',
    recognizedText: 'Station',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: 'Station', left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  }, 'translate-image');

  assert.equal(ui.transcript.children.length, 1);
  const card = ui.transcript.children[0];
  assert.match(card.className, /translation-attachment-image-card/);
  assert.ok(card.children.some(child => child.className === 'translation-attachment-conversation-figure'));
  const controls = findDescendant(card, 'translation-attachment-view-toggle');
  assert.deepEqual(controls.children.map(child => child.textContent), ['原图', '译图', '对照']);
  const stage = findDescendant(card, 'translation-attachment-conversation-stage');
  assert.equal(stage.children[0].src, 'data:image/jpeg;base64,AQ==');
  assert.equal(stage.children[0].dataset.originalSrc, 'data:image/jpeg;base64,AA==');
  assert.equal(stage.children[1].dataset.translationAttachmentAction, 'view-image');
  controls.children[0].handlers.get('click')[0]();
  assert.equal(stage.dataset.imageMode, 'original');
  assert.equal(stage.children[0].src, 'data:image/jpeg;base64,AA==');
  controls.children[1].handlers.get('click')[0]();
  assert.equal(stage.dataset.imageMode, 'translated');
  assert.equal(stage.children[0].src, 'data:image/jpeg;base64,AQ==');
  const comparison = findDescendant(card, 'translation-attachment-conversation-pairs');
  assert.equal(comparison.children[1].children[3].textContent, '译文：Station');
  comparison.children[1].handlers.get('click')[0]();
  assert.equal(card.dataset.selectedComparisonIndex, '0');
  assert.equal(ui.modal.classList.contains('open'), false);
});

test('failed image translation explains the failure and offers selection retry without claiming a translated image', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'receipt.jpg',
    recognizedText: 'Total',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    blocks: [{ text: 'Total', left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  }, null, { failTranslation: true });
  assert.equal(ui.transcript.children.length, 0);
  assert.equal(ui.modalTitle.textContent, '无法完成图片翻译');
  assert.match(ui.modalCopy.textContent, /当前翻译方向的离线语言包尚未下载/);
  assert.equal(ui.modal.dataset.retryImageKind, 'image');

});

test('image import shows a cancelable progress state and does not append a late result after cancellation', async () => {
  let resolveSelection;
  const pendingSelection = new Promise(resolve => { resolveSelection = resolve; });
  const ui = await runImageAttachmentFlow(pendingSelection, null, { deferSelection: true, resolveSelection });

  assert.equal(ui.modal.classList.contains('open'), true);
  assert.equal(ui.modalTitle.textContent, '图片翻译');
  assert.match(ui.modalOptions.innerHTML, /translation-attachment-spinner/);
  ui.invoke('cancel');
  resolveSelection({
    canceled: false,
    name: 'late.jpg',
    recognizedText: 'Station',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: 'Station', left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(ui.modal.classList.contains('open'), false);
  assert.equal(ui.transcript.children.length, 0);
});

test('an image request cannot overwrite or close a different modal opened while the picker is pending', async () => {
  let resolveSelection;
  const pendingSelection = new Promise(resolve => { resolveSelection = resolve; });
  const ui = await runImageAttachmentFlow(pendingSelection, null, { deferSelection: true, resolveSelection });
  ui.openExternalModal('用户设置');
  resolveSelection({
    canceled: false,
    name: 'late.jpg',
    recognizedText: 'Station',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: 'Station', left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  });
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(ui.modal.classList.contains('open'), true);
  assert.equal(ui.modalTitle.textContent, '用户设置');
  assert.equal(ui.transcript.children.length, 0);
});

test('normalized OCR bounds may use the exact zero and one edges when rectangle ordering is valid', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'full-page.jpg',
    recognizedText: 'Full page text',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: 'Full page text', left: 0, top: 0, right: 1, bottom: 1 }],
  }, 'translate-image');

  const stage = ui.transcript.children[0].children.find(child => child.className === 'translation-attachment-conversation-figure').children[0];
  assert.equal(stage.children[0].dataset.translatedSrc, 'data:image/jpeg;base64,AQ==');
});

test('image edit references retain only the eight newest source images', async () => {
  const selectionFor = index => ({
    canceled: false,
    name: `image-${index}.jpg`,
    recognizedText: `Image text ${index}`,
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: `Image text ${index}`, left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  });
  const ui = await runImageAttachmentFlow(selectionFor(1), 'translate-image');
  const cards = [ui.transcript.children[0]];

  for (let index = 2; index <= 9; index += 1) {
    await ui.translateAnotherImage(selectionFor(index));
    cards.push(ui.transcript.children.at(-1));
  }

  assert.equal(ui.transcript.children.length, 9);
  ui.invokeCardAction(cards[0], 'edit-image');
  assert.equal(ui.modalTitle.textContent, '图片内容已释放', 'an evicted image must not resolve to another image result');

  ui.invoke('cancel');
  ui.invokeCardAction(cards[1], 'edit-image');
  assert.match(ui.modalOptions.innerHTML, /image-2\.jpg/, 'the next-oldest image should remain editable within the eight-item limit');
});

test('non-finite, out-of-range, unordered, and non-numeric OCR bounds cannot generate a translated image', async () => {
  const invalidBounds = [
    { left: NaN, top: 0.1, right: 0.8, bottom: 0.2 },
    { left: 0.1, top: Infinity, right: 0.8, bottom: 0.2 },
    { left: -0.01, top: 0.1, right: 0.8, bottom: 0.2 },
    { left: 0.1, top: 0.1, right: 1.01, bottom: 0.2 },
    { left: 0.8, top: 0.1, right: 0.2, bottom: 0.2 },
    { left: 0.1, top: 0.8, right: 0.8, bottom: 0.2 },
    { left: '0.1', top: 0.1, right: 0.8, bottom: 0.2 },
  ];

  for (const bounds of invalidBounds) {
    const ui = await runImageAttachmentFlow({
      canceled: false,
      name: 'invalid-bounds.jpg',
      recognizedText: 'Keep this text',
      previewDataUrl: 'data:image/jpeg;base64,AA==',
      width: 640,
      height: 480,
      totalBlockCount: 1,
      omittedBlockCount: 0,
      blocks: [{ text: 'Keep this text', ...bounds }],
    }, 'translate-image-text');

    assert.equal(ui.transcript.children.length, 0, `unsafe bounds must not create a translated image: ${JSON.stringify(bounds)}`);
    assert.equal(ui.modalTitle.textContent, '无法生成译图');
    assert.match(ui.modalCopy.textContent, /可靠位置/);

  }
});

test('canceling an in-flight image translation prevents a late conversation card', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'street.jpg',
    recognizedText: 'Station',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 1,
    omittedBlockCount: 0,
    blocks: [{ text: 'Station', left: 0.1, top: 0.1, right: 0.8, bottom: 0.2 }],
  }, 'translate-image', { deferTranslations: true });

  await waitFor(() => ui.pendingTranslations.length === 1, 'image translation did not reach the deferred preview call');
  ui.invoke('cancel');
  ui.releaseTranslations();
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(ui.modal.classList.contains('open'), false);
  assert.equal(ui.transcript.children.length, 0);
});

test('overlapping OCR regions preserve source pixels and retain complete translation pairs', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'crowded-signs.jpg',
    recognizedText: 'Station entrance\nExit',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 2,
    omittedBlockCount: 0,
    blocks: [
      { text: 'Station entrance', left: 0.1, top: 0.1, right: 0.8, bottom: 0.25 },
      { text: 'Exit', left: 0.15, top: 0.15, right: 0.85, bottom: 0.3 },
    ],
  }, 'translate-image');

  assert.equal(ui.transcript.children.length, 1);
  const card = ui.transcript.children[0];
  const stage = card.children.find(child => child.className === 'translation-attachment-conversation-figure').children[0];
  assert.equal(stage.children[0].src, 'data:image/jpeg;base64,AQ==');
  assert.match(findDescendant(card, 'translation-attachment-card-notice').textContent, /区域重叠未覆盖原图/);
  const comparisons = findDescendant(card, 'translation-attachment-conversation-pairs');
  assert.equal(comparisons.children.length - 1, 2, 'both original/translated text pairs remain available');

});

test('image text without usable bounds reports why an in-place translated image cannot be generated', async () => {
  const ui = await runImageAttachmentFlow({
    canceled: false,
    name: 'street.jpg',
    recognizedText: 'Station entrance\nNearby sign',
    previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640,
    height: 480,
    totalBlockCount: 2,
    omittedBlockCount: 0,
    blocks: [
      { text: 'Station entrance' },
      { text: 'Nearby sign', left: 0.1, top: 0.3, right: 0.7, bottom: 0.4 },
    ],
  }, 'translate-image-text');

  assert.equal(ui.transcript.children.length, 0);
  assert.equal(ui.modalTitle.textContent, '无法生成译图');
  assert.match(ui.modalCopy.textContent, /可靠位置/);

});

test('OCR caps native and Dart-visible blocks and tells users when blocks were omitted', () => {
  assert.match(nativeOcr, /MAX_OCR_BLOCK_COUNT\s*=\s*80/);
  assert.match(nativeOcr, /val allBlocks\s*=\s*recognized\.textBlocks\.flatMap/);
  assert.match(nativeOcr, /val blocks\s*=\s*allBlocks\.take\(MAX_OCR_BLOCK_COUNT\)/);
  assert.match(nativeOcr, /val recognizedText\s*=\s*blocks\.joinToString\("\\n"\)/);
  assert.match(nativeOcr, /"recognizedText"\s+to\s+recognizedText/);
  assert.match(nativeOcr, /"totalBlockCount"\s+to\s+allBlocks\.size/);
  assert.match(nativeOcr, /"omittedBlockCount"\s+to\s+omittedBlockCount/);
  assert.match(dartOcr, /static const maxBlocks = 80/);
  assert.match(dartOcr, /rawBlocks\.take\(TranslationImageRecognition\.maxBlocks \+ 1\)/);
  assert.match(dartOcr, /'recognizedText': limited\.recognizedText/);
  assert.match(dartOcr, /'omittedBlockCount': limited\.omittedBlockCount/);
  assert.match(translationRouter, /final boundedRecognition = recognized\.limitBlocks\(\)/);
  assert.match(attachments, /MAX_OCR_BLOCK_COUNT = 80/);
  assert.match(attachments, /selected\.omittedBlockCount/);
  assert.match(attachments, /result\.omittedBlockCount/);
  assert.match(attachments, /未纳入对照翻译/);
});

test('image import automatically translates at most 80 OCR blocks and displays the omitted count', async () => {
  const blocks = Array.from({ length: 105 }, (_, index) => ({
    text: `block ${index}`, left: .1, top: .1, right: .9, bottom: .2,
  }));
  const ui = await runImageAttachmentFlow({ canceled: false, name: 'dense.jpg',
    recognizedText: blocks.map(block => block.text).join('\n'), previewDataUrl: 'data:image/jpeg;base64,AA==',
    width: 640, height: 480, totalBlockCount: blocks.length, omittedBlockCount: 0, blocks });
  const card = ui.transcript.children[0];
  assert.equal(ui.translationRequests.length, 80);
  assert.match(findDescendant(card, 'translation-attachment-card-notice').textContent, /另有 25 处未纳入翻译/);
});

test('article import is limited to pasted text and local UTF-8 TXT or Markdown', () => {
  assert.match(attachments, /attachment\.pickArticle/);
  assert.match(attachments, /UTF-8 \.txt \/ \.md/);
  assert.match(attachments, /accept\s*=\s*"\.txt,\.md,text\/plain,text\/markdown"/);
  assert.match(attachments, /文章原文/);
  assert.match(attachments, /TextDecoder\("utf-8", \{ fatal: true \}\)/);
});

test('article translation appends original and translated paragraphs together in the conversation', () => {
  assert.match(attachments, /splitArticleParagraphs/);
  assert.match(attachments, /translation-attachment-reader/);
  assert.match(attachments, /原文 · /);
  assert.match(attachments, /译文 · /);
  assert.match(attachments, /renderArticleReader/);
  assert.match(attachments, /append\(sourceHeading, source, translatedHeading, translated\)/);
  assert.match(attachments, /translation-attachment-conversation-card translation-attachment-article-card/);
  assert.match(attachments, /lastArticleRows\s*=\s*rows\.map/);
  assert.match(attachments, /appendConversationCard\(card(?:,\s*expectedRevision)?\)/);
});

test('article translation creates one readable source-and-translation pair per paragraph in chat', async () => {
  const ui = await runArticleAttachmentFlow('First paragraph.\n\nSecond paragraph.');

  assert.equal(ui.transcript.children.length, 1);
  const card = ui.transcript.children[0];
  assert.match(card.className, /translation-attachment-article-card/);
  const reader = card.children.find(child => child.className === 'translation-attachment-reader');
  assert.equal(reader.children.length, 2);
  assert.equal(reader.children[0].children[1].textContent, 'First paragraph.');
  assert.equal(reader.children[0].children[3].textContent, '译文：First paragraph.');
  assert.equal(reader.children[1].children[1].textContent, 'Second paragraph.');
  assert.equal(ui.modal.classList.contains('open'), false);
});

test('article edit references retain only the sixteen newest source articles', async () => {
  const ui = await runArticleAttachmentFlow('Article 1');
  const cards = [ui.transcript.children[0]];

  for (let index = 2; index <= 17; index += 1) {
    await ui.translateAnotherArticle(`Article ${index}`);
    cards.push(ui.transcript.children.at(-1));
  }

  assert.equal(ui.transcript.children.length, 17);
  ui.invokeCardAction(cards[0], 'edit-article');
  assert.equal(ui.modalTitle.textContent, '文章内容已释放', 'an evicted article must not resolve to another article');

  ui.invoke('cancel');
  ui.invokeCardAction(cards[1], 'edit-article');
  assert.equal(ui.editor.value, 'Article 2', 'the next-oldest article should remain editable within the sixteen-item limit');
});

test('article paragraphs translate with a bounded pool and preserve their original order', async () => {
  const paragraphs = Array.from({ length: 7 }, (_, index) => `Paragraph ${index + 1}.`);
  const ui = await runArticleAttachmentFlow(paragraphs.join('\n\n'), { deferTranslations: true });

  await waitFor(() => ui.pendingTranslations.length === 3, 'article translation did not start a three-request batch');
  assert.equal(ui.maxActiveTranslations, 3);

  for (let batch = 0; batch < 4 && ui.transcript.children.length === 0; batch += 1) {
    assert.ok(ui.pendingTranslations.length > 0, 'expected another bounded translation batch');
    ui.releaseTranslations();
    await new Promise(resolve => setImmediate(resolve));
  }

  await waitFor(() => ui.transcript.children.length === 1, 'article conversation card was not appended');
  assert.equal(ui.maxActiveTranslations, 3);
  assert.deepEqual(ui.translationRequests, paragraphs);
  const reader = ui.transcript.children[0].children.find(child => child.className === 'translation-attachment-reader');
  assert.deepEqual(reader.children.map(section => section.children[1].textContent), paragraphs);
  assert.deepEqual(reader.children.map(section => section.children[3].textContent), paragraphs.map(text => `译文：${text}`));
});

test('closing an in-flight article translation stops later batches and suppresses the result card', async () => {
  const paragraphs = Array.from({ length: 5 }, (_, index) => `Paragraph ${index + 1}.`);
  const ui = await runArticleAttachmentFlow(paragraphs.join('\n\n'), { deferTranslations: true });

  await waitFor(() => ui.pendingTranslations.length > 0, 'article translation did not reach the deferred preview call');
  const startedRequests = ui.translationRequests.length;
  ui.dismissByBackdrop();
  ui.releaseTranslations();
  await new Promise(resolve => setImmediate(resolve));
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(ui.modal.classList.contains('open'), false);
  assert.equal(ui.translationRequests.length, startedRequests, 'closing should prevent starting another paragraph request');
  assert.equal(ui.transcript.children.length, 0);
});

test('picker cancellation leaves the current translation draft untouched', () => {
  assert.match(attachments, /if\s*\(!selected\s*\|\|\s*selected\.canceled\)\s*\{\s*closeModal\(\);\s*return/);
  assert.match(attachments, /if\s*\(action\s*===\s*"cancel"\)\s*closeModal\(\)/);
  assert.doesNotMatch(attachments, /translation-input["'`]?\)\.value\s*=/);
});
