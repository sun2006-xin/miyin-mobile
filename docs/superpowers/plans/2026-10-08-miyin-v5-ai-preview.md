# Mi Yin V5 AI Chat Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an interactive V5 web preview that adds AI voice conversation, answer actions, complete AI conversation history, and explicit history attachments while preserving the approved V4 visual system.

**Architecture:** Copy the current static HTML/CSS/JavaScript preview into an isolated V5 directory, keeping V4 untouched. Separate pure chat/history/voice state transitions into a small browser-compatible core module that can also run under Node's built-in test runner. Store each AI chat as one local conversation with ordered messages; preserve other history categories and attach their selected content only after the user confirms sending it. Keep all model, speech, audio, and share behavior simulated in this preview.

**Tech Stack:** Existing HTML, CSS, vanilla JavaScript, V4 GLSL assets, localStorage, a zero-dependency UMD-style core module, Node's built-in `node:test`, and browser-based interaction/visual review.

**Spec:** [2026-10-08-miyin-ai-chat-history-voice-design.md](../specs/2026-10-08-miyin-ai-chat-history-voice-design.md)

## Global Constraints

- Keep the approved V4 directory and visual baseline unchanged; put new preview work in an independent V5 directory.
- The chat “语音” control starts direct AI voice conversation; it is not a response-language selector or speech-to-text-only action.
- Per-answer read-aloud is separate from live voice conversation.
- Store AI chats as independent conversations; only include another history item after the user explicitly selects and sends it as context.
- Keep session and history behavior local-first; use only a provider the user configured and selected, with no silent remote fallback.
- Do not call real model APIs, ASR, TTS, microphone or system audio capture, Android share APIs, Skills, or tools in the web preview.
- Preserve V4 theme, screen layout outside the approved AI/history changes, mode wheel, and distinctive microphone design.

## Review Focus

- Multiple turns must remain one AI history conversation after refresh; verify in Task 2.
- Unselected history must never leak into a chat request, and selected context must wait for send; verify in Task 5.
- Live voice conversation must be distinct from single-answer TTS, including denied-permission/error states; verify in Task 3.
- Model-unavailable or generation-error states must preserve the draft and selected model; verify in Task 4.
- History navigation must preserve the return category/query and remain usable at 375 × 667 without horizontal overflow; verify in Task 6.

---

## Plan Boundary

This plan covers the V5 browser preview only. The Android shell is a separate deliverable with no existing Android/Dart source in this repository and no selected native framework in the approved spec. After V5 is reviewed and approved, write a separate Android implementation plan against the final preview and current repository state.

The V4 preview is implemented as `index.html` with inline page logic plus companion CSS and JavaScript files. Follow that proven static-preview structure for V5 instead of refactoring V4 or introducing a build system in this phase.

### Task 1: Create an isolated V5 baseline

**Files:**
- Create: `docs/designs/miyin-full-app-preview-v5/index.html` (copy V4 and change only the document title and V5 asset references)
- Create: `docs/designs/miyin-full-app-preview-v5/miyin-v5.css` (copy V4 companion CSS)
- Create: `docs/designs/miyin-full-app-preview-v5/miyin-v5.js` (copy V4 companion JavaScript, update the displayed preview version, and isolate storage under V5)
- Create: `docs/designs/miyin-full-app-preview-v5/v4-baseline.sha256` (hashes for the three V4 files copied as the V5 baseline)
- Reference without modifying: `docs/designs/aurora-shape.glsl`, `docs/designs/miyin-mode-wheel-glass.glsl`

**Interfaces:**
- Consumes: V4 screen markup and shared shader assets.
- Produces: an independently served V5 preview at `/miyin-full-app-preview-v5/index.html` with V5-only CSS, JavaScript, and storage namespace.

