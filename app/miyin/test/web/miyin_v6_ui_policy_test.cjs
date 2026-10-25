const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const appRoot = path.resolve(__dirname, '../..');
const repoRoot = path.resolve(appRoot, '../..');
const v6Ui = fs.readFileSync(path.join(appRoot, 'assets/miyin_v5/miyin-v6-app.js'), 'utf8');
const appShell = fs.readFileSync(path.join(appRoot, 'assets/miyin_v5/index.html'), 'utf8');
const appStyles = fs.readFileSync(path.join(appRoot, 'assets/miyin_v5/miyin-v6-app.css'), 'utf8');
const nativeHost = fs.readFileSync(path.join(appRoot, 'lib/features/miyin/miyin_mobile_app.dart'), 'utf8');
const androidTranslationHandler = fs.readFileSync(
  path.join(appRoot, 'android/app/src/main/kotlin/com/miyin/app/MiyinTranslationMethodHandler.kt'),
  'utf8',
);
const router = fs.readFileSync(path.join(appRoot, 'lib/features/miyin/translation_rpc_router.dart'), 'utf8');
const repository = fs.readFileSync(path.join(appRoot, 'lib/core/storage/translation_history_repository.dart'), 'utf8');
const previewRoot = path.join(repoRoot, 'docs/designs/miyin-full-app-preview-v6');
const previewStyles = fs.readFileSync(path.join(previewRoot, 'miyin-v6.css'), 'utf8');
const previewUi = fs.readFileSync(path.join(previewRoot, 'miyin-v6-preview.js'), 'utf8');
const previewShell = fs.readFileSync(path.join(previewRoot, 'index.html'), 'utf8');
const appCore = require(path.join(appRoot, 'assets/miyin_v5/miyin-v5-core.js'));
const previewCore = require(path.join(previewRoot, 'miyin-v5-core.js'));

function assertMatches(source, expression, message = `Expected source to match ${expression}`) {
  assert.ok(expression.test(source), message);
}

function assertDoesNotMatch(source, expression, message = `Expected source not to match ${expression}`) {
  assert.ok(!expression.test(source), message);
}

