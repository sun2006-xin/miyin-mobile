"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const core = require("../docs/designs/miyin-full-app-preview-v5/miyin-v5-core.js");

test("creates a new AI conversation from its first prompt", () => {
  assert.equal(typeof core.createConversation, "function");

  const conversation = core.createConversation({
    id: "chat-1",
    firstPrompt: "  我想问路\n",
    modelId: "preview-model-1",
    now: 1000,
  });

  assert.deepEqual(conversation, {
    id: "chat-1",
    title: "我想问路",
    createdAt: 1000,
    updatedAt: 1000,
    modelId: "preview-model-1",
    messages: [],
  });
});

test("appends ordered messages to one immutable conversation", () => {
  assert.equal(typeof core.appendConversationMessage, "function");

  const original = {
    id: "chat-1",
    title: "问路",
    createdAt: 1000,
    updatedAt: 1000,
    modelId: "preview-model-1",
    messages: [],
  };
  const userMessage = {
    id: "m-1",
    role: "user",
    text: "How do I get to the station?",
    createdAt: 1100,
    status: "complete",
    contextAttachments: [],
  };
  const assistantMessage = {
    id: "m-2",
    role: "assistant",
    text: "Walk straight ahead.",
    createdAt: 1200,
    status: "complete",
    contextAttachments: [],
  };

  const afterUser = core.appendConversationMessage(original, userMessage, 1100);
  const afterAssistant = core.appendConversationMessage(afterUser, assistantMessage, 1200);

  assert.deepEqual(afterAssistant.messages, [userMessage, assistantMessage]);
  assert.equal(afterAssistant.updatedAt, 1200);
  assert.deepEqual(original.messages, []);
});

test("updates one history row per conversation id", () => {
  assert.equal(typeof core.upsertConversation, "function");

  const existing = {
    id: "chat-1",
    title: "问路",
    createdAt: 1000,
    updatedAt: 1100,
    modelId: "preview-model-1",
    messages: [{ id: "m-1", role: "user", text: "问路" }],
  };
  const updated = { ...existing, updatedAt: 1200, messages: [...existing.messages, { id: "m-2", role: "assistant", text: "直走" }] };
  const other = { ...existing, id: "chat-2", title: "新话题" };

  const result = core.upsertConversation([existing, other], updated);

  assert.deepEqual(result, [updated, other]);
  assert.equal(result.filter((conversation) => conversation.id === "chat-1").length, 1);
  assert.equal(result[0].messages.length, 2);
});

test("moves an updated AI conversation to the top without duplicating legacy rows", () => {
  const older = { id: "chat-1", title: "问路", messages: [] };
  const newer = { id: "chat-2", title: "旅行计划", messages: [] };
  const updated = { ...older, title: "问路补充", messages: [{ id: "m-1", role: "user", text: "补充" }] };

  assert.deepEqual(
    core.upsertConversation([newer, older, { ...older }], updated),
    [updated, newer]
  );
});
