(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  if (root) root.MiyinV5Core = api;
})(typeof globalThis === "undefined" ? this : globalThis, function () {
  "use strict";

  function deriveConversationTitle(prompt) {
    const normalized = String(prompt ?? "").replace(/\s+/gu, " ").trim();
    if (!normalized) return "新对话";

    const characters = Array.from(normalized);
    return characters.length > 32
      ? characters.slice(0, 31).join("") + "…"
      : normalized;
  }

  function createConversation({ id, firstPrompt, modelId = null, now = Date.now() }) {
    return {
      id: String(id),
      title: deriveConversationTitle(firstPrompt),
      createdAt: now,
      updatedAt: now,
      modelId,
      messages: [],
    };
  }

  function appendConversationMessage(conversation, message, updatedAt = message.createdAt) {
    if (!conversation || !Array.isArray(conversation.messages)) {
      throw new TypeError("A conversation with a messages array is required");
    }
    if (!message || typeof message.id !== "string" || !message.id) {
      throw new TypeError("A message with an id is required");
    }

    return {
      ...conversation,
      updatedAt,
      messages: [...conversation.messages, message],
    };
  }

  function upsertConversation(conversations, conversation) {
    if (!Array.isArray(conversations)) {
      throw new TypeError("A conversation list is required");
    }
    if (!conversation || typeof conversation.id !== "string" || !conversation.id) {
      throw new TypeError("A conversation with an id is required");
    }

    return [
      conversation,
      ...conversations.filter((item) => item && item.id !== conversation.id),
    ];
  }

  const voiceTransitions = {
    idle: { start: "permission-required" },
    "permission-required": {
      allow: "listening",
      "submit-text": "processing",
      deny: "permission-denied",
      unavailable: "unavailable",
      cancel: "idle",
      end: "idle",
    },
    listening: { process: "processing", "submit-text": "processing", pause: "paused", error: "error", end: "idle" },
    processing: { respond: "speaking", error: "error", end: "idle" },
    speaking: { "finish-response": "listening", interrupt: "listening", "submit-text": "processing", pause: "paused", error: "error", end: "idle" },
    paused: { resume: "listening", "submit-text": "processing", error: "error", end: "idle" },
    "permission-denied": { retry: "permission-required", "submit-text": "processing", end: "idle" },
    unavailable: { retry: "permission-required", "submit-text": "processing", end: "idle" },
    error: { retry: "permission-required", "submit-text": "processing", end: "idle" },
  };

  function transitionVoiceSession(state, event) {
    return voiceTransitions[state]?.[event] || state;
  }

  function updateConversationMessage(conversation, messageId, updates, updatedAt = Date.now()) {
    if (!conversation || !Array.isArray(conversation.messages)) {
      throw new TypeError("A conversation with a messages array is required");
    }
    const index = conversation.messages.findIndex((message) => message.id === messageId);
    if (index < 0) throw new RangeError("The message does not exist in this conversation");
    if (!updates || typeof updates !== "object" || Array.isArray(updates)) {
      throw new TypeError("Message updates must be an object");
    }

    const messages = conversation.messages.slice();
    messages[index] = { ...messages[index], ...updates, id: messageId };
    return { ...conversation, updatedAt, messages };
  }

  function createGeneration({
    id,
    conversationId,
    prompt,
    draftSnapshot = "",
    modelId = null,
    contextAttachments = [],
    now = Date.now(),
  }) {
    if (!id || !conversationId) throw new TypeError("Generation and conversation ids are required");
    return {
      id: String(id),
      conversationId: String(conversationId),
      prompt: String(prompt ?? ""),
      draftSnapshot: String(draftSnapshot ?? ""),
      modelId,
      contextAttachments: Array.isArray(contextAttachments) ? contextAttachments.slice() : [],
      status: "pending",
      createdAt: now,
      updatedAt: now,
    };
  }

  const generationTransitions = {
    pending: { stop: "stopped", fail: "failed", complete: "complete" },
    stopped: { retry: "pending" },
    failed: { retry: "pending" },
  };

  function transitionGeneration(generation, event, updatedAt = Date.now()) {
    if (!generation || typeof generation !== "object") {
      throw new TypeError("A generation state is required");
    }
    const status = generationTransitions[generation.status]?.[event];
    return status ? { ...generation, status, updatedAt } : generation;
  }

  function isSamePendingHomeTranslation(started, current) {
    if (started == null || current == null) return started == null && current == null;
    return started.text === current.text
      && Number(started.submittedAt) === Number(current.submittedAt)
      && Number(started.draftRevision) === Number(current.draftRevision)
      && (Number(started.submissionRevision) || 0) === (Number(current.submissionRevision) || 0);
  }

  function shouldRestoreChatDraft({ draftSnapshot, inputValue, inputRevisionAtSend, inputRevision }) {
    const snapshot = String(draftSnapshot ?? "");
    const sentRevision = Number(inputRevisionAtSend);
    const currentRevision = Number(inputRevision);
    return Boolean(snapshot.trim())
      && !String(inputValue ?? "").trim()
      && Number.isFinite(sentRevision)
      && Number.isFinite(currentRevision)
      && sentRevision === currentRevision;
  }

  function shouldConsumeRetriedChatDraft({ draftSnapshot, inputValue, inputRevisionAtSend, inputRevision }) {
    const snapshot = String(draftSnapshot ?? "");
    const sentRevision = Number(inputRevisionAtSend);
    const currentRevision = Number(inputRevision);
    return Boolean(snapshot.trim())
      && String(inputValue ?? "") === snapshot
      && Number.isFinite(sentRevision)
      && Number.isFinite(currentRevision)
      && sentRevision === currentRevision;
  }

  function cloneSnapshot(value) {
    if (Array.isArray(value)) return value.map(cloneSnapshot);
    if (value && typeof value === "object") {
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, cloneSnapshot(item)]));
    }
    return value;
  }

  function createContextAttachment({
    id,
    category,
    sourceRecordId,
    title,
    selectedContentSnapshot = null,
  }) {
    if (!id || !category || !sourceRecordId) {
      throw new TypeError("Context id, category, and source record id are required");
    }
    return {
      id: String(id),
      category: String(category),
      sourceRecordId: String(sourceRecordId),
      title: String(title ?? ""),
      selectedContentSnapshot: cloneSnapshot(selectedContentSnapshot),
    };
  }

  function attachContextToMessage(message, attachments = []) {
    if (!message || typeof message !== "object") {
      throw new TypeError("A message is required");
    }
    if (!Array.isArray(attachments)) {
      throw new TypeError("Context attachments must be a list");
    }
    return {
      ...message,
      contextAttachments: attachments.map(cloneSnapshot),
    };
  }

  function removeContextAttachment(attachments, attachmentId) {
    if (!Array.isArray(attachments)) {
      throw new TypeError("Context attachments must be a list");
    }
    return attachments.filter((attachment) => attachment && attachment.id !== attachmentId);
  }

  function searchableText(value) {
    if (value == null) return "";
    if (typeof value === "string" || typeof value === "number") return String(value);
    if (Array.isArray(value)) return value.map(searchableText).join(" ");
    if (typeof value === "object") return Object.values(value).map(searchableText).join(" ");
    return "";
  }

  function searchConversations(conversations, query = "") {
    if (!Array.isArray(conversations)) {
      throw new TypeError("A conversation list is required");
    }
    const terms = String(query ?? "").trim().toLocaleLowerCase().split(/\s+/u).filter(Boolean);
    if (!terms.length) return conversations.slice();

    return conversations.filter((conversation) => {
      const corpus = searchableText(conversation).toLocaleLowerCase();
      return terms.every((term) => corpus.includes(term));
    });
  }

  function filterInstalledTranslationPairs(supportedPairs, modelStatusByPair) {
    if (!Array.isArray(supportedPairs) || !modelStatusByPair || typeof modelStatusByPair !== "object") {
      return [];
    }

    const seen = new Set();
    return supportedPairs.filter((pair) => {
      if (!pair || typeof pair.sourceTag !== "string" || typeof pair.targetTag !== "string") return false;
      if (!pair.sourceTag || !pair.targetTag || pair.sourceTag === pair.targetTag) return false;
      const key = `${pair.sourceTag}->${pair.targetTag}`;
      if (seen.has(key) || modelStatusByPair[key] !== "downloaded") return false;
      seen.add(key);
      return true;
    });
  }

  function normalizeSpeechLanguageTag(value) {
    if (typeof value !== "string") return null;
    const normalized = value.trim().replace(/_/g, "-").toLocaleLowerCase();
    if (!normalized) return null;

    const aliases = {
      chinese: "zh-Hans",
      mandarin: "zh-Hans",
      english: "en",
      japanese: "ja",
      french: "fr",
      russian: "ru",
      korean: "ko",
      spanish: "es",
      german: "de",
      italian: "it",
      portuguese: "pt",
      dutch: "nl",
      arabic: "ar",
      hindi: "hi",
      thai: "th",
      turkish: "tr",
      vietnamese: "vi",
      indonesian: "id",
      ukrainian: "uk",
      polish: "pl",
      swedish: "sv",
      norwegian: "no",
      danish: "da",
      finnish: "fi",
      czech: "cs",
      greek: "el",
      hebrew: "he",
      hungarian: "hu",
      romanian: "ro",
      catalan: "ca",
      croatian: "hr",
      bulgarian: "bg",
      serbian: "sr",
      slovak: "sk",
      slovenian: "sl",
      malay: "ms",
      persian: "fa",
      bengali: "bn",
      tamil: "ta",
      telugu: "te",
      marathi: "mr",
      urdu: "ur",
      swahili: "sw",
      afrikaans: "af",
      icelandic: "is",
      welsh: "cy",
      bosnian: "bs",
      latvian: "lv",
      lithuanian: "lt",
      estonian: "et",
      macedonian: "mk",
      albanian: "sq",
      armenian: "hy",
      georgian: "ka",
      lao: "lo",
      khmer: "km",
      myanmar: "my",
    };
    if (aliases[normalized]) return aliases[normalized];
    if (normalized === "zh-hans") return "zh-Hans";
    if (normalized === "zh-hant") return "zh-Hant";
    if (normalized === "zh" || normalized.startsWith("zh-cn") || normalized.startsWith("zh-sg")) return "zh-Hans";
    if (normalized.startsWith("zh-tw") || normalized.startsWith("zh-hk") || normalized.startsWith("zh-hant")) return "zh-Hant";
    if (!/^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$/u.test(normalized)) return null;
    return normalized.split("-")[0];
  }

  function detectDistinctiveScriptLanguageTag(text) {
    const value = String(text ?? "");
    if (/[\u3040-\u30ff]/u.test(value)) return "ja";
    if (/[\uac00-\ud7af]/u.test(value)) return "ko";
    if (/[\u0e00-\u0e7f]/u.test(value)) return "th";
    if (/[\u0370-\u03ff]/u.test(value)) return "el";
    if (/[\u0590-\u05ff]/u.test(value)) return "he";
    return null;
  }

  function resolveSpeechTranslationPair({ selectedSourceTag, selectedTargetTag, detectedLanguageTag }) {
    const sourceTag = normalizeSpeechLanguageTag(selectedSourceTag);
    const targetTag = normalizeSpeechLanguageTag(selectedTargetTag);
    const detectedTag = normalizeSpeechLanguageTag(detectedLanguageTag);
    if (!sourceTag || !targetTag || !detectedTag || sourceTag === targetTag) {
      return { status: "unknown", detectedLanguageTag: detectedTag };
    }
    if (detectedTag !== sourceTag && detectedTag !== targetTag) {
      return { status: "unsupported", detectedLanguageTag: detectedTag };
    }
    return detectedTag === targetTag
      ? { status: "ready", sourceTag: targetTag, targetTag: sourceTag }
      : { status: "ready", sourceTag, targetTag };
  }

  function canRunTranslationMode(mode, dictionaryPackageInstalled) {
    if (mode === "sentence") return true;
    if (mode === "dictionary") return dictionaryPackageInstalled === true;
    return false;
  }

  function translationDirectionDecision(checkState, modelStatus, directionSupported = true) {
    if (checkState === "checking") return "checking";
    if (checkState === "failed" || checkState === "unavailable") return "unknown";
    if (directionSupported === false) return "unsupported";
    if (modelStatus === "downloaded") return "ready";
    if (modelStatus === "notDownloaded") return "notDownloaded";
    if (modelStatus === "unsupported") return "unsupported";
    if (modelStatus === "failed") return "failed";
    return "unknown";
  }

  function createScreenReturnStack(fallbacks = { dictionary: "home", resources: "settings" }) {
    const stack = [];
    const returnableScreens = new Set(["dictionary", "resources"]);
    const maxDepth = 32;

    return {
      push(from, to) {
        if (typeof from !== "string" || !from || !returnableScreens.has(to) || from === to) return false;
        if (returnableScreens.has(from)) {
          const existingTargetIndex = stack.findIndex(entry => entry.to === to);
          if (existingTargetIndex >= 0) {
            stack.length = existingTargetIndex + 1;
            return true;
          }
          if (stack.length && stack[stack.length - 1].to !== from) stack.length = 0;
        } else {
          stack.length = 0;
        }
        stack.push({ from, to });
        if (stack.length > maxDepth) stack.shift();
        return true;
      },
      pop(current) {
        if (returnableScreens.has(current) && stack.length && stack[stack.length - 1].to === current) return stack.pop().from;
        return fallbacks[current] || "home";
      },
      peek(current) {
        if (!returnableScreens.has(current) || !stack.length || stack[stack.length - 1].to !== current) return null;
        return stack[stack.length - 1].from;
      },
      clear() {
        stack.length = 0;
      },
      get depth() {
        return stack.length;
      },
    };
  }

  return {
    attachContextToMessage,
    appendConversationMessage,
    canRunTranslationMode,
    createConversation,
    createContextAttachment,
    createGeneration,
    createScreenReturnStack,
    detectDistinctiveScriptLanguageTag,
    filterInstalledTranslationPairs,
    isSamePendingHomeTranslation,
    normalizeSpeechLanguageTag,
    removeContextAttachment,
    resolveSpeechTranslationPair,
    searchConversations,
    shouldConsumeRetriedChatDraft,
    shouldRestoreChatDraft,
    translationDirectionDecision,
    transitionVoiceSession,
    transitionGeneration,
    updateConversationMessage,
    upsertConversation,
  };
});
