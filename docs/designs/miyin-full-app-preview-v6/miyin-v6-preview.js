(() => {
  "use strict";

  const stateKey = "miyin.full.preview.v6.translation-ui.";
  const read = (key, fallback = "") => {
    try {
      const value = localStorage.getItem(stateKey + key);
      return value == null ? fallback : JSON.parse(value);
    } catch {
      return fallback;
    }
  };
  const write = (key, value) => {
    try { localStorage.setItem(stateKey + key, JSON.stringify(value)); } catch { /* local preview only */ }
  };
  const icon = {
    dictionary: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H20v17H7.5A2.5 2.5 0 0 0 5 21.5z"/><path d="M5 4.5v17M9 7h7m-7 4h7"/></svg>',
    resources: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M4 5h16v14H4z"/><path d="M8 9h8M8 13h5m-3 6v-3"/><circle cx="17" cy="16" r="2.2"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="10.8" cy="10.8" r="6.8"/><path d="m16 16 4 4"/></svg>',
    book: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 4.5A2.5 2.5 0 0 1 7.5 2H20v17H7.5A2.5 2.5 0 0 0 5 21.5z"/><path d="M5 4.5v17M9 7h7m-7 4h6"/></svg>',
    info: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/></svg>',
    arrow: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m14 5-7 7 7 7M7 12h13"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="8" r="3.2"/><path d="M5 20c.4-3.5 2.8-5.5 7-5.5s6.6 2 7 5.5"/></svg>'
  };
  const screenNav = document.querySelector(".screen-nav");
  const app = document.querySelector("#app");
  if (!screenNav || !app) return;
  const previewLabel = document.querySelector(".nav-brand small");
  if (previewLabel) previewLabel.textContent = "手机端 · 交互预览 V6";

  const navMarkup = `
    <button type="button" data-screen="dictionary">${icon.dictionary}词典查词</button>
    <button type="button" data-screen="resources">${icon.resources}离线资源</button>`;
  const videoNav = screenNav.querySelector('[data-screen="video"]');
  if (videoNav && !screenNav.querySelector('[data-screen="dictionary"]')) {
    videoNav.insertAdjacentHTML("afterend", navMarkup);
  }

  const topbar = (backScreen, backLabel) => `
    <header class="topbar">
      <button class="top-icon" type="button" data-screen="${backScreen}" data-v6-nav-back aria-label="${backLabel}">${icon.arrow}</button>
      <div class="top-brand"><strong>觅音</strong></div>
      <button class="avatar-button" type="button" data-screen="settings" aria-label="用户与设置">${icon.user}</button>
    </header>`;

  app.insertAdjacentHTML("beforeend", `
    <section class="screen v6-screen" id="screen-dictionary" aria-label="词典查词">
      ${topbar("home", "返回翻译")}
      <main class="v6-screen-content">
        <h1 class="v6-page-heading">词典页面</h1>
        <p class="v6-page-subtitle">选择词典后查询；当前预览未连接词典数据。</p>
        <div class="v6-dictionary-toolbar">
          <span class="v6-direction">English <span>→</span> 简体中文</span>
          <label class="v6-dictionary-select-wrap" for="v6-dictionary-select"><span>词典</span>
            <select id="v6-dictionary-select" aria-label="选择词典">
              <option value="en-zh">英汉词典</option>
              <option value="zh-en">汉英词典</option>
              <option value="zh-ru">中俄词典</option>
              <option value="zh-ja">中日词典</option>
            </select>
          </label>
        </div>
        <form class="v6-dictionary-search" role="search" aria-label="词典查询">
          <input id="v6-dictionary-input" type="search" autocomplete="off" placeholder="输入英文单词或短语…" aria-label="输入要查的单词或短语">
          <button type="submit" aria-label="查询词典">${icon.search}</button>
        </form>
        <p class="v6-dictionary-query-status" id="v6-dictionary-query-status" role="status">尚未接入词典数据</p>
        <div class="v6-dictionary-browser">
          <div class="v6-dictionary-list" aria-live="polite">
            <div class="v6-letter-heading"><span id="v6-dictionary-letter">A</span><small>词条　音标　释义</small></div>
            <div class="v6-dictionary-empty" id="v6-dictionary-empty-copy">
              <span class="v6-empty-icon">${icon.book}</span>
              <strong id="v6-dictionary-empty-title">当前词典暂无可核验词条</strong>
              <p>为保证准确性，预览不生成单词、音标或词义。接入合规词典数据后将在此按字母显示。</p>
              <button class="v6-primary-action" type="button" data-screen="resources">查看词典资源</button>
            </div>
          </div>
          <nav class="v6-alphabet" aria-label="按字母浏览词典"></nav>
        </div>
        <p class="v6-structure-note"><strong>词条信息</strong>　将按词典来源展示单词、音标、词性和释义。</p>
      </main>
    </section>

    <section class="screen v6-screen" id="screen-resources" aria-label="离线资源">
      ${topbar("settings", "返回设置")}
      <main class="v6-screen-content">
        <h1 class="v6-page-heading">离线资源</h1>
        <p class="v6-page-subtitle">逐项查看翻译、词典与语音包；设备状态和下载目录尚未接入预览。</p>
        <aside class="v6-resource-note" aria-label="预览状态说明">
          <span class="v6-empty-icon">${icon.info}</span>
          <div><strong>设备状态不可读取</strong><p>当前是网页预览。下载和删除按钮保持禁用，不代表手机已下载或未下载。</p></div>
        </aside>
        <section class="v6-resource-section" aria-labelledby="v6-runtime-heading">
          <h2 id="v6-runtime-heading">离线翻译</h2>
          ${resourceCard("中英离线翻译", "中文 ⇄ English · 由 Android 平台管理", "device")}
          ${resourceCard("中日离线翻译", "中文 ⇄ 日本語 · 资源目录未接入", "unavailable")}
          ${resourceCard("中俄离线翻译", "中文 ⇄ Русский · 资源目录未接入", "unavailable")}
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-dictionary-heading">
          <h2 id="v6-dictionary-heading">离线词典</h2>
          ${resourceCard("英汉词典", "English → 简体中文 · 词条数据未接入", "unavailable", "en-zh")}
          ${resourceCard("汉英词典", "简体中文 → English · 词条数据未接入", "unavailable", "zh-en")}
          ${resourceCard("中俄词典", "简体中文 ⇄ Русский · 词条数据未接入", "unavailable", "zh-ru")}
          ${resourceCard("中日词典", "简体中文 ⇄ 日本語 · 词条数据未接入", "unavailable", "zh-ja")}
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-voice-heading">
          <h2 id="v6-voice-heading">语音识别与合成</h2>
          ${resourceCard("中文语音识别", "离线识别资源 · 设备状态未读取", "unavailable")}
          ${resourceCard("English 语音识别", "离线识别资源 · 设备状态未读取", "unavailable")}
          ${resourceCard("中文语音合成", "离线语音资源 · 设备状态未读取", "unavailable")}
          ${resourceCard("English 语音合成", "离线语音资源 · 设备状态未读取", "unavailable")}
        </section>
        <section class="v6-resource-section" aria-labelledby="v6-catalog-heading">
          <h2 id="v6-catalog-heading">资源说明</h2>
          <div class="v6-catalog-empty">预览暂时无法判断设备上已安装的资源。连接真实下载目录后，此处会显示实际状态、版本与可执行操作。</div>
        </section>
      </main>
    </section>`);

  function resourceCard(title, detail, status, dictionaryId = "") {
    const stateCopy = status === "device" ? "设备状态未读取" : "预览不可用";
    const dictionaryAction = dictionaryId
      ? `<button type="button" class="v6-resource-open" data-v6-dictionary-open="${dictionaryId}">查看词典</button>`
      : "";
    return `<article class="v6-resource-card" data-resource-state="${status}">
      <div class="v6-resource-copy"><strong>${title}</strong><small>${detail}</small><span class="v6-resource-status">${stateCopy}</span></div>
      <div class="v6-resource-actions">${dictionaryAction}<button type="button" disabled aria-disabled="true" title="预览未接入真实下载目录">下载</button><button type="button" disabled aria-disabled="true" title="预览未读取设备状态">删除</button></div>
    </article>`;
  }

  const dictionaryNav = screenNav.querySelector('[data-screen="dictionary"]');
  const resourcesNav = screenNav.querySelector('[data-screen="resources"]');
  if (!dictionaryNav || !resourcesNav) return;

  const sentenceMenu = document.createElement("div");
  sentenceMenu.className = "v6-mode-menu";
  sentenceMenu.setAttribute("role", "menu");
  sentenceMenu.setAttribute("aria-label", "选择翻译方式");
  sentenceMenu.innerHTML = '<button type="button" role="menuitemradio" aria-checked="true" data-v6-mode-choice="sentence">句子翻译</button><button type="button" role="menuitemradio" aria-checked="false" data-v6-mode-choice="dictionary">单词查词</button>';
  const modeHost = document.createElement("div");
  modeHost.className = "v6-mode-host";
  modeHost.innerHTML = '<button class="v6-mode-pill" type="button" data-v6-action="toggle-mode-menu" aria-haspopup="menu" aria-expanded="false">句子⌄</button>';
  modeHost.append(sentenceMenu);
  const translationInput = document.querySelector("#translation-input");
  const entry = document.querySelector("#screen-home .text-entry");
  const faceStatus = document.querySelector("#face-status");
  const dictInput = document.querySelector("#v6-dictionary-input");
  const dictionarySelect = document.querySelector("#v6-dictionary-select");
  const dictionaryDirection = document.querySelector(".v6-direction");
  const dictionaryBackButton = document.querySelector("#screen-dictionary .top-icon");
  const resourceBackButton = document.querySelector("#screen-resources .top-icon");
  const navigationStack = MiyinV5Core.createScreenReturnStack({ dictionary: "home", resources: "settings" });
  const returnableScreens = new Set(["dictionary", "resources"]);
  const toast = document.querySelector("#toast");
  const translateAction = document.querySelector('#screen-home [data-action="translate-text"]');
  const dictionaryDefinitions = {
    "en-zh": { source: "English", target: "简体中文", placeholder: "输入英文单词或短语…" },
    "zh-en": { source: "简体中文", target: "English", placeholder: "输入中文单词或短语…" },
    "zh-ru": { source: "简体中文", target: "Русский", placeholder: "输入中文或俄文词条…" },
    "zh-ja": { source: "简体中文", target: "日本語", placeholder: "输入中文或日文词条…" }
  };
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("");
  const alphabetNav = document.querySelector(".v6-alphabet");
  const alphabetHeading = document.querySelector("#v6-dictionary-letter");
  const alphabetEmptyTitle = document.querySelector("#v6-dictionary-empty-title");
  let dictionaryManuallySelected = read("dictionary-manually-selected", false) === true;
  if (alphabetNav) alphabetNav.innerHTML = alphabet.map(letter => `<button type="button" data-v6-letter="${letter}" aria-label="浏览 ${letter} 开头的词条">${letter}</button>`).join("");
  const homeInputTool = document.querySelector('#screen-home .text-entry [data-action="open-input-tools"]');
  const entryTools = document.querySelector("#entry-tools");
  const sentenceInputToolMarkup = homeInputTool?.innerHTML || "";
  if (translationInput && entry) {
    entry.insertBefore(modeHost, translationInput);
    translationInput.value = read("home-draft", translationInput.value);
    translationInput.addEventListener("input", () => write("home-draft", translationInput.value));
  }
  if (dictInput) dictInput.value = read("dictionary-draft", "");

  const updateDictionaryDirection = () => {
    const dictionary = dictionaryDefinitions[dictionarySelect?.value || "en-zh"] || dictionaryDefinitions["en-zh"];
    if (dictionaryDirection) {
      const arrow = document.createElement("span");
      arrow.textContent = "→";
      dictionaryDirection.replaceChildren(document.createTextNode(dictionary.source + " "), arrow, document.createTextNode(" " + dictionary.target));
    }
    if (dictInput) {
      dictInput.placeholder = dictionary.placeholder;
      dictInput.setAttribute("aria-label", dictionary.placeholder.replace("…", ""));
    }
  };
  if (dictionarySelect) {
    const savedDictionary = read("dictionary-id", "en-zh");
    dictionarySelect.value = dictionaryDefinitions[savedDictionary] ? savedDictionary : "en-zh";
  }
  updateDictionaryDirection();

  const modeValue = read("mode", "sentence");
  let selectedMode = modeValue === "dictionary" ? "dictionary" : "sentence";
  const syncTranslationInputTool = () => {
    if (!homeInputTool) return;
    const dictionaryMode = selectedMode === "dictionary";
    if (dictionaryMode) {
      entryTools?.classList.remove("open");
      homeInputTool.dataset.action = "open-dictionary-page";
      homeInputTool.classList.remove("round-tool");
      homeInputTool.classList.add("v6-dictionary-entry");
      homeInputTool.setAttribute("aria-label", "打开词典页面");
      homeInputTool.title = "打开词典页面";
      homeInputTool.innerHTML = `${icon.dictionary}<span>词典页</span>`;
      return;
    }
    homeInputTool.dataset.action = "open-input-tools";
    homeInputTool.classList.remove("v6-dictionary-entry");
    homeInputTool.classList.add("round-tool");
    homeInputTool.setAttribute("aria-label", "图片、文档或拍照翻译");
    homeInputTool.title = "图片、文档或拍照翻译";
    homeInputTool.innerHTML = sentenceInputToolMarkup;
  };
  const getPills = () => document.querySelectorAll(".v6-mode-pill");
  const closeMenus = () => {
    document.querySelectorAll(".v6-mode-menu.is-open").forEach(menu => menu.classList.remove("is-open"));
    getPills().forEach(pill => pill.setAttribute("aria-expanded", "false"));
  };
  const updatePills = () => {
    getPills().forEach(pill => { pill.textContent = selectedMode === "dictionary" ? "单词⌄" : "句子⌄"; });
    if (translationInput) translationInput.placeholder = selectedMode === "dictionary" ? "输入单词或短语…" : "输入文字翻译…";
    if (translateAction) {
      const label = selectedMode === "dictionary" ? "单词模式暂不可查词" : "翻译文字";
      translateAction.setAttribute("aria-label", label);
      translateAction.title = label;
    }
    document.querySelectorAll("[data-v6-mode-choice]").forEach(button => {
      button.setAttribute("aria-checked", String(button.dataset.v6ModeChoice === selectedMode));
    });
    syncTranslationInputTool();
  };
  const setBackTarget = (name, target) => {
    const button = name === "dictionary" ? dictionaryBackButton : name === "resources" ? resourceBackButton : null;
    if (!button) return;
    button.dataset.screen = target;
    button.setAttribute("aria-label", target === "resources" ? "返回离线资源" : target === "dictionary" ? "返回词典" : target === "settings" ? "返回设置" : "返回翻译");
  };
  const activeScreenName = () => document.querySelector(".screen.active")?.id.replace(/^screen-/, "") || "home";
  const navigate = (name, { recordReturn = true } = {}) => {
    const origin = activeScreenName();
    if (recordReturn) navigationStack.push(origin, name);
    if (returnableScreens.has(name)) {
      setBackTarget(name, navigationStack.peek(name) || (name === "dictionary" ? "home" : "settings"));
    }
    const button = document.querySelector(`.screen-nav [data-screen="${name}"]`);
    if (button) {
      button.dataset.v6ManagedNavigation = "true";
      button.click();
      delete button.dataset.v6ManagedNavigation;
    }
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
      if (activeScreenName() === "settings") {
        document.querySelector("#screen-settings [data-action='settings-back']")?.click();
        return true;
      }
      return navigateBackFromResourceArea();
    }
  };
  const chooseMode = mode => {
    selectedMode = mode === "dictionary" ? "dictionary" : "sentence";
    write("mode", selectedMode);
    updatePills();
    closeMenus();
    if (translationInput) write("home-draft", translationInput.value);
    window.dispatchEvent(new CustomEvent("miyin:translation-mode-change", { detail: { mode: selectedMode } }));
  };
  updatePills();

  const currentHomeDictionary = () => {
    const source = document.querySelector("#screen-home [data-action='source-language']")?.textContent.trim() || "中文";
    const target = document.querySelector("#screen-home [data-action='target-language']")?.textContent.trim() || "English";
    if (source === "English" && target === "中文") return "en-zh";
    if (source === "中文" && target === "English") return "zh-en";
    if (target.includes("日本")) return "zh-ja";
    if (target.includes("俄")) return "zh-ru";
    return "zh-en";
  };
  const selectDictionary = id => {
    const nextId = dictionaryDefinitions[id] ? id : "en-zh";
    if (dictionarySelect) dictionarySelect.value = nextId;
    write("dictionary-id", nextId);
    updateDictionaryDirection();
    if (alphabetHeading) alphabetHeading.textContent = "A";
    if (alphabetEmptyTitle) alphabetEmptyTitle.textContent = "A 开头词条暂不可用";
    alphabetNav?.querySelectorAll("[data-v6-letter]").forEach(button => button.setAttribute("aria-current", String(button.dataset.v6Letter === "A")));
  };
  const openDictionaryPage = ({ dictionaryId = "", fromHome = true } = {}) => {
    if (fromHome) {
      if (!dictionaryManuallySelected) selectDictionary(currentHomeDictionary());
      if (dictInput && translationInput) dictInput.value = translationInput.value;
      if (dictInput) write("dictionary-draft", dictInput.value);
    } else if (dictionaryId) {
      selectDictionary(dictionaryId);
      dictionaryManuallySelected = true;
      write("dictionary-manually-selected", true);
    }
    navigate("dictionary");
  };
  if (alphabetNav) {
    alphabetNav.querySelector('[data-v6-letter="A"]')?.setAttribute("aria-current", "true");
    alphabetNav.addEventListener("click", event => {
      const button = event.target.closest("[data-v6-letter]");
      if (!button) return;
      const letter = button.dataset.v6Letter;
      if (alphabetHeading) alphabetHeading.textContent = letter;
      if (alphabetEmptyTitle) alphabetEmptyTitle.textContent = `${letter} 开头词条暂不可用`;
      alphabetNav.querySelectorAll("[data-v6-letter]").forEach(item => item.setAttribute("aria-current", String(item === button)));
    });
  }
  dictionarySelect?.addEventListener("change", () => {
    write("dictionary-id", dictionarySelect.value);
    dictionaryManuallySelected = true;
    write("dictionary-manually-selected", true);
    updateDictionaryDirection();
    if (alphabetEmptyTitle) alphabetEmptyTitle.textContent = `${alphabetHeading?.textContent || "A"} 开头词条暂不可用`;
  });

  const micWrap = document.querySelector("#screen-face .face-mic-wrap");
  if (micWrap && faceStatus) {
    const meta = document.createElement("div");
    meta.className = "v6-face-meta";
    micWrap.append(meta);
    meta.append(faceStatus);
    faceStatus.textContent = "";
  }

  document.querySelectorAll(".top-brand strong").forEach(label => { label.textContent = "觅音"; });
  document.querySelectorAll(".top-brand small").forEach(label => label.remove());

  const settingsList = document.querySelector("#screen-settings .settings-list");
  if (settingsList && !settingsList.querySelector(".v6-resource-entry")) {
    settingsList.insertAdjacentHTML("beforeend", `
      <article class="setting-card v6-resource-entry">
        <button class="setting-trigger v6-resource-trigger" type="button" data-screen="resources" aria-label="打开离线资源管理">
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><path d="M4 5h16v14H4z"/><path d="M8 9h8M8 13h5m-3 6v-3"/><circle cx="17" cy="16" r="2.2"/></svg>离线资源</span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>
        </button>
      </article>`);
  }

  document.addEventListener("click", event => {
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
    const current = activeScreenName();
    if (returnableScreens.has(destination)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      navigate(destination);
      return;
    }
    if (destination !== "settings" && returnableScreens.has(current)) navigationStack.clear();
  }, true);

  const dictionaryForm = document.querySelector(".v6-dictionary-search");
  if (dictionaryForm) {
    dictionaryForm.addEventListener("submit", event => {
      event.preventDefault();
      if (dictInput) write("dictionary-draft", dictInput.value);
      const status = document.querySelector("#v6-dictionary-query-status");
      const query = dictInput?.value.trim() || "";
      if (status) status.textContent = query ? `未查询“${query}”：当前预览没有可用词典数据。` : "请输入单词或短语；当前未接入词典数据。";
      if (toast) {
        toast.textContent = "预览没有可用词典数据，未执行查询";
        toast.classList.add("show");
        window.setTimeout(() => toast.classList.remove("show"), 1700);
      }
    });
    dictInput?.addEventListener("input", () => {
      write("dictionary-draft", dictInput.value);
    });
  }
  dictionarySelect?.addEventListener("change", () => {
    write("dictionary-id", dictionarySelect.value);
    updateDictionaryDirection();
  });

  const chatMessages = document.querySelector("#screen-chat .chat-messages");
  if (chatMessages) {
    const updateChatHierarchy = () => {
      const bubbles = [...chatMessages.querySelectorAll(".chat-bubble")];
      let latestAssistant = -1;
      bubbles.forEach((bubble, index) => { if (bubble.classList.contains("assistant")) latestAssistant = index; });
      bubbles.forEach((bubble, index) => bubble.classList.toggle("v6-history", latestAssistant >= 0 && index < latestAssistant));
    };
    updateChatHierarchy();
    new MutationObserver(updateChatHierarchy).observe(chatMessages, { childList: true, subtree: true, characterData: true });
  }

  document.addEventListener("click", event => {
    const openDictionary = event.target.closest('#screen-home [data-action="open-dictionary-page"]');
    if (openDictionary) {
      event.preventDefault();
      event.stopImmediatePropagation();
      openDictionaryPage({ fromHome: true });
      return;
    }
    const openDictionaryFromResource = event.target.closest("[data-v6-dictionary-open]");
    if (openDictionaryFromResource) {
      event.preventDefault();
      event.stopImmediatePropagation();
      openDictionaryPage({ dictionaryId: openDictionaryFromResource.dataset.v6DictionaryOpen, fromHome: false });
      return;
    }
    const toggle = event.target.closest('[data-v6-action="toggle-mode-menu"]');
    if (toggle) {
      event.preventDefault();
      event.stopPropagation();
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
      event.stopPropagation();
      chooseMode(choice.dataset.v6ModeChoice);
      return;
    }
    if (!event.target.closest(".v6-mode-host")) closeMenus();
  });

  document.addEventListener("click", event => {
    const action = event.target.closest('#screen-home [data-action="translate-text"]');
    if (!action || selectedMode !== "dictionary") return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (toast) {
      toast.textContent = "单词模式已选中；点击词典页进入独立查词界面";
      toast.classList.add("show");
      window.setTimeout(() => toast.classList.remove("show"), 1700);
    }
  }, true);

  document.addEventListener("keydown", event => {
    if (event.target !== translationInput || event.key !== "Enter" || selectedMode !== "dictionary") return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (toast) {
      toast.textContent = "单词模式已选中；点击词典页进入独立查词界面";
      toast.classList.add("show");
      window.setTimeout(() => toast.classList.remove("show"), 1700);
    }
  }, true);

  window.addEventListener("miyin:open-dictionary-page", () => openDictionaryPage({ fromHome: true }));
  window.dispatchEvent(new CustomEvent("miyin:translation-mode-change", { detail: { mode: selectedMode } }));

  if (faceStatus) {
    const normalizeFaceStatus = () => {
      let text = faceStatus.textContent.trim();
      if (text.includes("按住说话") || text.includes("松开显示译文") || text.includes("点按上方状态继续")) {
        text = "待机";
        faceStatus.textContent = text;
      }
      faceStatus.classList.toggle("is-active", /正在(?:聆听|识别|翻译|显示译文|播放)/.test(text));
    };
    new MutationObserver(normalizeFaceStatus).observe(faceStatus, { childList: true, characterData: true, subtree: true });
    normalizeFaceStatus();
  }

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") closeMenus();
  });
})();
