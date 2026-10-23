const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const appRoot = path.resolve(__dirname, '../..');
const appShell = fs.readFileSync(path.join(appRoot, 'assets/miyin_v5/index.html'), 'utf8');

function sectionBetween(source, start, end) {
  const startIndex = source.indexOf(start);
  assert.notEqual(startIndex, -1, `missing section start: ${start}`);
  const endIndex = source.indexOf(end, startIndex);
  assert.notEqual(endIndex, -1, `missing section end: ${end}`);
  return source.slice(startIndex, endIndex);
}

test('language and speech settings separate translation downloads from bundled voice resources', () => {
  const languageSettings = sectionBetween(
    appShell,
    '<article class="setting-card" data-settings-language-card>',
    '</article>',
  );
  const speechSettings = sectionBetween(
    appShell,
    '<article class="setting-card" data-settings-speech-card>',
    '</article>',
  );

  assert.match(languageSettings, /翻译语言/);
  assert.match(languageSettings, /首次下载后由 Google Play 服务保存在本机/);
  assert.match(languageSettings, /data-action="open-dictionary-page"/);
  assert.doesNotMatch(speechSettings, /下载|管理模型|模型可选/);
  assert.match(speechSettings, /data-offline-tts-status/);
  assert.match(speechSettings, /自动识别当前翻译语言对/);
  assert.match(speechSettings, /data-action="tts-voice"/);
  assert.match(speechSettings, /data-action="tts-speed"/);
});

test('speech status is read from bundled ASR and TTS packages without offering model downloads', () => {
  const status = appShell.match(/async function refreshOfflineTtsStatus\(\)\{([\s\S]*?)\n      async function manageOfflineTts/);
  assert.ok(status, 'offline speech status reader must exist');
  assert.match(status[1], /voice\.offlineTtsStatus/);
  assert.match(status[1], /voice\.multilingualAsrStatus/);
  assert.match(status[1], /voice\.multilingualTtsStatus/);
  assert.match(status[1], /asr\?\.bundled===true&&tts\?\.bundled===true/);
  assert.match(status[1], /chineseReady===true&&.*englishReady===true/);
  assert.match(status[1], /languageTags/);

  const management = appShell.match(/async function manageOfflineTts\(\)\{([\s\S]*?)\n      async function openTtsVoicePicker/);
  assert.ok(management, 'offline TTS management must exist');
  assert.match(management[1], /source===?"downloaded"/);
  assert.match(management[1], /deletable===true/);
  assert.match(management[1], /!bundled/);
  assert.match(management[1], /无需下载/);
  assert.match(management[1], /不能单独删除/);

  const picker = appShell.match(/async function openTtsVoicePicker\(\)\{([\s\S]*?)\n      let multilingualTtsBusy/);
  assert.ok(picker, 'voice picker must exist');
  assert.match(picker[1], /speakerCount/);
  assert.match(picker[1], /previewAction:"preview-tts-voice"/);
  assert.doesNotMatch(picker[1], /downloadMultilingualTts|下载多语言|GitHub|129 MB/);
  assert.match(appShell, /"preview-tts-voice"/);
  assert.match(appShell, /action==="preview-tts-voice"\)\{void previewTtsVoice\(choice\.dataset\.value\);return\}/);
  assert.match(appShell, /async function previewTtsVoice\(value\)[\s\S]*?voice\.speak/);
});

test('face-to-face recognition keeps partial words visible and uses them if the final event is empty', () => {
  assert.match(appShell, /lastFaceRecognitionText=text;lastFaceRecognitionLanguageTag=sourceTag\|\|""/);
  assert.match(appShell, /正在确认识别结果："\+lastFaceRecognitionText/);
  assert.match(appShell, /rawText=finalText\|\|\(kind==="face"\?lastFaceRecognitionText:""\)/);
  assert.match(appShell, /sourceTag=speechLanguageFromEvent\(event,rawText,lastFaceRecognitionLanguageTag\)/);
});

test('face-to-face speaker placement follows the configured language pair', () => {
  const appendTurn = appShell.match(/function appendFaceTranslation\(sourceText,translatedText,pair\)\{([\s\S]*?)function getFaceRecordEntries/);
  assert.ok(appendTurn, 'face-to-face translation row builder must exist');
  assert.match(appendTurn[1], /pair\.sourceTag===faceBasePair\.targetTag/);
  assert.match(appendTurn[1], /isOtherSpeaker\?" · 对方说":" · 你说"/);
});

test('all inline scripts in the app shell remain syntactically valid', () => {
  const inlineScripts = [...appShell.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
    .map(match => match[1].trim())
    .filter(Boolean);
  assert.ok(inlineScripts.length > 0, 'the app shell must contain inline scripts');
  for (const [index, script] of inlineScripts.entries()) {
    assert.doesNotThrow(() => new vm.Script(script), `inline script ${index + 1} must parse`);
  }
});
