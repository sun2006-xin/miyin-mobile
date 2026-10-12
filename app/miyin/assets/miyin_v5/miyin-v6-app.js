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
        <h1 class="v6-page-heading">词典页面</h1>
        <p class="v6-page-subtitle">选择词典后查词。释义仅在接入并核验真实词典数据后显示。</p>
        <label class="v6-dictionary-select-label" for="v6-dictionary-select">当前词典</label>
        <div class="v6-dictionary-select-wrap">
          <select id="v6-dictionary-select" class="v6-dictionary-select" aria-label="选择词典">
            <option value="en-zh">英汉词典 · 未接入</option>
            <option value="zh-en">汉英词典 · 未接入</option>
            <option value="zh-ru">中俄词典 · 未接入</option>
            <option value="zh-ja">中日词典 · 未接入</option>
          </select>
          ${icons.chevron}
        </div>
        <form class="v6-dictionary-search" role="search" aria-label="词典查询">
          <input id="v6-dictionary-input" type="search" autocomplete="off" placeholder="输入单词或短语…" aria-label="输入要查的单词或短语">
          <button type="submit" aria-label="查询词典">${icons.search}</button>
        </form>
        <p class="v6-result-label" id="v6-dictionary-result-label" role="status" aria-live="polite">尚未提交查词</p>
        <section class="v6-dictionary-browser" aria-label="按字母浏览词条">
          <div class="v6-dictionary-list" aria-live="polite">
            <div class="v6-dictionary-columns" aria-hidden="true"><span>词条</span><span>音标</span><span>词义</span></div>
            <div class="v6-letter-heading"><span data-v6-current-letter>A</span><span class="v6-letter-language">英汉词典</span></div>
            <p class="v6-dictionary-empty" id="v6-dictionary-empty-copy">该词典尚未接入，无法读取真实词条。当前页面不显示模拟单词、音标或释义。</p>
            <button class="v6-primary-action" type="button" data-screen="resources">管理词典资源</button>
          </div>
          <nav class="v6-alphabet-index" aria-label="字母索引" data-v6-alphabet-index></nav>
        </section>
        <p class="v6-structure-note"><strong>词条信息</strong>　真实数据接入后显示词性、音标、释义、例句与来源版本。</p>
      </main>
    </section>

    <section class="screen v6-app-screen" id="screen-resources" aria-label="离线资源">
      ${header("settings", "返回上页")}
      <main class="v6-app-content">
        <h1 class="v6-page-heading">离线资源</h1>
        <p class="v6-page-subtitle">按资源类型查看状态。未接入的词典和语音资源不会显示可用下载操作。</p>
        <aside class="v6-resource-note" aria-label="资源状态说明">
          <span class="v6-empty-icon">${icons.info}</span>
          <div><strong>资源管理说明</strong><p>翻译模型由 Android ML Kit 管理；词典与独立语音包尚未接入可核验的数据目录。</p></div>
        </aside>
        <section class="v6-resource-section" aria-labelledby="v6-runtime-heading" data-v6-resource-section>
          <h2 id="v6-runtime-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-translation-resources">离线翻译${icons.chevron}</button></h2>
          <div class="v6-resource-list" id="v6-translation-resources" data-v6-translation-resources>
            <div class="v6-resource-loading" data-v6-translation-loading role="status">正在读取本机支持的翻译模型…</div>
          </div>
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-dictionary-heading" data-v6-resource-section>
          <h2 id="v6-dictionary-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-dictionary-resources">离线词典${icons.chevron}</button></h2>
          <div class="v6-resource-list" id="v6-dictionary-resources">
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>英汉词典</strong><small>英语 → 简体中文 · 词典数据目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button><button type="button" data-v6-open-dictionary="en-zh">查看词典</button></div>
            </article>
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>汉英词典</strong><small>简体中文 → 英语 · 词典数据目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button><button type="button" data-v6-open-dictionary="zh-en">查看词典</button></div>
            </article>
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>中俄词典</strong><small>简体中文 → 俄语 · 词典数据目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button><button type="button" data-v6-open-dictionary="zh-ru">查看词典</button></div>
            </article>
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>中日词典</strong><small>简体中文 → 日语 · 词典数据目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button><button type="button" data-v6-open-dictionary="zh-ja">查看词典</button></div>
            </article>
          </div>
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-voice-heading" data-v6-resource-section>
          <h2 id="v6-voice-heading"><button class="v6-resource-heading" type="button" aria-expanded="true" aria-controls="v6-voice-resources">语言识别与合成${icons.chevron}</button></h2>
          <div class="v6-resource-list" id="v6-voice-resources">
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>语音识别 · ASR</strong><small>离线语音识别模型 · 独立资源目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button></div>
            </article>
            <article class="v6-resource-card v6-resource-card--unavailable">
              <div class="v6-resource-copy"><strong>语音合成 · TTS</strong><small>离线语音合成音色包 · 独立资源目录未接入</small></div><span class="v6-resource-status" data-status="unavailable">未接入</span>
              <div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button></div>
            </article>
          </div>
        </section>
        <p class="v6-resource-declaration">资源状态以本机实际查询为准。词典与语音下载功能将在对应数据源和平台接口接入后开放。</p>
      </main>
    </section>`);

  const translationAction = document.querySelector('#screen-home [data-action="translate-text"]');
  const dictionaryInput = document.querySelector("#v6-dictionary-input");
  const dictionaryForm = document.querySelector(".v6-dictionary-search");
  const dictionarySelect = document.querySelector("#v6-dictionary-select");
  const resultLabel = document.querySelector("#v6-dictionary-result-label");
  const emptyCopy = document.querySelector("#v6-dictionary-empty-copy");
  const dictionaryBackButton = document.querySelector("#screen-dictionary .top-icon");
  const resourceBack = document.querySelector("#screen-resources .top-icon");
  const navigationStack = MiyinV5Core.createScreenReturnStack({ dictionary: "home", resources: "settings" });
  const returnableScreens = new Set(["dictionary", "resources"]);
  const translationResourceList = document.querySelector("[data-v6-translation-resources]");
  const alphabetIndex = document.querySelector("[data-v6-alphabet-index]");
  const toast = document.querySelector("#toast");
  let selectedMode = read("mode", "sentence") === "dictionary" ? "dictionary" : "sentence";
  let dictionaryChoiceExplicit = Boolean(read("dictionary-choice-explicit", false));
  let toastTimer = 0;
  const dictionaryCatalog = {
    "en-zh": { name: "英汉词典", source: "英语" },
    "zh-en": { name: "汉英词典", source: "简体中文" },
    "zh-ru": { name: "中俄词典", source: "简体中文" },
    "zh-ja": { name: "中日词典", source: "简体中文" }
  };
  let selectedDictionary = read("selected-dictionary", "en-zh");
  if (!dictionaryCatalog[selectedDictionary]) selectedDictionary = "en-zh";

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
  if (alphabetIndex) {
    alphabetIndex.innerHTML = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").map(letter =>
      '<button type="button" data-v6-letter="' + letter + '" aria-label="浏览 ' + letter + ' 开头词条">' + letter + '</button>'
    ).join("");
    alphabetIndex.querySelector('[data-v6-letter="A"]')?.setAttribute("aria-current", "true");
  }
  if (dictionarySelect) dictionarySelect.value = selectedDictionary;
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
      const modal = document.querySelector("#modal-scrim.open");
      if (modal) {
        modal.querySelector(".modal-close")?.click();
        return true;
      }
      if (document.querySelector("#screen-orb-style.active")) {
        document.querySelector("#screen-orb-style [data-action='orb-style-back']")?.click();
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
    if (!dictionaryCatalog[selectedDictionary]) selectedDictionary = "en-zh";
    if (dictionarySelect) dictionarySelect.value = selectedDictionary;
    const catalogItem = dictionaryCatalog[selectedDictionary];
    const letterLanguage = document.querySelector(".v6-letter-language");
    const currentLetter = document.querySelector("[data-v6-current-letter]");
    if (letterLanguage) letterLanguage.textContent = catalogItem.name;
    if (dictionaryInput) dictionaryInput.placeholder = "输入" + catalogItem.source + "单词或短语…";
    if (currentLetter) currentLetter.textContent = alphabetIndex?.querySelector("[aria-current='true']")?.dataset.v6Letter || "A";
    if (emptyCopy && !read("dictionary-last-submit", "")) {
      emptyCopy.textContent = catalogItem.name + "数据尚未接入，无法读取真实词条。当前页面不显示模拟单词、音标或释义。";
    }
  };
  const dictionaryForCurrentDirection = () => {
    const { source, target } = languagePair();
    if (source === "English" && target.includes("中文")) return "en-zh";
    if (source.includes("中文") && target === "English") return "zh-en";
    return selectedDictionary;
  };
  const openDictionaryPage = () => {
    const previousDictionary = selectedDictionary;
    const nextDictionary = dictionaryChoiceExplicit ? selectedDictionary : dictionaryForCurrentDirection();
    const nextQuery = homeInput.value.trim() ? homeInput.value : read("dictionary-draft", "");
    if (nextDictionary !== previousDictionary || (homeInput.value.trim() && nextQuery !== read("dictionary-draft", ""))) {
      write("dictionary-last-submit", "");
      if (resultLabel) resultLabel.textContent = "尚未查询";
    }
    selectedDictionary = nextDictionary;
    write("selected-dictionary", selectedDictionary);
    dictionaryInput.value = nextQuery;
    write("dictionary-draft", dictionaryInput.value);
    updateDictionaryPage();
    updateLookupState();
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
  const updateLookupState = () => {
    const previous = read("dictionary-last-submit", "");
    if (!previous) {
      resultLabel.textContent = "尚未查询";
      emptyCopy.textContent = dictionaryCatalog[selectedDictionary].name + "数据尚未接入，无法读取真实词条。当前页面不显示模拟单词、音标或释义。";
      return;
    }
    resultLabel.textContent = "尚未执行查询 · 词典数据未接入";
    emptyCopy.textContent = "已保留「" + previous + "」。" + dictionaryCatalog[selectedDictionary].name + "尚无本机数据，无法判断该词是否存在；没有调用普通翻译或网络。";
  };

  updatePills();
  dispatchModeState();
  updateDictionaryPage();
  updateLookupState();
  let homeDraftRevision = Math.max(0, Number(read("home-draft-revision", 0)) || 0);
  homeInput.addEventListener("input", () => {
    homeDraftRevision += 1;
    write("home-draft-revision", homeDraftRevision);
    write("home-draft", homeInput.value);
  });
  dictionaryInput?.addEventListener("input", () => write("dictionary-draft", dictionaryInput.value));
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
        <button class="setting-trigger v6-resource-trigger" type="button" data-screen="resources" aria-label="打开离线资源管理">
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M4 5h16v14H4z"/><path d="M8 9h8M8 13h5m-3 6v-3"/><circle cx="17" cy="16" r="2.2"/></svg>离线资源</span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>
        </button>
      </article>`);
  }

  const isNativeHost = () => document.documentElement.dataset.nativeHost === "true" && !!window.MiyinNativeBridge?.request;
  const languageNames = { "zh-Hans": "简体中文", en: "English", ru: "俄语", ja: "日语" };
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  const prettyModelStatus = status => ({
    downloaded: "已下载",
    notDownloaded: "未下载",
    downloading: "下载中",
    unsupported: "不支持",
    failed: "读取失败"
  }[status] || "状态未知");
  const setModelButtons = (row, status) => {
    const download = row.querySelector('[data-v6-model-action="download"]');
    const remove = row.querySelector('[data-v6-model-action="delete"]');
    if (download) { download.disabled = !isNativeHost() || status !== "notDownloaded"; download.setAttribute("aria-disabled", String(download.disabled)); }
    if (remove) {
      remove.disabled = !isNativeHost() || status !== "downloaded";
      remove.setAttribute("aria-disabled", String(remove.disabled));
      if (row.dataset.sharedModels === "true") remove.title = "删除此双向语言组合；Android 会保留其他组合仍在使用的模型";
    }
  };
  const translationRowMarkup = (pair, status) => {
    const sourceName = pair.sourceName || languageNames[pair.sourceTag] || pair.sourceTag;
    const targetName = pair.targetName || languageNames[pair.targetTag] || pair.targetTag;
    const pairName = sourceName + (pair.reverseAvailable ? " ↔ " : " → ") + targetName;
    return '<article class="v6-resource-card v6-translation-resource" data-v6-translation-row data-source-tag="' + escapeHtml(pair.sourceTag) + '" data-target-tag="' + escapeHtml(pair.targetTag) + '" data-shared-models="' + String(pair.reverseAvailable) + '" data-model-status="' + escapeHtml(status) + '">' +
      '<div class="v6-resource-copy"><strong>' + escapeHtml(pairName) + '</strong><small>Google ML Kit · Android 平台管理' + (pair.reverseAvailable ? '；双向共用模型' : '') + '</small></div>' +
      '<span class="v6-resource-status" data-v6-row-status data-status="' + escapeHtml(status) + '" role="status" aria-live="polite">' + prettyModelStatus(status) + '</span>' +
      '<div class="v6-resource-actions"><button type="button" data-v6-model-action="download" disabled aria-disabled="true">下载</button><button type="button" data-v6-model-action="delete" disabled aria-disabled="true">删除</button><button type="button" data-v6-model-action="refresh">刷新</button></div></article>';
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
    if (!translationResourceList) return;
    if (!isNativeHost()) {
      translationResourceList.innerHTML = '<article class="v6-resource-card v6-resource-card--unavailable"><div class="v6-resource-copy"><strong>简体中文 ↔ English</strong><small>Google ML Kit · 由 Android 平台管理</small></div><span class="v6-resource-status">请在觅音 App 中读取</span><div class="v6-resource-actions"><button type="button" disabled aria-disabled="true">下载</button><button type="button" disabled aria-disabled="true">删除</button></div></article>';
      return;
    }
    translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">正在读取本机支持的翻译模型…</div>';
    try {
      const pairs = await window.MiyinNativeBridge.request("translation.supportedPairs");
      if (!Array.isArray(pairs) || pairs.length === 0) {
        translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">此设备没有报告可管理的离线翻译语言组合。</div>';
        return;
      }
      const uniquePairs = new Map();
      pairs.forEach(pair => {
        const key = [pair.sourceTag, pair.targetTag].sort().join("::");
        const reverseAvailable = pairs.some(other => other.sourceTag === pair.targetTag && other.targetTag === pair.sourceTag);
        const current = uniquePairs.get(key);
        const preferThisDirection = pair.sourceTag === "zh-Hans" || pair.sourceTag === "zh";
        if (!current || (preferThisDirection && !current.preferred)) {
          uniquePairs.set(key, { ...pair, reverseAvailable, preferred: preferThisDirection });
        }
      });
      const packagePairs = [...uniquePairs.values()];
      translationResourceList.innerHTML = packagePairs.map(pair => translationRowMarkup(pair, "checking")).join("");
      await Promise.all([...translationResourceList.querySelectorAll("[data-v6-translation-row]")].map(row =>
        updateTranslationRow(row, { sourceTag: row.dataset.sourceTag, targetTag: row.dataset.targetTag })
      ));
    } catch {
      translationResourceList.innerHTML = '<div class="v6-resource-loading" role="status">无法读取本机模型目录，请稍后重试。</div><button type="button" class="v6-resource-retry" data-v6-model-action="reload-list">重试读取</button>';
    }
  };
  refreshTranslationResources();
  window.addEventListener("miyin:native-host-ready", refreshTranslationResources);

  const performTranslationModelAction = async actionButton => {
    const action = actionButton.dataset.v6ModelAction;
    if (action === "reload-list") { refreshTranslationResources(); return; }
    const row = actionButton.closest("[data-v6-translation-row]");
    if (!row) return;
    const pair = { sourceTag: row.dataset.sourceTag, targetTag: row.dataset.targetTag };
    if (action === "refresh") { updateTranslationRow(row, pair); return; }
    if (!isNativeHost()) return;
    if (action === "delete" && !window.confirm("删除此翻译模型？Android 会保留其他语言组合仍在使用的共享模型。")) return;
    const statusNode = row.querySelector("[data-v6-row-status]");
    row.querySelectorAll("button").forEach(button => { button.disabled = true; button.setAttribute("aria-disabled", "true"); });
    if (statusNode) {
      statusNode.dataset.status = action === "download" ? "downloading" : "deleting";
      statusNode.textContent = action === "download" ? "正在下载…" : "正在删除…";
    }
    row.dataset.modelStatus = action === "download" ? "downloading" : "deleting";
    try {
      await window.MiyinNativeBridge.request(
        action === "download" ? "translation.downloadModel" : "translation.deleteModel",
        { ...pair, ...(action === "download" ? { wifiOnly: true } : {}) }
      );
      showToast(action === "download" ? "已请求 Android 下载翻译模型" : "已请求 Android 删除翻译模型");
    } catch (error) {
      showToast(error?.message || "模型操作未完成");
    }
    await updateTranslationRow(row, pair);
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
    const alphabetButton = event.target.closest("[data-v6-letter]");
    if (alphabetButton) {
      event.preventDefault();
      alphabetIndex?.querySelector("[aria-current='true']")?.removeAttribute("aria-current");
      alphabetButton.setAttribute("aria-current", "true");
      const letter = alphabetButton.dataset.v6Letter;
      const currentLetter = document.querySelector("[data-v6-current-letter]");
      if (currentLetter) currentLetter.textContent = letter;
      if (resultLabel) resultLabel.textContent = letter + " · 词典数据未接入";
      if (emptyCopy) emptyCopy.textContent = dictionaryCatalog[selectedDictionary].name + "尚未接入词条数据，无法显示 " + letter + " 开头的真实词条。";
      return;
    }
    const dictionaryOption = event.target.closest("[data-v6-open-dictionary]");
    if (dictionaryOption) {
      event.preventDefault();
      event.stopImmediatePropagation();
      const nextDictionary = dictionaryOption.dataset.v6OpenDictionary;
      if (nextDictionary !== selectedDictionary) {
        write("dictionary-last-submit", "");
        if (resultLabel) resultLabel.textContent = "尚未查询";
      }
      selectedDictionary = nextDictionary;
      dictionaryChoiceExplicit = true;
      write("dictionary-choice-explicit", true);
      write("selected-dictionary", selectedDictionary);
      updateDictionaryPage();
      updateLookupState();
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

  dictionaryForm?.addEventListener("submit", event => {
    event.preventDefault();
    event.stopPropagation();
    const query = dictionaryInput.value.trim();
    write("dictionary-draft", dictionaryInput.value);
    if (!query) {
      showToast("先输入要查的单词或短语");
      dictionaryInput.focus({ preventScroll: true });
      return;
    }
    write("dictionary-initialized", true);
    write("dictionary-last-submit", query);
    resultLabel.textContent = "未执行查询 · " + dictionaryCatalog[selectedDictionary].name + "数据未接入";
    emptyCopy.textContent = "已保留「" + query + "」。" + dictionaryCatalog[selectedDictionary].name + "没有可核验的本机词条数据，无法判断该词是否存在；不会改用普通翻译生成词义。";
    showToast("本机没有可查询的词典数据，输入已保留");
  }, true);

  dictionarySelect?.addEventListener("change", () => {
    selectedDictionary = dictionarySelect.value;
    dictionaryChoiceExplicit = true;
    write("dictionary-choice-explicit", true);
    write("selected-dictionary", selectedDictionary);
    write("dictionary-last-submit", "");
    updateDictionaryPage();
    updateLookupState();
  });

  window.addEventListener("miyin:open-dictionary-page", openDictionaryPage);

  document.addEventListener("click", event => {
    const screenButton = event.target.closest('[data-screen="resources"]');
    if (screenButton) window.setTimeout(refreshTranslationResources, 0);
  });
})();