- [x] **Step 1: Copy the three V4 preview files into the V5 directory and record their source SHA-256 values in `v4-baseline.sha256`.** Keep the shared shader sources referenced by the existing relative paths because V4 and V5 folders have the same depth under `docs/designs`.
- [x] **Step 2: Point the copied V5 page at `miyin-v5.css` and `miyin-v5.js`; set its title and navigation label to V5; change every copied local-storage prefix to `miyin.full.preview.v5.` in both the HTML and companion script.** Do not edit any V4 file or migrate V4 values.
- [x] **Step 3: Serve and open the baseline V5 page.** Check HTTP 200 for the page, both V5 assets, and both shader sources; render at 390 × 844 and confirm it matches V4 before feature changes.
  **Expected:** All five resources return 200; no console errors; the 390 × 844 V5 baseline matches V4's page layout and theme.
- [x] **Step 4: Commit the isolated baseline.** `git add docs/designs/miyin-full-app-preview-v5` and commit as `feat: add isolated Miyin V5 preview baseline`.
  **Expected:** A new baseline commit contains only the three V5 copies and the V4 hash manifest.

### Task 2: Model complete AI conversations

**Files:**
- Modify: `docs/designs/miyin-full-app-preview-v5/index.html` (existing inline state, `sendChat`, and AI conversation entry)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.js` (conversation UI interactions)
- Create: `docs/designs/miyin-full-app-preview-v5/miyin-v5-core.js` (pure browser-compatible domain functions; begin with an empty export surface so missing behavior yields assertion failures)
- Create/modify: `tests/miyin-v5-core.test.js` (conversation behavior tests)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.css` (small “新对话” control in the AI history list header; keep the V4 main chat header layout)

**Interfaces:**
- Consumes: V4-compatible `load`, `save`, `escapeHtml`, `announce`, and `showScreen` helpers in the copied V5 page.
- Produces:
  - `createConversation({ id, firstPrompt, modelId, now }) -> Conversation`
  - `appendConversationMessage(conversation, message, updatedAt) -> Conversation`
  - `upsertConversation(conversations, conversation) -> Conversation[]`
  - `appendMessage(conversationId, message) -> Conversation` (browser adapter that persists through the V5 namespace)
  - `loadConversations() -> Conversation[]`
  - `saveConversations(conversations) -> void`
  - `startNewConversation() -> void`
  - `ensureConversationForFirstMessage(prompt) -> Conversation`
  - `getConversation(conversationId) -> Conversation | null`
  - `Conversation = { id, title, createdAt, updatedAt, modelId, messages }`
  - `Message = { id, role, text, createdAt, status, contextAttachments }`

- [x] **Step 1: Add conversation tests before behavior.** Create the empty core export shell, then test first-message conversation creation, prompt-derived title, ordered message append, and one-conversation storage shape. Run `node --test tests/miyin-v5-core.test.js`.
  **Expected:** Node loads the test file and reports assertion failures that name missing core functions; there are no import/syntax errors.
- [x] **Step 2: Implement the tested pure conversation functions.** Keep identity/time injectable for deterministic tests and append only the exact user message plus simulated answer to one conversation.
- [x] **Step 3: Run the focused Node tests and confirm they pass.** `node --test tests/miyin-v5-core.test.js` must pass before adding browser persistence.
  **Expected:** All conversation-domain tests pass with zero failures.
- [x] **Step 4: Route all conversation and history persistence through the V5 namespace established in Task 1.** Keep existing V4 browser data isolated; do not migrate or overwrite it.
- [x] **Step 5: Seed V5 demo records only when its V5 storage namespace is empty.** Include complete sample AI messages and transcript turns for the other three history categories; every record must have enough content to exercise a detail view. Never reseed over user-created V5 data.
- [x] **Step 6: Implement the new-conversation state.** Starting a new chat clears the active thread and transient composer state but leaves saved conversations untouched; do not persist an empty conversation. The first sent message creates and titles the new conversation from its opening prompt.
- [x] **Step 7: Keep the selected model visible per conversation.** A preview-only “model not configured/unavailable” state must preserve the draft and pending context without silently choosing another provider.
- [x] **Step 8: Honor the existing save-history setting in the preview.** Turning it off keeps the active session in memory, does not persist it to local history, leaves existing records intact, and does not clear the current draft.
- [x] **Step 9: Manually verify persistence.** Send at least two turns, refresh, and confirm one AI history item contains all turns; start a new chat and confirm the original thread remains. Confirm V4 storage keys are unchanged.
  **Expected:** Refresh restores one multi-turn conversation, starting a new chat leaves it intact, and no V4 storage entry changes.
