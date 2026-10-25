(() => {
  "use strict";

  const app = document.querySelector("#app");
  const homeInput = document.querySelector("#translation-input");
  const entry = document.querySelector("#screen-home .text-entry");
  if (!app || !homeInput || !entry) return;
  document.title = "觅音";

  const storagePrefix = "miyin.mobile.v6.translation-ui.";
  const read = (key, fallback) => {
    try {
      const value = localStorage.getItem(storagePrefix + key);
      return value == null ? fallback : JSON.parse(value);
    } catch {
      return fallback;
    }
  };
  const write = (key, value) => {
    try { localStorage.setItem(storagePrefix + key, JSON.stringify(value)); } catch { /* Keep UI usable when storage is unavailable. */ }
  };
  const icons = {
    arrow: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m14 5-7 7 7 7M7 12h13"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="8" r="3.2"/><path d="M5 20c.4-3.5 2.8-5.5 7-5.5s6.6 2 7 5.5"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="10.8" cy="10.8" r="6.8"/><path d="m16 16 4 4"/></svg>',
    book: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H20v17H7.5A2.5 2.5 0 0 0 5 21.5z"/><path d="M5 4.5v17M9 7h7m-7 4h6"/></svg>',
    paperclip: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m8 12.5 6.7-6.7a3.1 3.1 0 0 1 4.4 4.4l-8.9 8.9a5 5 0 0 1-7.1-7.1l8.5-8.5"/></svg>',
    info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/></svg>',
    chevron: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>'
  };
  const header = (backScreen, backLabel) => `
    <header class="topbar">
      <button class="top-icon" type="button" data-screen="${backScreen}" data-v6-nav-back aria-label="${backLabel}">${icons.arrow}</button>
      <div class="top-brand"><strong>觅音</strong></div>
      <button class="avatar-button" type="button" data-screen="settings" aria-label="用户与设置">${icons.user}</button>
    </header>`;

  app.insertAdjacentHTML("beforeend", `
    <section class="screen v6-app-screen" id="screen-dictionary" aria-label="词典查词">
      ${header("home", "返回翻译")}
      <main class="v6-app-content">
        <h1 class="v6-page-heading">词典</h1>
        <p class="v6-page-subtitle">输入中文或英语词条，觅音会自动匹配查询方式。</p>
        <label class="v6-dictionary-select-label" for="v6-dictionary-package">选择词典</label>
        <div class="v6-dictionary-select-wrap">
          <select class="v6-dictionary-select" id="v6-dictionary-package" data-v6-dictionary-package aria-label="选择词典">
            <option value="en-zh">英语—简体中文词典 · 已内置</option>
            <option value="zh-ja" disabled>简体中文—日语词典 · 尚未接入</option>
            <option value="zh-ru" disabled>简体中文—俄语词典 · 尚未接入</option>
          </select>${icons.chevron}
        </div>
        <div class="v6-dictionary-source-badge" data-v6-dictionary-source-badge>英语—简体中文词典 <span>·</span> 本机离线</div>
        <form class="v6-dictionary-search" role="search" aria-label="词典查询">
          <input id="v6-dictionary-input" type="search" autocomplete="off" placeholder="输入中文或英语词条…" aria-label="输入中文或英语词条">
          <button type="submit" aria-label="查询词典">${icons.search}</button>
        </form>
        <p class="v6-result-label" id="v6-dictionary-result-label" role="status" aria-live="polite">输入中文或英语词条开始查询</p>
        <p class="v6-dictionary-empty" id="v6-dictionary-empty-copy">中英词典在本机运行。英语词头支持 A–Z 分页浏览；日语和俄语词典尚未接入。</p>
        <div class="v6-dictionary-senses" data-v6-dictionary-senses aria-live="polite" hidden></div>
        <div class="v6-dictionary-browser" aria-label="按首字母浏览词典">
          <div class="v6-dictionary-list">
            <div class="v6-dictionary-columns"><span>英语词头</span><span>音标</span></div>
            <div data-v6-dictionary-browse-items aria-live="polite"><p class="v6-dictionary-empty">正在读取 A 开头词条…</p></div>
            <button class="v6-dictionary-load-more" type="button" data-v6-dictionary-load-more hidden>加载更多</button>
          </div>
          <nav class="v6-alphabet-index" data-v6-alphabet-index aria-label="选择英文字母"></nav>
        </div>
        <p class="v6-structure-note"><strong>音标说明</strong>　英语词条显示可匹配的美式 IPA；没有对应数据时标注“音标数据暂缺”。</p>
        <p class="v6-structure-note"><strong>数据说明</strong>　词条由 Chinese Open Wordnet 与 Princeton WordNet 3.0 对齐生成；中文为同义词对应项，英文定义和例句保留来源原文。</p>
      </main>
    </section>

    <section class="screen v6-app-screen" id="screen-resources" aria-label="离线资源">
      ${header("settings", "返回上页")}
      <main class="v6-app-content">
        <h1 class="v6-page-heading">离线资源</h1>
        <p class="v6-page-subtitle">查看随安装包提供的语音与词典资源，以及本机翻译语言包状态。</p>
        <aside class="v6-resource-note" aria-label="资源状态说明">
          <span class="v6-empty-icon">${icons.info}</span>
          <div><strong>觅音内置资源</strong><p>语音识别、语音合成、词典和图片 OCR 随安装包提供；翻译语言包由 Android 本机服务按需管理。</p></div>
        </aside>
        <section class="v6-resource-section" aria-labelledby="v6-runtime-heading" data-v6-resource-section>
          <h2 id="v6-runtime-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-translation-resources">离线翻译${icons.chevron}</button></h2>
          <div id="v6-translation-resources">
            <p class="v6-translation-resource-hint" data-v6-translation-hint>下方列出这台设备已下载的全部语言包。</p>
            <div class="v6-resource-list v6-installed-model-list" data-v6-installed-translation-models aria-live="polite">
              <div class="v6-resource-loading" role="status">正在读取本机已下载的语言包…</div>
            </div>
            <details class="v6-translation-add-model">
              <summary>下载新的语言组合</summary>
              <div class="v6-translation-language-picker" data-v6-translation-picker>
                <label class="v6-translation-language-field"><span>源语言</span><select data-v6-translation-source aria-label="下载翻译源语言" disabled><option>正在读取…</option></select></label>
                <button class="v6-translation-swap" type="button" data-v6-translation-swap aria-label="交换源语言和目标语言" title="交换语言">⇄</button>
                <label class="v6-translation-language-field"><span>目标语言</span><select data-v6-translation-target aria-label="下载翻译目标语言" disabled><option>正在读取…</option></select></label>
              </div>
              <p class="v6-translation-resource-hint">所选语言包会加入上方完整列表；同一语言包可供多个翻译方向共用。</p>
              <div class="v6-resource-list" data-v6-translation-pair-preview>
                <div class="v6-resource-loading" role="status">正在读取翻译语言…</div>
              </div>
            </details>
          </div>
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-dictionary-heading" data-v6-resource-section>
          <h2 id="v6-dictionary-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-dictionary-resources">离线词典${icons.chevron}</button></h2>
          <div class="v6-resource-list" id="v6-dictionary-resources">
            <article class="v6-resource-card">
              <div class="v6-resource-copy"><strong>词典 · 已内置</strong><small>中英双向查词 · 61,468 个英语词头 · 本机查询</small></div><span class="v6-resource-status" data-status="downloaded">随 APK 内置</span>
              <div class="v6-resource-actions"><button type="button" data-v6-open-dictionary="en-zh">打开词典</button></div>
            </article>
          </div>
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-voice-heading" data-v6-resource-section>
          <h2 id="v6-voice-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-voice-resources">语言识别与合成${icons.chevron}</button></h2>
          <div class="v6-resource-list" id="v6-voice-resources">
            <article class="v6-resource-card" data-v6-asr-resource>
              <div class="v6-resource-copy"><strong>语音识别 · ASR</strong><small data-v6-asr-description>多语种自动识别 57 种可尝试；默认松开麦克风后返回整段结果，准确度因语种而异。Whisper 不可用时，中英使用流式识别兜底。</small></div><span class="v6-resource-status" data-v6-asr-status data-status="checking" role="status" aria-live="polite">检查中</span>
            </article>
            <article class="v6-resource-card" data-v6-tts-resource>
              <div class="v6-resource-copy"><strong>语音合成 · TTS</strong><small data-v6-tts-description>中英离线语音随 APK 内置；另外内置 31 种语言和 10 种模型音色。中文使用独立内置女声。</small></div><span class="v6-resource-status" data-v6-tts-status data-status="checking" role="status" aria-live="polite">检查中</span>
            </article>
          </div>
        </section>
        <p class="v6-resource-declaration">语音资源首次使用时会在本机自动准备，不要求用户访问 GitHub 或手动找资源。翻译语言包与语音模型分开管理；语音模型支持语言不代表所有语言识别准确率均已完成真机验证。</p>
      </main>
    </section>`);

  const translationAction = document.querySelector('#screen-home [data-action="translate-text"]');
  const dictionaryInput = document.querySelector("#v6-dictionary-input");
  const dictionaryForm = document.querySelector(".v6-dictionary-search");
  const dictionaryPackageSelect = document.querySelector("[data-v6-dictionary-package]");
  const dictionarySourceBadge = document.querySelector("[data-v6-dictionary-source-badge]");
  const resultLabel = document.querySelector("#v6-dictionary-result-label");
  const emptyCopy = document.querySelector("#v6-dictionary-empty-copy");
  const dictionarySenses = document.querySelector("[data-v6-dictionary-senses]");
  const dictionaryBrowseItems = document.querySelector("[data-v6-dictionary-browse-items]");
  const dictionaryLoadMore = document.querySelector("[data-v6-dictionary-load-more]");
  const dictionaryAlphabetIndex = document.querySelector("[data-v6-alphabet-index]");
  const dictionaryBackButton = document.querySelector("#screen-dictionary .top-icon");
  const resourceBack = document.querySelector("#screen-resources .top-icon");
  const navigationStack = MiyinV5Core.createScreenReturnStack({ dictionary: "home", resources: "settings" });
  const returnableScreens = new Set(["dictionary", "resources"]);
  const installedTranslationResourceList = document.querySelector("[data-v6-installed-translation-models]");
  const translationResourceList = document.querySelector("[data-v6-translation-pair-preview]");
  const translationSourceSelect = document.querySelector("[data-v6-translation-source]");
  const translationTargetSelect = document.querySelector("[data-v6-translation-target]");
  const translationSwapButton = document.querySelector("[data-v6-translation-swap]");
  const translationResourceHint = document.querySelector("[data-v6-translation-hint]");
  const toast = document.querySelector("#toast");
  let selectedMode = read("mode", "sentence") === "dictionary" ? "dictionary" : "sentence";
  let toastTimer = 0;
  let translationLanguages = null;
  let translationLanguagesRequest = null;
  let translationResourceRevision = 0;
  let translationPairRevision = 0;
  let installedTranslationRevision = 0;
  let dictionaryRequestRevision = 0;
  let dictionaryBrowseRevision = 0;
  let dictionaryBrowseLetter = "A";
  let dictionaryBrowseOffset = 0;
  const dictionaryPageSize = 24;
  let dictionaryPackage = "en-zh";

  const modeMenuMarkup = '<button class="v6-mode-pill" type="button" data-v6-action="toggle-mode-menu" aria-haspopup="menu" aria-expanded="false">句子⌄</button><div class="v6-mode-menu" role="menu" aria-label="选择翻译方式"><button type="button" role="menuitemradio" aria-checked="true" data-v6-mode-choice="sentence">句子翻译</button><button type="button" role="menuitemradio" aria-checked="false" data-v6-mode-choice="dictionary">单词 / 短语查词</button></div>';
  const homeModeHost = document.createElement("div");
  homeModeHost.className = "v6-mode-host";
  homeModeHost.innerHTML = modeMenuMarkup;
  entry.insertBefore(homeModeHost, homeInput);

  homeInput.value = read("home-draft", homeInput.value);
  if (dictionaryInput) dictionaryInput.value = read("dictionary-draft", "");
  window.MiyinV6HomeDraft = {
    markSubmitted(text, submittedAt) {
      const submissionRevision = (Number(read("home-submission-revision", 0)) || 0) + 1;
      write("home-submission-revision", submissionRevision);
      write("pending-home-translation", {
        text,
        submittedAt,
        draftRevision: Number(read("home-draft-revision", 0)) || 0,
        submissionRevision,
      });
    },
    settleSubmitted(text, submittedAt) {
      const pending = read("pending-home-translation", null);
      if (pending?.text === text && pending?.submittedAt === submittedAt) write("pending-home-translation", null);
    },
  };
  const oldInputTools = entry.querySelector('[data-action="open-input-tools"], [data-action="open-dictionary-page"]');
  const entryTools = document.querySelector("#entry-tools");
  const sentenceInputToolMarkup = oldInputTools?.innerHTML || icons.paperclip;
  const syncTranslationInputTool = () => {
    if (!oldInputTools) return;
    const dictionaryMode = selectedMode === "dictionary";
    if (dictionaryMode) {
      entryTools?.classList.remove("open");
      oldInputTools.dataset.action = "open-dictionary-page";
      oldInputTools.classList.remove("round-tool");
      oldInputTools.classList.add("v6-dictionary-entry");
      oldInputTools.innerHTML = icons.book + "<span>词典页</span>";
      oldInputTools.setAttribute("aria-label", "打开词典页面");
      oldInputTools.title = "打开词典页面";
      return;
    }
    oldInputTools.dataset.action = "open-input-tools";
    oldInputTools.classList.remove("v6-dictionary-entry");
    oldInputTools.classList.add("round-tool");
    oldInputTools.innerHTML = sentenceInputToolMarkup;
    oldInputTools.setAttribute("aria-label", "图片、文档或拍照翻译");
    oldInputTools.title = "图片、文档或拍照翻译";
  };
  const modePills = () => document.querySelectorAll(".v6-mode-pill");
  const closeMenus = () => {
    document.querySelectorAll(".v6-mode-menu.is-open").forEach(menu => menu.classList.remove("is-open"));
    modePills().forEach(pill => pill.setAttribute("aria-expanded", "false"));
  };
  const activeScreenName = () => document.querySelector(".screen.active")?.id.replace(/^screen-/, "") || "home";
  const setBackTarget = (name, target) => {
    const button = name === "dictionary" ? dictionaryBackButton : name === "resources" ? resourceBack : null;
    if (!button) return;
    button.dataset.screen = target;
    button.setAttribute("aria-label", target === "resources" ? "返回离线资源" : target === "dictionary" ? "返回词典" : target === "settings" ? "返回设置" : "返回翻译");
  };
  const navigate = (name, { recordReturn = true } = {}) => {
    const origin = activeScreenName();
    if (recordReturn) navigationStack.push(origin, name);
    if (returnableScreens.has(name)) {
      setBackTarget(name, navigationStack.peek(name) || (name === "dictionary" ? "home" : "settings"));
    }
    const route = document.createElement("button");
    route.type = "button";
    route.hidden = true;
    route.dataset.screen = name;
    route.dataset.v6ManagedNavigation = "true";
    app.appendChild(route);
    route.click();
    route.remove();
  };
  const navigateBackFromResourceArea = () => {
    const current = activeScreenName();
    if (!returnableScreens.has(current)) return false;
    const destination = navigationStack.pop(current);
    setBackTarget(current, destination);
    if (destination === "settings") settingsReturnRestorePending = true;
    navigate(destination, { recordReturn: false });
    return true;
  };
  let settingsReturnRestorePending = false;
  window.MiyinV6Navigation = {
    consumeSettingsReturnRestore() {
      const pending = settingsReturnRestorePending;
      settingsReturnRestorePending = false;
      return pending;
    },
    handleSystemBack() {
      const liveRecordPanel = document.querySelector("#video-record-list:not([hidden])");
      if (liveRecordPanel) {
        liveRecordPanel.querySelector("[data-video-record-close]")?.click();
        return true;
      }
      const modal = document.querySelector("#modal-scrim.open");
      if (modal) {
        modal.querySelector(".modal-close")?.click();
        return true;
      }
      if (document.querySelector("#screen-appearance.active")) {
        document.querySelector("#screen-appearance [data-action='appearance-back']")?.click();
        return true;
      }
      if (document.querySelector("#screen-settings.active")) {
        const settingsBack = document.querySelector("#screen-settings [data-action='settings-back']");
        if (settingsBack) {
          settingsBack.click();
          return true;
        }
      }
      if (navigateBackFromResourceArea()) return true;
      window.dispatchEvent(new Event("miyin:request-app-exit"));
      return true;
    }
  };
  const showToast = message => {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("show");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => toast.classList.remove("show"), 1700);
  };
  const updatePills = () => {
    modePills().forEach(pill => { pill.textContent = selectedMode === "dictionary" ? "单词⌄" : "句子⌄"; });
    document.querySelectorAll("[data-v6-mode-choice]").forEach(button => button.setAttribute("aria-checked", String(button.dataset.v6ModeChoice === selectedMode)));
    homeInput.placeholder = selectedMode === "dictionary" ? "输入单词或短语…" : "输入文字翻译…";
    homeInput.setAttribute("aria-label", selectedMode === "dictionary" ? "输入要查的单词或短语" : "输入文字翻译");
    if (translationAction) {
      const label = selectedMode === "dictionary" ? "单词查词请打开词典页面" : "翻译文字";
      translationAction.setAttribute("aria-label", label);
      translationAction.title = label;
    }
    syncTranslationInputTool();
  };
  const languagePair = () => ({
    source: document.querySelector('#screen-home [data-action="source-language"]')?.textContent.trim() || "中文",
    target: document.querySelector('#screen-home [data-action="target-language"]')?.textContent.trim() || "English"
  });
  const updateDictionaryPage = () => {
    if (dictionaryInput) dictionaryInput.placeholder = "输入中文或英语词条…";
  };
  const clearDictionaryResult = (message = "中英词典在本机运行。英语词头支持 A–Z 分页浏览；日语和俄语词典尚未接入。") => {
    dictionaryRequestRevision += 1;
    if (resultLabel) resultLabel.textContent = "输入中文或英语词条开始查询";
    if (emptyCopy) {
      emptyCopy.hidden = false;
      emptyCopy.textContent = message;
    }
    if (dictionarySenses) {
      dictionarySenses.replaceChildren();
      dictionarySenses.hidden = true;
    }
  };
  const openDictionaryPage = () => {
    const nextQuery = homeInput.value.trim() ? homeInput.value : read("dictionary-draft", "");
    dictionaryInput.value = nextQuery;
    write("dictionary-draft", dictionaryInput.value);
    updateDictionaryPage();
    clearDictionaryResult();
    closeMenus();
    navigate("dictionary");
  };
  const chooseMode = mode => {
    selectedMode = mode === "dictionary" ? "dictionary" : "sentence";
    write("mode", selectedMode);
    updatePills();
    closeMenus();
    window.dispatchEvent(new CustomEvent("miyin:translation-mode-change", { detail: { mode: selectedMode } }));
  };
  const dispatchModeState = () => window.dispatchEvent(new CustomEvent("miyin:translation-mode-change", { detail: { mode: selectedMode } }));

  updatePills();
  dispatchModeState();
  updateDictionaryPage();
  clearDictionaryResult();
  let homeDraftRevision = Math.max(0, Number(read("home-draft-revision", 0)) || 0);
  let homeDraftSaveTimer = 0;
  const saveHomeDraft = () => {
    window.clearTimeout(homeDraftSaveTimer);
    homeDraftSaveTimer = 0;
    write("home-draft-revision", homeDraftRevision);
    write("home-draft", homeInput.value);
  };
  homeInput.addEventListener("input", () => {
    homeDraftRevision += 1;
    window.clearTimeout(homeDraftSaveTimer);
    homeDraftSaveTimer = window.setTimeout(saveHomeDraft, 180);
  });
  homeInput.addEventListener("blur", saveHomeDraft);
  window.addEventListener("pagehide", saveHomeDraft);
  dictionaryInput?.addEventListener("input", () => {
    write("dictionary-draft", dictionaryInput.value);
    clearDictionaryResult();
  });
  const clearRestoredDraftWhenAlreadyTranslated = async () => {
    const candidate = homeInput.value.trim();
    const migrationKey = "legacy-sent-draft-migration-v1.2";
    const migrationDone = read(migrationKey, false);
    const pending = read("pending-home-translation", null);
    const submissionRevision = Number(read("home-submission-revision", 0)) || 0;
    if (!candidate) {
      if (pending) write("pending-home-translation", null);
      if (!migrationDone) write(migrationKey, true);
      return;
    }
    if (document.location.protocol === "file:" && document.documentElement.dataset.nativeHost !== "true") return;
    const revision = homeDraftRevision;
    try {
      let latestSource = null;
      let latestCreatedAt = 0;
      if (document.documentElement.dataset.nativeHost === "true") {
        const rows = await window.MiyinNativeBridge.request("history.list", { limit: 1, offset: 0 });
        latestSource = Array.isArray(rows) ? rows[0]?.sourceText : null;
        latestCreatedAt = Date.parse(rows?.[0]?.createdAt || "") || 0;
      } else {
        const savedRecords = JSON.parse(localStorage.getItem("miyin.full.preview.v5.records") || "[]");
        const latestTranslation = Array.isArray(savedRecords) ? savedRecords.find(record => record?.category === "translation") : null;
        const entries = Array.isArray(latestTranslation?.entries) ? latestTranslation.entries : [];
        latestSource = entries.length ? entries[entries.length - 1]?.source || null : null;
        latestCreatedAt = Date.parse(latestTranslation?.createdAt || "") || 0;
      }
      if (homeDraftRevision !== revision || homeInput.value.trim() !== candidate) return;
      const latestPending = read("pending-home-translation", null);
      const latestSubmissionRevision = Number(read("home-submission-revision", 0)) || 0;
      if (latestSubmissionRevision !== submissionRevision || !MiyinV5Core.isSamePendingHomeTranslation(pending, latestPending)) return;
      const legacySentDraft = !migrationDone && homeDraftRevision === 0 && latestSource === candidate && (!pending || pending.draftRevision !== homeDraftRevision);
      const interruptedSuccessfulTranslation = pending?.text === candidate && pending?.draftRevision === homeDraftRevision && latestSource === candidate && latestCreatedAt >= Number(pending.submittedAt || 0);
      if (interruptedSuccessfulTranslation) {
        homeInput.value = "";
        write("home-draft", "");
      } else if (legacySentDraft && document.documentElement.dataset.nativeHost === "true") {
        window.dispatchEvent(new CustomEvent("miyin:legacy-sent-draft-found", { detail: { text: candidate } }));
      }
      if (!migrationDone) write(migrationKey, true);
      if (pending) write("pending-home-translation", null);
    } catch {
      // Keep the draft when local history cannot confirm that it was already sent.
    }
  };
  if (document.documentElement.dataset.nativeHost === "true") {
    void clearRestoredDraftWhenAlreadyTranslated();
  } else {
    window.addEventListener("miyin:native-host-ready", clearRestoredDraftWhenAlreadyTranslated, { once: true });
    void clearRestoredDraftWhenAlreadyTranslated();
  }

  const settingsList = document.querySelector("#screen-settings .settings-list");
  if (settingsList) {
    settingsList.insertAdjacentHTML("beforeend", `
      <article class="setting-card v6-resource-entry">
        <button class="setting-trigger v6-resource-trigger appearance-surface" type="button" data-screen="resources" aria-label="打开离线资源管理">
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M4 5h16v14H4z"/><path d="M8 9h8M8 13h5m-3 6v-3"/><circle cx="17" cy="16" r="2.2"/></svg>离线资源</span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>
        </button>
      </article>`);
  }

  const isNativeHost = () => document.documentElement.dataset.nativeHost === "true" && !!window.MiyinNativeBridge?.request;
  const languageNames = { "zh-Hans": "简体中文", en: "English", ru: "俄语", ja: "日语" };
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const loadTranslationLanguages = () => {
    if (translationLanguages) return Promise.resolve(translationLanguages);
    if (!translationLanguagesRequest) {
      translationLanguagesRequest = window.MiyinNativeBridge.request("translation.supportedLanguages").then(languages => {
        if (!Array.isArray(languages)) throw new Error("invalid_supported_languages");
        const supported = languages.filter(language => language && typeof language.tag === "string" && typeof language.name === "string");
        if (supported.length < 2) throw new Error("not_enough_supported_languages");
        translationLanguages = supported;
        return translationLanguages;
      }).catch(error => {
        translationLanguagesRequest = null;
        throw error;
      });
    }
    return translationLanguagesRequest;
  };
  const languageTagForLabel = (label, languages) => {
    const aliases = { "中": "zh-Hans", "中文": "zh-Hans", "简体中文": "zh-Hans", "英": "en", "英语": "en", "英文": "en", "English": "en" };
    const normalized = aliases[String(label || "").trim()] || String(label || "").trim();
    return languages.find(language => language.tag === normalized || language.name === normalized)?.tag || null;
  };
  const setTranslationLanguageOptions = languages => {
    if (!translationSourceSelect || !translationTargetSelect) return;
    const supported = tag => languages.some(language => language.tag === tag);
    const current = languagePair();
    let sourceTag = supported(translationSourceSelect.value) ? translationSourceSelect.value : read("resource-source-tag", null);
    let targetTag = supported(translationTargetSelect.value) ? translationTargetSelect.value : read("resource-target-tag", null);
    if (!supported(sourceTag)) sourceTag = languageTagForLabel(current.source, languages) || "zh-Hans";
    if (!supported(targetTag)) targetTag = languageTagForLabel(current.target, languages) || "en";
    if (!supported(sourceTag)) sourceTag = languages[0].tag;
    if (!supported(targetTag)) targetTag = languages.find(language => language.tag !== sourceTag)?.tag || languages[1].tag;
    if (sourceTag === targetTag) targetTag = languages.find(language => language.tag !== sourceTag)?.tag || languages[1].tag;

    const options = languages.map(language => '<option value="' + escapeHtml(language.tag) + '">' + escapeHtml(language.name) + '</option>').join("");
    translationSourceSelect.innerHTML = options;
    translationTargetSelect.innerHTML = options;
    translationSourceSelect.value = sourceTag;
    translationTargetSelect.value = targetTag;
    translationSourceSelect.disabled = false;
    translationTargetSelect.disabled = false;
  };
  const prettyModelStatus = status => ({
    downloaded: "已下载",
    notDownloaded: "未下载",
    downloading: "下载中",
    unsupported: "不支持",
    failed: "读取失败"
  }[status] || "状态未知");
  const setModelButtons = (row, status) => {
    const download = row.querySelector('[data-v6-model-action="download"]');
    if (download) { download.disabled = !isNativeHost() || status !== "notDownloaded"; download.setAttribute("aria-disabled", String(download.disabled)); }
  };
  const translationRowMarkup = (pair, status) => {
    const sourceName = pair.sourceName || languageNames[pair.sourceTag] || pair.sourceTag;
    const targetName = pair.targetName || languageNames[pair.targetTag] || pair.targetTag;
    const pairName = sourceName + (pair.reverseAvailable ? " ↔ " : " → ") + targetName;
    return '<article class="v6-resource-card v6-translation-resource" data-v6-translation-row data-source-tag="' + escapeHtml(pair.sourceTag) + '" data-target-tag="' + escapeHtml(pair.targetTag) + '" data-shared-models="' + String(pair.reverseAvailable) + '" data-model-status="' + escapeHtml(status) + '">' +
      '<div class="v6-resource-copy"><strong>' + escapeHtml(pairName) + '</strong><small>Google ML Kit · Android 平台管理' + (pair.reverseAvailable ? '；双向共用模型' : '') + '</small></div>' +
      '<span class="v6-resource-status" data-v6-row-status data-status="' + escapeHtml(status) + '" role="status" aria-live="polite">' + prettyModelStatus(status) + '</span>' +
      '<div class="v6-resource-actions"><button type="button" data-v6-model-action="download" disabled aria-disabled="true">下载所需语言包</button><button type="button" data-v6-model-action="refresh">刷新状态</button></div></article>';
  };
  const updateTranslationRow = async (row, pair) => {
    const statusNode = row.querySelector("[data-v6-row-status]");
    if (!statusNode) return;
    if (!isNativeHost()) {
      statusNode.textContent = "请在觅音 App 中读取";
      statusNode.dataset.status = "unavailable";
      row.dataset.modelStatus = "unavailable";
      setModelButtons(row, "unavailable");
      return;
    }
    statusNode.textContent = "正在读取";
    statusNode.dataset.status = "checking";
    row.dataset.modelStatus = "checking";
    setModelButtons(row, "checking");
    try {
      const info = await window.MiyinNativeBridge.request("translation.modelInfo", { sourceTag: pair.sourceTag, targetTag: pair.targetTag });
      const status = info?.status || "failed";
      row.dataset.modelStatus = status;
      statusNode.dataset.status = status;
      statusNode.textContent = prettyModelStatus(status);
      setModelButtons(row, status);
    } catch {
      row.dataset.modelStatus = "failed";
      statusNode.dataset.status = "failed";
      statusNode.textContent = "无法读取";
      setModelButtons(row, "failed");
    }
  };
  const refreshTranslationResources = async () => {
    if (!installedTranslationResourceList && !translationResourceList) return;
    const revision = ++translationResourceRevision;
    if (!isNativeHost()) {
      if (translationSourceSelect) translationSourceSelect.disabled = true;
      if (translationTargetSelect) translationTargetSelect.disabled = true;
      if (installedTranslationResourceList) installedTranslationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">请在觅音 App 中读取已下载的语言包。</div>';
      if (translationResourceList) translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">请在觅音 App 中读取可用语言与离线模型状态。</div>';
      return;
    }
    if (installedTranslationResourceList) installedTranslationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">正在读取本机已下载的语言包…</div>';
    if (translationResourceList) translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">正在读取可用翻译语言…</div>';
    try {
      const languages = await loadTranslationLanguages();
      if (revision !== translationResourceRevision) return;
      if (!languages.length) {
        if (translationResourceList) translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">此设备没有报告可管理的离线翻译语言。</div>';
        return;
      }
      setTranslationLanguageOptions(languages);
      if (translationResourceHint) translationResourceHint.textContent = "已下载的语言包会完整列在上方，不随翻译方向变化。ML Kit 的同一语言包可供多个方向共用。";
      await Promise.all([refreshInstalledTranslationModels(), refreshSelectedTranslationModel()]);
    } catch {
      if (revision !== translationResourceRevision) return;
      if (translationSourceSelect) translationSourceSelect.disabled = true;
      if (translationTargetSelect) translationTargetSelect.disabled = true;
      if (installedTranslationResourceList) installedTranslationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">无法读取本机语言包目录，请稍后重试。</div><button type="button" class="v6-resource-retry" data-v6-model-action="reload-list">重试读取</button>';
      if (translationResourceList) translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">无法读取本机模型目录，请稍后重试。</div><button type="button" class="v6-resource-retry" data-v6-model-action="reload-list">重试读取</button>';
    }
  };
  const refreshInstalledTranslationModels = async () => {
    if (!installedTranslationResourceList) return;
    const revision = ++installedTranslationRevision;
    try {
      const models = await window.MiyinNativeBridge.request("translation.installedModels");
      if (revision !== installedTranslationRevision) return;
      if (!Array.isArray(models)) throw new Error("invalid_installed_models");
      const rows = [
        '<article class="v6-resource-card v6-installed-translation-model" data-language-tag="en"><div class="v6-resource-copy"><strong>英语</strong><small>ML Kit 内置语言 · 无需下载</small></div><span class="v6-resource-status" data-status="downloaded">内置</span></article>',
        ...models.map(model => {
          const tag = String(model?.tag || "");
          const name = String(model?.name || tag);
          return '<article class="v6-resource-card v6-installed-translation-model" data-language-tag="' + escapeHtml(tag) + '"><div class="v6-resource-copy"><strong>' + escapeHtml(name) + '</strong><small>Google ML Kit · ' + escapeHtml(tag) + ' · 供包含该语言的翻译方向共用</small></div><span class="v6-resource-status" data-status="downloaded">已下载</span><div class="v6-resource-actions"><button type="button" data-v6-language-model-action="delete" data-language-tag="' + escapeHtml(tag) + '" aria-label="删除' + escapeHtml(name) + '语言包">删除语言包</button></div></article>';
        })
      ];
      installedTranslationResourceList.innerHTML = rows.join("");
      if (models.length === 0) {
        installedTranslationResourceList.insertAdjacentHTML("beforeend", '<p class="v6-resource-empty">目前只含英语内置能力；下载其它语言后会显示在这里。</p>');
      }
    } catch (error) {
      if (revision !== installedTranslationRevision) return;
      installedTranslationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">无法读取已下载语言包：' + escapeHtml(error?.message || "请稍后重试") + '</div><button type="button" class="v6-resource-retry" data-v6-model-action="reload-list">重试读取</button>';
    }
  };
  const refreshSelectedTranslationModel = async () => {
    if (!translationResourceList || !translationSourceSelect || !translationTargetSelect) return;
    const revision = ++translationPairRevision;
    const sourceTag = translationSourceSelect.value;
    const targetTag = translationTargetSelect.value;
    const source = translationLanguages?.find(language => language.tag === sourceTag);
    const target = translationLanguages?.find(language => language.tag === targetTag);
    if (!source || !target) {
      translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">请选择翻译语言组合。</div>';
      return;
    }
    if (sourceTag === targetTag) {
      translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">源语言和目标语言不能相同，请重新选择。</div>';
      return;
    }
    const pair = { sourceTag, targetTag, sourceName: source.name, targetName: target.name, reverseAvailable: true };
    translationResourceList.innerHTML = translationRowMarkup(pair, "checking");
    const row = translationResourceList.querySelector("[data-v6-translation-row]");
    await updateTranslationRow(row, pair);
    if (revision !== translationPairRevision) return;
  };
  const handleTranslationLanguageChange = () => {
    if (!translationSourceSelect || !translationTargetSelect) return;
    write("resource-source-tag", translationSourceSelect.value);
    write("resource-target-tag", translationTargetSelect.value);
    void refreshSelectedTranslationModel();
  };
  translationSourceSelect?.addEventListener("change", handleTranslationLanguageChange);
  translationTargetSelect?.addEventListener("change", handleTranslationLanguageChange);
  translationSwapButton?.addEventListener("click", () => {
    if (!translationSourceSelect || !translationTargetSelect || translationSourceSelect.disabled || translationTargetSelect.disabled) return;
    const sourceTag = translationSourceSelect.value;
    translationSourceSelect.value = translationTargetSelect.value;
    translationTargetSelect.value = sourceTag;
    handleTranslationLanguageChange();
  });
  refreshTranslationResources();
  window.addEventListener("miyin:native-host-ready", refreshTranslationResources);

  const setResourceState = (statusNode, description, state, title, copy) => {
    if (statusNode) {
      statusNode.dataset.status = state;
      statusNode.textContent = title;
    }
    if (description) description.textContent = copy;
  };
  const refreshVoiceResources = async () => {
    const asrRow = document.querySelector("[data-v6-asr-resource]");
    const asrStatus = asrRow?.querySelector("[data-v6-asr-status]");
    const asrDescription = asrRow?.querySelector("[data-v6-asr-description]");
    const ttsRow = document.querySelector("[data-v6-tts-resource]");
    const ttsStatus = ttsRow?.querySelector("[data-v6-tts-status]");
    const ttsDescription = ttsRow?.querySelector("[data-v6-tts-description]");
    if (!isNativeHost() || !window.MiyinNativeBridge) {
      setResourceState(asrStatus, asrDescription, "unavailable", "仅 App 可读取", "网页预览不包含模型状态；Android APK 内置多语种识别模型，中英另有流式兜底。");
      setResourceState(ttsStatus, ttsDescription, "unavailable", "仅 App 可读取", "中英离线语音及多语言多音色模型随 Android APK 内置；中文使用独立内置女声。");
      return;
    }
    setResourceState(asrStatus, asrDescription, "checking", "准备中", "正在校验并准备 APK 内置的本地识别模型…");
    setResourceState(ttsStatus, ttsDescription, "checking", "准备中", "正在校验并准备 APK 内置的本地合成模型…");
    try {
      const bilingualTts = await window.MiyinNativeBridge.request("voice.offlineTtsStatus");
      const multilingualTts = await window.MiyinNativeBridge.request("voice.multilingualTtsStatus");
      const ttsReady = bilingualTts?.bundled === true && bilingualTts?.chineseReady === true && bilingualTts?.englishReady === true && multilingualTts?.bundled === true && multilingualTts?.installed === true;
      if (ttsReady) {
        setResourceState(ttsStatus, ttsDescription, "downloaded", "随 APK 内置", "中文和英语使用觅音离线语音；另支持 " + (multilingualTts.languageTags?.length || 31) + " 种语言、" + (multilingualTts.speakerCount || 10) + " 种模型音色。中文使用独立内置女声。");
      } else {
        setResourceState(ttsStatus, ttsDescription, "failed", "准备失败", "内置合成资源尚未就绪。检查设备存储空间后重新打开觅音；不需要另找或下载语音包。");
      }
    } catch (error) {
      setResourceState(ttsStatus, ttsDescription, "failed", "准备失败", error?.message || "无法准备 APK 内置语音合成资源。请检查设备存储空间并重新打开觅音。");
      console.warn("Could not prepare bundled TTS resources", error);
    }
    try {
      const asr = await window.MiyinNativeBridge.request("voice.multilingualAsrStatus");
      const tags = Array.isArray(asr?.languageTags) ? asr.languageTags : [];
      if (asr?.bundled === true && asr?.installed === true) {
        const languageCount = tags.length;
        const languageSummary = languageCount > 0
          ? `多语种自动识别 ${languageCount} 种可尝试（含中文、英语、日语、法语、俄语等）`
          : "多语种自动识别可尝试";
        setResourceState(asrStatus, asrDescription, "downloaded", "随 APK 内置", `${languageSummary}；默认由 Whisper 在松开麦克风后返回整段结果，准确度因语种而异。Whisper 不可用时，中英使用流式识别兜底。`);
      } else {
        setResourceState(asrStatus, asrDescription, "failed", "准备失败", "内置识别资源尚未就绪。检查设备存储空间后重新打开觅音；不需要另找或下载识别包。");
      }
    } catch (error) {
      setResourceState(asrStatus, asrDescription, "failed", "准备失败", error?.message || "无法准备 APK 内置语音识别资源。请检查设备存储空间并重新打开觅音。");
      console.warn("Could not prepare bundled ASR resources", error);
    }
  };
  void refreshVoiceResources();
  window.addEventListener("miyin:native-host-ready", refreshVoiceResources);
  window.addEventListener("miyin:app-resumed", refreshVoiceResources);
  window.addEventListener("miyin:surface-visibility-change", () => {
    if (document.getElementById("screen-resources")?.classList.contains("active")) void refreshVoiceResources();
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && document.getElementById("screen-resources")?.classList.contains("active")) void refreshVoiceResources();
  });

  const performTranslationModelAction = async actionButton => {
    const action = actionButton.dataset.v6ModelAction;
    if (action === "reload-list") { refreshTranslationResources(); return; }
    const row = actionButton.closest("[data-v6-translation-row]");
    if (!row) return;
    const pair = { sourceTag: row.dataset.sourceTag, targetTag: row.dataset.targetTag };
    if (action === "refresh") { updateTranslationRow(row, pair); return; }
    if (action !== "download") return;
    if (!isNativeHost()) return;
    const statusNode = row.querySelector("[data-v6-row-status]");
    row.querySelectorAll("button").forEach(button => { button.disabled = true; button.setAttribute("aria-disabled", "true"); });
    if (statusNode) {
      statusNode.dataset.status = "downloading";
      statusNode.textContent = "正在下载…";
    }
    row.dataset.modelStatus = "downloading";
    try {
      await window.MiyinNativeBridge.request("translation.downloadModel", { ...pair, wifiOnly: true });
      showToast("已请求下载所需语言包");
    } catch (error) {
      showToast(error?.message || "模型操作未完成");
    }
    await Promise.all([updateTranslationRow(row, pair), refreshInstalledTranslationModels()]);
  };

  const performTranslationLanguageModelDelete = async actionButton => {
    const languageTag = actionButton.dataset.languageTag;
    const language = translationLanguages?.find(value => value.tag === languageTag);
    const languageName = language?.name || languageTag;
    if (!languageTag || !isNativeHost()) return;
    if (!window.confirm("删除「" + languageName + "」语言包后，所有涉及该语言的翻译方向都需要重新下载模型才能离线使用。其它语言包会保留。确定删除吗？")) return;
    actionButton.disabled = true;
    actionButton.setAttribute("aria-disabled", "true");
    actionButton.textContent = "正在删除…";
    try {
      await window.MiyinNativeBridge.request("translation.deleteLanguageModel", { languageTag });
      showToast("已删除「" + languageName + "」语言包");
      await Promise.all([refreshInstalledTranslationModels(), refreshSelectedTranslationModel()]);
    } catch (error) {
      actionButton.disabled = false;
      actionButton.setAttribute("aria-disabled", "false");
      actionButton.textContent = "删除语言包";
      showToast(error?.message || "语言包删除失败");
    }
  };

  document.addEventListener("click", event => {
    const toggle = event.target.closest('[data-v6-action="toggle-mode-menu"]');
    if (toggle) {
      event.preventDefault();
      event.stopImmediatePropagation();
      const menu = toggle.parentElement.querySelector(".v6-mode-menu");
      const willOpen = menu && !menu.classList.contains("is-open");
      closeMenus();
      if (willOpen) {
        menu.classList.add("is-open");
        toggle.setAttribute("aria-expanded", "true");
      }
      return;
    }
    const choice = event.target.closest("[data-v6-mode-choice]");
    if (choice) {
      event.preventDefault();
      event.stopImmediatePropagation();
      chooseMode(choice.dataset.v6ModeChoice);
      return;
    }
    const dictionaryOption = event.target.closest("[data-v6-open-dictionary]");
    if (dictionaryOption) {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (dictionaryOption.dataset.v6OpenDictionary !== "en-zh") return;
      updateDictionaryPage();
      clearDictionaryResult();
      navigate("dictionary");
      return;
    }
    const resourceHeading = event.target.closest(".v6-resource-heading");
    if (resourceHeading) {
      const panel = document.getElementById(resourceHeading.getAttribute("aria-controls"));
      const expanded = resourceHeading.getAttribute("aria-expanded") === "true";
      resourceHeading.setAttribute("aria-expanded", String(!expanded));
      if (panel) panel.hidden = expanded;
      return;
    }
    const languageModelAction = event.target.closest('[data-v6-language-model-action="delete"]');
    if (languageModelAction) {
      event.preventDefault();
      performTranslationLanguageModelDelete(languageModelAction);
      return;
    }
    const modelAction = event.target.closest("[data-v6-model-action]");
    if (modelAction) {
      event.preventDefault();
      performTranslationModelAction(modelAction);
      return;
    }
    const backButton = event.target.closest("[data-v6-nav-back]");
    if (backButton) {
      event.preventDefault();
      event.stopImmediatePropagation();
      navigateBackFromResourceArea();
      return;
    }
    const screenButton = event.target.closest("[data-screen]");
    if (!screenButton || screenButton.dataset.v6ManagedNavigation === "true") return;
    const destination = screenButton.dataset.screen;
    if (returnableScreens.has(destination)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      navigate(destination);
      return;
    }
    if (destination !== "settings" && returnableScreens.has(activeScreenName())) navigationStack.clear();
    const translate = event.target.closest('#screen-home [data-action="translate-text"]');
    if (translate && selectedMode === "dictionary") {
      event.preventDefault();
      event.stopImmediatePropagation();
      showToast(homeInput.value.trim() ? "请点击“词典页”进入词典页面查词" : "先输入单词，再点击“词典页”查词");
      return;
    }
    if (!event.target.closest(".v6-mode-host")) closeMenus();
  }, true);

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") closeMenus();
    if (event.target === homeInput && event.key === "Enter" && selectedMode === "dictionary") {
      event.preventDefault();
      event.stopImmediatePropagation();
      showToast(homeInput.value.trim() ? "请点击“词典页”进入词典页面查词" : "先输入单词，再点击“词典页”查词");
    }
  }, true);

  const dictionaryPosLabels = {
    noun: "名词",
    verb: "动词",
    adjective: "形容词",
    adverb: "副词",
  };
  const refreshDictionaryPackagePresentation = () => {
    if (dictionarySourceBadge) {
      dictionarySourceBadge.innerHTML = "英语—简体中文词典 <span>·</span> 本机离线";
    }
    if (dictionaryInput) {
      dictionaryInput.placeholder = "输入中文或英语词条…";
      dictionaryInput.setAttribute("aria-label", "输入中文或英语词条");
    }
  };
  const makeDictionaryEntryCard = entry => {
    const card = document.createElement("article");
    card.className = "v6-dictionary-entry-result";
    const header = document.createElement("div");
    header.className = "v6-dictionary-entry-heading";
    const heading = document.createElement("h2");
    heading.textContent = entry.word;
    const phonetic = document.createElement("span");
    phonetic.className = "v6-dictionary-phonetic";
    phonetic.dataset.v6DictionaryPhonetic = "";
    phonetic.textContent = typeof entry.ipa === "string" && entry.ipa.trim()
      ? "美式 IPA · " + entry.ipa
      : "音标数据暂缺";
    header.append(heading, phonetic);
    card.append(header);
    const meanings = document.createElement("div");
    meanings.className = "v6-dictionary-meanings";
    const exampleGroups = [];
    for (const sense of Array.isArray(entry.senses) ? entry.senses : []) {
      const row = document.createElement("section");
      row.className = "v6-dictionary-sense-row";
      const title = document.createElement("h3");
      const part = dictionaryPosLabels[sense.partOfSpeech] || "词义";
      const translations = Array.isArray(sense.translations) ? sense.translations : [];
      const senseLabel = part + (translations.length ? " · " + translations.join("、") : "");
      title.textContent = part;
      row.append(title);
      if (translations.length) {
        const translatedMeaning = document.createElement("p");
        translatedMeaning.className = "v6-dictionary-sense-translations";
        translatedMeaning.textContent = translations.join("、");
        row.append(translatedMeaning);
      }
      if (sense.definition) {
        const definition = document.createElement("p");
        definition.className = "v6-dictionary-sense-definition";
        definition.textContent = "英文释义：" + sense.definition;
        row.append(definition);
      }
      if (Array.isArray(sense.examples) && sense.examples.length) {
        exampleGroups.push({ label: senseLabel, examples: sense.examples });
      }
      meanings.append(row);
    }
    if (meanings.childElementCount) card.append(meanings);
    if (exampleGroups.length) {
      const exampleSection = document.createElement("section");
      exampleSection.className = "v6-dictionary-example-section";
      const examplesHeading = document.createElement("h3");
      examplesHeading.className = "v6-dictionary-examples-heading";
      examplesHeading.textContent = "例句";
      exampleSection.append(examplesHeading);
      for (const group of exampleGroups) {
        const groupList = document.createElement("ul");
        groupList.className = "v6-dictionary-sense-examples";
        if (exampleGroups.length > 1 && group.label) {
          const groupLabel = document.createElement("li");
          groupLabel.className = "v6-dictionary-example-label";
          groupLabel.textContent = group.label;
          groupList.append(groupLabel);
        }
        for (const example of group.examples) {
          const item = document.createElement("li");
          item.textContent = example;
          groupList.append(item);
        }
        exampleSection.append(groupList);
      }
      card.append(exampleSection);
    }
    const source = document.createElement("p");
    source.className = "v6-dictionary-sense-source";
    source.textContent = "Chinese Open Wordnet · Princeton WordNet 3.0";
    card.append(source);
    return card;
  };
  const renderDictionaryLookup = result => {
    const entries = Array.isArray(result?.entries)
      ? result.entries
      : result?.entry ? [result.entry] : [];
    if (!result?.found || entries.length === 0) {
      if (resultLabel) resultLabel.textContent = "没有找到精确词头";
      if (emptyCopy) {
        emptyCopy.hidden = false;
      emptyCopy.textContent = "本机中英词典没有收录“" + dictionaryInput.value.trim() + "”。请检查拼写或尝试词条原形；不会用普通翻译补造词义。";
      }
      dictionarySenses?.replaceChildren();
      if (dictionarySenses) dictionarySenses.hidden = true;
      return;
    }
    if (resultLabel) {
      const normalized = result.matchedByNormalization ? " · 已忽略大小写或空格差异" : "";
      resultLabel.textContent = entries.length === 1
        ? entries[0].word + " · " + (entries[0].senses?.length || 0) + " 条词义" + normalized
        : "找到 " + entries.length + " 个英语词头" + normalized;
    }
    if (emptyCopy) emptyCopy.hidden = true;
    if (!dictionarySenses) return;
    dictionarySenses.replaceChildren();
    for (const entry of entries) dictionarySenses.append(makeDictionaryEntryCard(entry));
    dictionarySenses.hidden = false;
  };
  const renderDictionaryAlphabetIndex = () => {
    if (!dictionaryAlphabetIndex) return;
    dictionaryAlphabetIndex.innerHTML = Array.from("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
      .map(letter => '<button type="button" data-v6-dictionary-letter="' + letter + '" aria-label="浏览 ' + letter + ' 开头词条" aria-current="' + String(letter === dictionaryBrowseLetter) + '">' + letter + '</button>')
      .join("");
  };
  const loadDictionaryBrowsePage = async (letter = dictionaryBrowseLetter, reset = true) => {
    if (!dictionaryBrowseItems) return;
    if (reset) {
      dictionaryBrowseLetter = letter;
      dictionaryBrowseOffset = 0;
      dictionaryBrowseItems.replaceChildren();
      renderDictionaryAlphabetIndex();
    }
    const revision = ++dictionaryBrowseRevision;
    if (!isNativeHost() || !window.MiyinNativeBridge) {
      dictionaryBrowseItems.innerHTML = '<p class="v6-dictionary-empty">请在觅音 App 中浏览本机词典。</p>';
      if (dictionaryLoadMore) dictionaryLoadMore.hidden = true;
      return;
    }
    if (reset) dictionaryBrowseItems.innerHTML = '<p class="v6-dictionary-empty">正在读取 ' + escapeHtml(dictionaryBrowseLetter) + ' 开头词条…</p>';
    try {
      const page = await window.MiyinNativeBridge.request("dictionary.browse", {
        letter: dictionaryBrowseLetter,
        offset: dictionaryBrowseOffset,
        limit: dictionaryPageSize,
      });
      if (revision !== dictionaryBrowseRevision) return;
      const words = Array.isArray(page?.words) ? page.words : [];
      const ipaByWord = page?.ipaByWord && typeof page.ipaByWord === "object" ? page.ipaByWord : {};
      if (reset) dictionaryBrowseItems.replaceChildren();
      if (!words.length && reset) {
        dictionaryBrowseItems.innerHTML = '<p class="v6-dictionary-empty">' + escapeHtml(dictionaryBrowseLetter) + ' 开头暂无词条。</p>';
      }
      for (const word of words) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "v6-dictionary-word";
        button.dataset.v6DictionaryWord = word;
        const name = document.createElement("span");
        name.textContent = word;
        const phonetic = document.createElement("span");
        const ipa = ipaByWord[word];
        phonetic.textContent = typeof ipa === "string" && ipa.trim()
          ? "美式 IPA · " + ipa
          : "音标数据暂缺";
        button.append(name, phonetic);
        dictionaryBrowseItems.append(button);
      }
      dictionaryBrowseOffset = Number(page?.offset || 0) + words.length;
      if (dictionaryLoadMore) dictionaryLoadMore.hidden = page?.hasMore !== true;
      if (dictionaryAlphabetIndex) {
        dictionaryAlphabetIndex.querySelectorAll("button").forEach(button => {
          button.setAttribute("aria-current", String(button.dataset.v6DictionaryLetter === dictionaryBrowseLetter));
        });
      }
    } catch (error) {
      if (revision !== dictionaryBrowseRevision) return;
      dictionaryBrowseItems.innerHTML = '<p class="v6-dictionary-empty">词条列表暂时无法读取：' + escapeHtml(error?.message || "请稍后重试") + '</p>';
      if (dictionaryLoadMore) dictionaryLoadMore.hidden = true;
    }
  };
  const retryDictionaryBrowseWhenNativeHostReady = () => {
    if (!isNativeHost()) return;
    void loadDictionaryBrowsePage("A", true);
  };
  window.addEventListener("miyin:native-host-ready", retryDictionaryBrowseWhenNativeHostReady);
  const reloadDictionaryBrowseWhenScreenOpens = () => {
    if (!isNativeHost() || activeScreenName() !== "dictionary") return;
    void loadDictionaryBrowsePage(dictionaryBrowseLetter, true);
  };
  window.addEventListener("miyin:surface-visibility-change", reloadDictionaryBrowseWhenScreenOpens);
  if (dictionaryPackageSelect) dictionaryPackageSelect.value = dictionaryPackage;
  refreshDictionaryPackagePresentation();
  dictionaryPackageSelect?.addEventListener("change", () => {
    if (dictionaryPackageSelect.value !== "en-zh") {
      dictionaryPackageSelect.value = dictionaryPackage;
      showToast("该词典包尚未接入");
      return;
    }
    dictionaryPackage = dictionaryPackageSelect.value;
    write("dictionary-package", dictionaryPackage);
    if (resultLabel) resultLabel.textContent = "输入中文或英语词条开始查询";
    dictionarySenses?.replaceChildren();
    if (dictionarySenses) dictionarySenses.hidden = true;
  });
  dictionaryAlphabetIndex?.addEventListener("click", event => {
    const button = event.target.closest("[data-v6-dictionary-letter]");
    if (button) void loadDictionaryBrowsePage(button.dataset.v6DictionaryLetter, true);
  });
  dictionaryBrowseItems?.addEventListener("click", event => {
    const wordButton = event.target.closest("[data-v6-dictionary-word]");
    if (!wordButton) return;
    dictionaryInput.value = wordButton.dataset.v6DictionaryWord;
    dictionaryForm?.requestSubmit();
  });
  dictionaryLoadMore?.addEventListener("click", () => void loadDictionaryBrowsePage(dictionaryBrowseLetter, false));
  renderDictionaryAlphabetIndex();
  void loadDictionaryBrowsePage("A", true);
  dictionaryForm?.addEventListener("submit", async event => {
    event.preventDefault();
    event.stopPropagation();
    const query = dictionaryInput.value.trim();
    write("dictionary-draft", dictionaryInput.value);
    if (!query) {
      showToast("先输入要查的单词或短语");
      dictionaryInput.focus({ preventScroll: true });
      return;
    }
    clearDictionaryResult("正在自动识别中文或英语词条…");
    const requestRevision = dictionaryRequestRevision;
    if (/[\u3040-\u30ff]/.test(query)) {
      if (resultLabel) resultLabel.textContent = "日语词典尚未接入";
      if (emptyCopy) emptyCopy.textContent = "当前可用的是英语—简体中文词典；日语词典数据尚未加入应用。";
      return;
    }
    if (/[\u0400-\u04ff]/.test(query)) {
      if (resultLabel) resultLabel.textContent = "俄语词典尚未接入";
      if (emptyCopy) emptyCopy.textContent = "当前可用的是英语—简体中文词典；俄语词典数据尚未加入应用。";
      return;
    }
    if (!isNativeHost() || !window.MiyinNativeBridge) {
      if (resultLabel) resultLabel.textContent = "请在觅音 Android 应用中查词";
      if (emptyCopy) emptyCopy.textContent = "本机词典随 Android 安装包提供；网页预览不包含词典数据。";
      return;
    }
    try {
      const lookupMethod = /[\u3400-\u9fff]/.test(query) ? "dictionary.lookupChinese" : "dictionary.lookup";
      const result = await window.MiyinNativeBridge.request(lookupMethod, { query });
      if (requestRevision !== dictionaryRequestRevision) return;
      renderDictionaryLookup(result);
    } catch (error) {
      if (requestRevision !== dictionaryRequestRevision) return;
      if (resultLabel) resultLabel.textContent = "本机词典暂时无法读取";
      if (emptyCopy) {
        emptyCopy.hidden = false;
        emptyCopy.textContent = error?.message || "请重新打开觅音后再试。";
      }
      dictionarySenses?.replaceChildren();
      if (dictionarySenses) dictionarySenses.hidden = true;
    }
  }, true);

  window.addEventListener("miyin:open-dictionary-page", openDictionaryPage);
  window.addEventListener("miyin:open-offline-resources", () => navigate("resources"));

  document.addEventListener("click", event => {
    const screenButton = event.target.closest('[data-screen="resources"]');
    if (screenButton) window.setTimeout(refreshTranslationResources, 0);
  });
})();
