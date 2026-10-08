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
      deny: "permission-denied",
      unavailable: "unavailable",
      cancel: "idle",
      end: "idle",
    },
    listening: { process: "processing", pause: "paused", error: "error", end: "idle" },
    processing: { respond: "speaking", error: "error", end: "idle" },
    speaking: { "finish-response": "listening", pause: "paused", error: "error", end: "idle" },
    paused: { resume: "listening", error: "error", end: "idle" },
    "permission-denied": { retry: "permission-required", end: "idle" },
    unavailable: { retry: "permission-required", end: "idle" },
    error: { retry: "permission-required", end: "idle" },
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

  return {
    appendConversationMessage,
    createConversation,
    createGeneration,
    transitionVoiceSession,
    transitionGeneration,
    updateConversationMessage,
    upsertConversation,
  };
});
