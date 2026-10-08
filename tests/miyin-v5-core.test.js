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

test("models the live AI voice conversation states in order", () => {
  assert.equal(typeof core.transitionVoiceSession, "function");

  let state = "idle";
  const transition = (event) => { state = core.transitionVoiceSession(state, event); };

  transition("start");
  assert.equal(state, "permission-required");
  transition("allow");
  assert.equal(state, "listening");
  transition("process");
  assert.equal(state, "processing");
  transition("respond");
  assert.equal(state, "speaking");
  transition("finish-response");
  assert.equal(state, "listening");
  transition("pause");
  assert.equal(state, "paused");
  transition("resume");
  assert.equal(state, "listening");
  transition("end");
  assert.equal(state, "idle");
});

test("keeps permission, unavailable, and error recovery explicit", () => {
  assert.equal(typeof core.transitionVoiceSession, "function");
  assert.equal(core.transitionVoiceSession("permission-required", "deny"), "permission-denied");
  assert.equal(core.transitionVoiceSession("permission-denied", "retry"), "permission-required");
  assert.equal(core.transitionVoiceSession("permission-required", "unavailable"), "unavailable");
  assert.equal(core.transitionVoiceSession("unavailable", "retry"), "permission-required");
  assert.equal(core.transitionVoiceSession("listening", "error"), "error");
  assert.equal(core.transitionVoiceSession("error", "retry"), "permission-required");
  assert.equal(core.transitionVoiceSession("error", "end"), "idle");
  assert.equal(core.transitionVoiceSession("listening", "unknown-event"), "listening");
});

test("updates one message without changing the order or original conversation", () => {
  assert.equal(typeof core.updateConversationMessage, "function");
  const first = { id: "m-1", role: "user", text: "question", status: "complete" };
  const second = { id: "m-2", role: "assistant", text: "pending", status: "pending" };
  const conversation = { id: "chat-1", updatedAt: 10, messages: [first, second] };
  const updated = core.updateConversationMessage(conversation, "m-2", { text: "answer", status: "complete" }, 20);

  assert.deepEqual(updated.messages, [first, { ...second, text: "answer", status: "complete" }]);
  assert.equal(updated.updatedAt, 20);
  assert.deepEqual(conversation.messages, [first, second]);
});

test("tracks generation stop, failure, and retry while preserving draft/model/context", () => {
  assert.equal(typeof core.createGeneration, "function");
  assert.equal(typeof core.transitionGeneration, "function");
  const initial = core.createGeneration({
    id: "generation-1",
    conversationId: "chat-1",
    prompt: "submitted prompt",
    draftSnapshot: "unsent draft",
    modelId: "model-a",
    contextAttachments: [{ id: "context-1", title: "Airport phrases" }],
    now: 100,
  });
  const failed = core.transitionGeneration(initial, "fail", 200);
  const retried = core.transitionGeneration(failed, "retry", 300);
  const stopped = core.transitionGeneration(retried, "stop", 400);

  assert.equal(initial.status, "pending");
  assert.equal(failed.status, "failed");
  assert.equal(retried.status, "pending");
  assert.equal(stopped.status, "stopped");
  for (const state of [failed, retried, stopped]) {
    assert.equal(state.draftSnapshot, "unsent draft");
    assert.equal(state.modelId, "model-a");
    assert.deepEqual(state.contextAttachments, [{ id: "context-1", title: "Airport phrases" }]);
  }
});
