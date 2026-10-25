(function () {
  "use strict";

  const MAX_TEXT_LENGTH = 10000;
  const MAX_OCR_BLOCK_COUNT = 80;
  const MAX_ARTICLE_BYTES = MAX_TEXT_LENGTH * 4 + 3;
  const MAX_IMAGE_PREVIEW_LENGTH = 2300000;
  const JPEG_DATA_URL = /^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/;
  const modal = document.querySelector("#modal-scrim");
  const modalTitle = document.querySelector("#modal-title");
  const modalCopy = document.querySelector("#modal-copy");
  const modalOptions = document.querySelector("#modal-options");
  const modalFooter = document.querySelector("#modal-footer");
  const app = document.querySelector("#app");
  if (!modal || !modalOptions || !modalFooter || !app) return;
  let imageRecognition = null;
  let supportedLanguages = null;
  const imageModelDownloads = new Map();
  let lastArticleRows = null;
  let currentArticleName = "";
  let nextImageResultId = 0;
  let nextArticleResultId = 0;
  let modalRevision = 0;
  let modalOwnershipAnchor = null;
  const imageResults = new Map();
  const articleResults = new Map();
  const MAX_IMAGE_RESULT_REFERENCES = 8;
  const MAX_ARTICLE_RESULT_REFERENCES = 16;

  function rememberBoundedResult(store, key, value, limit) {
    store.set(key, value);
    while (store.size > limit) {
      const oldestKey = store.keys().next().value;
      if (oldestKey === undefined) break;
      store.delete(oldestKey);
    }
  }

  const icons = {
    camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 7h3l1.5-2h7L17 7h3v12H4z"/><circle cx="12" cy="13" r="3.5"/></svg>',
    photo: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.5"/><path d="m4 17 5-5 4 4 3-3 4 4"/></svg>',
    article: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 3h8l5 5v13H6z"/><path d="M14 3v6h5M9 13h7m-7 4h7"/></svg>',
  };

  function setModal(title, copy, optionsMarkup, footerMarkup) {
    modalRevision += 1;
    modalOwnershipAnchor = null;
    modalTitle.textContent = title;
    modalCopy.textContent = copy;
    modalOptions.classList.remove("chat-attachment-grid", "translation-attachment-grid");
    modalOptions.removeAttribute("aria-label");
    modalOptions.innerHTML = optionsMarkup;
    modalFooter.innerHTML = footerMarkup;
    modal.classList.add("open");
  }

  function closeModal() {
    modalRevision += 1;
    modalOwnershipAnchor = null;
    modal.classList.remove("open");
  }

  function isCurrentModal(revision) {
    return modalRevision === revision &&
      modal.classList.contains("open") &&
      (!modalOwnershipAnchor || modalOptions.contains(modalOwnershipAnchor));
  }

  function openMenu() {
    const hostCopy = document.documentElement.dataset.nativeHost === "true"
      ? "图片会在本机自动识别并翻译；文章支持粘贴或导入 UTF-8 .txt / .md。"
      : "网页预览支持粘贴或导入 UTF-8 .txt / .md；图片识别需在 Android 应用中使用。";
    const actions = [
      ["camera", "拍照"],
      ["photo", "图片"],
      ["article", "文章"],
    ];
    const options = actions.map(([action, label]) =>
      '<button class="chat-attachment-option translation-attachment-option" type="button" data-translation-attachment-action="' + action + '" aria-label="' + label + '" title="' + label + '">' + icons[action] + '<span>' + label + '</span></button>'
    ).join("");
    setModal("添加到翻译", hostCopy, options,
      '<button class="translation-attachment-cancel" type="button" data-translation-attachment-action="cancel">关闭</button>');
    modalOptions.classList.add("translation-attachment-grid");
    modalOptions.setAttribute("aria-label", "翻译附件工具");
  }

  function openEditor(kind, text, status, name) {
    const article = kind === "article";
    if (article) currentArticleName = name || "";
    const title = article ? "文章翻译" : "图片文字翻译";
    const copy = article
      ? "粘贴文字，或导入本机 UTF-8 .txt / .md 文件。最多 10,000 个字符。"
      : "文字由本机离线识别。请检查识别结果，再开始翻译。";
    const options = '<textarea class="translation-attachment-editor" data-translation-attachment-editor maxlength="' + MAX_TEXT_LENGTH + '" aria-label="' + (article ? "文章内容" : "图片识别文字") + '" placeholder="' + (article ? "在这里粘贴文章…" : "图片识别结果…") + '"></textarea><p class="translation-attachment-status" data-translation-attachment-status role="status" aria-live="polite"></p>';
    const footer = (article
      ? '<button type="button" data-translation-attachment-action="import-article">导入 TXT / MD</button>'
      : '<span class="translation-attachment-file-name"></span>') +
      '<button class="confirm" type="button" data-translation-attachment-action="translate">翻译</button>' +
      '<button type="button" data-translation-attachment-action="cancel">取消</button>';
    setModal(title, copy, options, footer);
    const editor = modal.querySelector("[data-translation-attachment-editor]");
    const statusNode = modal.querySelector("[data-translation-attachment-status]");
    const fileName = modal.querySelector(".translation-attachment-file-name");
    editor.value = text || "";
    statusNode.textContent = status || "";
    if (fileName) fileName.textContent = name ? "已识别：" + name : "本机 OCR";
    // Keep the import and translate actions visible until the user chooses to type.
  }

  function openImageReview(result, name) {
    imageRecognition = { ...result, name, geometryComplete: true };
    const blocks = Array.isArray(result.blocks) ? result.blocks : [];
    const status = result.omittedBlockCount > 0
      ? '本机识别完成 · 当前仅处理前 ' + blocks.length + ' 处文字，另有 ' + result.omittedBlockCount + ' 处未纳入对照翻译。建议裁剪图片后重试。'
      : '本机识别完成 · 可逐块校对后生成图片对照译文';
    const content = '<div class="translation-attachment-image-review"><figure class="translation-attachment-image-preview"><img src="' + result.previewDataUrl + '" alt="' + escapeHtml(name || "待翻译图片") + '"><figcaption>原图预览 · ' + blocks.length + ' 处文字</figcaption></figure><div class="translation-attachment-block-list" data-translation-attachment-block-list></div><p class="translation-attachment-status" data-translation-attachment-status role="status" aria-live="polite">' + escapeHtml(status) + '</p></div>';
    const footer = '<span class="translation-attachment-file-name">' + escapeHtml(name || "本机 OCR") + '</span><button class="confirm" type="button" data-translation-attachment-action="translate-image">生成图片对照译文</button><button type="button" data-translation-attachment-action="cancel">取消</button>';
    setModal("图片对照翻译", "请核对原图文字。确认后，图片和对照译文会加入翻译对话。", content, footer);
    const list = modal.querySelector("[data-translation-attachment-block-list]");
    blocks.forEach((block, index) => {
      const label = document.createElement("label");
      label.className = "translation-attachment-block-editor";
      const title = document.createElement("span");
      const include = document.createElement("input");
      include.type = "checkbox";
      include.checked = true;
      include.dataset.translationAttachmentInclude = String(index);
      include.setAttribute("aria-label", "翻译第 " + (index + 1) + " 处文字");
      title.append(include, document.createTextNode(" 翻译文字 " + (index + 1)));
      const editor = document.createElement("textarea");
      editor.dataset.translationAttachmentBlock = String(index);
      editor.maxLength = MAX_TEXT_LENGTH;
      editor.rows = Math.max(2, Math.min(4, String(block.text || "").split("\n").length + 1));
      editor.value = String(block.text || "");
      label.append(title, editor);
      list.appendChild(label);
    });
  }

  function openImageTextReview(result, name, reason) {
    imageRecognition = { ...result, name, geometryComplete: false };
    const content = '<div class="translation-attachment-image-review"><figure class="translation-attachment-image-preview"><img src="' + result.previewDataUrl + '" alt="' + escapeHtml(name || "待翻译图片") + '"><figcaption>原图预览</figcaption></figure><label class="translation-attachment-block-editor"><span>本机识别文字 · 可校对</span><textarea data-translation-attachment-image-text maxlength="' + MAX_TEXT_LENGTH + '" aria-label="图片识别文字" rows="6"></textarea></label><p class="translation-attachment-status" data-translation-attachment-status role="status" aria-live="polite"></p></div>';
    const footer = '<span class="translation-attachment-file-name">' + escapeHtml(name || "本机 OCR") + '</span><button class="confirm" type="button" data-translation-attachment-action="translate-image-text">翻译并加入对话</button><button type="button" data-translation-attachment-action="cancel">取消</button>';
    setModal("图片文字翻译", "原图会保留在翻译对话中。当前没有完整可靠的位置坐标，译文会放在原图下方逐段对照。", content, footer);
    const editor = modal.querySelector("[data-translation-attachment-image-text]");
    const status = modal.querySelector("[data-translation-attachment-status]");
    editor.value = String(result.recognizedText || "").slice(0, MAX_TEXT_LENGTH);
    status.textContent = reason || "无法可靠定位全部文字；请校对识别内容，再按原图下方的文字对照查看译文。";
    // Opening the review must not summon the keyboard over the action buttons.
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, char => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[char]));
  }

  function showError(title, message) {
    setModal(title, message, "", '<button class="confirm" type="button" data-translation-attachment-action="cancel">知道了</button>');
  }

  function errorMessage(error) {
    switch (error && error.code) {
      case "image_ocr_no_text": return "图片中没有识别到文字。请换一张清晰、文字完整的图片。";
      case "image_ocr_unavailable": return "本机图片识别暂不可用，请更新觅音应用后重试。";
      case "image_ocr_failed": return "本机没有完成图片识别，请换一张清晰图片后重试。";
      case "image_invalid": return "无法打开这张图片。请选择常见格式且小于 20 MB 的图片。";
      case "image_ocr_geometry_missing": return "本机没有取得文字在图片中的位置，暂时无法生成对照图。请重新拍摄清晰、正向且文字完整的图片。";
      case "translation_preview_unavailable": return error && error.message ? String(error.message) : "本机翻译没有返回译文，请重试。";
      case "attachment_language_unavailable": return error && error.message ? String(error.message) : "无法读取当前翻译语言，请重新选择语言后重试。";
      case "empty_translation": return "本机离线翻译没有返回译文，请重试或裁剪图片后翻译。";
      case "model_missing": return "当前翻译方向的离线语言包尚未下载，请先下载后重试。";
      case "unsupported_language_pair": return "当前离线翻译暂不支持这组语言。";
      case "article_too_long":
      case "text_too_long": return "内容超过 10,000 个字符，请先删减后重试。";
      case "article_not_utf8": return "文件不是有效的 UTF-8 文本，请另存为 UTF-8 后重试。";
      case "article_format_unsupported": return "只支持 UTF-8 编码的 .txt 和 .md 文件。";
      case "attachment_picker_failed": return "系统相机或文件选择器暂时无法打开，请重试。";
      default: return error && error.message ? String(error.message) : "操作失败，请重试。";
    }
  }

  function openImageProgress(kind) {
    const source = kind === "camera" ? "相机" : "相册";
    setModal(
      "图片翻译",
      "选择图片后会自动进行本机文字识别和翻译；处理期间可以取消。",
      '<div class="translation-attachment-progress" data-translation-attachment-progress role="status" aria-live="polite"><span class="translation-attachment-spinner" aria-hidden="true"></span><p data-translation-attachment-status>正在等待图片选择与本机识别完成…</p></div>',
      '<button type="button" data-translation-attachment-action="cancel">取消</button>',
    );
    modalOwnershipAnchor = modal.querySelector("[data-translation-attachment-progress]");
    return modalRevision;
  }

  function showImageFailure(kind, title, message) {
    const canSelectText = imageRecognition?.geometryComplete && imageRecognition.blocks?.length;
    setModal(
      title,
      message,
      "",
      (canSelectText ? '<button class="confirm" type="button" data-translation-attachment-action="review-image">选择文字翻译</button>' : '') +
      '<button type="button" data-translation-attachment-action="retry-image">重新选择图片</button><button type="button" data-translation-attachment-action="cancel">关闭</button>',
    );
    modal.dataset.retryImageKind = kind;
  }

  async function translateRecognizedImage(revision, kind) {
    const status = modal.querySelector("[data-translation-attachment-status]");
    let sourceBlocks = [];
    try {
      const pair = await resolveCurrentPair(imageRecognition.recognizedText, { image: true });
      if (!isCurrentModal(revision)) return;
      const hasGeometry = imageRecognition.geometryComplete && imageRecognition.blocks.length > 0;
      if (!hasGeometry) {
        showImageFailure(kind, "无法生成译图", "未取得文字在图片中的可靠位置。请换一张清晰、正向的图片重试。");
        return;
      }
      sourceBlocks = groupAdjacentImageBlocks(imageRecognition.blocks);
      const translations = new Array(sourceBlocks.length);
      const blockPairs = sourceBlocks.map(block => imagePairForBlock(block.text, pair));
      const blockErrors = new Array(sourceBlocks.length);
      let nextIndex = 0;
      let completed = 0;
      if (status) status.textContent = "正在翻译图片文字 0/" + sourceBlocks.length + "…";
      const worker = async () => {
        while (nextIndex < sourceBlocks.length && isCurrentModal(revision)) {
          const index = nextIndex++;
          try {
            const block = sourceBlocks[index];
            const blockPair = blockPairs[index];
            if (isImageBlockAlreadyTarget(block.text, pair.targetTag)) {
              translations[index] = block.text;
              completed += 1;
              if (status) status.textContent = "正在翻译图片文字 " + completed + "/" + sourceBlocks.length + "…";
              continue;
            }
            let translatedText;
            try {
              translatedText = await translateImageBlock(block.text, blockPair, status);
            } catch (error) {
              const segments = block.segments;
              if (!Array.isArray(segments) || segments.length < 2) throw error;
              const translatedSegments = [];
              for (const segment of segments) {
                translatedSegments.push(isImageBlockAlreadyTarget(segment, pair.targetTag)
                  ? segment : await translateImageBlock(segment, imagePairForBlock(segment, pair), status));
              }
              translatedText = translatedSegments.join(" ");
            }
            if (!isCurrentModal(revision)) return;
            translations[index] = translatedText;
            completed += 1;
            if (status) status.textContent = "正在翻译图片文字 " + completed + "/" + sourceBlocks.length + "…";
          } catch (error) {
            if (["attachment_language_unavailable", "native_unavailable", "translation_unavailable", "request_timeout"].includes(error?.code)) throw error;
            blockErrors[index] = error;
            completed += 1;
            if (status) status.textContent = "正在翻译图片文字 " + completed + "/" + sourceBlocks.length + "…";
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(3, sourceBlocks.length) }, worker));
      if (!isCurrentModal(revision)) return;
      const failedCount = blockErrors.filter(Boolean).length;
      const translatedCount = sourceBlocks.filter((block, index) => !blockErrors[index] && !isImageBlockAlreadyTarget(block.text, pair.targetTag)).length;
      if (failedCount && translatedCount === 0) throw blockErrors.find(Boolean);
      const rows = sourceBlocks.map((block, index) => ({
        ...block,
        sourceText: block.text,
        sourceTag: blockPairs[index].sourceTag,
        sourceName: blockPairs[index].sourceName,
        translatedText: blockErrors[index] ? "【未译，原文保留】" : translations[index],
        untranslated: Boolean(blockErrors[index]),
        skipOverlay: Boolean(blockErrors[index]) || isImageBlockAlreadyTarget(block.text, pair.targetTag),
      }));
      if (status) status.textContent = "正在生成译图…";
      const translatedImage = await composeTranslatedImage(imageRecognition.previewDataUrl, rows);
      if (!isCurrentModal(revision)) return;
      if (!translatedImage) {
        showImageFailure(kind, "无法生成译图", "这张图片的文字位置无法用于原位替换。请裁剪或重新拍摄后重试。");
        return;
      }
      renderImageConversationCard(rows, pair, { hasGeometry: true, translatedImage, failedCount }, revision);
    } catch (error) {
      if (!isCurrentModal(revision)) return;
      showImageFailure(kind, "无法完成图片翻译", errorMessage(error));
    }
  }

  async function recognizeImage(kind, capturedImage) {
    if (document.documentElement.dataset.nativeHost !== "true" || !window.MiyinNativeBridge) {
      showError("图片识别暂不可用", "图片会在 Android 应用中通过本机离线 OCR 识别；当前网页预览不会读取或上传图片。");
      return;
    }
    imageRecognition = null;
    const revision = openImageProgress(kind);
    try {
      const selected = capturedImage || await window.MiyinNativeBridge.request("attachment.recognizeImage", { kind });
      if (!isCurrentModal(revision)) return;
      if (!selected || selected.canceled) {
        closeModal();
        return;
      }
      const status = modal.querySelector("[data-translation-attachment-status]");
      if (status) status.textContent = "图片文字已识别，正在自动翻译…";
      const preview = selected.previewDataUrl;
      const rawBlocks = Array.isArray(selected.blocks) ? selected.blocks : [];
      if (typeof preview !== "string" ||
          !JPEG_DATA_URL.test(preview) ||
          preview.length > MAX_IMAGE_PREVIEW_LENGTH) {
        showImageFailure(kind, "无法读取图片", errorMessage({ code: "image_invalid" }));
        return;
      }
      const providerOmitted = Number.isSafeInteger(Number(selected.omittedBlockCount))
        ? Math.max(0, Number(selected.omittedBlockCount))
        : 0;
      const parsedBlocks = rawBlocks.slice(0, MAX_OCR_BLOCK_COUNT + 1).map(block => ({
        text: String(block.text || "").trim(),
        segments: Array.isArray(block.segments) ? block.segments.filter(segment => typeof segment === "string" && segment.trim()).map(segment => segment.trim()) : null,
        left: normalizedCoordinate(block.left),
        top: normalizedCoordinate(block.top),
        right: normalizedCoordinate(block.right),
        bottom: normalizedCoordinate(block.bottom),
      }));
      const hasValidGeometry = block => Boolean(block.text && hasValidNormalizedBounds(block));
      const validBlocks = parsedBlocks.filter(hasValidGeometry);
      const blocks = validBlocks.slice(0, MAX_OCR_BLOCK_COUNT);
      const textBlocks = parsedBlocks.slice(0, MAX_OCR_BLOCK_COUNT).filter(block => block.text);
      const reportedTotal = Number.isSafeInteger(Number(selected.totalBlockCount))
        ? Math.max(0, Number(selected.totalBlockCount))
        : 0;
      const totalBlockCount = Math.max(
        reportedTotal,
        rawBlocks.length + providerOmitted,
        validBlocks.length + providerOmitted,
      );
      const geometryComplete = rawBlocks.length > 0 &&
        parsedBlocks.slice(0, Math.min(rawBlocks.length, MAX_OCR_BLOCK_COUNT)).every(hasValidGeometry);
      const omittedBlockCount = Math.max(
        providerOmitted,
        totalBlockCount - (geometryComplete ? blocks.length : rawBlocks.length),
      );
      const blockText = blocks.map(block => block.text).join("\n");
      const parsedText = textBlocks.map(block => block.text).join("\n");
      const recognizedText = geometryComplete && blockText
        ? blockText
        : String(selected.recognizedText || parsedText || blockText).trim();
      if (!recognizedText.trim()) {
        showImageFailure(kind, "没有识别到文字", "请换一张文字清楚、光线充足的图片后重试。");
        return;
      }
      if (recognizedText.length > MAX_TEXT_LENGTH) {
        showImageFailure(kind, "图片文字过多", "识别文字超过 10,000 个字符。请裁剪图片后重试。 ");
        return;
      }
      imageRecognition = {
        previewDataUrl: preview,
        name: selected.name || "已选择图片",
        width: Number(selected.width) || 1,
        height: Number(selected.height) || 1,
        recognizedText,
        textBlocks,
        totalBlockCount,
        omittedBlockCount,
        blocks,
        geometryComplete,
      };
      await translateRecognizedImage(revision, kind);
    } catch (error) {
      if (isCurrentModal(revision)) showImageFailure(kind, "图片识别失败", errorMessage(error));
    }
  }

  async function readArticleFile(file, targetEditor, statusNode) {
    const extension = String(file.name || "").split(".").pop().toLowerCase();
    if (extension !== "txt" && extension !== "md") {
      statusNode.textContent = "只支持 UTF-8 编码的 .txt 和 .md 文件。";
      return;
    }
    if (file.size > MAX_ARTICLE_BYTES) {
      statusNode.textContent = "文章超过 10,000 个字符，请选择较短的文件。";
      return;
    }
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      let text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
      if (!text.trim()) {
        statusNode.textContent = "所选文件没有可翻译的文字。";
        return;
      }
      if (text.length > MAX_TEXT_LENGTH) {
        statusNode.textContent = "文章超过 10,000 个字符，请删减后重试。";
        return;
      }
      targetEditor.value = text;
      currentArticleName = file.name || "";
      statusNode.textContent = "已在当前设备导入：" + file.name;
    } catch (_) {
      statusNode.textContent = "无法读取文件；请确认它是 UTF-8 编码的 .txt 或 .md。";
    }
  }

  async function importArticle() {
    const editor = modal.querySelector("[data-translation-attachment-editor]");
    const statusNode = modal.querySelector("[data-translation-attachment-status]");
    if (!editor || !statusNode) return;
    if (document.documentElement.dataset.nativeHost !== "true" || !window.MiyinNativeBridge) {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".txt,.md,text/plain,text/markdown";
      input.addEventListener("change", async () => {
        const file = input.files && input.files[0];
        if (file) await readArticleFile(file, editor, statusNode);
        input.value = "";
      }, { once: true });
      input.click();
      return;
    }
    const importButton = modal.querySelector('[data-translation-attachment-action="import-article"]');
    if (importButton) importButton.disabled = true;
    statusNode.textContent = "正在打开本机文件选择器…";
    try {
      const selected = await window.MiyinNativeBridge.request("attachment.pickArticle", {});
      if (selected && !selected.canceled) {
        const text = typeof selected.text === "string" ? selected.text : "";
        if (text.length > MAX_TEXT_LENGTH) {
          statusNode.textContent = "文章超过 10,000 个字符，请选择较短的文件。";
        } else if (!text.trim()) {
          statusNode.textContent = "所选文件没有可翻译的文字。";
        } else {
          editor.value = text;
          currentArticleName = selected.name || "";
          statusNode.textContent = "已在本机导入：" + (selected.name || "文章");
        }
      } else {
        statusNode.textContent = "未导入文件；已保留当前编辑内容。";
      }
    } catch (error) {
      statusNode.textContent = errorMessage(error);
    } finally {
      if (importButton) importButton.disabled = false;
    }
  }

  async function translateEditor() {
    const editor = modal.querySelector("[data-translation-attachment-editor]");
    const statusNode = modal.querySelector("[data-translation-attachment-status]");
    const text = editor ? editor.value.trim() : "";
    if (!text) {
      if (statusNode) statusNode.textContent = "请先粘贴、导入或核对要翻译的文字。";
      editor && editor.focus();
      return;
    }
    if (text.length > MAX_TEXT_LENGTH) {
      if (statusNode) statusNode.textContent = "内容超过 10,000 个字符，请删减后重试。";
      return;
    }
    const sourceLabel = modalTitle.textContent === "文章翻译" ? "文章原文" : "图片识别";
    const translate = window.MiyinTranslationAttachmentFlow && window.MiyinTranslationAttachmentFlow.translate;
    if (typeof translate !== "function") {
      if (statusNode) statusNode.textContent = "翻译服务尚未准备好，请稍后重试。";
      return;
    }
    const button = modal.querySelector('[data-translation-attachment-action="translate"]');
    if (button) button.disabled = true;
    try {
      const accepted = await translate(text, sourceLabel);
      if (accepted) closeModal();
    } catch (error) {
      if (statusNode) statusNode.textContent = errorMessage(error);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function normalizedCoordinate(value) {
    return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1
      ? value
      : null;
  }

  function hasValidNormalizedBounds(bounds) {
    if (!bounds) return false;
    const { left, top, right, bottom } = bounds;
    return [left, top, right, bottom].every(Number.isFinite) &&
      left >= 0 && left < right && right <= 1 &&
      top >= 0 && top < bottom && bottom <= 1;
  }

  function currentPairLabels() {
    return {
      sourceName: document.querySelector('#screen-home [data-action="source-language"]')?.textContent.trim() || "中文",
      targetName: document.querySelector('#screen-home [data-action="target-language"]')?.textContent.trim() || "English",
    };
  }

  function dominantImageLanguage(text) {
    const sample = String(text || "");
    // A short screenshot can contain only a word or two. Waiting for 20–30
    // letters leaves these images in the wrong translation direction.
    if (/[\u3040-\u30ff\u0400-\u052f\u0600-\u06ff\u0900-\u097f\u0e00-\u0e7f]/u.test(sample)) return null;
    const latin = (sample.match(/[A-Za-z]/g) || []).length;
    const han = (sample.match(/[\u3400-\u9fff]/g) || []).length;
    if (latin >= 4 && latin >= han * 2) return "en";
    if (han >= 2 && han >= latin * 2) return "zh-Hans";
    return null;
  }

  function isImageBlockAlreadyTarget(text, targetTag) {
    const latin = (String(text).match(/[A-Za-z]/g) || []).length;
    const han = (String(text).match(/[\u3400-\u9fff]/g) || []).length;
    if (!/[\p{L}]/u.test(String(text))) return true;
    if (distinctiveImageBlockLanguage(text) === targetTag) return true;
    if (/[\u3040-\u30ff\u0400-\u052f\u0600-\u06ff\u0900-\u097f\u0e00-\u0e7f]/u.test(String(text))) return false;
    if (targetTag === "zh-Hans") return han >= 2 && han >= latin;
    if (targetTag === "en") return latin >= 3 && han === 0;
    return false;
  }

  function distinctiveImageBlockLanguage(text) {
    const value = String(text || "");
    if (/[\u3040-\u30ff]/u.test(value)) return "ja";
    if (/[\uac00-\ud7af]/u.test(value)) return "ko";
    if (/[\u0e00-\u0e7f]/u.test(value)) return "th";
    if (/[\u0370-\u03ff]/u.test(value)) return "el";
    if (/[\u0590-\u05ff]/u.test(value)) return "he";
    if (/[\u0400-\u052f]/u.test(value)) return "ru";
    if (/[\u0600-\u06ff]/u.test(value)) return "ar";
    if (/[\u0900-\u097f]/u.test(value)) return "hi";
    return dominantImageLanguage(value);
  }

  function imagePairForBlock(text, selectedPair) {
    const detected = distinctiveImageBlockLanguage(text);
    if (!detected || detected === selectedPair.targetTag) return selectedPair;
    if (detected === selectedPair.sourceTag) return selectedPair;
    const names = { ja: "日语", ko: "韩语", th: "泰语", el: "希腊语", he: "希伯来语", ru: "俄语", ar: "阿拉伯语", hi: "印地语", en: "英语", "zh-Hans": "中文" };
    return { ...selectedPair, sourceTag: detected, sourceName: names[detected] || detected };
  }

  async function translateImageBlock(text, pair, status) {
    try {
      return await translatePreview(text, pair);
    } catch (error) {
      if (error?.code !== "model_missing") throw error;
      const key = pair.sourceTag + "→" + pair.targetTag;
      let download = imageModelDownloads.get(key);
      if (!download) {
        if (status) status.textContent = "正在通过 Wi-Fi 准备图片文字所需的离线语言包…";
        download = window.MiyinNativeBridge.request("translation.downloadModel", {
          sourceTag: pair.sourceTag,
          targetTag: pair.targetTag,
          wifiOnly: true,
        }).finally(() => imageModelDownloads.delete(key));
        imageModelDownloads.set(key, download);
      }
      await download;
      return translatePreview(text, pair);
    }
  }

  async function resolveCurrentPair(sampleText = "", options = {}) {
    if (!window.MiyinNativeBridge) throw Object.assign(new Error("本机翻译暂不可用"), { code: "translation_preview_unavailable" });
    if (!supportedLanguages) {
      supportedLanguages = window.MiyinNativeBridge.request("translation.supportedLanguages", {}).catch(error => {
        supportedLanguages = null;
        throw error;
      });
    }
    const languages = await supportedLanguages;
    const labels = currentPairLabels();
    const aliases = name => ({"中文": "简体中文", "中": "简体中文", "英": "English"}[name] || name);
    const find = name => {
      const normalized = aliases(name);
      const match = Array.isArray(languages) && languages.find(item => item && (item.name === normalized || item.name === name || item.tag === normalized));
      if (match && typeof match.tag === "string") return { tag: match.tag, name: match.name || name };
      if (normalized === "简体中文") return { tag: "zh-Hans", name: "简体中文" };
      if (normalized === "English") return { tag: "en", name: "English" };
      throw Object.assign(new Error("无法识别当前语言“" + name + "”。请重新选择翻译语言后重试。"), { code: "attachment_language_unavailable" });
    };
    let source = find(labels.sourceName);
    let target = find(labels.targetName);
    const dominant = options.image ? dominantImageLanguage(sampleText) : null;
    const resolvePair = window.MiyinTranslationAttachmentFlow?.resolvePair;
    if (dominant && [source.tag, target.tag].includes(dominant)) {
      if (dominant === target.tag) [source, target] = [target, source];
    } else if (sampleText.trim() && typeof resolvePair === "function") {
      const decision = resolvePair(sampleText);
      if (decision.status === "outside-pair" && !options.image) {
        throw Object.assign(new Error("识别到" + decision.detectedName + "文字，当前翻译方向不包含该语言。请先调整语言后重试。"), { code: "attachment_language_mismatch" });
      }
      if (decision.sourceTag === target.tag) [source, target] = [target, source];
    }
    return { sourceTag: source.tag, targetTag: target.tag, sourceName: source.name, targetName: target.name };
  }

  async function translatePreview(text, pair) {
    if (!window.MiyinNativeBridge || document.documentElement.dataset.nativeHost !== "true") {
      return "翻译预览仅在觅音 Android 应用中可用。";
    }
    const result = await window.MiyinNativeBridge.request("translation.preview", {
      text,
      sourceTag: pair.sourceTag,
      targetTag: pair.targetTag,
    });
    const translated = result && result.translatedText;
    if (typeof translated !== "string" || !translated.trim()) {
      throw Object.assign(new Error("本机离线翻译没有返回译文"), { code: "empty_translation" });
    }
    return translated.trim();
  }

  function splitArticleParagraphs(text) {
    return String(text || "")
      .replace(/\r\n?/g, "\n")
      .split(/\n[\t ]*\n+/)
      .map(paragraph => paragraph.trim())
      .filter(Boolean);
  }

  function groupAdjacentImageBlocks(blocks) {
    const ordered = blocks.slice().sort((a, b) => (a.top - b.top) || (a.left - b.left));
    const lines = [];
    for (const block of ordered) {
      const previous = lines[lines.length - 1];
      const previousHeight = previous ? previous.bottom - previous.top : 0;
      const blockHeight = block.bottom - block.top;
      const verticalOverlap = previous ? Math.min(previous.bottom, block.bottom) - Math.max(previous.top, block.top) : 0;
      const horizontalGap = previous ? block.left - previous.right : 1;
      const spansBlank = previous && (/_\s*$/.test(previous.text) || /^_/.test(block.text));
      if (previous && verticalOverlap > Math.min(previousHeight, blockHeight) * .5 &&
          horizontalGap >= -.005 && horizontalGap <= (spansBlank ? .2 : .085) &&
          previous.text.length + block.text.length < 260) {
        previous.segments = (previous.segments || [previous.text]).concat(block.segments || [block.text]);
        previous.text += " " + block.text;
        previous.left = Math.min(previous.left, block.left);
        previous.top = Math.min(previous.top, block.top);
        previous.right = Math.max(previous.right, block.right);
        previous.bottom = Math.max(previous.bottom, block.bottom);
      } else {
        lines.push({ ...block });
      }
    }
    const groups = [];
    for (const block of lines) {
      const previous = groups[groups.length - 1];
      const previousHeight = previous ? previous.bottom - previous.top : 0;
      const gap = previous ? block.top - previous.bottom : 1;
      const overlap = previous ? Math.min(previous.right, block.right) - Math.max(previous.left, block.left) : 0;
      const sameParagraph = previous &&
        previous._lineCount < 3 &&
        previous.text.length + block.text.length < 260 &&
        !/[.!?。！？:：]$/.test(previous.text) &&
        !/^\s*(?:\d+[.、]|[A-D][.、]|第[一二三四五六七八九十]+[部章节])/.test(block.text) &&
        gap >= -0.002 && gap <= Math.min(previousHeight * 1.2, .023) &&
        block.top > previous.top + previousHeight * .55 &&
        Math.abs(block.left - previous.left) <= .1 &&
        overlap > Math.min(previous.right - previous.left, block.right - block.left) * .25;
      if (sameParagraph) {
        previous.segments = (previous.segments || [previous.text]).concat(block.segments || [block.text]);
        previous.text += " " + block.text;
        previous.left = Math.min(previous.left, block.left);
        previous.top = Math.min(previous.top, block.top);
        previous.right = Math.max(previous.right, block.right);
        previous.bottom = Math.max(previous.bottom, block.bottom);
        previous._lineCount += 1;
      } else {
        groups.push({ ...block, _lineCount: 1 });
      }
    }
    return groups;
  }

  async function translateImageBlocks() {
    const revision = modalRevision;
    const status = modal.querySelector("[data-translation-attachment-status]");
    const editors = Array.from(modal.querySelectorAll("[data-translation-attachment-block]"));
    const blocks = imageRecognition && imageRecognition.blocks;
    if (!Array.isArray(blocks) || !blocks.length || editors.length !== blocks.length) {
      if (status) status.textContent = "没有可与图片位置对应的文字块，请重新选择图片。";
      return;
    }
    const texts = editors.map(editor => editor.value.trim());
    const included = Array.from(modal.querySelectorAll("[data-translation-attachment-include]"), input => input.checked);
    if (!included.some(Boolean)) {
      if (status) status.textContent = "请至少勾选一处要翻译的文字。";
      return;
    }
    if (texts.some((text, index) => included[index] && !text)) {
      if (status) status.textContent = "请先补全勾选位置的文字，或取消勾选。";
      return;
    }
    if (texts.join("\n").length > MAX_TEXT_LENGTH) {
      if (status) status.textContent = "识别文字超过 10,000 字，请删减后重试。";
      return;
    }
    const button = modal.querySelector('[data-translation-attachment-action="translate-image"]');
    if (button) button.disabled = true;
    try {
      const pair = await resolveCurrentPair(texts.filter((_, index) => included[index]).join("\n"), { image: true });
      if (!isCurrentModal(revision)) return;
      const translations = new Array(texts.length);
      const blockPairs = texts.map(text => imagePairForBlock(text, pair));
      const blockErrors = new Array(texts.length);
      let nextIndex = 0;
      let completed = 0;
      if (status) status.textContent = `正在翻译图片文字 0/${texts.length}…`;
      const worker = async () => {
        while (nextIndex < texts.length && isCurrentModal(revision)) {
          const index = nextIndex++;
          try {
            translations[index] = !included[index] || isImageBlockAlreadyTarget(texts[index], pair.targetTag)
              ? texts[index] : await translateImageBlock(texts[index], blockPairs[index], status);
          } catch (error) {
            if (["attachment_language_unavailable", "native_unavailable", "translation_unavailable", "request_timeout"].includes(error?.code)) throw error;
            blockErrors[index] = error;
          }
          completed += 1;
          if (status) status.textContent = `正在翻译图片文字 ${completed}/${texts.length}…`;
        }
      };
      await Promise.all(Array.from({ length: Math.min(3, texts.length) }, worker));
      if (!isCurrentModal(revision)) return;
      const failedCount = blockErrors.filter(Boolean).length;
      if (failedCount && included.every((selected, index) => !selected || blockErrors[index])) throw blockErrors.find(Boolean);
      imageRecognition.blocks = blocks.map((block, index) => ({ ...block, text: texts[index] }));
      imageRecognition.recognizedText = texts.join("\n");
      const rows = blocks.map((block, index) => ({
        ...block,
        sourceText: texts[index],
        sourceTag: blockPairs[index].sourceTag,
        sourceName: blockPairs[index].sourceName,
        translatedText: blockErrors[index] ? "【未译，原文保留】" : translations[index],
        untranslated: Boolean(blockErrors[index]),
        skipped: !included[index],
        skipOverlay: !included[index] || Boolean(blockErrors[index]) || isImageBlockAlreadyTarget(texts[index], pair.targetTag),
      }));
      if (status) status.textContent = "正在生成译图…";
      const translatedImage = await composeTranslatedImage(imageRecognition.previewDataUrl, rows);
      if (!isCurrentModal(revision)) return;
      renderImageConversationCard(rows, pair, { hasGeometry: true, translatedImage, failedCount }, revision);
    } catch (error) {
      if (isCurrentModal(revision) && status) status.textContent = errorMessage(error);
    } finally {
      if (isCurrentModal(revision) && button) button.disabled = false;
    }
  }

  // Produce actual image pixels. The source photo is never modified.
  async function composeTranslatedImage(sourceUrl, rows) {
    if (!rows.length || !rows.every(hasValidNormalizedBounds)) return null;
    const source = new Image();
    source.src = sourceUrl;
    await new Promise((resolve, reject) => {
      if (source.complete && source.naturalWidth) return resolve();
      source.onload = resolve;
      source.onerror = () => reject(new Error("图片无法生成译图"));
    });
    const canvas = document.createElement("canvas");
    canvas.width = source.naturalWidth;
    canvas.height = source.naturalHeight;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) throw new Error("当前设备无法生成译图");
    context.drawImage(source, 0, 0);
    const original = context.getImageData(0, 0, canvas.width, canvas.height).data;
    const width = canvas.width, height = canvas.height;
    const pixel = (x, y) => {
      const offset = (Math.max(0, Math.min(height - 1, y)) * width + Math.max(0, Math.min(width - 1, x))) * 4;
      return [original[offset], original[offset + 1], original[offset + 2]];
    };
    const ordered = rows.slice().sort((a, b) => (a.top - b.top) || (a.left - b.left));
    for (const row of ordered) {
      if (row.skipOverlay) continue;
      const x = Math.max(0, Math.floor(row.left * width));
      const y = Math.max(0, Math.floor(row.top * height));
      const right = Math.min(width, Math.ceil(row.right * width));
      const bottom = Math.min(height, Math.ceil(row.bottom * height));
      const boxWidth = right - x, boxHeight = bottom - y;
      if (boxWidth < 3 || boxHeight < 3) {
        row.unplacedOnImage = true;
        continue;
      }
      const overlapsAnotherBlock = rows.some(other => other !== row &&
        Math.min(row.right, other.right) > Math.max(row.left, other.left) &&
        Math.min(row.bottom, other.bottom) > Math.max(row.top, other.top));
      const text = String(row.translatedText || "").trim();
      const availableWidth = Math.max(1, boxWidth - 4);
      const availableHeight = Math.max(1, boxHeight - 2);
      let lines = [];
      let fontSize = Math.min(54, Math.floor(boxHeight * .88));
      let fits = false;
      for (; fontSize >= 7; fontSize -= 1) {
        context.font = `600 ${fontSize}px sans-serif`;
        lines = [];
        let line = "";
        for (const char of text) {
          if (char === "\n") { lines.push(line); line = ""; continue; }
          if (line && context.measureText(line + char).width > availableWidth) { lines.push(line); line = char; }
          else line += char;
        }
        if (line) lines.push(line);
        if (lines.every(part => context.measureText(part).width <= availableWidth) &&
            lines.length * fontSize * 1.08 <= availableHeight) {
          fits = true;
          break;
        }
      }
      // Keep the original pixels when geometry is unsafe or the complete
      // translation cannot fit; the full pair remains available below.
      if (!text || !fits || overlapsAnotherBlock) {
        row.unplacedOnImage = true;
        continue;
      }
      const samples = [];
      for (let index = 0; index < 12; index++) {
        const sx = x + Math.floor((boxWidth - 1) * index / 11);
        const sy = y + Math.floor((boxHeight - 1) * index / 11);
        samples.push(pixel(sx, y - 2), pixel(sx, bottom + 1), pixel(x - 2, sy), pixel(right + 1, sy));
      }
      const background = [0, 1, 2].map(channel => {
        const values = samples.map(sample => sample[channel]).sort((a, b) => a - b);
        return values[Math.floor(values.length / 2)];
      });
      // Reconstruct the text rectangle from its surrounding pixels. A flat
      // background can be replaced entirely, which also removes faint glyph
      // antialiasing; textured regions keep pixels close to the local estimate.
      const patch = context.getImageData(x, y, boxWidth, boxHeight);
      const variation = samples.reduce((sum, sample) =>
        sum + Math.max(...sample.map((value, channel) => Math.abs(value - background[channel]))), 0) / samples.length;
      const smoothBackground = variation < 18;
      const threshold = Math.max(16, Math.min(70, variation * 1.15));
      for (let py = 0; py < boxHeight; py++) {
        const verticalWeight = boxHeight < 2 ? .5 : py / (boxHeight - 1);
        const leftColor = pixel(x - 3, y + py);
        const rightColor = pixel(right + 2, y + py);
        for (let px = 0; px < boxWidth; px++) {
          const horizontalWeight = boxWidth < 2 ? .5 : px / (boxWidth - 1);
          const topColor = pixel(x + px, y - 3);
          const bottomColor = pixel(x + px, bottom + 2);
          const estimated = smoothBackground ? background : [0, 1, 2].map(channel =>
            Math.round((
              topColor[channel] * (1 - verticalWeight) + bottomColor[channel] * verticalWeight +
              leftColor[channel] * (1 - horizontalWeight) + rightColor[channel] * horizontalWeight
            ) / 2),
          );
          const offset = (py * boxWidth + px) * 4;
          const difference = Math.max(
            Math.abs(patch.data[offset] - estimated[0]),
            Math.abs(patch.data[offset + 1] - estimated[1]),
            Math.abs(patch.data[offset + 2] - estimated[2]),
          );
          if (!smoothBackground && difference < threshold) continue;
          patch.data[offset] = estimated[0];
          patch.data[offset + 1] = estimated[1];
          patch.data[offset + 2] = estimated[2];
        }
      }
      context.putImageData(patch, x, y);
      const corners = [pixel(x - 5, y - 5), pixel(right + 5, y - 5),
        pixel(x - 5, bottom + 5), pixel(right + 5, bottom + 5)];
      const cornerBrightness = corners.map(color => color[0] * .299 + color[1] * .587 + color[2] * .114)
        .sort((a, b) => a - b);
      const brightness = (cornerBrightness[1] + cornerBrightness[2]) / 2;
      context.fillStyle = brightness > 115 ? "#152536" : "#ffffff";
      context.textBaseline = "top";
      context.textAlign = "left";
      const lineHeight = fontSize * 1.08;
      const startY = y + Math.max(1, (boxHeight - lines.length * lineHeight) / 2);
      context.save();
      context.beginPath();
      context.rect(x, y, boxWidth, boxHeight);
      context.clip();
      lines.forEach((line, index) => context.fillText(line, x + 2, startY + index * lineHeight, availableWidth));
      context.restore();
    }
    for (const quality of [.94, .88, .8]) {
      const rendered = canvas.toDataURL("image/jpeg", quality);
      if (rendered.length <= 3900000) return rendered;
    }
    throw new Error("译图过大，无法安全保存；请选用文件较小的图片");
  }

  function appendConversationCard(card, expectedRevision) {
    if (expectedRevision !== undefined && !isCurrentModal(expectedRevision)) return false;
    const holder = document.querySelector("#home-transcript");
    if (!holder) {
      showError("无法显示翻译结果", "翻译已完成，但当前页面没有可用的对话区域。请返回翻译页后重试。");
      return false;
    }
    holder.appendChild(card);
    if (typeof card.getBoundingClientRect === "function" &&
        typeof holder.getBoundingClientRect === "function") {
      const cardTop = card.getBoundingClientRect().top - holder.getBoundingClientRect().top + holder.scrollTop;
      holder.scrollTop = card.scrollHeight > holder.clientHeight ? Math.max(0, cardTop - 8) : holder.scrollHeight;
    } else {
      holder.scrollTop = holder.scrollHeight;
    }
    closeModal();
    return true;
  }

  function persistAttachmentHistory(card, payload) {
    if (document.documentElement.dataset.nativeHost !== "true" || !window.MiyinNativeBridge) return;
    void window.MiyinNativeBridge.request("history.saveAttachment", payload)
      .then(result => {
        if (result?.saved !== true || !Number.isInteger(result.id)) throw new Error("历史记录未保存");
        card.dataset.nativeHistoryId = String(result.id);
        window.dispatchEvent(new Event("miyin:translation-history-changed"));
      })
      .catch(error => {
        const warning = makeTextNode("p", "translation-attachment-card-notice", "翻译已完成，但未能保存到本机历史。" + errorMessage(error));
        card.appendChild(warning);
      });
  }

  function makeTextNode(tagName, className, text) {
    const node = document.createElement(tagName);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function openImageViewer(card, initialMode = "zoom") {
    const sourceStage = card && card.querySelector?.(".translation-attachment-conversation-stage");
    const sourceImage = card?.tagName === "IMG" ? card : sourceStage?.querySelector("img");
    if (!sourceImage) return;
    const viewingOriginal = (sourceStage?.dataset.imageMode || sourceImage.dataset.imageMode) === "original";
    app.querySelector(".translation-attachment-image-viewer")?.remove();
    const previousFocus = document.activeElement;
    const viewer = makeTextNode("div", "translation-attachment-image-viewer");
    viewer.setAttribute("role", "dialog");
    viewer.setAttribute("aria-modal", "true");
    viewer.setAttribute("aria-label", initialMode === "compare" ? "原图与译图对照" : viewingOriginal ? "查看原图" : "查看译图");
    const header = makeTextNode("div", "translation-attachment-image-viewer-header");
    const title = makeTextNode("strong", "", initialMode === "compare" ? "原图与译图" : viewingOriginal ? "原图" : "译图");
    const zoomOut = makeTextNode("button", "", "−");
    const reset = makeTextNode("button", "", "适合屏幕");
    const zoomIn = makeTextNode("button", "", "+");
    const close = makeTextNode("button", "translation-attachment-image-viewer-close", "关闭");
    for (const button of [zoomOut, reset, zoomIn, close]) button.type = "button";
    zoomOut.setAttribute("aria-label", "缩小图片");
    zoomIn.setAttribute("aria-label", "放大图片");
    header.append(title, zoomOut, reset, zoomIn, close);
    const viewport = makeTextNode("div", "translation-attachment-image-viewport");
    viewport.setAttribute("aria-label", "双指缩放图片，单指移动图片");
    const stage = makeTextNode("div", "translation-attachment-conversation-stage translation-attachment-image-viewer-stage");
    const image = document.createElement("img");
    image.src = sourceImage.src;
    image.alt = initialMode === "compare" || viewingOriginal ? "原图" : "译图";
    image.draggable = false;
    stage.append(image);
    viewport.append(stage);
    const footer = makeTextNode("div", "translation-attachment-image-viewer-footer");
    footer.append(makeTextNode("span", "", "双指缩放 · 单指移动"));
    viewer.append(header, viewport, footer);
    app.append(viewer);

    let scale = 1;
    let offsetX = 0;
    let offsetY = 0;
    let fitWidth = 1;
    let fitHeight = 1;
    const pointers = new Map();
    let dragStart = null;
    let pinchStart = null;
    const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
    const render = () => {
      const maxX = Math.max(0, (fitWidth * scale - viewport.clientWidth) / 2);
      const maxY = Math.max(0, (fitHeight * scale - viewport.clientHeight) / 2);
      offsetX = clamp(offsetX, -maxX, maxX);
      offsetY = clamp(offsetY, -maxY, maxY);
      stage.style.transform = `translate(-50%, -50%) translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
      reset.disabled = scale === 1 && offsetX === 0 && offsetY === 0;
    };
    const fit = () => {
      if (!image.naturalWidth || !image.naturalHeight || !viewport.clientWidth || !viewport.clientHeight) return;
      const factor = Math.min(viewport.clientWidth / image.naturalWidth, viewport.clientHeight / image.naturalHeight);
      fitWidth = image.naturalWidth * factor;
      fitHeight = image.naturalHeight * factor;
      stage.style.width = `${fitWidth}px`;
      stage.style.height = `${fitHeight}px`;
      render();
    };
    const setScale = (nextScale, clientX, clientY) => {
      const oldScale = scale;
      scale = clamp(nextScale, 1, 5);
      const rect = viewport.getBoundingClientRect();
      const pivotX = clientX - rect.left - rect.width / 2;
      const pivotY = clientY - rect.top - rect.height / 2;
      offsetX = pivotX - (pivotX - offsetX) * scale / oldScale;
      offsetY = pivotY - (pivotY - offsetY) * scale / oldScale;
      render();
    };
    const resetView = () => { scale = 1; offsetX = 0; offsetY = 0; render(); };
    const closeViewer = () => {
      window.removeEventListener("resize", fit);
      document.removeEventListener("keydown", onKeydown, true);
      viewer.remove();
      if (previousFocus && typeof previousFocus.focus === "function") previousFocus.focus();
    };
    const onKeydown = event => {
      if (event.key === "Escape") { event.preventDefault(); event.stopImmediatePropagation(); closeViewer(); }
      else if (event.key === "Tab") {
        const buttons = Array.from(viewer.querySelectorAll("button:not(:disabled), input:not([hidden])"));
        if (!buttons.length) return;
        const first = buttons[0];
        const last = buttons[buttons.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    };
    const pointerPair = () => Array.from(pointers.values()).slice(0, 2);
    const startGesture = () => {
      const pair = pointerPair();
      if (pair.length === 2) {
        const [first, second] = pair;
        pinchStart = {
          distance: Math.hypot(first.x - second.x, first.y - second.y),
          scale,
          x: offsetX,
          y: offsetY,
          centerX: (first.x + second.x) / 2,
          centerY: (first.y + second.y) / 2,
        };
        dragStart = null;
      } else if (pair.length === 1) {
        dragStart = { x: pair[0].x, y: pair[0].y, offsetX, offsetY };
        pinchStart = null;
      }
    };
    viewport.addEventListener("pointerdown", event => {
      event.preventDefault();
      viewport.setPointerCapture(event.pointerId);
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      startGesture();
    });
    viewport.addEventListener("pointermove", event => {
      if (!pointers.has(event.pointerId)) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      const pair = pointerPair();
      if (pair.length === 2 && pinchStart) {
        const [first, second] = pair;
        const distance = Math.hypot(first.x - second.x, first.y - second.y);
        if (pinchStart.distance > 0) {
          scale = pinchStart.scale;
          offsetX = pinchStart.x;
          offsetY = pinchStart.y;
          setScale(pinchStart.scale * distance / pinchStart.distance, pinchStart.centerX, pinchStart.centerY);
          offsetX += (first.x + second.x) / 2 - pinchStart.centerX;
          offsetY += (first.y + second.y) / 2 - pinchStart.centerY;
          render();
        }
      } else if (pair.length === 1 && dragStart) {
        offsetX = dragStart.offsetX + pair[0].x - dragStart.x;
        offsetY = dragStart.offsetY + pair[0].y - dragStart.y;
        render();
      }
    });
    const endPointer = event => {
      pointers.delete(event.pointerId);
      startGesture();
    };
    viewport.addEventListener("pointerup", endPointer);
    viewport.addEventListener("pointercancel", endPointer);
    viewport.addEventListener("wheel", event => {
      event.preventDefault();
      setScale(scale * (event.deltaY < 0 ? 1.15 : 1 / 1.15), event.clientX, event.clientY);
    }, { passive: false });
    zoomOut.addEventListener("click", () => setScale(scale / 1.5, viewport.getBoundingClientRect().left + viewport.clientWidth / 2, viewport.getBoundingClientRect().top + viewport.clientHeight / 2));
    zoomIn.addEventListener("click", () => setScale(scale * 1.5, viewport.getBoundingClientRect().left + viewport.clientWidth / 2, viewport.getBoundingClientRect().top + viewport.clientHeight / 2));
    reset.addEventListener("click", resetView);
    close.addEventListener("click", closeViewer);
    document.addEventListener("keydown", onKeydown, true);
    window.addEventListener("resize", fit);
    if (image.complete) requestAnimationFrame(fit);
    else image.addEventListener("load", fit, { once: true });
    close.focus();

    if (initialMode === "compare" && sourceImage.dataset.translatedSrc && sourceImage.dataset.originalSrc) {
      image.src = sourceImage.dataset.originalSrc;
      const translatedImage = document.createElement("img");
      translatedImage.src = sourceImage.dataset.translatedSrc;
      translatedImage.alt = "译图";
      translatedImage.draggable = false;
      translatedImage.className = "translation-attachment-compare-translated";
      const divider = makeTextNode("span", "translation-attachment-compare-divider");
      divider.setAttribute("aria-hidden", "true");
      stage.replaceChildren(image, translatedImage, divider);
      stage.classList.add("translation-attachment-compare-stage");
      const controls = makeTextNode("div", "translation-attachment-view-toggle");
      const compare = makeTextNode("button", "", "对照");
      const translated = makeTextNode("button", "", "译图");
      const original = makeTextNode("button", "", "原图");
      for (const button of [compare, translated, original]) button.type = "button";
      controls.append(compare, translated, original);
      const range = document.createElement("input");
      range.className = "translation-attachment-compare-range";
      range.type = "range";
      range.min = "0";
      range.max = "100";
      range.value = "50";
      range.setAttribute("aria-label", "原图与译图对照位置");
      const choose = mode => {
        stage.dataset.imageMode = mode;
        range.hidden = mode !== "compare";
        compare.setAttribute("aria-pressed", String(mode === "compare"));
        translated.setAttribute("aria-pressed", String(mode === "translated"));
        original.setAttribute("aria-pressed", String(mode === "original"));
      };
      compare.addEventListener("click", () => choose("compare"));
      translated.addEventListener("click", () => choose("translated"));
      original.addEventListener("click", () => choose("original"));
      range.addEventListener("input", () => stage.style.setProperty("--translation-compare-split", `${range.value}%`));
      footer.replaceChildren(controls, range);
      choose("compare");
      if (image.complete) requestAnimationFrame(fit);
      else image.addEventListener("load", fit, { once: true });
    }
  }
  window.miyinOpenImageViewer = openImageViewer;

  function renderImageConversationCard(rows, pair, options = {}, expectedRevision) {
    if (expectedRevision !== undefined && !isCurrentModal(expectedRevision)) return false;
    const hasGeometry = options.hasGeometry === true && imageRecognition.geometryComplete;
    const overlayAvailable = hasGeometry && Boolean(options.translatedImage);
    if (!overlayAvailable) {
      showError("无法生成译图", options.failureMessage || "未能在图片原位置替换文字，请换一张清晰图片重试。");
      return false;
    }
    const card = makeTextNode("article", "translation-attachment-conversation-card translation-attachment-image-card");
    const imageResultId = String(++nextImageResultId);
    rememberBoundedResult(imageResults, imageResultId, {
      ...imageRecognition,
      blocks: Array.isArray(imageRecognition.blocks) ? imageRecognition.blocks.map(block => ({ ...block })) : [],
    }, MAX_IMAGE_RESULT_REFERENCES);
    card.dataset.imageResultId = imageResultId;
    card.setAttribute("aria-label", "图片翻译对照结果");
    const header = makeTextNode("div", "translation-attachment-card-header");
    const title = makeTextNode("strong", "", options.failureMessage ? "图片翻译未完成" : options.failedCount ? "图片部分翻译" : "图片翻译");
    const shortLanguage = name => ({ 中文: "中", 简体中文: "中", 繁体中文: "繁", 英语: "英", 日语: "日", 法语: "法", 俄语: "俄", 韩语: "韩", English: "英", Chinese: "中" })[name] || String(name).replace(/语$/, "").slice(0, 2);
    const rowSources = [...new Set(rows.filter(row => !row.skipOverlay).map(row => row.sourceName || pair.sourceName))];
    const displayedSource = rowSources.length > 1 ? "多语" : rowSources[0] || pair.sourceName;
    const details = makeTextNode("small", "", shortLanguage(displayedSource) + "→" + shortLanguage(pair.targetName));
    details.title = displayedSource + " → " + pair.targetName;
    header.append(title, details);
    card.appendChild(header);

    const figure = document.createElement("figure");
    figure.className = "translation-attachment-conversation-figure";
    const stage = document.createElement("div");
    stage.className = "translation-attachment-conversation-stage";
    stage.dataset.imageMode = overlayAvailable ? "translated" : "original";
    const image = document.createElement("img");
    image.dataset.originalSrc = imageRecognition.previewDataUrl;
    if (overlayAvailable) image.dataset.translatedSrc = options.translatedImage;
    image.src = overlayAvailable ? options.translatedImage : imageRecognition.previewDataUrl;
    image.alt = overlayAvailable ? "文字已替换的译图" : "图片翻译原图";
    stage.appendChild(image);
    const expand = makeTextNode("button", "translation-attachment-image-expand");
    expand.type = "button";
    expand.dataset.translationAttachmentAction = "view-image";
    expand.setAttribute("aria-label", "点击图片放大查看");
    stage.appendChild(expand);
    const overlayButtons = [];
    if (overlayAvailable && !options.translatedImage) {
      const overlay = document.createElement("div");
      overlay.className = "translation-attachment-conversation-labels";
      rows.forEach((row, index) => {
        const label = document.createElement("button");
        label.type = "button";
        label.className = "translation-attachment-conversation-label";
        label.style.left = (row.left * 100) + "%";
        label.style.top = (row.top * 100) + "%";
        label.style.width = ((row.right - row.left) * 100) + "%";
        label.style.height = ((row.bottom - row.top) * 100) + "%";
        label.title = "原文：" + row.sourceText + "；译文：" + row.translatedText;
        label.setAttribute("aria-label", "第 " + (index + 1) + " 处译文：" + row.translatedText);
        label.textContent = row.translatedText;
        overlay.appendChild(label);
        overlayButtons.push(label);
      });
      stage.appendChild(overlay);
    }
    figure.appendChild(stage);
    card.appendChild(figure);

    if (overlayAvailable) {
      const controls = makeTextNode("div", "translation-attachment-view-toggle");
      const originalButton = makeTextNode("button", "", "原图");
      const translatedButton = makeTextNode("button", "", "译图");
      const compareButton = makeTextNode("button", "", "对照");
      originalButton.type = translatedButton.type = compareButton.type = "button";
      compareButton.dataset.translationAttachmentAction = "compare-image";
      compareButton.setAttribute("aria-label", "对照原图与译图");
      originalButton.setAttribute("aria-pressed", "false");
      translatedButton.setAttribute("aria-pressed", "true");
      originalButton.addEventListener("click", () => {
        stage.dataset.imageMode = "original";
        image.src = image.dataset.originalSrc;
        image.alt = "图片原图";
        originalButton.setAttribute("aria-pressed", "true");
        translatedButton.setAttribute("aria-pressed", "false");
      });
      translatedButton.addEventListener("click", () => {
        stage.dataset.imageMode = "translated";
        image.src = image.dataset.translatedSrc;
        image.alt = "文字已替换的译图";
        originalButton.setAttribute("aria-pressed", "false");
        translatedButton.setAttribute("aria-pressed", "true");
      });
      controls.append(originalButton, translatedButton, compareButton);
      header.appendChild(controls);
    }

    const notice = makeTextNode("p", "translation-attachment-card-notice");
    if (options.failedCount) {
      notice.textContent = options.failedCount + " 处文字未能译出，译图保留了这些位置的原文；可在下方原文与译文中查看标记。";
    } else if (options.failureMessage) {
      notice.textContent = "原图和识别文字已保留。" + options.failureMessage;
    } else if (!hasGeometry) {
      notice.textContent = options.reason || "没有完整可靠的位置坐标；译文已放在原图下方逐条对照。";
    } else if (!overlayAvailable && imageRecognition.omittedBlockCount > 0) {
      notice.textContent = "识别区域过密或彼此重叠；已在原图下方对照前 " + rows.length + " 处文字，另有 " + imageRecognition.omittedBlockCount + " 处未纳入翻译。";
    } else if (!overlayAvailable) {
      notice.textContent = "识别区域过密或彼此重叠；为避免译文错位，改为在原图下方逐条对照。";
    } else if (imageRecognition.omittedBlockCount > 0) {
      notice.textContent = "已对照前 " + rows.length + " 处文字，另有 " + imageRecognition.omittedBlockCount + " 处未纳入翻译。建议裁剪图片后补译。";
    }
    const unplacedCount = rows.filter(row => row.unplacedOnImage).length;
    if (unplacedCount) notice.textContent += (notice.textContent ? " " : "") + unplacedCount + " 处译文因空间不足或区域重叠未覆盖原图；完整译文见下方“查看原文与译文”。";
    if (notice.textContent) card.appendChild(notice);

    const comparisonDisclosure = makeTextNode("details", "translation-attachment-comparison-disclosure");
    const comparisonSummary = makeTextNode("summary", "", "查看原文与译文");
    comparisonDisclosure.appendChild(comparisonSummary);
    const comparisons = makeTextNode("div", "translation-attachment-conversation-pairs");
    const heading = makeTextNode("strong", "translation-attachment-pairs-heading", "原文与译文");
    comparisons.appendChild(heading);
    let selectedRow = null;
    const comparisonButtons = [];
    const selectRow = index => {
      comparisonButtons.forEach((button, buttonIndex) => {
        button.classList.toggle("is-selected", buttonIndex === index);
        button.setAttribute("aria-pressed", buttonIndex === index ? "true" : "false");
      });
      overlayButtons.forEach((button, buttonIndex) => button.classList.toggle("is-selected", buttonIndex === index));
      selectedRow = index;
      card.dataset.selectedComparisonIndex = String(index);
      if (overlayAvailable) stage.dataset.selectedIndex = String(index);
    };
    overlayButtons.forEach((button, index) => button.addEventListener("click", () => selectRow(index)));
    rows.forEach((row, index) => {
      const item = document.createElement("button");
      item.type = "button";
      item.className = "translation-attachment-conversation-pair";
      item.setAttribute("aria-pressed", "false");
      const source = makeTextNode("span", "translation-attachment-pair-source", row.sourceText);
      const translated = makeTextNode("span", "translation-attachment-pair-translation", row.translatedText);
      const sourceLabel = makeTextNode("small", "", "原文 · " + (row.sourceName || pair.sourceName));
      const translatedLabel = makeTextNode("small", "", row.skipped ? "未选择 · 原文保留" : row.untranslated ? "未译 · 原文保留" : "译文 · " + pair.targetName);
      item.append(sourceLabel, source, translatedLabel, translated);
      item.addEventListener("click", () => selectRow(index));
      comparisonButtons.push(item);
      comparisons.appendChild(item);
    });
    comparisonDisclosure.appendChild(comparisons);
    const actions = makeTextNode("div", "translation-attachment-card-actions translation-attachment-image-actions");
    const review = makeTextNode("button", "", "查看原文与译文");
    review.type = "button";
    review.setAttribute("aria-expanded", "false");
    review.addEventListener("click", () => {
      comparisonDisclosure.open = !comparisonDisclosure.open;
      review.setAttribute("aria-expanded", String(comparisonDisclosure.open));
    });
    actions.appendChild(review);
    if (options.failureMessage) {
      const retry = makeTextNode("button", "", "重试翻译");
      retry.type = "button";
      retry.dataset.translationAttachmentAction = "retry-image-result";
      actions.appendChild(retry);
    }
    const edit = makeTextNode("button", "", "选择/校对文字");
    edit.type = "button";
    edit.dataset.translationAttachmentAction = "edit-image";
    actions.appendChild(edit);
    const save = makeTextNode("button", "translation-attachment-save-icon", "↓");
    save.type = "button";
    save.dataset.translationAttachmentAction = "save-image";
    save.setAttribute("aria-label", "保存译图到相册");
    save.title = "保存译图";
    actions.appendChild(save);
    card.appendChild(actions);
    card.appendChild(comparisonDisclosure);
    card.dataset.selectedComparisonIndex = selectedRow === null ? "" : String(selectedRow);
    const appended = appendConversationCard(card, expectedRevision);
    if (appended) persistAttachmentHistory(card, {
      kind: "image",
      name: imageRecognition.name || "图片翻译",
      sourceTag: pair.sourceTag,
      targetTag: pair.targetTag,
      rows: rows.map(row => ({ sourceText: row.sourceText, translatedText: row.translatedText })),
      originalImage: imageRecognition.previewDataUrl,
      translatedImage: options.translatedImage,
    });
    return appended;
  }

  async function translateUnlocatedImage() {
    const revision = modalRevision;
    const editor = modal.querySelector("[data-translation-attachment-image-text]");
    const status = modal.querySelector("[data-translation-attachment-status]");
    const text = editor ? editor.value.trim() : "";
    if (!text) {
      if (status) status.textContent = "请先核对图片识别文字。";
      editor && editor.focus();
      return;
    }
    if (text.length > MAX_TEXT_LENGTH) {
      if (status) status.textContent = "识别文字超过 10,000 字，请删减后重试。";
      return;
    }
    const button = modal.querySelector('[data-translation-attachment-action="translate-image-text"]');
    if (button) button.disabled = true;
    try {
      const pair = await resolveCurrentPair(text);
      if (!isCurrentModal(revision)) return;
      if (status) status.textContent = "正在翻译图片文字…";
      const translatedText = await translatePreview(text, pair);
      if (!isCurrentModal(revision)) return;
      imageRecognition.recognizedText = text;
      renderImageConversationCard([{ sourceText: text, translatedText }], pair, {
        hasGeometry: false,
        reason: "没有完整可靠的位置坐标；原图已保留，识别文字与译文按块显示在下方。",
      }, revision);
    } catch (error) {
      if (isCurrentModal(revision) && status) status.textContent = errorMessage(error);
    } finally {
      if (isCurrentModal(revision) && button) button.disabled = false;
    }
  }

  async function translateArticleReader() {
    const revision = modalRevision;
    const editor = modal.querySelector("[data-translation-attachment-editor]");
    const status = modal.querySelector("[data-translation-attachment-status]");
    const paragraphs = splitArticleParagraphs(editor ? editor.value : "");
    if (!paragraphs.length) {
      if (status) status.textContent = "请先粘贴或导入文章内容。";
      return;
    }
    if (paragraphs.join("\n\n").length > MAX_TEXT_LENGTH) {
      if (status) status.textContent = "文章超过 10,000 个字符，请删减后重试。";
      return;
    }
    const button = modal.querySelector('[data-translation-attachment-action="translate"]');
    if (button) button.disabled = true;
    try {
      const pair = await resolveCurrentPair(paragraphs.join("\n\n"));
      if (!isCurrentModal(revision)) return;
      const rows = new Array(paragraphs.length);
      let nextIndex = 0;
      let completed = 0;
      let failure = null;
      if (status) status.textContent = `正在翻译文章 0/${paragraphs.length} 段…`;
      const worker = async () => {
        while (!failure && nextIndex < paragraphs.length && isCurrentModal(revision)) {
          const index = nextIndex++;
          try {
            const translatedText = await translatePreview(paragraphs[index], pair);
            if (!isCurrentModal(revision) || failure) return;
            rows[index] = { sourceText: paragraphs[index], translatedText };
            completed += 1;
            if (status) status.textContent = `正在翻译文章 ${completed}/${paragraphs.length} 段…`;
          } catch (error) {
            failure = failure || error;
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(3, paragraphs.length) }, worker));
      if (!isCurrentModal(revision)) return;
      if (failure) throw failure;
      renderArticleReader(rows, pair, revision);
    } catch (error) {
      if (isCurrentModal(revision) && status) status.textContent = errorMessage(error);
    } finally {
      if (isCurrentModal(revision) && button) button.disabled = false;
    }
  }

  function renderArticleReader(rows, pair, expectedRevision) {
    if (expectedRevision !== undefined && !isCurrentModal(expectedRevision)) return;
    lastArticleRows = rows.map(row => ({ ...row }));
    const card = makeTextNode("article", "translation-attachment-conversation-card translation-attachment-article-card");
    const articleResultId = String(++nextArticleResultId);
    rememberBoundedResult(articleResults, articleResultId, {
      rows: lastArticleRows.map(row => ({ ...row })),
      name: currentArticleName,
    }, MAX_ARTICLE_RESULT_REFERENCES);
    card.dataset.articleResultId = articleResultId;
    card.setAttribute("aria-label", "文章逐段翻译对照");
    const header = makeTextNode("div", "translation-attachment-card-header");
    const title = makeTextNode("strong", "", "文章翻译");
    const details = makeTextNode("small", "", (currentArticleName ? currentArticleName + " · " : "") + pair.sourceName + " → " + pair.targetName);
    header.append(title, details);
    card.appendChild(header);
    const reader = makeTextNode("div", "translation-attachment-reader");
    rows.forEach((row, index) => {
      const section = document.createElement("section");
      section.className = "translation-attachment-paragraph";
      const sourceHeading = document.createElement("small");
      sourceHeading.textContent = "原文 · " + pair.sourceName;
      const source = document.createElement("p");
      source.textContent = row.sourceText;
      const translatedHeading = document.createElement("small");
      translatedHeading.textContent = "译文 · " + pair.targetName;
      const translated = document.createElement("p");
      translated.textContent = row.translatedText;
      section.dataset.paragraph = String(index);
      section.append(sourceHeading, source, translatedHeading, translated);
      reader.appendChild(section);
    });
    card.appendChild(reader);
    const actions = makeTextNode("div", "translation-attachment-card-actions");
    const edit = makeTextNode("button", "", "修改原文");
    edit.type = "button";
    edit.dataset.translationAttachmentAction = "edit-article";
    actions.appendChild(edit);
    card.appendChild(actions);
    if (appendConversationCard(card, expectedRevision)) persistAttachmentHistory(card, {
      kind: "article",
      name: currentArticleName || "文章翻译",
      sourceTag: pair.sourceTag,
      targetTag: pair.targetTag,
      rows: rows.map(row => ({ sourceText: row.sourceText, translatedText: row.translatedText })),
    });
  }

  function handleAttachmentAction(event) {
    const target = event.target instanceof Element ? event.target : null;
    const actionButton = target && target.closest("[data-translation-attachment-action]");
    if (actionButton) {
      const action = actionButton.dataset.translationAttachmentAction;
      event.preventDefault();
      event.stopImmediatePropagation();
      if (action === "cancel") closeModal();
      else if (action === "review-image" && imageRecognition?.geometryComplete) {
        openImageReview(imageRecognition, imageRecognition.name || "已选择图片");
      }
      else if (action === "camera" || action === "photo") {
        void recognizeImage(action === "camera" ? "camera" : "image");
      } else if (action === "retry-image") {
        void recognizeImage(modal.dataset.retryImageKind === "camera" ? "camera" : "image");
      } else if (action === "article") {
        openEditor("article", "", "", "");
      } else if (action === "import-article") {
        void importArticle();
      } else if (action === "translate") {
        if (modalTitle.textContent === "文章翻译") void translateArticleReader();
        else void translateEditor();
      } else if (action === "translate-image") {
        void translateImageBlocks();
      } else if (action === "translate-image-text") {
        void translateUnlocatedImage();
      } else if (action === "edit-image") {
        const imageCard = actionButton.closest(".translation-attachment-image-card");
        const selectedImage = imageResults.get(imageCard && imageCard.dataset.imageResultId);
        if (selectedImage) {
          imageRecognition = selectedImage;
          if (selectedImage.geometryComplete) openImageReview(selectedImage, selectedImage.name || "已选择图片");
          else openImageTextReview(selectedImage, selectedImage.name || "已选择图片");
        } else {
          showError("图片内容已释放", "这张图片的可编辑缓存已回收；对话里的翻译结果仍可查看。请重新选择图片并翻译。 ");
        }
      } else if (action === "view-image") {
        openImageViewer(actionButton.closest(".translation-attachment-image-card"));
      } else if (action === "compare-image") {
        openImageViewer(actionButton.closest(".translation-attachment-image-card"), "compare");
      } else if (action === "save-image") {
        const card = actionButton.closest(".translation-attachment-image-card");
        const dataUrl = card && card.querySelector(".translation-attachment-conversation-stage img")?.dataset.translatedSrc;
        if (dataUrl && window.MiyinNativeBridge) {
          actionButton.disabled = true;
          actionButton.setAttribute("aria-label", "正在保存译图");
          void window.MiyinNativeBridge.request("attachment.saveTranslatedImage", { dataUrl })
            .then(() => { actionButton.textContent = "✓"; actionButton.setAttribute("aria-label", "已保存到相册"); actionButton.title = "已保存到相册"; })
            .catch(error => { actionButton.textContent = "↓"; actionButton.setAttribute("aria-label", "重试保存译图"); actionButton.title = "重试保存译图"; showError("保存译图失败", errorMessage(error)); })
            .finally(() => { actionButton.disabled = false; });
        }
      } else if (action === "retry-image-result") {
        const imageCard = actionButton.closest(".translation-attachment-image-card");
        const selectedImage = imageResults.get(imageCard && imageCard.dataset.imageResultId);
        if (selectedImage) {
          imageRecognition = selectedImage;
          const revision = openImageProgress("image");
          const status = modal.querySelector("[data-translation-attachment-status]");
          if (status) status.textContent = "正在重新翻译已识别的图片文字…";
          void translateRecognizedImage(revision, "image");
        } else {
          showError("图片内容已释放", "这张图片的重试缓存已回收；请重新选择图片并翻译。");
        }
      } else if (action === "edit-article") {
        const articleCard = actionButton.closest(".translation-attachment-article-card");
        const selectedArticle = articleResults.get(articleCard && articleCard.dataset.articleResultId);
        if (selectedArticle) {
          const text = selectedArticle.rows.map(row => row.sourceText).join("\n\n");
          currentArticleName = selectedArticle.name;
          openEditor("article", text, "可修改后重新翻译", currentArticleName);
        } else {
          showError("文章内容已释放", "这篇文章的可编辑缓存已回收；对话里的段落对照仍可查看。请重新粘贴或导入文章。");
        }
      }
      return;
    }

    if (target && target.closest('button[data-action="open-input-tools"]')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      openMenu();
    }
  }

  document.addEventListener("click", handleAttachmentAction, true);
  window.addEventListener("miyin:screenshot-ready", event => {
    void recognizeImage("screenshot", event.detail);
  });
  window.addEventListener("miyin:screenshot-error", event => {
    showError("截屏翻译失败", String(event.detail || "当前画面未能截取，请重试。"));
  });
  document.addEventListener("click", event => {
    if (event.target === modal && modal.classList.contains("open")) closeModal();
  }, true);
})();