test('remote translation service is initialized on demand, not during app startup', () => {
  assertMatches(androidTranslationHandler, /private val modelManager by lazy\(LazyThreadSafetyMode\.SYNCHRONIZED\)/);
  assertDoesNotMatch(androidTranslationHandler, /private val modelManager\s*=\s*RemoteModelManager\.getInstance\(\)/);
  assertMatches(androidTranslationHandler, /override fun onMethodCall\(call: MethodCall, result: MethodChannel\.Result\) \{\s*try \{\s*dispatch\(call, result\)/);
  assertMatches(androidTranslationHandler, /"translation_unavailable"/);
});

test('dictionary mode stays on the translation home; the separate dictionary button opens the dictionary page', () => {
  const chooseMode = v6Ui.match(/const chooseMode = mode => \{([\s\S]*?)\n  \};/);
  assert.ok(chooseMode, 'V6 mode selection handler must exist');
  assertMatches(chooseMode[1], /miyin:translation-mode-change/);
  assertDoesNotMatch(chooseMode[1], /\bnavigate\s*\(/);

  const dictionaryEntry = v6Ui.match(/const oldInputTools = entry\.querySelector\(([\s\S]*?)\n  \}/);
  assert.ok(dictionaryEntry, 'the home attachment button must be repurposed as a dedicated dictionary-page entry');
  assertMatches(v6Ui, /miyin:open-dictionary-page/);
  assertMatches(appShell, /case "open-dictionary-page"/);
  assertDoesNotMatch(v6Ui, /routeDictionary\(true\)/);
  const productionOpen = v6Ui.match(/const openDictionaryPage = \(\) => \{([\s\S]*?)\n  \};/);
  const previewOpen = previewUi.match(/const openDictionaryPage = \(\{[\s\S]*?\n  \};/);
  assert.ok(productionOpen, 'production dictionary page navigation must exist');
  assert.ok(previewOpen, 'preview dictionary page navigation must exist');
  assertDoesNotMatch(productionOpen[1], /\.focus\s*\(/, 'entering the dictionary page must not summon the keyboard');
  assertDoesNotMatch(previewOpen[0], /\.focus\s*\(/, 'entering the preview dictionary page must not summon the keyboard');
});

test('language package management opens the complete offline resources page and dictionary is labeled generically', () => {
  assertMatches(appShell, /data-action="open-offline-resources">管理语言包/);
  assertMatches(appShell, /action==="open-offline-resources"[\s\S]*?miyin:open-offline-resources/);
  assertMatches(v6Ui, /miyin:open-offline-resources",\s*\(\)\s*=>\s*navigate\("resources"\)/);
  assertMatches(appShell, /<b>词典<\/b>/);
  assertDoesNotMatch(appShell, /<b>英汉词典<\/b>/);
});

test('returning from orb appearance to settings does not replace the original settings return destination', () => {
  const orbStyleHeader = appShell.match(/<header class="settings-head orb-style-head">([\s\S]*?)<\/header>/);
  assert.ok(orbStyleHeader, 'orb appearance screen header must exist');
  assertMatches(orbStyleHeader[1], /data-action="appearance-back"/);
  assertDoesNotMatch(orbStyleHeader[1], /data-screen="settings"/);
  assertMatches(appShell, /function showScreen\(name,options=\{\}\)[\s\S]*?options\.recordSettingsReturn!==false/);
  assertMatches(appShell, /case "appearance-back":if\(!window\.MiyinAppearance\?\.back\?\.\(\)\)showScreen\("settings",\{recordSettingsReturn:false\}\);break;/);
});

test('the translation home shows dictionary entry only for word mode and restores sentence input tools', () => {
  const syncTools = v6Ui.match(/const syncTranslationInputTool = \(\) => \{([\s\S]*?)\n  \};/);
  assert.ok(syncTools, 'production must switch the home input tool with translation mode');
  assertMatches(syncTools[1], /selectedMode === "dictionary"/);
  assertMatches(syncTools[1], /open-dictionary-page/);
  assertMatches(syncTools[1], /open-input-tools/);
  assertMatches(syncTools[1], /entryTools\?\.classList\.remove\("open"\)/);
  const updatePills = v6Ui.match(/const updatePills = \(\) => \{([\s\S]*?)\n  \};/);
  assert.ok(updatePills, 'translation mode UI must be synchronized');
  assertMatches(updatePills[1], /syncTranslationInputTool\(\)/);
  assertMatches(appShell, /data-action="camera"[\s\S]*?data-action="photo"[\s\S]*?data-action="document"/);
  assertMatches(previewUi, /syncTranslationInputTool/);
});

test('dictionary lookup uses the local English-Chinese dataset and never falls back to translation', () => {
  const handler = v6Ui.match(
    /dictionaryForm\?\.addEventListener\("submit", async event => \{([\s\S]*?)\n  \}, true\);/,
  );
  assert.ok(handler, 'dictionary form submit handler must exist');
  assertMatches(handler[1], /write\("dictionary-draft"/);
  assertMatches(handler[1], /const lookupMethod = \/\[\\u3400-\\u9fff\]\//);
  assertMatches(handler[1], /MiyinNativeBridge\.request\(lookupMethod, \{ query \}\)/);
  assertMatches(handler[1], /renderDictionaryLookup\(result\)/);
  assertDoesNotMatch(handler[1], /translation\.translate|\bfetch\s*\(/);
  assertMatches(router, /'dictionary\.lookup'/);
  assertMatches(v6Ui, /61,468 个英语词头/);
  assertMatches(v6Ui, /简体中文—日语词典 · 尚未接入/);
  assertMatches(v6Ui, /简体中文—俄语词典 · 尚未接入/);
});

test('AI chat keeps a narrower touch-friendly composer aligned with the right mode wheel', () => {
  assertMatches(appShell, /#screen-chat \.chat-bubble\.user \{[^}]*background:var\(--selected\)/);
  assertMatches(appStyles, /#screen-chat \.chat-bubble\.assistant \{[^}]*border: 1px solid var\(--line\)[^}]*background: var\(--surface\)/);
  assertMatches(appStyles, /#screen-chat \{[^}]*--chat-compose-side: 12px;[^}]*--chat-wheel-width: 68px;[^}]*--chat-control-gap: 8px;[^}]*--chat-wheel-side: 0px;[^}]*--chat-compose-width: min\(calc\(100% - var\(--chat-wheel-width\) - var\(--chat-compose-side\) - var\(--chat-control-gap\) - var\(--chat-wheel-side\)\), 280px\)/);
  assertMatches(appStyles, /#screen-chat \.chat-compose \{[^}]*width: var\(--chat-compose-width\);[^}]*min-width: 0;[^}]*align-self: flex-start;[^}]*margin: 0 0 0 var\(--chat-compose-side\)/);
  assertMatches(appStyles, /@media \(max-width: 370px\)[\s\S]*?#screen-chat \{ --chat-wheel-side: 7px; \}/);
  assertDoesNotMatch(appStyles, /#screen-chat \.mode-wheel/);
  assertMatches(appShell, /--chat-compose-side:12px;--chat-wheel-width:68px;--chat-control-gap:8px;--chat-wheel-side:0px;--chat-compose-width:min\(calc\(100% - var\(--chat-wheel-width\) - var\(--chat-compose-side\) - var\(--chat-control-gap\) - var\(--chat-wheel-side\)\),280px\)/);
  assertMatches(appShell, /#screen-chat \{ --chat-wheel-side:7px; \}/);
  assertMatches(appShell, /\.mode-wheel \{ position:absolute;z-index:5;right:0;bottom:12px;width:68px;height:140px/);
  assertMatches(appShell, /@media \(max-width:370px\) \{ \.mode-wheel \{ right:7px;width:68px;height:140px; \}/);
  assertDoesNotMatch(appShell, /#screen-chat \.mode-wheel/);
  assertMatches(appShell, /class="mode-wheel" data-wheel="translate"/);
  assertMatches(appShell, /class="mode-wheel" data-wheel="chat"/);
  assertDoesNotMatch(appStyles, /#screen-chat \.chat-compose \{[^}]*min-width: 244px/);
  assertMatches(appStyles, /#screen-chat \.compose-card textarea \{ height: 48px; min-height: 48px; max-height: 104px; padding: 5px 1px; resize: none; overflow-y: hidden; font-size: 15px; line-height: 1\.42; \}/);
  assertMatches(appStyles, /#screen-chat \.compose-tools button \{ min-height: 44px;[^}]*\}/);
  assertMatches(appStyles, /@media \(max-width: 370px\)[\s\S]*?#screen-chat \.compose-tools \.model-select \{ max-width: 64px; font-size: 9px; \}[\s\S]*?#screen-chat \.compose-tools \[data-action="chat-voice"\] span \{ display: none; \}/);
  assertMatches(appShell, /<textarea id="chat-input" rows="1"/);
  assertMatches(appShell, /function resizeChatInput\(\)[^\n]*chatInput\.style\.height="48px"[^\n]*Math\.min\(chatInput\.scrollHeight,104\)/);
  assertMatches(appShell, /let chatDraftRevision=0/);
  assertMatches(appShell, /chatInput\?\.addEventListener\("input",\(\)=>\{chatDraftRevision\+\+;resizeChatInput\(\)\}\)/);
  assertMatches(appStyles, /#screen-chat \.compose-card \{ padding: 5px 8px 7px; border-radius: 16px; \}/);
  assertMatches(appStyles, /#screen-chat \.compose-tools \{ gap: 4px; \}/);
  assertMatches(appShell, /input\.value="";resizeChatInput\(\);renderChatConversation\(getConversation\(conversation\.id\)\)/);
  assertMatches(appShell, /function startNewConversation\(\)[^\n]*resizeChatInput\(\)/);
  assertMatches(previewStyles, /#screen-chat \.chat-compose \{[^}]*width: min\(68%, 320px\);[^}]*align-self: flex-start/);
  assertDoesNotMatch(previewStyles, /chat-bubble\.(?:user|assistant)::before/);
  assertDoesNotMatch(previewStyles, /align-self:\s*flex-start\s*!important/);
});

test('translation screens start empty and clearing saved translation history clears the visible transcript', () => {
  assertMatches(appShell, /<div class="home-transcript" id="home-transcript" aria-live="polite"><\/div>/);
  assertMatches(appShell, /<div class="face-transcript" id="face-transcript" aria-live="polite"><\/div>/);
  assertDoesNotMatch(appShell, /请问去地铁站怎么走|附近的博物馆|Go straight ahead/);
  assertMatches(appShell, /const demoRecordIds=new Set\(\["t1","t2","f1","f2","v1"\]\)/);
  assertMatches(appShell, /conversation\?\.id!=="demo-chat-1"/);
  assertDoesNotMatch(appShell, /const sampleRecords=|const sampleEntries=|const sampleConversation=/);
  assertMatches(appShell, /async function clearNativeTranslationHistory\(\)/);
  assertMatches(appShell, /function tagTranslationHistoryNodes\(source,translation,kind,id,text\)/);
  assertMatches(appShell, /tagTranslationHistoryNodes\(source,translation,"native",result\.historyEntryId,text\)/);
  assertMatches(appShell, /removeHistoryTranscriptEntries\("translation","native",\[id\]\)/);
  assertMatches(appShell, /clearHistoryTranscript\("translation"\)/);
  assertMatches(appShell, /category==="translation"\|\|category==="face"\)clearHistoryTranscript\(category\)/);
  assertDoesNotMatch(appShell, /clearSubmittedDraftIfMatching|MiyinV6HomeDraft\?\.clearSubmitted/);
  assertMatches(appShell, /if\(translationPending\)\{announce\("当前翻译完成后将清空历史"\);await translationPendingSettled\}/);
  assertMatches(appShell, /if\(nativeHistoryClearPending\)\{announce\("正在清空翻译历史，请稍后再试"\);return\}/);
  assertMatches(appShell, /finally\{nativeHistoryClearPending=false\}/);
});

test('successful translation clears its stored draft, while a failed or changed draft remains intact', () => {
  assertMatches(appShell, /translationInputRevision!==draftRevision/);
  assertMatches(appShell, /clearTranslationDraftIfUnchanged\(input,draftSnapshot,draftRevision\)/);
  assertMatches(appShell, /settleTranslationDraftSubmitted\(draftSnapshot,submittedAt\)/);
  assertMatches(appShell, /MiyinV6HomeDraft\?\.markSubmitted/);
  assertMatches(v6Ui, /write\("home-draft", ""\)/);
  assertMatches(v6Ui, /draftRevision: Number\(read\("home-draft-revision", 0\)\) \|\| 0/);
  assertMatches(v6Ui, /write\("home-draft-revision", homeDraftRevision\)/);
  assertMatches(v6Ui, /history\.list[\s\S]*?rows\[0\]\?\.sourceText/);
  assertMatches(v6Ui, /homeDraftRevision !== revision/);
  assertMatches(v6Ui, /write\("home-submission-revision", submissionRevision\)/);
  assertMatches(v6Ui, /const submissionRevision = Number\(read\("home-submission-revision", 0\)\) \|\| 0/);
  assertMatches(v6Ui, /const latestSubmissionRevision = Number\(read\("home-submission-revision", 0\)\) \|\| 0/);
  assertMatches(v6Ui, /latestSubmissionRevision !== submissionRevision \|\| !MiyinV5Core\.isSamePendingHomeTranslation\(pending, latestPending\)/);
  assertMatches(v6Ui, /pending\?\.text === candidate && pending\?\.draftRevision === homeDraftRevision[\s\S]*?latestCreatedAt >= Number\(pending\.submittedAt/);
  assertMatches(v6Ui, /!migrationDone && homeDraftRevision === 0 && latestSource === candidate && \(!pending \|\| pending\.draftRevision !== homeDraftRevision\)/);
  assertMatches(v6Ui, /miyin:legacy-sent-draft-found/);
  assertMatches(appShell, /miyin:legacy-sent-draft-found[\s\S]*?label:"保留草稿"[\s\S]*?action:"clear-legacy-sent-draft"/);
  assertMatches(appShell, /translationInputRevision===prompt\.revision&&input\.value\.trim\(\)===prompt\.text/);
  assertMatches(v6Ui, /legacy-sent-draft-migration-v1\.2/);
  assertMatches(v6Ui, /Keep the draft when local history cannot confirm that it was already sent/);
  assertMatches(appShell, /startNewConversation\(\)[^\n]*chatDraftRevision\+\+/);
});

test('startup history reconciliation ignores a superseded translation submission', () => {
  const pendingAtStartup = {
    text: 'hello',
    submittedAt: 1000,
    draftRevision: 4,
    submissionRevision: 7,
  };
  const resubmittedSameText = { ...pendingAtStartup, submissionRevision: 8 };

  assert.equal(appCore.isSamePendingHomeTranslation(pendingAtStartup, pendingAtStartup), true);
  assert.equal(appCore.isSamePendingHomeTranslation(pendingAtStartup, resubmittedSameText), false);
  assert.equal(appCore.isSamePendingHomeTranslation(null, resubmittedSameText), false);
  assert.equal(appCore.isSamePendingHomeTranslation(null, null), true);
  assertMatches(v6Ui, /const latestPending = read\("pending-home-translation", null\)/);
  assertMatches(v6Ui, /isSamePendingHomeTranslation\(pending, latestPending\)/);
  const reconcile = v6Ui.match(/const clearRestoredDraftWhenAlreadyTranslated = async \(\) => \{([\s\S]*?)\n  \};/);
  assert.ok(reconcile, 'startup history reconciliation must exist');
  assert.ok(reconcile[1].indexOf('history.list') < reconcile[1].indexOf('const latestPending'));
  assert.ok(reconcile[1].indexOf('latestSubmissionRevision !== submissionRevision') < reconcile[1].indexOf('if (interruptedSuccessfulTranslation)'));
});

test('AI reply completion and failure do not overwrite a draft edited after sending', () => {
  assert.equal(appCore.shouldRestoreChatDraft({
    draftSnapshot: 'original prompt',
    inputValue: '',
    inputRevisionAtSend: 3,
    inputRevision: 3,
  }), true);
  assert.equal(appCore.shouldRestoreChatDraft({
    draftSnapshot: 'same prompt typed again',
    inputValue: 'same prompt typed again',
    inputRevisionAtSend: 3,
    inputRevision: 4,
  }), false);
  assert.equal(appCore.shouldRestoreChatDraft({
    draftSnapshot: 'original prompt',
    inputValue: '',
    inputRevisionAtSend: 3,
    inputRevision: 4,
  }), false);
  assert.equal(appCore.shouldConsumeRetriedChatDraft({
    draftSnapshot: 'original prompt',
    inputValue: 'original prompt',
    inputRevisionAtSend: 3,
    inputRevision: 3,
  }), true);
  assert.equal(appCore.shouldConsumeRetriedChatDraft({
    draftSnapshot: 'same prompt typed again',
    inputValue: 'same prompt typed again',
    inputRevisionAtSend: 3,
    inputRevision: 4,
  }), false);
  assertMatches(appShell, /inputRevisionAtSend:chatDraftRevision/);
  assertMatches(appShell, /function restoreGenerationDraft\(generation\)[^\n]*shouldRestoreChatDraft/);
  assertMatches(appShell, /shouldConsumeRetriedChatDraft/);
  assertMatches(appShell, /function startMockGeneration\([^\n]*updateMessage\([^\n]*status:"complete"/);
  assertDoesNotMatch(appShell, /clearDraftOnSuccess|input\.value===generation\.draftSnapshot/);
});

test('voice controls use native recognition and never fabricate speech or translations', () => {
  const handler = appShell.match(/function finishVoice\(kind\)\{[^}]*\}/);
  assert.ok(handler, 'voice release handler must exist');
  assertMatches(appShell, /voice\.startListening/);
  assertMatches(appShell, /voice\.stopListening/);
  assertMatches(appShell, /recognition_final/);
  assertDoesNotMatch(handler[0], /你好，很高兴认识你|Hello, it’s nice to meet you|正在翻译/);
  assertDoesNotMatch(appShell, /已识别（预览）/);
});

test('TTS prewarms the selected output voice and states multilingual ASR limits clearly', () => {
  assertMatches(appShell, /function prewarmTtsVoice\([^]*MiyinNativeBridge\.request\("voice\.prepare"/);
  assertMatches(appShell, /function updateLanguages\(\)[^]*prewarmTtsVoice\(pair\.targetTag/);
  assertMatches(appShell, /miyin:native-host-ready",\(\)=>\{const pair=translationPairParams\(\);void prewarmTtsVoice/);
  assertMatches(router, /'voice\.prepare'/);
  assertMatches(appShell, /多语种自动识别 57 种可尝试；准确度因语种而异/);
  assertMatches(appShell, /多语种自动识别 \$\{asrCount\} 种可尝试（准确度因语种而异）/);
});

test('TTS prewarm retry uses a bounded key cooldown and clears only the matching failed request', () => {
  assertMatches(appShell, /TTS_PREWARM_RETRY_AFTER_MS=30000/);
  assertMatches(appShell, /setTimeout\(\(\)=>resetTtsPrewarmKey\(key\),TTS_PREWARM_RETRY_AFTER_MS\)/);
  assertMatches(appShell, /catch\(\(\)=>\{resetTtsPrewarmKey\(key\);return null\}\)/);
  assertMatches(appShell, /function resetTtsPrewarmKey\(key\)\{if\(lastTtsPrewarmKey!==key\)return/);
});

test('TTS click-to-start latency is correlated by session until the native started event', () => {
  assertMatches(appShell, /async function toggleSpeechPlayback\(button\)\{\s*const clickStartedAt=performance\.now\(\)[^]*beginTtsStartTimer\(sessionId,clickStartedAt\);[^]*request\("voice\.speak"/);
  assertMatches(appShell, /async function previewTtsVoice\(value\)\{const clickStartedAt=performance\.now\(\)[^]*activeTtsSessionId=sessionId;beginTtsStartTimer\(sessionId,clickStartedAt\);[^]*request\("voice\.speak"/);
  assertMatches(appShell, /if\(type==="tts_started"\)\{finishTtsStartTimer\(sessionId\);return\}/);
  assertMatches(appShell, /click_to_started_ms=.*sessionId=/);
  assertMatches(appShell, /ttsStartTimes\.delete\(sessionId\)/);
  assertDoesNotMatch(appShell, /click_to_started_ms=[^\n]*text/);
});

test('the face-to-face footer has no pause control and exposes transient recognition status', () => {
  assertMatches(appShell, /id="face-status" role="status" aria-live="polite">准备就绪<\/small>/);
  assertMatches(appShell, /faceStatus|role="status"/);
  assertDoesNotMatch(appShell, /session-pause|data-action="toggle-pause"|facePaused/);
  assertDoesNotMatch(previewShell, /session-state|data-action="toggle-pause"|facePaused/);
  assertDoesNotMatch(previewUi, /pauseControl|session-state|toggle-pause/);
  assertDoesNotMatch(previewStyles, /session-state/);
  assertMatches(appShell, /\.face-status-row \{[^}]*clip-path:inset\(50%\)/);
  assertMatches(appShell, /#screen-face \.face-status-row\.is-visible small \{[^}]*opacity:1/);
  const faceBottom = appShell.match(/<div class="face-bottom">([\s\S]*?)<div class="mode-wheel" data-wheel="translate"/);
  assert.ok(faceBottom, 'face-to-face status must be in the footer above the language controls');
  assert.ok(faceBottom[1].indexOf('face-status-row') < faceBottom[1].indexOf('face-language'));
  assert.doesNotMatch(faceBottom[1], /face-mic-wrap[^]*face-status-row/);
  assertMatches(appShell, /#screen-face \.face-status-row\.is-visible \{[^}]*position:relative;grid-column:1\/-1;[^}]*width:100%/);
  assertMatches(appShell, /#screen-face \.face-status-row \{[^}]*position:absolute;[^}]*width:1px;height:1px/);
  assertMatches(appShell, /recognition_partial/);
  assertMatches(appShell, /正在聆听：/);
});

test('AI attachment menu shows accessible camera, screen, file, and image icons', () => {
  const menu = appShell.match(/function openChatAttachmentMenu\(\)\s*\{([\s\S]*?)\n      \}/);
  assert.ok(menu, 'AI attachment menu builder must exist');
  for (const [action, label] of [['camera', '相机拍照'], ['screen', '投屏'], ['file', '文件'], ['image', '图片']]) {
    assert.ok(menu[1].includes('["' + action + '","' + label + '"'), `missing accessible ${label} attachment action`);
  }
  assertMatches(appStyles, /\.chat-attachment-grid/);
  assertMatches(appStyles, /\.chat-attachment-option[^}]*min-width:\s*44px[^}]*min-height:\s*48px/);
  assertMatches(appShell, /系统投屏能力尚未接入/);
  assertMatches(previewShell, /仅展示已选文件信息；不读取内容、不上传，也不会交给 AI 处理/);
  assertDoesNotMatch(previewShell, /仅在本机暂存/);
  assertMatches(appShell, /pendingChatAttachments/);
});

test('chat and translation file pickers have fixed destinations, even when a picker is canceled', () => {
  for (const id of ['file-photo', 'file-image', 'file-document']) assertMatches(appShell, new RegExp('id="' + id + '"[^>]*data-selection-target="translation"'));
  for (const id of ['chat-file-camera', 'chat-file-image', 'chat-file-document']) assertMatches(appShell, new RegExp('id="' + id + '"[^>]*data-selection-target="chat"'));
  assertMatches(appShell, /target=file\.dataset\.selectionTarget/);
  assertDoesNotMatch(appShell, /fileSelectionTarget/);
  assertMatches(appShell, /function openLocalFileInput\(selector,label\)[\s\S]*?if\(isNativeHost\(\)\)[\s\S]*?pickNativeAttachment\(kind,input\.dataset\.selectionTarget,label\)/);
  assertMatches(appShell, /function pickNativeAttachment\(kind,target,label\)[\s\S]*?MiyinNativeBridge\.request\("attachment\.pickSource",\{kind\}\)/);
  assertMatches(appShell, /function pickNativeAttachment\(kind,target,label\)[\s\S]*?selected\.canceled/);
  assertDoesNotMatch(appShell, /Android 文件选择器/);
  assertMatches(appShell, /case "camera":openLocalFileInput\("#file-photo"/);
  assertMatches(appShell, /case "photo":openLocalFileInput\("#file-image"/);
  assertMatches(appShell, /case "document":openLocalFileInput\("#file-document"/);
  assertMatches(appShell, /openLocalFileInput\(kind==="camera"\?"#chat-file-camera"/);
  assertMatches(appShell, /attachments:pendingChatAttachments\.map/);
});

test('native app resizes the chat canvas to the visible keyboard viewport', () => {
  assertMatches(nativeHost, /window\.visualViewport/);
  assertMatches(nativeHost, /--miyin-visible-height/);
  assertMatches(appStyles, /html\[data-native-host="true"\] \.workspace \{[^}]*min-height: 0/);
  assertMatches(appStyles, /html\[data-native-host="true"\] \.device \{[^}]*min-height: 0/);
});

test('history categories share one-line back controls and offer multi-select delete', () => {
  assertMatches(appShell, /\.history-unified-toolbar/);
  assertMatches(appShell, /data-history-bulk-toggle/);
  assertMatches(appShell, /data-history-select-all/);
  assertMatches(appShell, /data-history-bulk-delete/);
  assertMatches(appShell, /history\.deleteMany/);
  assertMatches(router, /history\.deleteMany/);
  assertMatches(repository, /Future<int> deleteTranslations/);
  assertMatches(previewShell, /data-v6-history-action="delete-selected"/);
  assertMatches(appShell, /\.history-unified-toolbar \.back-button[^}]*white-space:\s*nowrap/);
  assertMatches(previewStyles, /\.history-content \[data-history-back\][\s\S]*?white-space: nowrap/);
});

test('offline resources use the setting capsule and describe bundled speech and dictionary data accurately', () => {
  assertMatches(v6Ui, /button class="setting-trigger v6-resource-trigger appearance-surface" type="button" data-screen="resources"/);
  assertMatches(previewUi, /button class="setting-trigger v6-resource-trigger" type="button" data-screen="resources"/);
  assertMatches(appStyles, /\.v6-resource-trigger \{[^}]*appearance: none/);
  assertMatches(previewStyles, /\.v6-resource-trigger \{[^}]*appearance: none/);
  assertMatches(v6Ui, /词典 · 已内置/);
  assertMatches(v6Ui, /61,468 个英语词头/);
  assertMatches(v6Ui, /data-v6-asr-resource/);
  assertMatches(v6Ui, /data-v6-tts-resource/);
  assertMatches(v6Ui, /voice\.multilingualAsrStatus/);
  assertMatches(v6Ui, /voice\.multilingualTtsStatus/);
  assertMatches(v6Ui, /随 APK 内置/);
  assertDoesNotMatch(v6Ui, /下载多音色包|可选下载|删除多音色包/);
  assertMatches(v6Ui, /已下载的语言包会完整列在上方/);
  assertMatches(previewUi, /词典查词|英汉词典/);
});

test('dictionary and resource back buttons pop a shared navigation stack', () => {
  assertMatches(v6Ui, /MiyinV5Core\.createScreenReturnStack/);
  assertMatches(v6Ui, /data-v6-nav-back/);
  assertMatches(v6Ui, /navigationStack\.pop\(current\)/);
  assertDoesNotMatch(v6Ui, /const setDictionaryBackTarget = screen/);
  assertMatches(previewUi, /MiyinV5Core\.createScreenReturnStack/);
  assertMatches(previewUi, /data-v6-nav-back/);
  assertMatches(previewUi, /navigationStack\.pop\(current\)/);
  assertMatches(v6Ui, /window\.MiyinV6Navigation\s*=\s*\{[\s\S]*?handleSystemBack/);
  assertMatches(previewUi, /window\.MiyinV6Navigation\s*=\s*\{[\s\S]*?handleSystemBack/);
  assertMatches(nativeHost, /PopScope<Object\?>\([\s\S]*?onPopInvokedWithResult:[\s\S]*?_handleSystemBack/);
  assertMatches(nativeHost, /addJavaScriptChannel\([\s\S]*?'MiyinNavigation'/);
  assertMatches(appShell, /miyin:request-app-exit/);
  assertMatches(appShell, /data-modal-action="exit-app"|action:"exit-app"/);
});

test('settings/resource return keeps its original destination and system back closes modal first', () => {
  for (const source of [v6Ui, previewUi]) {
    assertMatches(source, /if \(destination === "settings"\) settingsReturnRestorePending = true/);
    assertMatches(source, /consumeSettingsReturnRestore\(\)/);
    assertDoesNotMatch(source, /isSettingsOwnedRoute/);
    const backHandler = source.match(/handleSystemBack\(\)\s*\{([\s\S]*?)\n\s*\}\n\s*\};/);
    assert.ok(backHandler, 'system back handler must exist');
    assert.ok(backHandler[1].indexOf('#modal-scrim.open') < backHandler[1].indexOf('navigateBackFromResourceArea'));
  }
  assertMatches(appShell, /restoringSettingsRoute=window\.MiyinV6Navigation\?\.consumeSettingsReturnRestore\?\.\(\)===true/);
  assertMatches(appShell, /settingsReturnStack=\[\]/);
  assertMatches(appShell, /if\(origin==="appearance"\)\{if\(!settingsReturnStack\.length\)settingsReturnStack\.push\("home"\)\}else if\(origin!=="settings"&&!restoringSettingsRoute&&options\.recordSettingsReturn!==false\)\{settingsReturnStack\.length=0;settingsReturnStack\.push\(origin\)/);
  assertMatches(appShell, /function backFromSettings\(\)\{const candidate=settingsReturnStack\.pop\(\)\|\|"home";settingsReturnStack\.length=0;const target=candidate!=="appearance"/);
  assertDoesNotMatch(appShell, /settingsReturnScreen|isSettingsOwnedRoute/);

  assertMatches(previewShell, /function showScreen\(name\)\{[\s\S]*?restoringSettingsRoute=window\.MiyinV6Navigation\?\.consumeSettingsReturnRestore\?\.\(\)===true;if\(origin!=="settings"&&!restoringSettingsRoute\)\{settingsReturnStack\.push\(origin\)/);
  assertMatches(previewShell, /function backFromSettings\(\)\{const candidate=settingsReturnStack\.pop\(\)\|\|"home"/);
  assertDoesNotMatch(previewShell, /settingsReturnScreen|isSettingsOwnedRoute/);

  for (const core of [appCore, previewCore]) {
    const stack = core.createScreenReturnStack();
    assert.equal(stack.push('settings', 'resources'), true);
    assert.equal(stack.peek('resources'), 'settings');
    assert.equal(stack.pop('resources'), 'settings');
    assert.equal(stack.depth, 0);

    assert.equal(stack.push('home', 'dictionary'), true);
    assert.equal(stack.push('dictionary', 'resources'), true);
    assert.equal(stack.peek('resources'), 'dictionary');
    assert.equal(stack.pop('resources'), 'dictionary');
    assert.equal(stack.pop('dictionary'), 'home');
    assert.equal(stack.depth, 0);

    assert.equal(stack.push('settings', 'resources'), true);
    assert.equal(stack.push('resources', 'dictionary'), true);
    assert.equal(stack.peek('dictionary'), 'resources');
    assert.equal(stack.pop('dictionary'), 'resources');
    assert.equal(stack.peek('resources'), 'settings');
    assert.equal(stack.pop('resources'), 'settings');
    assert.equal(stack.depth, 0);
  }
});

test('profile avatar opens settings from headers and stays circular and centered', () => {
  assertMatches(appShell, /<button[^>]*class="profile-avatar"[^>]*data-action="change-avatar"/);
  assertMatches(appShell, /profile\.pickAvatar/);
  assertMatches(appShell, /avatar-camera/);
  assertMatches(appShell, /avatar-gallery/);
  assertMatches(appShell, /load\("profile-avatar"/);
  assertMatches(appShell, /save\("profile-avatar"/);
  assertMatches(appShell, /\.avatar-image \{ position:absolute;inset:0;display:none;width:100%;height:100%;border-radius:50%;object-fit:cover;object-position:center;clip-path:circle\(50%\); \}/);
  assertMatches(appShell, /\$\$\("\.profile-avatar, \.avatar-button"\)\.forEach/);
  assertMatches(v6Ui, /class="avatar-button"[^>]*data-screen="settings" aria-label="用户与设置"/);
  assertMatches(previewUi, /class="avatar-button"[^>]*data-screen="settings" aria-label="用户与设置"/);
  assertMatches(appShell, /class="avatar-button"[^>]*data-screen="settings" aria-label="用户与设置"/);
  assertDoesNotMatch(appShell, /header-avatar|avatar-settings/);
  assertMatches(appShell, /function backFromSettings\(\)/);
  assertMatches(appShell, /data-action="settings-back"/);
  assertMatches(appShell, /if\(screenBtn\.dataset\.screen!=="history"&&screenBtn\.dataset\.screen!=="settings"\)/);
  assertMatches(v6Ui, /destination !== "settings" && returnableScreens\.has\(activeScreenName\(\)\)/);
  assertMatches(previewUi, /destination !== "settings" && returnableScreens\.has\(current\)/);
  assertMatches(appShell, /\.profile-avatar \{ position:relative;flex:0 0 88px;width:88px;height:88px;aspect-ratio:1 \/ 1;[\s\S]*?clip-path:circle\(50%\)/);
  assertMatches(appShell, /\.settings-head h1 \{[\s\S]*?font-size:24px/);
  assertMatches(appShell, /\.profile-name span \{ grid-column:2/);
  assertMatches(appShell, /\.profile-name button \{ grid-column:3/);
  assertMatches(appShell, /avatar_image_invalid/);
  assertMatches(appShell, /avatar_picker_failed/);
  assertMatches(appShell, /avatar-remove/);
  assertMatches(appShell, /removeItem\("miyin\.full\.preview\.v5\.profile-avatar"\)/);
});

test('sentence translation opens a compact attachment icon menu without focusing the text field', () => {
  const productionAction = appShell.match(/case "open-input-tools":([\s\S]*?)break;/);
  const previewAction = previewShell.match(/case "open-input-tools":([\s\S]*?)break;/);
  assert.ok(productionAction, 'production sentence attachment action must exist');
  assert.ok(previewAction, 'preview sentence attachment action must exist');
  assertMatches(productionAction[1], /openTranslationAttachmentMenu\(\)/);
  assertMatches(previewAction[1], /openTranslationAttachmentMenu\(\)/);
  assertDoesNotMatch(productionAction[1], /translation-input|entry-tools/);
  assertDoesNotMatch(previewAction[1], /translation-input|entry-tools/);

  for (const source of [appShell, previewShell]) {
    const menu = source.match(/function openTranslationAttachmentMenu\(\)\s*\{([\s\S]*?)\n\s*\}/);
    assert.ok(menu, 'translation attachment icon menu builder must exist');
    assertMatches(menu[1], /data-translation-attachment/);
    for (const action of ['camera', 'photo', 'document']) {
      assert.ok(menu[1].includes('["' + action + '"'), `translation menu must keep ${action} action`);
    }
  }
  assertMatches(appStyles, /\.translation-attachment-grid/);
  assertMatches(previewStyles, /\.translation-attachment-grid/);
  assertMatches(appShell, /data-translation-attachment[\s\S]*?openLocalFileInput/);
  assertMatches(appShell, /可以在本机选择照片或文档；识别与文档翻译尚未接入/);
  assertMatches(previewShell, /data-translation-attachment[\s\S]*?\$\("#file-photo"\)\.click\(\)/);
  assertDoesNotMatch(appShell, /\.entry-tools\.open\s*\{\s*display:\s*flex/);
  assertDoesNotMatch(previewShell, /\.entry-tools\.open\s*\{\s*display:\s*flex/);
});

test('restored image picker failures show a short retry message', () => {
  assertMatches(appShell, /miyin:native-picker-recovery-failed/);
  assertMatches(appShell, /上次图片选择未能恢复，请重新选择/);
});

test('home transcript starts below the header and settings opens shared language management', () => {
  assertDoesNotMatch(appShell, /\.home-transcript::before\s*\{/);
  assertDoesNotMatch(appStyles, /\.home-transcript::before\s*\{/);
  assertDoesNotMatch(previewStyles, /\.home-transcript::before\s*\{/);
  assertDoesNotMatch(appShell, /<button class="offline-model-status"/);
  assertDoesNotMatch(appShell, /class="native-model-row"/);
  assertMatches(appShell, /data-settings-language-card[\s\S]*?<b>离线翻译<\/b>[\s\S]*?data-action="open-offline-resources"/);
});

test('translation history stays on one vertical page and avoids a large sticky white toolbar', () => {
  assertMatches(appShell, /\.history-content\s*\{[^}]*overflow-x:\s*hidden[^}]*touch-action:\s*pan-y/);
  assertMatches(appShell, /\.history-unified-toolbar\s*\{[^}]*position:\s*relative[^}]*background:\s*transparent/);
  assertMatches(appShell, /\.native-history-pair\s*\{[^}]*display:\s*grid/);
  assertMatches(appShell, /entry\.sourceText\|\|""/);
  assertMatches(appShell, /entry\.translatedText\|\|""/);
  assertDoesNotMatch(appShell, /const open=event\.target\.closest\("\[data-native-history-open\]"\)/);
});

test('choosing a translation file never overwrites the translation draft with a filename', () => {
  for (const source of [appShell, previewShell]) {
    assertMatches(source, /已选择「"\+f\.name\+"」/);
    assertDoesNotMatch(source, /translation-input"\)\.value="已添加文件："\+f\.name/);
  }
});

test('offline translation resources list every installed language model independently of the selected pair', () => {
  assertMatches(v6Ui, /data-v6-installed-translation-models/);
  assertMatches(v6Ui, /translation\.installedModels/);
  assertMatches(v6Ui, /translation\.deleteLanguageModel/);
  assertMatches(v6Ui, /data-v6-language-model-action="delete"/);
  assertMatches(androidTranslationHandler, /"getDownloadedModels"/);
  assertMatches(androidTranslationHandler, /getDownloadedModels\(TranslateRemoteModel::class\.java\)/);
  assertMatches(androidTranslationHandler, /"deleteLanguageModel"/);
  assertMatches(androidTranslationHandler, /\.language\b/);
  assertDoesNotMatch(v6Ui, /translation\.deleteModel/);
});

test('dictionary selects a package and automatically routes Chinese or English lookup with bounded A-Z browsing', () => {
  assertMatches(v6Ui, /<h1 class="v6-page-heading">词典<\/h1>/);
  assertMatches(v6Ui, /data-v6-dictionary-package/);
  assertMatches(v6Ui, /简体中文—日语词典 · 尚未接入/);
  assertMatches(v6Ui, /简体中文—俄语词典 · 尚未接入/);
  assertMatches(v6Ui, /输入中文或英语词条…/);
  assertMatches(v6Ui, /输入中文或英语词条开始查询/);
  assertDoesNotMatch(v6Ui, /placeholder = "输入英语单词或短语/);
  assertMatches(v6Ui, /dictionary\.lookupChinese/);
  assertMatches(v6Ui, /const lookupMethod = \/\[\\u3400-\\u9fff\]\//);
  assertDoesNotMatch(v6Ui, /data-v6-dictionary-direction|查词方向|切换到“简体中文 → 英语”/);
  assertMatches(v6Ui, /data-v6-alphabet-index/);
  assertMatches(v6Ui, /data-v6-dictionary-browse-items/);
  assertMatches(v6Ui, /dictionary\.browse/);
  assertMatches(v6Ui, /ABCDEFGHIJKLMNOPQRSTUVWXYZ/);
  const renderer = v6Ui.match(/const makeDictionaryEntryCard = entry => \{([\s\S]*?)\n  \};/);
  assert.ok(renderer, 'dictionary entry renderer must exist');
  assertMatches(renderer[1], /v6-dictionary-entry-result/);
  assertMatches(renderer[1], /v6-dictionary-sense-row/);
  assertMatches(renderer[1], /exampleGroups\.push/);
  assert.ok(renderer[1].indexOf('card.append(meanings)') < renderer[1].indexOf('card.append(exampleSection)'), 'all meanings must appear before the shared examples section');
  assertMatches(renderer[1], /美式 IPA/);
  assertMatches(v6Ui, /美式 IPA/);
  assertMatches(v6Ui, /ipaByWord/);
  assertDoesNotMatch(renderer[1], /card\.className = "v6-dictionary-sense"/);
  assertMatches(v6Ui, /音标数据暂缺/);
  assertMatches(appStyles, /\.v6-dictionary-entry-result\s*\{/);
  assertMatches(appStyles, /\.v6-dictionary-sense-row\s*\{/);
  assertMatches(appStyles, /\.v6-dictionary-example-section\s*\{/);
  assertMatches(appStyles, /\.v6-dictionary-word\s*\{/);
  assertMatches(appStyles, /\.v6-dictionary-load-more\s*\{/);
  assertMatches(appStyles, /\.v6-translation-add-model\s*>\s*summary/);
});

test('dictionary retries A after native-host readiness and reloads the current letter when opened', () => {
  const readyRetry = v6Ui.match(
    /const retryDictionaryBrowseWhenNativeHostReady = \(\) => \{([\s\S]*?)\n  \};/,
  );
  assert.ok(readyRetry, 'dictionary browse must retry after the native host is ready');
  assertMatches(readyRetry[1], /isNativeHost\(\)/);
  assertMatches(readyRetry[1], /loadDictionaryBrowsePage\("A", true\)/);
  assertMatches(v6Ui, /addEventListener\("miyin:native-host-ready", retryDictionaryBrowseWhenNativeHostReady\)/);

  const screenReload = v6Ui.match(
    /const reloadDictionaryBrowseWhenScreenOpens = \(\) => \{([\s\S]*?)\n  \};/,
  );
  assert.ok(screenReload, 'opening the dictionary screen must load its current browse letter');
  assertMatches(screenReload[1], /activeScreenName\(\) !== "dictionary"/);
  assertMatches(screenReload[1], /loadDictionaryBrowsePage\(dictionaryBrowseLetter, true\)/);
  assertMatches(v6Ui, /addEventListener\("miyin:surface-visibility-change", reloadDictionaryBrowseWhenScreenOpens\)/);

  const browse = v6Ui.match(/const loadDictionaryBrowsePage = async[\s\S]*?\n  \};/);
  assert.ok(browse, 'dictionary browse loader must remain available to both lifecycle retries');
  assertMatches(browse[0], /请在觅音 App 中浏览本机词典。/);
});
