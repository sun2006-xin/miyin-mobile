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
  if (navVersion) navVersion.textContent = "手机端 · 整合预览 V5";

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

  let voiceState = "idle";
  let voiceTimers = [];
  let voiceDisplayMode = "immersive";
  let microphoneEnabled = false;
  let voiceDraft = "";
  let voiceFiles = [];
  let voiceCycle = 0;
  let voiceHintTimer = 0;
  let voiceStreamTimer = 0;
  let voiceStreamingText = "";
  let voiceStreamingActive = false;
  const voiceOverlay = $("#voice-overlay");
  const voiceStates = ["idle", "permission-required", "unavailable", "listening", "processing", "speaking", "paused", "permission-denied", "error"];
  const escapeHTML = value => String(value).replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[character]));

  function clearVoiceTimers() {
    voiceTimers.forEach(timer => window.clearTimeout(timer));
    voiceTimers = [];
    window.clearTimeout(voiceStreamTimer);
    voiceStreamTimer = 0;
    voiceCycle += 1;
  }
  function commitVoiceStream() {
    if (!voiceStreamingActive) return "";
    const text = voiceStreamingText.trim();
    voiceStreamingActive = false;
    voiceStreamingText = "";
    if (text && window.MiyinV5Chat && typeof window.MiyinV5Chat.appendVoiceAssistant === "function") {
      window.MiyinV5Chat.appendVoiceAssistant(text);
    }
    renderVoiceTranscript();
    return text;
  }
  function startVoiceAnswerStream(answer, cycle) {
    const characters = typeof Intl.Segmenter === "function"
      ? Array.from(new Intl.Segmenter("zh-CN", { granularity: "grapheme" }).segment(answer), part => part.segment)
      : Array.from(answer);
    let cursor = 0;
    voiceStreamingText = "";
    voiceStreamingActive = true;

    const revealNext = () => {
      if (cycle !== voiceCycle || voiceState !== "speaking" || !voiceStreamingActive) return;
      if (cursor >= characters.length) {
        commitVoiceStream();
        voiceTimers.push(window.setTimeout(() => {
          if (cycle === voiceCycle && voiceState === "speaking") applyVoiceEvent("finish-response");
        }, 1050));
        return;
      }

      const character = characters[cursor++];
      voiceStreamingText += character;
      renderVoiceTranscript();
      const delay = /[，。！？；：,.!?;:]/u.test(character) ? 135 : 31;
      voiceStreamTimer = window.setTimeout(revealNext, delay);
    };

    voiceStreamTimer = window.setTimeout(revealNext, 100);
  }
  function voicePanelMarkup() {
    return '<div class="voice-experience"><header class="voice-topbar"><button class="voice-history" type="button" data-screen="history" aria-label="AI 会话历史" title="AI 会话历史"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.2 2"/></svg></button><div class="voice-top-title"><strong id="voice-title">觅音</strong></div><button class="voice-profile" type="button" data-screen="settings" aria-label="用户与设置" title="用户与设置"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="8" r="3.2"/><path d="M5 20c.4-3.5 2.8-5.5 7-5.5s6.6 2 7 5.5"/></svg></button></header><main class="voice-stage"><p class="sr-only" id="voice-copy">AI 实时聊天的单一会话页面。上滑或点按箭头查看字幕，下滑或再次点按箭头收起字幕。</p><div class="voice-orb-row"><button class="voice-caption-toggle" type="button" data-v5-voice-action="toggle-captions" aria-label="上滑查看对话" aria-expanded="false"><svg class="voice-arrow-up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="m6 14 6-6 6 6"/></svg><svg class="voice-arrow-down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="m6 10 6 6 6-6"/></svg></button><div class="voice-orb-slot"></div><div class="voice-state-label" id="voice-state-label" role="status" aria-live="polite"></div><span class="voice-hint" id="voice-hint" aria-hidden="true">上滑查看对话</span></div><div class="voice-transcript" id="voice-transcript" role="log" aria-label="AI 实时聊天字幕" aria-live="off" aria-hidden="true" inert></div></main><footer class="voice-controls"><div class="voice-interrupt-slot"><button class="voice-interrupt" type="button" data-v5-voice-action="interrupt" hidden>点击中断回答</button></div><div class="voice-extension-menu" id="voice-extension-menu" aria-label="更多能力" hidden><button type="button" data-v5-voice-action="camera"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6H8l1.4-2h5.2L16 6h1.5A2.5 2.5 0 0 1 20 8.5v8a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.2"/></svg>拍照附加文字</button><button type="button" data-v5-voice-action="screen-share"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8m-4-4v4m-3-10 3-3 3 3m-3-3v7"/></svg>共享屏幕</button><button type="button" data-v5-voice-action="image"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M4 5h16v14H4z"/><circle cx="9" cy="10" r="1.3"/><path d="m20 15-4-4-7 8"/></svg>附加图片文字</button><button type="button" data-v5-voice-action="file"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v5h5M9 13h6m-6 4h6"/></svg>附加文本文件</button><button type="button" data-v5-voice-action="tts-language">朗读语言与音色</button><div class="voice-selected-files" id="voice-selected-files" aria-live="polite"></div></div><form class="voice-controls-row" id="voice-composer"><button class="voice-add" type="button" data-v5-voice-action="toggle-menu" aria-label="更多能力" aria-expanded="false" aria-controls="voice-extension-menu" title="更多能力"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg></button><div class="voice-input-capsule"><input id="voice-input" type="text" enterkeyhint="send" autocomplete="off" placeholder="回复 AI…" aria-label="在 AI 实时聊天中输入消息"><button class="voice-microphone is-muted" type="button" data-v5-voice-action="toggle-mic" aria-label="开启麦克风" aria-pressed="false" title="开启麦克风"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3m-3 0h6M4 4l16 16"/></svg></button></div><button class="voice-end" type="button" data-v5-voice-action="end" aria-label="结束 AI 实时会话" title="结束 AI 实时会话"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg></button></form><input class="voice-file-input" id="voice-image-file" type="file" accept="image/*" aria-label="选择图片"><input class="voice-file-input" id="voice-document-file" type="file" accept=".pdf,.doc,.docx,.txt,.md,.ppt,.pptx,.xls,.xlsx" aria-label="选择文件"></footer></div>';
  }
  function renderVoiceTranscript() {
    const box = $("#voice-transcript", voiceOverlay);
    if (!box || voiceDisplayMode !== "captions") return;
    const stickToLatest = box.scrollHeight - box.scrollTop - box.clientHeight < 44;
    const streamingParagraph = voiceStreamingActive
      ? $(".voice-transcript-line.is-streaming p", box)
      : null;
    if (streamingParagraph) {
      streamingParagraph.textContent = voiceStreamingText;
      if (stickToLatest) box.scrollTop = box.scrollHeight;
      return;
    }
    const messages = window.MiyinV5Chat && typeof window.MiyinV5Chat.getActiveMessages === "function"
      ? window.MiyinV5Chat.getActiveMessages()
      : [];
    const recent = messages.slice(-18);
    const lastAssistant = recent.reduce((index, message, current) => message.role === "assistant" ? current : index, -1);
    if (!recent.length) {
      box.innerHTML = '<div class="voice-transcript-empty">你的对话会显示在这里</div>';
      return;
    }
    box.innerHTML = recent.map((message, index) => {
      const speaker = message.role === "user" ? "你" : "觅音 AI";
      const roleClass = message.role === "user" ? "user" : "assistant";
      const current = !voiceStreamingActive && index === lastAssistant && (voiceState === "speaking" || message.status === "pending");
      const older = index < recent.length - 4 ? " is-older" : "";
      const attachments = Array.isArray(message.attachments) && message.attachments.length
        ? '<small class="voice-message-attachments">' + message.attachments.map(file => escapeHTML(file.name)).join(" · ") + "</small>"
        : "";
      return '<article class="voice-transcript-line ' + roleClass + older + (current ? " is-current" : "") + '" data-message-id="' + escapeHTML(message.id) + '"><small>' + speaker + '</small><p>' + escapeHTML(message.text) + '</p>' + attachments + '</article>';
    }).join("");
    if (voiceState === "processing") {
      box.insertAdjacentHTML("beforeend", '<article class="voice-transcript-line assistant is-current"><small>觅音 AI</small><p class="voice-thinking">正在思考…</p></article>');
    }
    if (voiceStreamingActive) {
      box.insertAdjacentHTML("beforeend", '<article class="voice-transcript-line assistant is-current is-streaming"><small>觅音 AI</small><p>' + escapeHTML(voiceStreamingText) + '</p></article>');
    }
    if (stickToLatest) box.scrollTop = box.scrollHeight;
  }
  function updateVoiceControls() {
    if (!voiceOverlay) return;
    voiceOverlay.dataset.voiceState = voiceState;
    voiceOverlay.dataset.displayMode = voiceDisplayMode;
    voiceOverlay.dataset.micMuted = String(!microphoneEnabled);
    const label = $("#voice-state-label", voiceOverlay);
    const mic = $("[data-v5-voice-action='toggle-mic']", voiceOverlay);
    const interrupt = $("[data-v5-voice-action='interrupt']", voiceOverlay);
    const transcript = $("#voice-transcript", voiceOverlay);
    const captionToggle = $("[data-v5-voice-action='toggle-captions']", voiceOverlay);
    const orb = $(".ai-orb-renderer", voiceOverlay);
    const statuses = {
      "permission-required": "点按麦克风开始语音 · 也可直接输入",
      unavailable: "语音暂不可用 · 仍可输入文字",
      listening: microphoneEnabled ? "正在聆听 · 本地交互预览" : "麦克风已静音 · 可继续输入文字",
      processing: "觅音正在思考",
      speaking: "觅音正在回答",
      paused: "语音已暂停 · 点按麦克风继续",
      "permission-denied": "麦克风未开启 · 仍可输入文字",
      error: "语音暂时中断 · 仍可输入文字"
    };
    if (label) label.textContent = window.MiyinChat?.native ? ({listening:"正在本机聆听 · 停顿两秒或点麦克风结束",processing:"正在处理这条消息",speaking:"觅音正在回答",paused:"点麦克风继续 · 也可直接输入", "permission-required":"点麦克风开始 · 也可直接输入"}[voiceState] || statuses[voiceState] || "") : statuses[voiceState] || "";
    if (mic) {
      const micLabel = microphoneEnabled ? "静音麦克风" : "开启麦克风";
      mic.setAttribute("aria-label", micLabel);
      mic.setAttribute("title", micLabel);
      mic.setAttribute("aria-pressed", String(microphoneEnabled));
      mic.classList.toggle("is-muted", !microphoneEnabled);
      mic.innerHTML = microphoneEnabled
        ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3m-3 0h6"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3m-3 0h6M4 4l16 16"/></svg>';
    }
    if (interrupt) interrupt.hidden = voiceState !== "speaking";
    if (transcript) {
      const hidden = voiceDisplayMode !== "captions";
      transcript.setAttribute("aria-hidden", String(hidden));
      transcript.inert = hidden;
    }
    if (captionToggle) {
      const expanded = voiceDisplayMode === "captions";
      captionToggle.setAttribute("aria-expanded", String(expanded));
      captionToggle.setAttribute("aria-label", expanded ? "收起字幕，返回沉浸聊天" : "上滑查看对话");
      captionToggle.title = expanded ? "收起字幕" : "查看对话";
    }
    if (orb) {
      orb.classList.toggle("is-listening", voiceState === "listening");
      orb.classList.toggle("is-thinking", voiceState === "processing");
      orb.classList.toggle("is-speaking", voiceState === "speaking");
    }
    renderVoiceTranscript();
    renderVoiceFiles();
  }
  function renderVoiceFiles() {
    const box = $("#voice-selected-files", voiceOverlay);
    if (!box) return;
    const shownFiles=window.MiyinChat?.native?window.MiyinChatUI.getPending().files:voiceFiles;
    box.innerHTML = shownFiles.map((file, index) => '<span class="voice-file-chip"><span class="voice-file-name">' + escapeHTML(file.name) + '</span><button type="button" data-v5-voice-action="remove-file" data-file-index="' + index + '" aria-label="移除 ' + escapeHTML(file.name) + '">×</button></span>').join("");
  }
  function renderVoiceSession() {
    if (!voiceOverlay) return;
    const panel = $(".voice-panel", voiceOverlay);
    const wasOpen = voiceOverlay.getAttribute("aria-hidden") === "false";
    const open = voiceState !== "idle";
    voiceOverlay.setAttribute("aria-hidden", String(!open));
    if (!$(".voice-experience", panel)) {
      const orb = $(".ai-orb-renderer", panel);
      panel.innerHTML = voicePanelMarkup();
      if (orb) $(".voice-orb-slot", panel).append(orb);
      const selectedFiles = $("#voice-selected-files", panel);
      const composer = $("#voice-composer", panel);
      if (selectedFiles && composer) composer.parentElement.insertBefore(selectedFiles, composer);
      panel.dataset.voiceBuilt = "true";
    }
    updateVoiceControls();
    if (wasOpen !== open) window.dispatchEvent(new Event("miyin:surface-visibility-change"));
    if (open && !wasOpen) {
      panel.focus();
      if (!load("voice-hint-seen", false)) {
        const hint = $("#voice-hint", voiceOverlay);
        if (hint) hint.classList.add("visible");
        save("voice-hint-seen", true);
        window.clearTimeout(voiceHintTimer);
        voiceHintTimer = window.setTimeout(() => $("#voice-hint", voiceOverlay)?.classList.remove("visible"), 3400);
      }
    }
  }
  function setVoiceSessionState(nextState) {
    if (!voiceStates.includes(nextState)) return false;
    voiceState = nextState;
    reportNativeRefreshActivity(["listening", "processing", "speaking"].includes(nextState));
    renderVoiceSession();
    return true;
  }
  function reportNativeRefreshActivity(active) {
    window.__miyinVoiceRefreshActive = active;
    if (!window.MiyinPerformance) return;
    if (active || !window.__miyinPointerInteractionActive) {
      window.MiyinPerformance.postMessage(active ? "active" : "idle");
    }
  }
  window.addEventListener("miyin:refresh-state-sync", () => {
    reportNativeRefreshActivity(["listening", "processing", "speaking"].includes(voiceState));
  });
  function applyVoiceEvent(eventName) {
    const nextState = window.MiyinV5Core.transitionVoiceSession(voiceState, eventName);
    setVoiceSessionState(nextState);
    return nextState;
  }
  function startVoiceSession() {
    if (voiceState !== "idle") { renderVoiceSession(); return; }
    clearVoiceTimers();
    voiceStreamingText = "";
    voiceStreamingActive = false;
    voiceDisplayMode = "immersive";
    microphoneEnabled = false;
    voiceFiles = [];
    voiceDraft = "";
    if (applyVoiceEvent("start") !== "permission-required") return;
  }
  function setVoiceDisplayMode(mode) {
    if (mode !== "immersive" && mode !== "captions") return;
    const openingCaptions = mode === "captions" && voiceDisplayMode !== "captions";
    voiceDisplayMode = mode;
    updateVoiceControls();
    if (openingCaptions) {
      const transcript = $("#voice-transcript", voiceOverlay);
      if (transcript) transcript.scrollTop = transcript.scrollHeight;
    }
  }
  function toggleVoiceDisplayMode() {
    setVoiceDisplayMode(voiceDisplayMode === "immersive" ? "captions" : "immersive");
  }
  function toggleMicrophone() {
    if(window.MiyinChat?.native){void window.MiyinChatVoice.toggleMicrophone();return}
    if (voiceState === "permission-required") {
      microphoneEnabled = true;
      applyVoiceEvent("allow");
      notify("麦克风已开启（本地预览）");
      return;
    }
    if (["permission-denied", "unavailable", "error"].includes(voiceState)) {
      applyVoiceEvent("retry");
      microphoneEnabled = true;
      applyVoiceEvent("allow");
      notify("麦克风已开启（本地预览）");
      return;
    }
    if (voiceState === "paused") applyVoiceEvent("resume");
    microphoneEnabled = !microphoneEnabled;
    updateVoiceControls();
    notify(microphoneEnabled ? "麦克风已开启（本地预览）" : "麦克风已静音");
  }
  function previewAnswer(text) {
    const shortText = String(text).replace(/\s+/gu, " ").trim().slice(0, 20);
    return "收到，我会围绕“" + shortText + "”继续和你讨论。这是本地预览回复，没有调用模型 API。";
  }
  function sendVoiceMessage(text = voiceDraft) {
    if(window.MiyinChat?.native){window.MiyinChatVoice.submit(text);return}
    const message = String(text || "").trim();
    if (voiceState === "idle") return;
    if (voiceState === "speaking") interruptVoiceAnswer();
    if (!message && !voiceFiles.length) { $("#voice-input", voiceOverlay)?.focus(); return; }
    if (voiceState === "processing") { notify("觅音正在思考，请稍候"); return; }
    clearVoiceTimers();
    voiceDraft = "";
    const input = $("#voice-input", voiceOverlay);
    if (input) input.value = "";
    const submittedText = message || "请帮我看看这个附件。";
    const attachments = voiceFiles.map(file => ({ name: file.name, type: file.type }));
    voiceFiles = [];
    const chat = window.MiyinV5Chat;
    if (!chat || typeof chat.appendVoiceUser !== "function") { applyVoiceEvent("error"); return; }
    chat.appendVoiceUser(submittedText, attachments);
    applyVoiceEvent("submit-text");
    const answer = previewAnswer(submittedText);
    const cycle = voiceCycle;
    voiceTimers.push(window.setTimeout(() => {
      if (voiceCycle !== cycle || voiceState !== "processing") return;
      applyVoiceEvent("respond");
      startVoiceAnswerStream(answer, cycle);
    }, 720));
    const menu = $("#voice-extension-menu", voiceOverlay);
    const plus = $("[data-v5-voice-action='toggle-menu']", voiceOverlay);
    if (menu) menu.hidden = true;
    if (plus) plus.setAttribute("aria-expanded", "false");
    updateVoiceControls();
  }
  function interruptVoiceAnswer() {
    if(window.MiyinChat?.native){void window.MiyinChatVoice.interrupt();return}
    if (voiceState !== "speaking") return;
    commitVoiceStream();
    clearVoiceTimers();
    applyVoiceEvent("interrupt");
    notify("已中断觅音回答");
  }
  function endVoiceSession() {
    if(window.MiyinChat?.native)void window.MiyinChatVoice.shutdown();
    if (voiceState === "speaking") commitVoiceStream();
    clearVoiceTimers();
    if (voiceState !== "idle") applyVoiceEvent("end");
    microphoneEnabled = false;
    voiceFiles = [];
    window.clearTimeout(voiceHintTimer);
    setVoiceSessionState("idle");
    const menu = $("#voice-extension-menu", voiceOverlay);
    const plus = $("[data-v5-voice-action='toggle-menu']", voiceOverlay);
    if (menu) menu.hidden = true;
    if (plus) plus.setAttribute("aria-expanded", "false");
    const trigger = $("[data-action='chat-voice']");
    if (trigger) trigger.focus();
  }
  function requestEndVoiceSession() {
    if (voiceState === "idle") return;
    window.dispatchEvent(new CustomEvent("miyin-v5:request-end-voice-session"));
  }
  window.addEventListener("miyin-v5:confirm-end-voice-session", () => {
    if (voiceState === "idle") return;
    endVoiceSession();
    notify("语音对话已结束");
  });
  function addVoiceFiles(fileList) {
    const selected = Array.from(fileList || []).map(file => ({ name: file.name, type: file.type || "application/octet-stream" }));
    voiceFiles = voiceFiles.concat(selected).slice(0, 4);
    renderVoiceFiles();
    if (selected.length) notify("已添加附件 · 仅在本地预览，不会上传");
  }
  function canStartVoiceSwipe(target) {
    if (!target || voiceState === "idle" || target.closest(".voice-controls, button, input, textarea, select")) return false;
    const transcript = target.closest(".voice-transcript");
    if (transcript && (voiceDisplayMode !== "captions" || transcript.scrollTop > 0)) return false;
    return true;
  }
  function onVoiceSwipeEnd(startX, startY, clientX, clientY) {
    if (!Number.isFinite(startX) || !Number.isFinite(startY)) return;
    const deltaX = clientX - startX;
    const deltaY = clientY - startY;
    if (Math.abs(deltaY) < 48 || Math.abs(deltaY) < Math.abs(deltaX) * 1.15) return;
    if (deltaY < 0 && voiceDisplayMode === "immersive") setVoiceDisplayMode("captions");
    else if (deltaY > 0 && voiceDisplayMode === "captions") setVoiceDisplayMode("immersive");
  }
  function onVoicePointerDown(event) {
    if (event.pointerType === "touch" || !canStartVoiceSwipe(event.target)) return;
    voiceOverlay.dataset.pointerSwipeStartX = String(event.clientX);
    voiceOverlay.dataset.pointerSwipeStartY = String(event.clientY);
  }
  function onVoicePointerUp(event) {
    if (event.pointerType === "touch" || !voiceOverlay.dataset.pointerSwipeStartY) return;
    const startX = Number(voiceOverlay.dataset.pointerSwipeStartX);
    const startY = Number(voiceOverlay.dataset.pointerSwipeStartY);
    delete voiceOverlay.dataset.pointerSwipeStartX;
    delete voiceOverlay.dataset.pointerSwipeStartY;
    onVoiceSwipeEnd(startX, startY, event.clientX, event.clientY);
  }
  function onVoiceTouchStart(event) {
    const touch = event.changedTouches && event.changedTouches[0];
    if (!touch) return;
    const target = document.elementFromPoint(touch.clientX, touch.clientY) || event.target;
    if (!canStartVoiceSwipe(target)) return;
    voiceOverlay.dataset.touchSwipeStartX = String(touch.clientX);
    voiceOverlay.dataset.touchSwipeStartY = String(touch.clientY);
  }
  function onVoiceTouchEnd(event) {
    const touch = event.changedTouches && event.changedTouches[0];
    if (!touch || !voiceOverlay.dataset.touchSwipeStartY) return;
    const startX = Number(voiceOverlay.dataset.touchSwipeStartX);
    const startY = Number(voiceOverlay.dataset.touchSwipeStartY);
    delete voiceOverlay.dataset.touchSwipeStartX;
    delete voiceOverlay.dataset.touchSwipeStartY;
    onVoiceSwipeEnd(startX, startY, touch.clientX, touch.clientY);
  }
  function onVoicePointerCancel() {
    delete voiceOverlay.dataset.pointerSwipeStartX;
    delete voiceOverlay.dataset.pointerSwipeStartY;
  }
  function onVoiceTouchCancel() {
    delete voiceOverlay.dataset.touchSwipeStartX;
    delete voiceOverlay.dataset.touchSwipeStartY;
  }
  function bindVoiceInteractions() {
    if (!voiceOverlay) return;
    voiceOverlay.addEventListener("pointerdown", onVoicePointerDown);
    voiceOverlay.addEventListener("pointerup", onVoicePointerUp);
    voiceOverlay.addEventListener("pointercancel", onVoicePointerCancel);
    voiceOverlay.addEventListener("touchstart", onVoiceTouchStart, { passive: true });
    voiceOverlay.addEventListener("touchend", onVoiceTouchEnd, { passive: true });
    voiceOverlay.addEventListener("touchcancel", onVoiceTouchCancel, { passive: true });
    voiceOverlay.addEventListener("submit", event => {
      if (event.target.id !== "voice-composer") return;
      event.preventDefault();
      sendVoiceMessage($("#voice-input", voiceOverlay)?.value || "");
    });
    voiceOverlay.addEventListener("input", event => {
      if (event.target.id === "voice-input") voiceDraft = event.target.value;
    });
    voiceOverlay.addEventListener("change", event => {
      if (!["voice-image-file", "voice-document-file"].includes(event.target.id)) return;
      addVoiceFiles(event.target.files);
      event.target.value = "";
    });
    voiceOverlay.addEventListener("click", event => {
      if (event.target.closest(".voice-controls")) return;
      const menu = $("#voice-extension-menu", voiceOverlay);
      const plus = $("[data-v5-voice-action='toggle-menu']", voiceOverlay);
      if (menu && !menu.hidden) {
        menu.hidden = true;
        plus?.setAttribute("aria-expanded", "false");
      }
    });
  }
  bindVoiceInteractions();
  renderVoiceSession();
  window.addEventListener("miyin-v5:start-voice-session", startVoiceSession);
  window.MiyinVoiceUI = Object.freeze({open:startVoiceSession,
    state(value,mic=false){microphoneEnabled=mic;setVoiceSessionState(value)},
    refresh:renderVoiceTranscript,refreshFiles:renderVoiceFiles,
    draft(text){const input=$("#voice-input",voiceOverlay);if(input){input.value=text;voiceDraft=text}},
    close:endVoiceSession});

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
  $$(".wheel-mode[data-mode-index='1'] .wheel-mode-icon, .wheel-center[data-mode-index='1'] .wheel-center-icon", app).forEach(node => { node.innerHTML = icon.ai; });
  const chatTitle = $("#screen-chat .top-brand strong");
  if (chatTitle) {
    chatTitle.classList.add("chat-title");
    chatTitle.textContent = "觅音";
  }

  const floatingEnabled = Boolean(load("floating-ball", false));
  let floatBallEnabled = floatingEnabled;
  let audioSources = { app: true, mic: true };
  let captionPrefs = { position: "bottom", size: "standard", display: "bilingual", font: "standard", backdrop: "medium", color: "white", ...load("caption-window", {}) };
  let pipEnabled = Boolean(load("pip-enabled", true));
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
    row.innerHTML = '<div class="setting-copy"><b>全局悬浮球</b><small>在其他 App 使用截屏翻译、同传和设置</small><span class="v4-switch-status" id="v4-float-status">已关闭</span></div><button class="v4-toggle" type="button" data-v4-float-toggle aria-pressed="false" aria-label="开启全局悬浮球"></button>';
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
      sourcePanel.innerHTML = '<div class="v4-audio-heading"><strong>音频来源</strong><small>会议可同时采集双方发言</small></div><div class="v4-audio-grid">' +
        '<button type="button" class="v4-audio-choice" data-v4-audio="app" aria-pressed="false"><span class="v4-audio-icon">' + icon.appAudio + '</span><span class="v4-audio-copy"><strong>其他 App 音频</strong><small>需系统授权 · 部分应用禁止采集</small></span></button>' +
        '<button type="button" class="v4-audio-choice" data-v4-audio="mic" aria-pressed="true"><span class="v4-audio-icon">' + icon.mic + '</span><span class="v4-audio-copy"><strong>麦克风</strong><small>你的现场发言</small></span></button>' +
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
    document.addEventListener("click", event => {
      const bilingualButton = event.target.closest('#screen-video .video-setting .switch[aria-label="字幕双语对照"]');
      if (bilingualButton) {
        const enabled = bilingualButton.getAttribute("aria-pressed") !== "true";
        bilingualButton.setAttribute("aria-pressed", String(enabled));
        captionPrefs.display = enabled ? "bilingual" : "translation";
        save("caption-window", captionPrefs);
        syncSubtitleWindow();
        window.dispatchEvent(new Event("miyin:subtitle-preferences-change"));
      }
    });
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
    windowEl.dataset.color = captionPrefs.color || "white";
    const source = $("#screen-home .v4-language-shell [data-action='source-language']")?.textContent.trim() || "中";
    const target = $("#screen-home .v4-language-shell [data-action='target-language']")?.textContent.trim() || "英";
    const meta = $("#v4-pip-meta");
    const metaText = "同传字幕 · " + source + " ⇄ " + target;
    if (meta && meta.textContent !== metaText) meta.textContent = metaText;
    const videoPreview = $("#screen-video .subtitle-preview");
    if (videoPreview) {
      videoPreview.dataset.v4Display = captionPrefs.display;
      videoPreview.dataset.v4Font = captionPrefs.font;
      videoPreview.dataset.v4Color = captionPrefs.color;
      const original = $(".caption-card:not(.translation)", videoPreview);
      const translated = $(".caption-card.translation", videoPreview);
      if (original) original.hidden = captionPrefs.display === "translation";
      if (translated) translated.hidden = captionPrefs.display === "source";
    }
    syncSettingSheet();
  }

  window.addEventListener("miyin:subtitle-preferences-change", () => {
    pipEnabled = Boolean(load("pip-enabled", true));
    captionPrefs = { ...captionPrefs, ...load("caption-window", {}) };
    syncSubtitleWindow();
  });
  window.addEventListener("miyin:caption-quick-preferences", event => {
    const incoming = event.detail || {};
    const allowed = { font: ["small", "standard", "large"], color: ["white", "mint", "yellow"], display: ["bilingual", "source", "translation"], size: ["small", "standard", "large"] };
    for (const [key, values] of Object.entries(allowed)) {
      if (values.includes(incoming[key])) captionPrefs[key] = incoming[key];
    }
    save("caption-window", captionPrefs);
    window.dispatchEvent(new Event("miyin:subtitle-preferences-change"));
  });

  function syncSettingSheet() {
    if (openSheetKind !== "caption-settings") return;
    $$("[data-v4-pref]", sheet).forEach(button => button.setAttribute("aria-pressed", String(captionPrefs[button.dataset.v4Pref] === button.dataset.v4Value)));
    const positionLabel = { top: "上方", middle: "中间", bottom: "下方" }[captionPrefs.position] || "下方";
    const previewPosition = $("#v4-setting-preview-position", sheet);
    if (previewPosition && previewPosition.textContent !== positionLabel) previewPosition.textContent = positionLabel;
    const demo = $(".v4-demo-screen", sheet);
    if (demo) {
      demo.dataset.backdrop = captionPrefs.backdrop || "medium";
      demo.dataset.color = captionPrefs.color || "white";
      demo.dataset.font = captionPrefs.font || "standard";
    }
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
      sheet.innerHTML = '<section class="v4-sheet-card" role="dialog" aria-modal="true" aria-labelledby="v4-sheet-title"><div class="v4-sheet-head"><h2 id="v4-sheet-title">截屏翻译</h2><button class="v4-sheet-close" type="button" data-v4-action="close-sheet" aria-label="关闭">×</button></div><p class="v4-sheet-copy">切换到要翻译的应用，点击觅音悬浮球中的“截屏翻译”。允许系统单次截屏后，觅音会在原图文字位置生成译图。</p><div class="v4-sheet-actions"><button type="button" class="primary" data-v4-action="close-sheet">知道了</button></div></section>';
    } else {
      sheet.innerHTML = '<section class="v4-sheet-card" role="dialog" aria-modal="true" aria-labelledby="v4-sheet-title"><div class="v4-sheet-head"><h2 id="v4-sheet-title">字幕窗口设置</h2><button class="v4-sheet-close" type="button" data-v4-action="close-sheet" aria-label="关闭">×</button></div><p class="v4-sheet-copy">调整字幕窗口的位置、大小、音源和显示内容。正在同传时会立即生效。</p><div class="v4-demo-screen"><div class="v4-demo-screen-head"><span>字幕窗口预览</span><span id="v4-setting-preview-position">下方</span><span>觅音</span></div><div class="v4-demo-screen-copy"><b>The course starts at half past nine.</b><small>课程九点半开始。</small></div></div>' +
        '<section class="v4-setting-group"><b>窗口位置</b><div class="v4-choice-row"><button type="button" data-v4-pref="position" data-v4-value="top">上方</button><button type="button" data-v4-pref="position" data-v4-value="middle">中间</button><button type="button" data-v4-pref="position" data-v4-value="bottom">下方</button></div></section>' +
        '<section class="v4-setting-group"><b>字幕框高度 · 可见历史</b><div class="v4-choice-row"><button type="button" data-v4-pref="size" data-v4-value="small">约两段</button><button type="button" data-v4-pref="size" data-v4-value="standard">标准</button><button type="button" data-v4-pref="size" data-v4-value="large">更多历史</button></div></section>' +
        '<section class="v4-setting-group"><b>音频来源 · 可同时开启</b><div class="v4-source-sheet-list"><button type="button" data-v4-audio="app" aria-pressed="false"><span>其他 App 媒体声音 · 对方发言</span><span class="v4-source-check"></span></button><button type="button" data-v4-audio="mic" aria-pressed="false"><span>麦克风 · 我的发言</span><span class="v4-source-check"></span></button></div></section>' +
        '<section class="v4-setting-group"><b>翻译语言</b><div class="v4-choice-row"><button type="button" data-v4-action="choose-caption-language">选择源语言与译文语言</button></div></section>' +
        '<section class="v4-setting-group"><b>字幕内容</b><div class="v4-choice-row"><button type="button" data-v4-pref="display" data-v4-value="bilingual">原文 + 译文</button><button type="button" data-v4-pref="display" data-v4-value="translation">仅译文</button><button type="button" data-v4-pref="display" data-v4-value="source">仅原文</button></div></section>' +
        '<section class="v4-setting-group"><b>字幕外观</b><div class="v4-choice-row"><button type="button" data-v4-pref="font" data-v4-value="small">小字</button><button type="button" data-v4-pref="font" data-v4-value="standard">标准</button><button type="button" data-v4-pref="font" data-v4-value="large">大字</button></div><div class="v4-choice-row" style="margin-top:6px"><button type="button" data-v4-pref="backdrop" data-v4-value="clear">更透明</button><button type="button" data-v4-pref="backdrop" data-v4-value="light">浅色半透明</button><button type="button" data-v4-pref="backdrop" data-v4-value="medium">深色半透明</button><button type="button" data-v4-pref="backdrop" data-v4-value="dark">深色增强</button></div><div class="v4-choice-row" style="margin-top:6px"><button type="button" data-v4-pref="color" data-v4-value="white">白字</button><button type="button" data-v4-pref="color" data-v4-value="mint">薄荷字</button><button type="button" data-v4-pref="color" data-v4-value="yellow">暖黄字</button></div></section>' +
        '<p class="v4-note">其他 App 音频只采集 Android 和播放应用允许录制的媒体声音；通话声音可能无法采集。</p><div class="v4-sheet-actions"><button type="button" data-v4-action="close-sheet">完成</button></div></section>';
    }
    sheet.classList.add("open");
    sheet.setAttribute("aria-hidden", "false");
    if (kind === "caption-settings") {
      syncAudio();
      syncSettingSheet();
      window.dispatchEvent(new Event("miyin:caption-settings-opened"));
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
    const voiceAction = target.closest("[data-v5-voice-action]");
    if (voiceAction) {
      const action = voiceAction.dataset.v5VoiceAction;
      if (action === "toggle-captions") { toggleVoiceDisplayMode();return; }
      if (action === "toggle-mic") { toggleMicrophone();return; }
      if (action === "interrupt") { interruptVoiceAnswer();return; }
      if (action === "end") { requestEndVoiceSession();return; }
      if (action === "toggle-menu") {
        const menu = $("#voice-extension-menu", voiceOverlay);
        const expanded = menu && menu.hidden;
        if (menu) menu.hidden = !expanded;
        voiceAction.setAttribute("aria-expanded", String(Boolean(expanded)));
        return;
      }
      if (action === "camera" || action === "screen-share") {
        const menu = $("#voice-extension-menu", voiceOverlay);
        const plus = $("[data-v5-voice-action='toggle-menu']", voiceOverlay);
        if (menu) menu.hidden = true;
        if (plus) plus.setAttribute("aria-expanded", "false");
        notify(action === "camera" ? "摄像头能力将在 Android 阶段接入 · 当前为界面预览" : "屏幕共享能力将在 Android 阶段接入 · 当前为界面预览");
        return;
      }
      if (action === "image" || action === "file") {
        const menu = $("#voice-extension-menu", voiceOverlay);
        const plus = $("[data-v5-voice-action='toggle-menu']", voiceOverlay);
        if (menu) menu.hidden = true;
        if (plus) plus.setAttribute("aria-expanded", "false");
        $(action === "image" ? "#voice-image-file" : "#voice-document-file", voiceOverlay)?.click();
        return;
      }
      if (action === "remove-file") {
        voiceFiles.splice(Number(voiceAction.dataset.fileIndex), 1);
        renderVoiceFiles();
        return;
      }
    }
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
      if (name === "choose-caption-language") { closeSheet(); $("#screen-video .subtitle-lang")?.click(); return; }
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
      window.dispatchEvent(new Event("miyin:subtitle-preferences-change"));
      return;
    }

    if (sheet.classList.contains("open") && target === sheet) { closeSheet(); return; }
    if (!target.closest(".v4-float-menu, .v4-float-ball")) closeFloatMenu();
  });

  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && !event.defaultPrevented) {
      if (voiceOverlay && voiceOverlay.getAttribute("aria-hidden") === "false") { requestEndVoiceSession();event.preventDefault();return; }
      if (sheet.classList.contains("open")) closeSheet();
      else closeFloatMenu();
    }
    if (event.key === "Tab" && voiceOverlay && voiceOverlay.getAttribute("aria-hidden") === "false") {
      const focusable = $$('button:not(:disabled), input:not(:disabled)', voiceOverlay).filter(element => element.offsetParent !== null && !element.hidden);
      if (!focusable.length) return;
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault();last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault();first.focus(); }
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