- [x] **Step 10: Commit the conversation state change.** `git add docs/designs/miyin-full-app-preview-v5 tests/miyin-v5-core.test.js` and commit as `feat: model AI chats as persistent conversations`.
  **Expected:** Commit contains only the V5 conversation code and its tests.

### Task 3: Restore AI identity and add live voice conversation

**Files:**
- Modify: `docs/designs/miyin-full-app-preview-v5/index.html` (chat composer and voice-session overlay markup)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.css` (AI mark and overlay states)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.js` (voice-session interaction and the V5 AI icon)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5-core.js` (voice state transitions)
- Modify: `tests/miyin-v5-core.test.js` (voice state tests)

**Interfaces:**
- Consumes: `appendMessage(conversationId, message)` browser adapter from Task 2.
- Produces:
  - `startVoiceSession() -> void`
  - `setVoiceSessionState(state) -> void`
  - `pauseVoiceSession() -> void`
  - `resumeVoiceSession() -> void`
  - `endVoiceSession() -> void`
  - `VoiceSessionState = idle | permission-required | unavailable | listening | processing | speaking | paused | permission-denied | error`

- [x] **Step 1: Restore a consistent AI mark in the chat UI.** Use the existing V4 speech-bubble-plus-sparkle identity, not the former bear icon; keep the mode wheel and other V4 pages visually unchanged.
- [x] **Step 2: Add a distinct voice-conversation control to the composer.** Its accessible label must say it starts AI voice conversation; it must not look or behave like a language selector or single-answer read-aloud action.
- [x] **Step 3: Write voice transition tests first and confirm the expected assertion failures.** Cover idle → permission-required → listening → processing → speaking, pause/resume, end, denied, and error recovery.
  **Expected:** Tests fail only because the required transition function/behavior is missing.
- [x] **Step 4: Implement an in-chat voice overlay and the state transitions in the Interfaces block.** It must show permission-required, unavailable, listening, processing, speaking, paused, permission-denied, and error states, with explicit pause/resume/end controls.
- [x] **Step 5: Run the focused Node tests, then simulate a voice exchange without capturing real audio.** Append the mock user transcript and AI reply to the same conversation; ending the session returns to that thread.
  **Expected:** All voice-state tests pass; transcript and reply appear in the active AI conversation, and no audio capture API is called.
- [x] **Step 6: Manually verify the distinction.** Opening voice mode must not populate the text composer; ending returns to the same chat; answer read-aloud (added in Task 4) must not open this overlay; denied permission/error state must offer text chat recovery.
  **Expected:** Voice actions remain within the active AI thread and the text recovery path preserves that thread.
- [x] **Step 7: Commit the voice interaction.** `git add docs/designs/miyin-full-app-preview-v5 tests/miyin-v5-core.test.js` and commit as `feat: add simulated AI voice conversation`.

### Task 4: Add answer actions and generation recovery

**Files:**
- Modify: `docs/designs/miyin-full-app-preview-v5/index.html` (inline styles, message action markup, and pending/error message states)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5-core.js` (generation state transitions)
- Modify: `tests/miyin-v5-core.test.js` (generation-state tests)

**Interfaces:**
- Consumes: `Conversation`, `Message`, and `appendMessage` from Task 2; voice session UI from Task 3.
- Produces:
  - `handleMessageAction(action, messageId) -> void`
  - `startMockGeneration(conversationId, prompt) -> void`
  - `stopGeneration(conversationId) -> void`
  - `retryGeneration(conversationId, messageId) -> void`
  - `speakAnswer(messageId) -> void`

