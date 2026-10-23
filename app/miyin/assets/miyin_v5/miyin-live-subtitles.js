(() => {
  "use strict";

  const screen = document.querySelector("#screen-video");
  const bridge = window.MiyinNativeBridge;
  const context = window.MiyinLiveSubtitlesContext;
  if (!screen || !bridge || !context) return;

  const button = screen.querySelector("#video-start");
  const status = screen.querySelector("#video-status");
  const sourceLine = screen.querySelector("#video-source-text");
  const translatedLine = screen.querySelector("#video-target-text");
  const liveFeed = screen.querySelector("#video-live-feed");
  const currentCaption = screen.querySelector(".subtitle-current");
  const sourceLabel = screen.querySelector(".caption-card:not(.translation) small");
  const translatedLabel = screen.querySelector(".caption-card.translation small");
  const audioStatus = screen.querySelector("#v4-audio-status");
  const appAudio = screen.querySelector('[data-v4-audio="app"]');
  const microphone = screen.querySelector('[data-v4-audio="mic"]');
  const prefix = "miyin.full.preview.v5.";
  const floatingToggle = document.querySelector("[data-v4-float-toggle]");
  const floatingStatus = document.querySelector("#v4-float-status");
  const recordToggle = screen.querySelector("#video-record-toggle");
  const recordList = screen.querySelector("#video-record-list");
  const recordCount = screen.querySelector("#video-record-count");
  if (recordList) document.body.appendChild(recordList);
  const segmentMs = 9000;
  let active = false;
  let busy = false;
  let sessionId = null;
  let segmentTimer = 0;
  let sequence = 0;
  let generation = 0;
  let translationJob = Promise.resolve();
  let entries = [];
  let recognizedText = "";
  let recognizedLanguage = null;
  let audioSources = { app: true, mic: true };
  try {
    const saved = JSON.parse(localStorage.getItem(prefix + "audio-sources") || "null");
    if (saved && typeof saved === "object" && (saved.app || saved.mic)) {
      audioSources = { app: saved.app === true, mic: saved.mic === true };
    }
  } catch { /* use conference defaults */ }
  let playbackActive = false;
  let conferenceActive = false;
  let playbackSaved = false;
  let playbackEntries = [];
  let playbackRecording = null;
  let playbackRecordingError = "";
  let recordListMode = "segments";
  let previewSessionId = null;

  function message(text) { status.textContent = text; }
  function shouldRecordAudio() {
    return screen.querySelector('[aria-label="保存到历史记录"]')?.getAttribute("aria-pressed") === "true";
  }
  function overlayPrefs() {
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(prefix + "caption-window") || "{}"); } catch { /* defaults */ }
    return {
      position: saved.position || "bottom",
      size: saved.size || "standard",
      display: saved.display || "bilingual",
      font: saved.font || "standard",
      backdrop: saved.backdrop || "medium",
      color: saved.color || "white",
      enabled: localStorage.getItem(prefix + "pip-enabled") === "false" ? "false" : "true",
    };
  }
  async function refreshFloatingStatus() {
    if (document.documentElement.dataset.nativeHost !== "true") return;
    const previewLayer = document.querySelector(".v4-floating-layer");
    if (previewLayer) previewLayer.style.display = "none";
    try {
      const result = await bridge.request("floating.status");
      const enabled = result?.enabled === true;
      floatingToggle?.setAttribute("aria-pressed", String(enabled));
      floatingToggle?.setAttribute("aria-label", enabled ? "关闭全局悬浮球" : "开启全局悬浮球");
      if (floatingStatus) floatingStatus.textContent = enabled ? "已开启 · 可在其他 App 拖动并点按" : "已关闭";
    } catch {
      if (floatingStatus) floatingStatus.textContent = "暂时无法读取悬浮球状态";
    }
  }
  async function toggleFloating() {
    if (!floatingToggle) return;
    if (document.documentElement.dataset.nativeHost !== "true") {
      if (floatingStatus) floatingStatus.textContent = "请在觅音 Android 应用中开启";
      return;
    }
    const enable = floatingToggle.getAttribute("aria-pressed") !== "true";
    floatingToggle.disabled = true;
    try {
      const result = await bridge.request("floating.setEnabled", { enabled: enable });
      if (result?.permissionRequested) {
        if (floatingStatus) floatingStatus.textContent = "请在系统页面允许悬浮显示，返回后再次开启";
      } else {
        if (enable) await new Promise(resolve => window.setTimeout(resolve, 180));
        await refreshFloatingStatus();
      }
    } catch (error) {
      if (floatingStatus) floatingStatus.textContent = error?.message || "悬浮球操作失败";
    } finally {
      floatingToggle.disabled = false;
    }
  }
  function setButton() {
    button.disabled = busy;
    button.classList.toggle("active", active);
    button.textContent = active ? "结束同传" : busy ? "正在处理…" : "开始同传";
  }
  function setAudioChoice() {
    screen.querySelectorAll('[data-v4-audio="app"]').forEach(node => node.setAttribute("aria-pressed", String(audioSources.app)));
    document.querySelectorAll('.v4-sheet [data-v4-audio="app"]').forEach(node => node.setAttribute("aria-pressed", String(audioSources.app)));
    appAudio?.setAttribute("aria-label", "其他 App 媒体声音，" + (audioSources.app ? "已开启" : "已关闭"));
    appAudio?.removeAttribute("data-unavailable");
    const appCheck = appAudio?.querySelector(".v4-audio-check");
    if (appCheck) appCheck.textContent = audioSources.app ? "✓" : "";
    screen.querySelectorAll('[data-v4-audio="mic"]').forEach(node => node.setAttribute("aria-pressed", String(audioSources.mic)));
    document.querySelectorAll('.v4-sheet [data-v4-audio="mic"]').forEach(node => node.setAttribute("aria-pressed", String(audioSources.mic)));
    const micCheck = microphone?.querySelector(".v4-audio-check");
    if (micCheck) micCheck.textContent = audioSources.mic ? "✓" : "";
    screen.querySelector(".v4-audio-heading small")?.replaceChildren(document.createTextNode(audioSources.app && audioSources.mic ? "会议双声源" : audioSources.app ? "其他 App 媒体声音" : "麦克风"));
    const appDescription = appAudio?.querySelector(".v4-audio-copy small");
    if (appDescription) appDescription.textContent = "需系统授权 · 部分应用禁止采集";
    if (audioStatus) audioStatus.textContent = audioSources.app && audioSources.mic ? "双方发言同时记录 · 本机离线识别" : audioSources.app ? "其他 App 媒体声音 · 本机离线识别" : "麦克风 · 本机离线识别";
    try { localStorage.setItem(prefix + "audio-sources", JSON.stringify(audioSources)); } catch { /* optional preference */ }
  }
  function renderRecords() {
    if (!recordList) return;
    const wasNearEnd = recordList.scrollHeight - recordList.clientHeight - recordList.scrollTop < 36;
    const previousScrollTop = recordList.scrollTop;
    const current = playbackEntries.length ? playbackEntries : entries;
    if (liveFeed) {
      const feedWasNearEnd = liveFeed.scrollHeight - liveFeed.clientHeight - liveFeed.scrollTop < 40;
      const feedScrollTop = liveFeed.scrollTop;
      liveFeed.replaceChildren();
      for (const entry of current.slice(-40)) {
        const row = document.createElement("article");
        const meta = document.createElement("small");
        const source = document.createElement("p");
        const translated = document.createElement("strong");
        const at = Number(entry.capturedAtMs);
        meta.textContent = (Number.isFinite(at) && at > 0 ? new Date(at).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", second: "2-digit" }) + " · " : "") + (entry.audioSource === "app" ? "其他 App" : entry.audioSource === "mic" ? "麦克风" : "语音");
        source.textContent = entry.sourceText || "";
        translated.textContent = entry.translatedText || "";
        row.append(meta, source, translated);
        liveFeed.appendChild(row);
      }
      liveFeed.scrollTop = feedWasNearEnd ? liveFeed.scrollHeight : feedScrollTop;
    }
    recordCount.textContent = current.length + " 段";
    if (recordListMode === "files") return;
    recordList.replaceChildren();
    const header = document.createElement("div");
    header.className = "subtitle-record-header";
    const heading = document.createElement("b");
    heading.textContent = "本次同传 · " + current.length + " 段";
    const close = document.createElement("button");
    close.type = "button";
    close.dataset.videoRecordClose = "";
    close.textContent = "关闭";
    header.append(heading, close);
    recordList.appendChild(header);
    if (!current.length) {
      const empty = document.createElement("p");
      empty.className = "subtitle-record-empty";
      empty.textContent = "开始同传后，发言会按时间显示在这里。";
      recordList.appendChild(empty);
      return;
    }
    current.forEach((entry, index) => {
      const item = document.createElement("article");
      const meta = document.createElement("small");
      const time = Number(entry.capturedAtMs);
      const label = entry.audioSource === "app" ? "其他 App 音频" : entry.audioSource === "mic" ? "麦克风" : "语音";
      meta.textContent = (Number.isFinite(time) && time > 0 ? new Date(time).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", second: "2-digit" }) : String(index + 1).padStart(2, "0")) + " · " + label;
      const original = document.createElement("p");
      original.textContent = entry.sourceText || "";
      const translated = document.createElement("strong");
      translated.textContent = entry.translatedText || "";
      item.append(meta, original, translated);
      if (entry.audioId) {
        const play = document.createElement("button");
        play.type = "button";
        play.className = "subtitle-record-audio";
        play.dataset.liveAudioId = entry.audioId;
        play.textContent = "▶ 播放原声";
        item.appendChild(play);
      }
      recordList.appendChild(item);
    });
    if (!recordList.hidden) recordList.scrollTop = wasNearEnd ? recordList.scrollHeight : previousScrollTop;
  }
  async function showRecordingFiles() {
    recordListMode = "files";
    recordList.hidden = false;
    document.body.classList.add("miyin-record-open");
    recordToggle.setAttribute("aria-expanded", "false");
    recordToggle.firstChild.textContent = "查看完整记录 ";
    recordList.replaceChildren();
    const heading = document.createElement("div");
    heading.className = "subtitle-record-header";
    const title = document.createElement("b");
    title.textContent = "整场录制文件";
    const close = document.createElement("button");
    close.type = "button";
    close.dataset.videoRecordClose = "";
    close.textContent = "关闭";
    heading.append(title, close);
    recordList.appendChild(heading);
    const notice = document.createElement("p");
    notice.className = "subtitle-record-empty";
    notice.textContent = "正在读取手机里的录制文件…";
    recordList.appendChild(notice);
    try {
      const result = await bridge.request("live.listRecordings");
      if (recordListMode !== "files") return;
      const rows = Array.isArray(result?.recordings) ? result.recordings : [];
      notice.textContent = rows.length ? "点开 MP4 查看整场录屏；原声也按来源单独保存。录制失败的旧文件可能只有画面。" : "手机里还没有整场录制文件。";
      for (const row of rows) {
        const item = document.createElement("article");
        const date = new Date(Number(row.startedAtMs) || Date.now());
        const duration = Math.max(0, Math.round((Number(row.durationMs) || 0) / 1000));
        const meta = document.createElement("small");
        meta.textContent = date.toLocaleString("zh-CN") + " · " + Math.floor(duration / 60) + ":" + String(duration % 60).padStart(2, "0");
        item.appendChild(meta);
        for (const [key, label] of [["videoUri", row.videoHasAudio ? "有声录屏 MP4" : "画面 MP4"], ["audioUri", "其他 App 声音 WAV"], ["microphoneUri", "麦克风声音 WAV"]]) {
          if (!row[key]) continue;
          const open = document.createElement("button");
          open.type = "button";
          open.className = "subtitle-record-audio";
          open.dataset.liveRecordingUri = row[key];
          open.textContent = label;
          item.appendChild(open);
        }
        recordList.appendChild(item);
      }
    } catch (error) {
      notice.textContent = error?.message || "暂时无法读取录制文件";
    }
  }
  function clearSegmentTimer() { window.clearTimeout(segmentTimer); segmentTimer = 0; }
  function pairFor(text, tag) {
    const selected = context.pair();
    const detected = window.MiyinV5Core?.normalizeSpeechLanguageTag(tag) ||
      window.MiyinV5Core?.detectDistinctiveScriptLanguageTag(text) || null;
    if (detected === selected.targetTag) return { sourceTag: selected.targetTag, targetTag: selected.sourceTag };
    if (detected && detected !== selected.sourceTag) return null;
    return selected;
  }
  async function translateSegment(text, tag, currentGeneration) {
    const pair = pairFor(text, tag);
    if (!pair) { message("识别语种不在当前翻译组合中，请调整语言后重试"); return; }
    const source = String(text || "").trim();
    if (!source) return;
    sourceLine.textContent = source;
    sourceLabel.textContent = context.languageName(pair.sourceTag) + " · 识别原文";
    translatedLabel.textContent = context.languageName(pair.targetTag) + " · 译文";
    translatedLine.textContent = "正在翻译…";
    try {
      const result = await bridge.request("translation.translate", { ...pair, text: source });
      if (currentGeneration !== generation) return;
      const translated = String(result?.translatedText || "").trim();
      if (!translated) throw new Error("译文为空");
      translatedLine.textContent = translated;
      entries.push({ sourceText: source, translatedText: translated, ...pair });
      renderRecords();
      document.querySelector("#v4-pip-source")?.replaceChildren(document.createTextNode(source));
      document.querySelector("#v4-pip-translation")?.replaceChildren(document.createTextNode(translated));
      message(active ? "已翻译 " + entries.length + " 段 · 正在继续聆听" : "已翻译 " + entries.length + " 段");
    } catch (error) {
      translatedLine.textContent = "本段翻译失败";
      message(error?.message || "本段翻译失败，请检查离线语言包");
    }
  }
  async function startSegment(currentGeneration) {
    if (!active || currentGeneration !== generation) return;
    const pair = context.pair();
    const id = "video-asr-" + Date.now().toString(36) + "-" + (++sequence).toString(36);
    sessionId = id;
    recognizedText = "";
    recognizedLanguage = null;
    message("正在准备麦克风…");
    try {
      const result = await bridge.request("voice.startListening", { sessionId: id, mode: "video", ...pair });
      if (currentGeneration !== generation || !active) {
        if (result?.status === "listening") await bridge.request("voice.cancelListening", { sessionId: id });
        return;
      }
      if (result?.status === "permission_granted") {
        active = false;
        sessionId = null;
        setButton();
        message("麦克风权限已开启，请再点一次开始同传");
        return;
      }
      if (result?.status !== "listening") throw new Error("麦克风未启动");
      message("正在聆听 · 每约 9 秒生成一段字幕");
      segmentTimer = window.setTimeout(() => void finishSegment(id, currentGeneration), segmentMs);
    } catch (error) {
      if (currentGeneration !== generation) return;
      active = false;
      sessionId = null;
      setButton();
      message(error?.message || "无法启动语音识别");
    }
  }
  async function finishSegment(id, currentGeneration) {
    if (sessionId !== id || currentGeneration !== generation) return;
    clearSegmentTimer();
    message("正在确认这一段语音…");
    try {
      const result = await bridge.request("voice.stopListening", { sessionId: id });
      if (currentGeneration !== generation) return;
      if (typeof result?.text === "string") {
        recognizedText = result.text.trim();
        recognizedLanguage = result.languageTag || recognizedLanguage;
      }
      if (recognizedText) {
        const text = recognizedText;
        const tag = recognizedLanguage;
        translationJob = translationJob.then(() => translateSegment(text, tag, currentGeneration));
      }
    } catch (error) {
      if (currentGeneration === generation) message(error?.message || "这段语音识别失败");
    }
    sessionId = null;
    if (active && currentGeneration === generation) void startSegment(currentGeneration);
  }
  async function stop() {
    if (!active || busy) return;
    busy = true;
    setButton();
    message("正在保存并合成整场录制…");
    try {
      const result = await bridge.request("live.stopMic");
      if (Array.isArray(result?.entries)) playbackEntries = result.entries;
      playbackRecording = result?.recording || playbackRecording;
      playbackRecordingError = result?.recordingError || "";
      renderRecords();
      savePlaybackSession();
      message(playbackRecordingError || (playbackEntries.length ? "本次同传已结束 · 共 " + playbackEntries.length + " 段 · 可查看录制文件" : "本次未识别到语音 · 可查看录制文件"));
    } catch (error) {
      message(error?.message || "无法结束麦克风同传");
    } finally {
      active = false;
      busy = false;
      setButton();
    }
  }
  async function startMic() {
    const pair = context.pair();
    active = true;
    playbackSaved = false;
    playbackEntries = [];
    playbackRecording = null;
    playbackRecordingError = "";
    renderRecords();
    setButton();
    sourceLine.textContent = "正在聆听…";
    translatedLine.textContent = "识别后显示翻译字幕";
    if (currentCaption) currentCaption.hidden = false;
    message("正在准备麦克风…");
    try {
      const result = await bridge.request("live.startMic", { ...pair, overlay: overlayPrefs(), recordAudio: shouldRecordAudio() });
      if (result?.status === "overlay_permission_requested") {
        active = false;
        setButton();
        message("请在系统页面允许悬浮显示，返回后再次开始同传");
      } else {
        message("正在聆听 · 切换应用后字幕继续显示");
      }
    } catch (error) {
      active = false;
      setButton();
      message(error?.message || "麦克风同传未能启动");
    }
  }
  function savePlaybackSession() {
    if (playbackSaved || (!playbackEntries.length && !playbackRecording)) return;
    playbackSaved = true;
    const audioIds = playbackEntries.map(entry => entry.audioId).filter(Boolean);
    if (shouldRecordAudio()) {
      let savedId = null;
      try { savedId = context.saveSession(playbackEntries, playbackRecording); } catch { /* local storage may be full */ }
      if (audioIds.length && savedId) {
        void bridge.request("live.commitAudio", { audioIds })
          .catch(() => message("字幕已保存，但音频保存失败，请检查本机空间"));
      } else if (audioIds.length) {
        void bridge.request("live.deleteAudio", { audioIds });
        message("本次记录未能保存，请检查本机空间");
      }
    } else {
      if (audioIds.length) void bridge.request("live.deleteAudio", { audioIds });
    }
  }
  async function stopPlayback() {
    if (!playbackActive || busy) return;
    busy = true;
    setButton();
    message("正在保存并合成整场录制…");
    try {
      const result = await bridge.request("live.stopPlayback");
      if (Array.isArray(result?.entries)) playbackEntries = result.entries;
      playbackRecording = result?.recording || playbackRecording;
      playbackRecordingError = result?.recordingError || "";
      renderRecords();
      savePlaybackSession();
      message(playbackRecordingError || "本次同传已结束 · 共 " + playbackEntries.length + " 段 · 可查看录制文件");
    } catch (error) {
      message(error?.message || "无法结束媒体同传");
    } finally {
      playbackActive = false;
      active = false;
      busy = false;
      setButton();
    }
  }
  async function startPlayback() {
    const pair = context.pair();
    active = true;
    playbackActive = true;
    playbackSaved = false;
    playbackEntries = [];
    playbackRecording = null;
    playbackRecordingError = "";
    renderRecords();
    setButton();
    message("正在请求系统音频授权…");
    sourceLine.textContent = "等待其他 App 的媒体声音…";
    translatedLine.textContent = "识别后显示翻译字幕";
    if (currentCaption) currentCaption.hidden = false;
    try {
      const result = await bridge.request("live.startPlayback", { ...pair, overlay: overlayPrefs(), recordAudio: shouldRecordAudio() });
      if (result?.status === "overlay_permission_requested") {
        active = false;
        playbackActive = false;
        setButton();
        message("请在系统页面允许悬浮显示，返回后再次开始同传");
      } else {
        message(result?.status === "capturing" ? "正在识别媒体声音" : "请在系统页面允许录制媒体声音");
      }
    } catch (error) {
      playbackActive = false;
      active = false;
      setButton();
      message(error?.message || "无法启动其他 App 音频采集");
    }
  }
  async function stopConference() {
    if (!conferenceActive || busy) return;
    busy = true;
    setButton();
    message("正在保存并合成整场录制…");
    try {
      const result = await bridge.request("live.stopConference");
      if (Array.isArray(result?.entries)) playbackEntries = result.entries;
      playbackRecording = result?.recording || playbackRecording;
      playbackRecordingError = result?.recordingError || "";
      renderRecords();
      savePlaybackSession();
      message(playbackRecordingError || "本次同传已结束 · 共 " + playbackEntries.length + " 段 · 可查看录制文件");
    } catch (error) {
      message(error?.message || "无法结束会议同传");
    } finally {
      conferenceActive = false;
      active = false;
      busy = false;
      setButton();
    }
  }
  async function startConference() {
    const pair = context.pair();
    active = true;
    conferenceActive = true;
    playbackSaved = false;
    playbackEntries = [];
    playbackRecording = null;
    playbackRecordingError = "";
    renderRecords();
    setButton();
    sourceLine.textContent = "等待双方发言…";
    translatedLine.textContent = "识别后显示翻译字幕";
    if (currentCaption) currentCaption.hidden = false;
    message("正在准备会议双声源…");
    try {
      const result = await bridge.request("live.startConference", { ...pair, overlay: overlayPrefs(), recordAudio: shouldRecordAudio() });
      if (result?.status === "overlay_permission_requested") {
        active = false;
        conferenceActive = false;
        setButton();
        message("请在系统页面允许悬浮显示，返回后再次开始同传");
      } else if (result?.status === "mic_fallback") {
        message("其他 App 音频未能启动，麦克风同传继续运行");
      } else {
        message(result?.status === "capturing" ? "正在记录双方发言" : "请允许系统录制媒体声音");
      }
    } catch (error) {
      active = false;
      conferenceActive = false;
      setButton();
      message(error?.message || "会议同传未能启动");
    }
  }
  function onPlaybackEvent(event) {
    const detail = event.detail || {};
    if (detail.type === "recognition_partial") {
      const preview = String(detail.text || "").trim();
      previewSessionId = detail.previewSessionId || null;
      if (preview) sourceLine.textContent = preview;
      translatedLine.textContent = "";
      translatedLabel.textContent = "临时译文 · 待确认";
      if (currentCaption) currentCaption.hidden = false;
      sourceLabel.textContent = detail.audioSource === "app"
        ? "其他 App · 实时原文"
        : "麦克风 · 实时原文";
      return;
    }
    if (detail.type === "translation_partial") {
      if (!previewSessionId || detail.previewSessionId !== previewSessionId) return;
      translatedLine.textContent = String(detail.text || "").trim();
      translatedLabel.textContent = "临时译文 · 待确认";
      if (currentCaption) currentCaption.hidden = false;
      return;
    }
    if (Array.isArray(detail.entries)) playbackEntries = detail.entries;
    renderRecords();
    if (detail.type === "segment" || detail.type === "snapshot") {
      previewSessionId = null;
      const entry = detail.entry || playbackEntries.at(-1);
      if (entry) {
        sourceLine.textContent = "";
        translatedLine.textContent = "";
        if (currentCaption) currentCaption.hidden = true;
        const channel = entry.audioSource === "app" ? "其他 App 音频" : entry.audioSource === "mic" ? "麦克风" : "语音";
        sourceLabel.textContent = context.languageName(entry.sourceTag) + " · " + channel;
        translatedLabel.textContent = context.languageName(entry.targetTag) + " · 译文";
      }
      if (detail.type === "segment") message("已翻译 " + playbackEntries.length + " 段 · 正在继续聆听");
    } else if (detail.type === "ended") {
      playbackRecording = detail.recording || playbackRecording;
      playbackRecordingError = detail.recordingError || playbackRecordingError;
      playbackActive = false;
      conferenceActive = false;
      active = false;
      savePlaybackSession();
      setButton();
      message(detail.message || "本次同传已结束");
    } else if (detail.message) {
      message(detail.message);
    }
  }
  async function refreshLiveStatus() {
    if (!active || busy) return;
    try {
      const state = await bridge.request("live.status");
      if (!active || !state?.active) return;
      if (state.playbackCapturing === true) {
        message(conferenceActive ? "正在记录双方发言" : "正在识别其他 App 媒体声音");
      } else if (conferenceActive && state.mode === "mic") {
        message("其他 App 音频不可用，麦克风同传继续运行");
      }
    } catch { /* keep the last visible status */ }
  }
  function onVoiceEvent(event) {
    const detail = event.detail;
    if (!detail) return;
    const liveMicPreview = active && String(detail.sessionId || "").startsWith("live-mic-");
    if (detail.sessionId !== sessionId && !liveMicPreview) return;
    if (detail.type === "recognition_partial" && typeof detail.text === "string") {
      sourceLine.textContent = detail.text || "正在聆听…";
      translatedLine.textContent = "";
      if (currentCaption) currentCaption.hidden = false;
      sourceLabel.textContent = "实时原文 · 待确认";
      return;
    }
    if (detail.type === "recognition_final" && !liveMicPreview) {
      recognizedText = String(detail.text || "").trim();
      recognizedLanguage = detail.languageTag || null;
    }
  }
  document.addEventListener("click", event => {
    const recordingFile = event.target.closest("#video-record-list [data-live-recording-uri]");
    if (recordingFile) {
      event.preventDefault();
      event.stopImmediatePropagation();
      void bridge.request("live.openRecording", { uri: recordingFile.dataset.liveRecordingUri })
        .catch(error => message(error?.message || "无法打开录制文件"));
      return;
    }
    const audioButton = event.target.closest("#video-record-list [data-live-audio-id]");
    if (audioButton) {
      event.preventDefault();
      event.stopImmediatePropagation();
      void bridge.request("live.playAudio", { audioId: audioButton.dataset.liveAudioId })
        .then(() => message("正在播放本段原声"))
        .catch(error => message(error?.message || "本段原声无法播放"));
      return;
    }
    if (event.target.closest("[data-video-record-close]")) {
      void bridge.request("live.stopAudio").catch(() => {});
      recordToggle.setAttribute("aria-expanded", "false");
      recordToggle.firstChild.textContent = "查看完整记录 ";
      recordList.hidden = true;
      recordListMode = "segments";
      document.body.classList.remove("miyin-record-open");
      return;
    }
    if (event.target.closest("#video-record-toggle")) {
      recordListMode = "segments";
      renderRecords();
      const expanded = recordToggle.getAttribute("aria-expanded") !== "true";
      if (!expanded) void bridge.request("live.stopAudio").catch(() => {});
      recordToggle.setAttribute("aria-expanded", String(expanded));
      recordToggle.firstChild.textContent = expanded ? "收起完整记录 " : "查看完整记录 ";
      recordList.hidden = !expanded;
      document.body.classList.toggle("miyin-record-open", expanded);
      if (expanded) recordList.scrollTop = 0;
      return;
    }
    if (event.target.closest("#video-record-files")) {
      event.preventDefault();
      event.stopImmediatePropagation();
      void showRecordingFiles();
      return;
    }
    if (event.target.closest('[data-v4-audio="app"]')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (active) { message("请先结束当前同传，再更换音频来源"); return; }
      if (audioSources.app && !audioSources.mic) { message("请至少保留一个音频来源"); return; }
      audioSources.app = !audioSources.app;
      setAudioChoice();
      message(audioSources.app ? "其他 App 音频已加入；开始时需系统授权" : "其他 App 音频已关闭");
      return;
    }
    if (event.target.closest('[data-v4-audio="mic"]')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (active) { message("请先结束当前同传，再更换音频来源"); return; }
      if (audioSources.mic && !audioSources.app) { message("请至少保留一个音频来源"); return; }
      audioSources.mic = !audioSources.mic;
      setAudioChoice();
      message(audioSources.mic ? "麦克风已加入，用于记录现场发言" : "麦克风已关闭");
      return;
    }
    if (event.target.closest("[data-v4-float-toggle]")) {
      event.preventDefault();
      event.stopImmediatePropagation();
      void toggleFloating();
      return;
    }
    const pip = event.target.closest('#screen-video [aria-label="字幕画中画 PiP"]');
    if (pip) {
      event.preventDefault();
      event.stopImmediatePropagation();
      const enabled = pip.getAttribute("aria-pressed") !== "true";
      pip.setAttribute("aria-pressed", String(enabled));
      localStorage.setItem(prefix + "pip-enabled", JSON.stringify(enabled));
      window.dispatchEvent(new Event("miyin:subtitle-preferences-change"));
      message(enabled
        ? active ? "字幕窗口已在其他应用上方显示" : "开始同传后会显示跨应用字幕窗口"
        : "跨 App 字幕已关闭；同传仍会在本页显示");
      return;
    }
    const clicked = event.target.closest("#video-start, #screen-video [data-v4-audio]");
    if (!clicked) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (busy) return;
    if (active) { if (conferenceActive) void stopConference(); else if (playbackActive) void stopPlayback(); else void stop(); return; }
    if (screen.querySelector('[aria-label="视频翻译字幕"]')?.getAttribute("aria-pressed") !== "true") {
      message("请先开启视频翻译字幕");
      return;
    }
    if (document.documentElement.dataset.nativeHost !== "true") { message("同传需要在觅音 Android 应用中使用"); return; }
    if (audioSources.app && audioSources.mic) { void startConference(); return; }
    if (audioSources.app) { void startPlayback(); return; }
    void startMic();
  }, true);
  window.addEventListener("miyin:voice-event", onVoiceEvent);
  window.addEventListener("miyin:playback-subtitle", onPlaybackEvent);
  window.addEventListener("miyin:subtitle-preferences-change", () => {
    if (active) void bridge.request("live.configureOverlay", { overlay: overlayPrefs() });
  });
  window.addEventListener("miyin:caption-settings-opened", setAudioChoice);
  window.addEventListener("miyin:surface-visibility-change", () => {
    if (!screen.classList.contains("active")) {
      void bridge.request("live.stopAudio").catch(() => {});
      if (active) message("同传仍在运行，可返回本页结束");
    }
  });
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      void refreshFloatingStatus();
      window.setTimeout(() => void refreshLiveStatus(), 400);
    }
  });
  window.addEventListener("focus", () => window.setTimeout(() => void refreshLiveStatus(), 400));
  window.addEventListener("miyin:native-host-ready", () => void refreshFloatingStatus());
  setAudioChoice();
  renderRecords();
  setButton();
  sourceLabel.textContent = "识别原文";
  translatedLabel.textContent = "译文";
  sourceLine.textContent = "开始后显示识别文字";
  translatedLine.textContent = "开始后显示翻译字幕";
  message("尚未开始 · 可选择双方音频来源");
  void refreshFloatingStatus();
})();
