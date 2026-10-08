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

  return {
    appendConversationMessage,
    createConversation,
    upsertConversation,
  };
});