- [x] **Step 1: Give each assistant message labeled controls for read aloud, copy, share, and regenerate.** The share preview must identify that it shares one answer.
- [x] **Step 2: Implement preview responses for the four controls.** Use browser clipboard only when available, with visible feedback; show read-aloud as a simulated playback state without invoking browser/device speech synthesis; use a local share preview rather than calling the system share API; regenerate with mock content.
- [x] **Step 3: Write generation-state tests first and confirm the expected assertion failures.** Cover pending → stopped, pending → failed → retry, and preservation of draft/model/context data on failure.
  **Expected:** Tests fail only on missing generation transitions or preservation behavior.
- [x] **Step 4: Implement generation states and recovery.** Show pending, stop, failure, and retry states. Keep the draft and selected model on failure; Task 5 adds attachment chips and send-time snapshots.
- [x] **Step 5: Run the focused Node tests.** `node --test tests/miyin-v5-core.test.js` must pass.
  **Expected:** Conversation, voice, and generation tests all pass with zero failures.
- [x] **Step 6: Keep single-answer read-aloud state separate from voice-session state.** Starting and stopping answer playback must not start or terminate a live voice session.
- [x] **Step 7: Manually verify all actions.** Exercise read/stop, copy feedback, one-answer share preview, regenerate, stop generation, simulated failure, and retry; confirm message order and input state.
  **Expected:** Each action produces the corresponding local UI state; failure/retry does not lose the draft or selected model.
- [x] **Step 8: Commit the answer controls.** `git add docs/designs/miyin-full-app-preview-v5 tests/miyin-v5-core.test.js` and commit as `feat: add AI answer actions and recovery states`.

### Task 5: Add searchable history details and explicit context attachment

**Files:**
- Modify: `docs/designs/miyin-full-app-preview-v5/index.html` (inline history, detail, search, and attachment UI logic)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5-core.js` (context snapshot, send-time attachment, and history search)
- Modify: `tests/miyin-v5-core.test.js` (attachment/search tests)

**Interfaces:**
- Consumes: `loadConversations`, `saveConversations`, `getConversation`, and `startNewConversation` from Task 2.
- Produces:
  - `renderHistory() -> void`
  - `openHistoryDetail(category, recordId) -> void`
  - `continueAiConversation(conversationId) -> void`
  - `prepareContextAttachment(category, recordId) -> ContextAttachment`
  - `removeContextAttachment(attachmentId) -> void`
  - `ContextAttachment = { id, category, sourceRecordId, title, selectedContentSnapshot }`

- [x] **Step 1: Render AI history by conversation.** Add search over AI titles and message text; support rename, whole-thread share preview, and confirmed deletion.
- [x] **Step 2: Add AI history detail.** Render the full ordered exchange and attached-context labels. “Continue” must reopen the same conversation ID and preserve the list’s return location.
- [x] **Step 3: Add detail views for translation, face-to-face, and video records.** Show the sample source/translation content, speaker/source details, and timestamps applicable to each category; keep record deletion available with confirmation.
- [x] **Step 4: Write context and search tests first and confirm the expected assertion failures.** Cover attachment snapshots, send-time association, removal before send, and title/message search.
  **Expected:** Tests fail only on missing snapshot, association/removal, or search behavior.
- [x] **Step 5: Implement explicit history-to-AI attachment flows.** Both an item detail action and the composer attachment picker can prepare an attachment. Render a removable chip before send; only associate it with the submitted user message after the user presses send. Store a content snapshot in that message so later deletion of the source record does not silently change the AI conversation; keep the source category and title visible.
- [x] **Step 6: Run the focused Node tests.** `node --test tests/miyin-v5-core.test.js` must pass.
  **Expected:** All conversation, voice, generation, attachment, and search tests pass with zero failures.
- [x] **Step 7: Add empty and no-search-result states.** Preserve the current history category and search query when returning from a detail view.
- [x] **Step 8: Manually verify context isolation.** Select one record and confirm its chip is visible; remove it and confirm it is absent; select another and send; verify only that selected content appears with the new AI message and no unrelated record is included.
  **Expected:** Only selected, unsent-until-confirmed context snapshots appear beside the submitted user message; unrelated history is absent.
- [x] **Step 9: Commit history and context flows.** `git add docs/designs/miyin-full-app-preview-v5 tests/miyin-v5-core.test.js` and commit as `feat: add AI history details and explicit context attachments`.

### Task 6: Verify V5 against the approved preview baseline

**Files:**
- Modify: `docs/designs/miyin-full-app-preview-v5/index.html` (only fixes found during review)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.css` (only fixes found during review)
- Modify: `docs/designs/miyin-full-app-preview-v5/miyin-v5.js` (only fixes found during review)
- Modify: `README.md` (replace stale V1/current-stage description with V4-approved and V5-review status)
- Modify: `docs/product/移动端产品边界-v0.1.md` (record V4 baseline and V5 scope without claiming Android implementation)
- Create: `output/playwright/miyin-v5-chat-390x844.png`
- Create: `output/playwright/miyin-v5-history-390x844.png`
- Create: `output/playwright/miyin-v5-history-detail-390x844.png`
- Create: `output/playwright/miyin-v5-desktop-1280x900.png`
- Modify: `docs/superpowers/specs/2026-10-08-miyin-ai-chat-history-voice-design.md` (record the V5 review state)

