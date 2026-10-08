(() => {
  "use strict";

  const app = document.querySelector("#app");
  if (!app) return;

  const prefix = "miyin.full.preview.v5.";
  const $ = (selector, scope = document) => scope.querySelector(selector);
  const $$ = (selector, scope = document) => Array.from(scope.querySelectorAll(selector));
  const load = (key, fallback) => {
    try {
      const value = localStorage.getItem(prefix + key);
      return value === null ? fallback : JSON.parse(value);
    } catch { return fallback; }
  };
  const save = (key, value) => {
    try { localStorage.setItem(prefix + key, JSON.stringify(value)); } catch { /* preview only */ }
  };
  const icon = {
    ai: '<svg data-v4-ai="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 11.5a7.5 7.5 0 0 1-8 7.5 8.5 8.5 0 0 1-3.8-.9L4 20l1.4-3.5A7 7 0 0 1 4 12c0-4 3.4-7 8-7s8 2.6 8 6.5Z"/><path d="M8.5 11h6M8.5 14h3.5"/><path d="m18.1 2.3.55 1.6 1.6.55-1.6.55-.55 1.6-.55-1.6-1.6-.55 1.6-.55z"/></svg>',
    appAudio: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="3.5" width="16" height="17" rx="2.5"/><path d="M8 8h8M8 11h4"/><path d="M14 15v2m3-4v6"/></svg>',
    mic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3m-3 0h6"/></svg>',
    camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6H8l1.4-2h5.2L16 6h1.5A2.5 2.5 0 0 1 20 8.5v8a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.2"/></svg>',
    image: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 5h16v14H4z"/><circle cx="9" cy="10" r="1.3"/><path d="m20 15-4-4-7 8"/></svg>',
    settings: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 8v8m-4-4h8"/><circle cx="12" cy="12" r="8.5"/><path d="M19 5 21 3"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12 4 4L19 6"/></svg>'
  };

  document.title = "觅音 · 手机端交互预览 V5";
  const navVersion = $(".nav-brand small");
  if (navVersion) navVersion.textContent = "手机端 · 整合预览 V4";

  let toastTimer = 0;
  function notify(message) {
    let toast = $("#v4-toast");
    if (!toast) {
      toast = document.createElement("div");
      toast.id = "v4-toast";
      toast.className = "v4-toast";
      toast.setAttribute("role", "status");
      toast.setAttribute("aria-live", "polite");
      app.appendChild(toast);
    }
    toast.textContent = message;
    toast.classList.add("show");
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => toast.classList.remove("show"), 2200);
  }

  function shortLanguage(value) {
    const names = {
      "中文": "中", "English": "英", "en": "英", "en-us": "英",
      "日本語": "日", "日本": "日", "한국어": "韩", "한국": "韩",
      "Français": "法", "fr": "法", "Español": "西", "es": "西"
    };
    return names[value] || names[value.toLocaleLowerCase()] || value.slice(0, 1);
  }
  function normalizeLanguageLabels() {
    $$(".v4-language-shell [data-action='source-language']").forEach(button => {
      const label = shortLanguage(button.textContent.trim());
      if (button.textContent !== label) button.textContent = label;
      button.setAttribute("aria-label", "选择源语言：" + label);
    });
    $$(".v4-language-shell [data-action='target-language']").forEach(button => {
      const label = shortLanguage(button.textContent.trim());
      if (button.textContent !== label) button.textContent = label;
      button.setAttribute("aria-label", "选择目标语言：" + label);
    });
    syncSubtitleWindow();
  }
  function buildLanguageShell(parent, reuseParent) {
    if (!parent) return null;
    const existing = $(".v4-language-shell", parent);
    if (existing) return existing;
    const shell = reuseParent ? parent : document.createElement("div");
    shell.classList.add("v4-language-shell");
    shell.setAttribute("role", "group");
    shell.setAttribute("aria-label", "翻译语言");
    const source = $("[data-action='source-language']", parent);
    const swap = $("[data-action='swap-language']", parent);
    const target = $("[data-action='target-language']", parent);
    if (!source || !swap || !target) return null;
    source.classList.add("language-pill");
    target.classList.add("language-pill");
    source.classList.add("language-option");
    target.classList.add("language-option");
    swap.classList.add("language-swap");
    if (!reuseParent) {
      parent.replaceChildren(shell);
      shell.append(source, swap, target);
    } else {
      shell.replaceChildren(source, swap, target);
    }
    return shell;
  }
  buildLanguageShell($("#screen-home .language-row"), false);
  buildLanguageShell($("#screen-face .face-language"), true);

  const aiObserver = new MutationObserver(() => {
    $$(".wheel-mode[data-mode-index='1'] .wheel-mode-icon, .wheel-center[data-mode-index='1'] .wheel-center-icon", app).forEach(node => {
      if (!$("svg[data-v4-ai]", node)) node.innerHTML = icon.ai;
    });
  });
  aiObserver.observe(app, { childList: true, subtree: true });
  const chatNavIcon = $(".screen-nav [data-screen='chat'] svg");
  if (chatNavIcon) chatNavIcon.outerHTML = icon.ai;

  const floatingEnabled = Boolean(load("floating-ball", false));
  let floatBallEnabled = floatingEnabled;
  let audioSources = load("audio-sources", { app: true, mic: true });
  let captionPrefs = load("caption-window", { position: "bottom", size: "standard", display: "bilingual", font: "standard", backdrop: "medium" });
  let pipEnabled = Boolean(load("pip-enabled", false));
  let videoActive = false;
  let priorFocus = null;

  const styleOptions = [
    { id: "sea-glass", label: "海玻璃", hint: "你选中的蓝色" },
    { id: "mint-metallic", label: "薄荷金属", hint: "清透薄荷色" },
    { id: "classic-mist", label: "经典雾蓝", hint: "旧版按钮外观" }
  ];
  function setMicStyle(style, quiet = false) {
    if (!styleOptions.some(option => option.id === style)) return;
    $$(".mic-button").forEach(button => { button.dataset.v4MicStyle = style; });
    $$("[data-v4-mic-style]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.v4MicStyle === style)));
    const label = $("#v4-mic-style-current");
    const selected = styleOptions.find(option => option.id === style);
    if (label) label.textContent = selected.label;
    save("mic-style", style);
    if (!quiet) notify("语音按钮外观已切换为「" + selected.label + "」");
  }
  function injectMicStyles() {
    const displayCard = $$(".setting-card").find(card => $(".setting-trigger", card)?.textContent.includes("显示与偏好"));
    const panel = displayCard && $(".setting-panel", displayCard);
    const themeChoices = panel && $(".theme-choice-list", panel);
    if (!panel || !themeChoices) return;
    const section = document.createElement("section");
    section.className = "v4-mic-style-section";
    section.innerHTML = '<div class="v4-style-heading"><div><b>语音按钮外观</b><small>单独选择按钮效果，不改变 V2 页面主题</small></div><span id="v4-mic-style-current">海玻璃</span></div><div class="v4-style-list" role="group" aria-label="选择语音按钮外观">' +
      '<button class="v4-style-choice" type="button" data-v4-mic-style="sea-glass" aria-pressed="false"><span class="v4-style-sample sea-glass">' + icon.mic + '</span><strong>海玻璃</strong><small>你选中的蓝色</small></button>' +
      '<button class="v4-style-choice" type="button" data-v4-mic-style="mint-metallic" aria-pressed="false"><span class="v4-style-sample mint-metallic">' + icon.mic + '</span><strong>薄荷金属</strong><small>清透薄荷色</small></button>' +
      '<button class="v4-style-choice" type="button" data-v4-mic-style="classic-mist" aria-pressed="false"><span class="v4-style-sample classic-mist">' + icon.mic + '</span><strong>经典雾蓝</strong><small>旧版外观</small></button>' +
      '</div>';
    themeChoices.insertAdjacentElement("afterend", section);
  }
  injectMicStyles();
  setMicStyle(load("mic-style", "sea-glass"), true);

  const privacyCard = $$(".setting-card").find(card => $(".setting-trigger", card)?.textContent.includes("隐私与权限"));
  const privacyPanel = privacyCard && $(".setting-panel", privacyCard);
  if (privacyPanel) {
    const row = document.createElement("div");
    row.className = "setting-row v4-floating-setting";
    row.innerHTML = '<div class="setting-copy"><b>全局悬浮球</b><small>开启后可在其他 App 使用截图翻译和字幕工具</small><span class="v4-switch-status" id="v4-float-status">预览关闭</span></div><button class="v4-toggle" type="button" data-v4-float-toggle aria-pressed="false" aria-label="开启全局悬浮球"></button>';
    privacyPanel.appendChild(row);
  }

  const videoScreen = $("#screen-video");
  if (videoScreen) {
    const oldSources = $(".source-pills", videoScreen);
    if (oldSources) {
      const sourcePanel = document.createElement("section");
      sourcePanel.className = "v4-audio-sources";
      sourcePanel.setAttribute("role", "group");
      sourcePanel.setAttribute("aria-label", "字幕采集音源，可同时选择多个来源");
      sourcePanel.innerHTML = '<div class="v4-audio-heading"><strong>音频来源</strong><small>会议可同时开启两种</small></div><div class="v4-audio-grid">' +
        '<button type="button" class="v4-audio-choice" data-v4-audio="app" aria-pressed="true"><span class="v4-audio-icon">' + icon.appAudio + '</span><span class="v4-audio-copy"><strong>其他 App 音频</strong><small>会议 / 直播 / 视频</small></span><span class="v4-audio-check"></span></button>' +
        '<button type="button" class="v4-audio-choice" data-v4-audio="mic" aria-pressed="true"><span class="v4-audio-icon">' + icon.mic + '</span><span class="v4-audio-copy"><strong>麦克风</strong><small>你的现场发言</small></span><span class="v4-audio-check"></span></button>' +
        '</div><div class="v4-audio-status" id="v4-audio-status">两种音源同时开启</div>';
      oldSources.insertAdjacentElement("afterend", sourcePanel);
      oldSources.remove();
    }
    const startButton = $("#video-start", videoScreen);
    if (startButton) {
      startButton.removeAttribute("data-action");
      startButton.dataset.v4Action = "toggle-video";
      startButton.textContent = "开始识别";
    }
    const pipButton = $(".video-setting .switch[aria-label='字幕画中画 PiP']", videoScreen);
    if (pipButton) {
      pipButton.addEventListener("click", event => {
        event.stopPropagation();
        pipEnabled = !pipEnabled;
        pipButton.setAttribute("aria-pressed", String(pipEnabled));
        save("pip-enabled", pipEnabled);
        syncSubtitleWindow();
        notify(pipEnabled ? "字幕窗口已开启，可在其他页面预览" : "字幕窗口已关闭");
      });
    }
    const bilingualButton = $(".video-setting .switch[aria-label='字幕双语对照']", videoScreen);
    if (bilingualButton) {
      bilingualButton.addEventListener("click", event => {
        event.stopPropagation();
        const enabled = bilingualButton.getAttribute("aria-pressed") !== "true";
        bilingualButton.setAttribute("aria-pressed", String(enabled));
        captionPrefs.display = enabled ? "bilingual" : "translation";
        save("caption-window", captionPrefs);
        syncSubtitleWindow();
      });
    }
  }

  const floatingLayer = document.createElement("div");
  floatingLayer.className = "v4-floating-layer";
  floatingLayer.innerHTML = '<div class="v4-subtitle-window" id="v4-subtitle-window" data-enabled="false" data-position="bottom" data-size="standard" data-display="bilingual" data-font="standard" data-backdrop="medium" aria-label="字幕悬浮窗预览"><div class="v4-pip-head"><span class="v4-pip-meta" id="v4-pip-meta">字幕预览 · 中 ⇄ 英</span><button class="v4-pip-settings" type="button" data-v4-action="open-caption-settings" aria-label="设置字幕窗口位置、大小、音源与译文">' + icon.settings + '</button></div><span class="v4-pip-line source" id="v4-pip-source">The course starts at half past nine.</span><span class="v4-pip-line translation" id="v4-pip-translation">课程九点半开始。</span></div>' +
    '<button class="v4-float-ball" id="v4-float-ball" type="button" data-v4-action="toggle-float-menu" data-enabled="false" aria-expanded="false" aria-label="打开觅音全局悬浮球工具">' + icon.camera + '</button>' +
    '<div class="v4-float-menu" id="v4-float-menu" role="menu" aria-label="觅音悬浮球工具"><small>觅音快捷工具 · 跨页面预览</small><button type="button" role="menuitem" data-v4-action="open-screenshot">' + icon.image + '<span>截图翻译</span></button><button type="button" role="menuitem" data-v4-action="open-caption-settings">' + icon.settings + '<span>字幕与音频设置</span></button></div>';
  app.appendChild(floatingLayer);

  const sheet = document.createElement("div");
  sheet.className = "v4-sheet";
  sheet.setAttribute("aria-hidden", "true");
  app.appendChild(sheet);
  let openSheetKind = "";
  normalizeLanguageLabels();

  function sourceNames() {
    const names = [];
    if (audioSources.app) names.push("其他 App 音频");
    if (audioSources.mic) names.push("麦克风");
    return names;
  }
  function syncAudio() {
    $$("[data-v4-audio]").forEach(button => {
      const enabled = Boolean(audioSources[button.dataset.v4Audio]);
      button.setAttribute("aria-pressed", String(enabled));
      if (button.classList.contains("v4-audio-choice")) {
        button.setAttribute("aria-label", (button.dataset.v4Audio === "app" ? "其他 App 音频" : "麦克风") + (enabled ? "，已开启" : "，已关闭"));
        const check = $(".v4-audio-check", button);
        if (check) check.innerHTML = enabled ? icon.check : "";
      }
      const check = $(".v4-source-check", button);
      if (check) check.innerHTML = enabled ? icon.check : "";
    });
    const chosen = sourceNames();
    const status = $("#v4-audio-status");
    const start = $("#video-start");
    if (status) {
      status.dataset.error = String(chosen.length === 0);
      status.textContent = chosen.length === 2 ? "App 音频 + 麦克风同时开启 · 预览模拟" : chosen.length === 1 ? chosen[0] + "已开启 · 预览模拟" : "至少开启一个音源，才能开始识别";
    }
    if (start) {
      start.disabled = chosen.length === 0;
      start.setAttribute("aria-disabled", String(chosen.length === 0));
    }
  }

  function syncSubtitleWindow() {
    const windowEl = $("#v4-subtitle-window");
    if (!windowEl) return;
    windowEl.dataset.enabled = String(pipEnabled);
    windowEl.dataset.position = captionPrefs.position;
    windowEl.dataset.size = captionPrefs.size;
    windowEl.dataset.display = captionPrefs.display;
    windowEl.dataset.font = captionPrefs.font;
    windowEl.dataset.backdrop = captionPrefs.backdrop;
    const source = $("#screen-home .v4-language-shell [data-action='source-language']")?.textContent.trim() || "中";
    const target = $("#screen-home .v4-language-shell [data-action='target-language']")?.textContent.trim() || "英";
    const meta = $("#v4-pip-meta");
    const metaText = "字幕预览 · " + source + " ⇄ " + target;
    if (meta && meta.textContent !== metaText) meta.textContent = metaText;
    const videoPreview = $("#screen-video .subtitle-preview");
    if (videoPreview) {
      videoPreview.dataset.v4Display = captionPrefs.display;
      const original = $(".caption-card:not(.translation)", videoPreview);
      const translated = $(".caption-card.translation", videoPreview);
      if (original) original.hidden = captionPrefs.display === "translation";
      if (translated) translated.hidden = captionPrefs.display === "source";
    }
    syncSettingSheet();
  }

  function syncSettingSheet() {
    if (openSheetKind !== "caption-settings") return;
    $$("[data-v4-pref]", sheet).forEach(button => button.setAttribute("aria-pressed", String(captionPrefs[button.dataset.v4Pref] === button.dataset.v4Value)));
    const positionLabel = { top: "上方", middle: "中间", bottom: "下方" }[captionPrefs.position] || "下方";
    const previewPosition = $("#v4-setting-preview-position", sheet);
    if (previewPosition && previewPosition.textContent !== positionLabel) previewPosition.textContent = positionLabel;
  }

  function setFloatBall(enabled, quiet = false) {
    floatBallEnabled = Boolean(enabled);
    save("floating-ball", floatBallEnabled);
    const button = $("#v4-float-ball");
    const toggle = $("[data-v4-float-toggle]");
    const status = $("#v4-float-status");
    if (button) button.dataset.enabled = String(floatBallEnabled);
    if (toggle) {
      toggle.setAttribute("aria-pressed", String(floatBallEnabled));
      toggle.setAttribute("aria-label", floatBallEnabled ? "关闭全局悬浮球" : "开启全局悬浮球");
    }
    if (status) status.textContent = floatBallEnabled ? "预览已开启 · 真实系统权限需在 Android 设置" : "预览关闭";
    if (!floatBallEnabled) closeFloatMenu();
    if (!quiet) notify(floatBallEnabled ? "全局悬浮球已开启（页面预览）" : "全局悬浮球已关闭");
  }
  function closeFloatMenu() {
    const menu = $("#v4-float-menu");
    const button = $("#v4-float-ball");
    if (menu) menu.classList.remove("open");
    if (button) button.setAttribute("aria-expanded", "false");
  }
  function openSheet(kind) {
    openSheetKind = kind;
    priorFocus = document.activeElement;
    closeFloatMenu();
    if (kind === "screenshot") {
      sheet.innerHTML = '<section class="v4-sheet-card" role="dialog" aria-modal="true" aria-labelledby="v4-sheet-title"><div class="v4-sheet-head"><h2 id="v4-sheet-title">截图翻译</h2><button class="v4-sheet-close" type="button" data-v4-action="close-sheet" aria-label="关闭">×</button></div><p class="v4-sheet-copy">从当前画面选取文字并查看译文。这里先展示流程样例，暂不读取其他 App 的真实屏幕。</p><div class="v4-demo-screen"><div class="v4-demo-screen-head"><span>课程视频</span><span>09:30</span><span>⋯</span></div><div class="v4-demo-screen-copy"><b>THE COURSE STARTS AT HALF PAST NINE.</b><small>示例画面 · 已选择文字区域</small></div></div><div class="v4-result"><div><small>识别原文 · English</small><strong>The course starts at half past nine.</strong></div><div><small>翻译结果 · 简体中文</small><strong>课程九点半开始。</strong></div></div><p class="v4-note">正式功能会在用户授权后截取当前屏幕，并提供选择文字区域和翻译结果。</p><div class="v4-sheet-actions"><button type="button" data-v4-action="close-sheet">关闭</button><button class="primary" type="button" data-v4-action="save-screenshot-draft">保存译文草稿</button></div></section>';
    } else {
      sheet.innerHTML = '<section class="v4-sheet-card" role="dialog" aria-modal="true" aria-labelledby="v4-sheet-title"><div class="v4-sheet-head"><h2 id="v4-sheet-title">字幕窗口设置</h2><button class="v4-sheet-close" type="button" data-v4-action="close-sheet" aria-label="关闭">×</button></div><p class="v4-sheet-copy">调整字幕小窗口的位置、大小、采集音源和译文显示。更改会同步到悬浮窗预览。</p><div class="v4-demo-screen"><div class="v4-demo-screen-head"><span>字幕窗口预览</span><span id="v4-setting-preview-position">下方</span><span>觅音</span></div><div class="v4-demo-screen-copy"><b>The course starts at half past nine.</b><small>课程九点半开始。</small></div></div>' +
        '<section class="v4-setting-group"><b>窗口位置</b><div class="v4-choice-row"><button type="button" data-v4-pref="position" data-v4-value="top">上方</button><button type="button" data-v4-pref="position" data-v4-value="middle">中间</button><button type="button" data-v4-pref="position" data-v4-value="bottom">下方</button></div></section>' +
        '<section class="v4-setting-group"><b>窗口大小</b><div class="v4-choice-row"><button type="button" data-v4-pref="size" data-v4-value="small">小</button><button type="button" data-v4-pref="size" data-v4-value="standard">标准</button><button type="button" data-v4-pref="size" data-v4-value="large">大</button></div></section>' +
        '<section class="v4-setting-group"><b>音频来源 · 可以同时开启</b><div class="v4-source-sheet-list"><button type="button" data-v4-audio="app" aria-pressed="false"><span>其他 App 音频 · 会议 / 直播 / 视频</span><span class="v4-source-check"></span></button><button type="button" data-v4-audio="mic" aria-pressed="false"><span>麦克风 · 你的现场发言</span><span class="v4-source-check"></span></button></div></section>' +
        '<section class="v4-setting-group"><b>字幕内容</b><div class="v4-choice-row"><button type="button" data-v4-pref="display" data-v4-value="bilingual">原文 + 译文</button><button type="button" data-v4-pref="display" data-v4-value="translation">仅译文</button><button type="button" data-v4-pref="display" data-v4-value="source">仅原文</button></div></section>' +
        '<section class="v4-setting-group"><b>字号与底色</b><div class="v4-choice-row"><button type="button" data-v4-pref="font" data-v4-value="small">小字</button><button type="button" data-v4-pref="font" data-v4-value="standard">标准</button><button type="button" data-v4-pref="font" data-v4-value="large">大字</button></div><div class="v4-choice-row" style="margin-top:6px"><button type="button" data-v4-pref="backdrop" data-v4-value="light">浅色底</button><button type="button" data-v4-pref="backdrop" data-v4-value="medium">半透明</button><button type="button" data-v4-pref="backdrop" data-v4-value="dark">深色底</button></div></section>' +
        '<p class="v4-note">音源开关分别控制 App 播放声音和麦克风输入；两项都开启时，会议双方的声音都可进入字幕流程。</p><div class="v4-sheet-actions"><button type="button" data-v4-action="close-sheet">完成</button></div></section>';
    }
    sheet.classList.add("open");
    sheet.setAttribute("aria-hidden", "false");
    if (kind === "caption-settings") {
      syncAudio();
      syncSettingSheet();
    }
    const first = $("button", sheet);
    if (first) window.setTimeout(() => first.focus(), 0);
  }
  function closeSheet() {
    sheet.classList.remove("open");
    sheet.setAttribute("aria-hidden", "true");
    openSheetKind = "";
    if (priorFocus && typeof priorFocus.focus === "function") priorFocus.focus();
  }

  function updateVideoStatus() {
    const button = $("#video-start");
    const status = $("#video-status");
    const chosen = sourceNames();
    if (!button || !status) return;
    if (videoActive) {
      button.textContent = "暂停识别";
      button.classList.add("active");
      status.textContent = "正在识别：" + chosen.join(" + ") + " · 预览模拟";
    } else {
      button.textContent = "开始识别";
      button.classList.remove("active");
      status.textContent = "尚未开始 · 本页为交互预览";
    }
  }
  function toggleVideo() {
    if (!videoActive && sourceNames().length === 0) {
      const status = $("#v4-audio-status");
      if (status) status.dataset.error = "true";
      notify("请先开启 App 音频或麦克风");
      return;
    }
    videoActive = !videoActive;
    updateVideoStatus();
    notify(videoActive ? "字幕识别已开始（预览模拟）" : "字幕识别已暂停");
  }

  setFloatBall(floatBallEnabled, true);
  syncAudio();
  syncSubtitleWindow();
  if (videoScreen) {
    const pipButton = $(".video-setting .switch[aria-label='字幕画中画 PiP']", videoScreen);
    if (pipButton) pipButton.setAttribute("aria-pressed", String(pipEnabled));
    const bilingualButton = $(".video-setting .switch[aria-label='字幕双语对照']", videoScreen);
    if (bilingualButton) bilingualButton.setAttribute("aria-pressed", String(captionPrefs.display === "bilingual"));
    updateVideoStatus();
  }

  document.addEventListener("click", event => {
    const target = event.target;
    const action = target.closest("[data-v4-action]");
    if (action) {
      const name = action.dataset.v4Action;
      if (name === "toggle-float-menu") {
        if (!floatBallEnabled) return;
        const menu = $("#v4-float-menu");
        const expanded = action.getAttribute("aria-expanded") !== "true";
        menu.classList.toggle("open", expanded);
        action.setAttribute("aria-expanded", String(expanded));
        return;
      }
      if (name === "open-screenshot") { openSheet("screenshot"); return; }
      if (name === "open-caption-settings") { openSheet("caption-settings"); return; }
      if (name === "close-sheet") { closeSheet(); return; }
      if (name === "save-screenshot-draft") { closeSheet(); notify("示例译文已加入本地草稿"); return; }
      if (name === "toggle-video") { toggleVideo(); return; }
    }

    const floatToggle = target.closest("[data-v4-float-toggle]");
    if (floatToggle) { setFloatBall(!floatBallEnabled); return; }

    const styleChoice = target.closest("[data-v4-mic-style]");
    if (styleChoice) { setMicStyle(styleChoice.dataset.v4MicStyle); return; }

    const audioChoice = target.closest("[data-v4-audio]");
    if (audioChoice) {
      const key = audioChoice.dataset.v4Audio;
      audioSources[key] = !audioSources[key];
      save("audio-sources", audioSources);
      syncAudio();
      if (videoActive) updateVideoStatus();
      return;
    }

    const preference = target.closest("[data-v4-pref]");
    if (preference) {
      captionPrefs[preference.dataset.v4Pref] = preference.dataset.v4Value;
      save("caption-window", captionPrefs);
      syncSubtitleWindow();
      return;
    }

    if (sheet.classList.contains("open") && target === sheet) { closeSheet(); return; }
    if (!target.closest(".v4-float-menu, .v4-float-ball")) closeFloatMenu();
  });

  document.addEventListener("keydown", event => {
    if (event.key === "Escape") {
      if (sheet.classList.contains("open")) closeSheet();
      else closeFloatMenu();
    }
    if (event.key === "Tab" && sheet.classList.contains("open")) {
      const focusable = $$("button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled)", sheet);
      if (!focusable.length) return;
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });

  const languageObserver = new MutationObserver(normalizeLanguageLabels);
  languageObserver.observe(app, { childList: true, subtree: true, characterData: true });
  window.addEventListener("storage", event => {
    if (event.key === prefix + "floating-ball") setFloatBall(load("floating-ball", false), true);
  });
})();