**Interfaces:**
- Consumes: all V5 UI, conversation, voice, and history flows from Tasks 1–5.
- Produces: a reviewable V5 preview with screenshots and truthful repository documentation.

- [x] **Step 1: Run all dependency-free logic tests and syntax checks.** Run `node --test tests/miyin-v5-core.test.js`, `node --check` on both V5 JavaScript files and the extracted inline page scripts; verify the page, CSS, JS, and GLSL assets return HTTP 200.
  **Expected:** Node tests pass, both syntax checks exit 0, and every local page/asset request returns 200.
- [x] **Step 2: Run the requested viewport review.** Use browser review at 390 × 844, 375 × 667, and 1280 × 900. Check horizontal overflow, clipped controls, focus/touch targets, and the V4 theme and mode wheel.
  **Expected:** No horizontal overflow or clipped primary actions at any viewport; V4 visual system and wheel remain intact.
- [x] **Step 3: Walk the complete preview flows.** Test new chat, multi-turn persistence, save-history off, voice entry and exit, answer operations, model-unavailable recovery without silent fallback, search, history detail/continue/rename/share/delete, attachment selection/removal/send, empty state, permission-required/denied voice states, and error retry.
  **Expected:** Every listed interaction reaches its labeled state; no browser console errors occur.
- [x] **Step 4: Check V4 isolation.** Compare pre/post SHA-256 for the existing V4 `index.html`, `miyin-v4.css`, and `miyin-v4.js`; confirm none changed. Confirm V5 localStorage uses only the V5 namespace.
  **Expected:** All three V4 hashes match `v4-baseline.sha256`; only V5-prefixed browser keys are created or changed.
- [x] **Step 5: Update repository docs accurately.** State that V4 is the approved visual baseline, V5 is implemented and awaiting review, Android source and real model/audio services are not yet implemented.
- [x] **Step 6: Commit final V5 QA and documentation.** Stage only the reviewed V5 model-recovery preview, the updated README/product/spec/plan docs, and the four newly generated `output/playwright/miyin-v5-*.png` screenshots, then commit as `feat: finalize Miyin V5 preview and review evidence`.
  **Expected:** Final commit contains the final QA screenshots and truthful status docs; tests are already present in earlier commits, and no pre-existing user file is staged.

After the user approves V5, prepare a separate Android-shell plan. That plan must first select the framework and storage approach from the actual repository and keep model, voice/TTS, context, history, and Android platform adapters behind the interfaces described in the spec.
