const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const core = require(path.resolve(__dirname, '../../assets/miyin_v5/miyin-v5-core.js'));
const appShell = require('node:fs').readFileSync(
  path.resolve(__dirname, '../../assets/miyin_v5/index.html'),
  'utf8',
);

test('speech language aliases are normalized before comparing with translation languages', () => {
  assert.equal(core.normalizeSpeechLanguageTag('Japanese'), 'ja');
  assert.equal(core.normalizeSpeechLanguageTag('en-US'), 'en');
  assert.equal(core.normalizeSpeechLanguageTag('zh-CN'), 'zh-Hans');
});

test('recognized languages outside the selected pair never fall through to a guessed translation direction', () => {
  assert.deepEqual(core.resolveSpeechTranslationPair({
    selectedSourceTag: 'zh-Hans',
    selectedTargetTag: 'en',
    detectedLanguageTag: 'Japanese',
  }), { status: 'unsupported', detectedLanguageTag: 'ja' });
});

test('speech language detection swaps only when the recognized language is the selected target', () => {
  assert.deepEqual(core.resolveSpeechTranslationPair({
    selectedSourceTag: 'zh-Hans',
    selectedTargetTag: 'en',
    detectedLanguageTag: 'en-US',
  }), { status: 'ready', sourceTag: 'en', targetTag: 'zh-Hans' });
});

test('a multilingual recognizer with no reliable language result stays unknown', () => {
  assert.deepEqual(core.resolveSpeechTranslationPair({
    selectedSourceTag: 'zh-Hans',
    selectedTargetTag: 'en',
    detectedLanguageTag: null,
  }), { status: 'unknown', detectedLanguageTag: null });
});

test('distinctive Japanese, Korean, Thai, Greek, and Hebrew scripts are recognized without confusing CJK kanji', () => {
  assert.equal(core.detectDistinctiveScriptLanguageTag('ありがとう'), 'ja');
  assert.equal(core.detectDistinctiveScriptLanguageTag('안녕하세요'), 'ko');
  assert.equal(core.detectDistinctiveScriptLanguageTag('สวัสดี'), 'th');
  assert.equal(core.detectDistinctiveScriptLanguageTag('γειά'), 'el');
  assert.equal(core.detectDistinctiveScriptLanguageTag('שלום'), 'he');
  assert.equal(core.detectDistinctiveScriptLanguageTag('漢字中国'), null);
  assert.equal(core.detectDistinctiveScriptLanguageTag('hello'), null);
});

test('multilingual speech without a reliable label stays unknown except for a distinctive script', () => {
  assert.match(appShell, /function speechLanguageFromEvent\(event,text,lastKnownTag=null\)[\s\S]*?if\(event\?\.recognitionMode==="multilingual"\)return null/);
  assert.match(appShell, /const distinctiveTag=MiyinV5Core\.detectDistinctiveScriptLanguageTag\(value\)/);
  assert.match(appShell, /function speechLanguageFromEvent\(event,text,lastKnownTag=null\)\{const pair=[\s\S]*?const distinctiveTag=[\s\S]*?if\(distinctiveTag\)return distinctiveTag;[\s\S]*?const supplied=/);
  assert.match(appShell, /distinctiveLanguage&&!\(\[selectedPair\.sourceTag,selectedPair\.targetTag\]\.includes\(distinctiveLanguage\)\)/);
  assert.match(appShell, /sourceTag=speechLanguageFromEvent\(event,rawText,lastFaceRecognitionLanguageTag\)/);
  assert.match(appShell, /if\(!sourceTag\)[\s\S]*?无法可靠判断语种/);
});

test('distinctive scripts override a contradictory ASR language label', () => {
  assert.match(appShell, /function speechLanguageFromEvent\(event,text,lastKnownTag=null\)\{const pair=[\s\S]*?const distinctiveTag=MiyinV5Core\.detectDistinctiveScriptLanguageTag\(value\);if\(distinctiveTag\)return distinctiveTag;[\s\S]*?const supplied=MiyinV5Core\.normalizeSpeechLanguageTag\(event\?\.languageTag\)/);
});

test('speech source language survives the recognition input event and controls the final translation direction', () => {
  assert.match(appShell, /dataset\.recognizedLanguage=detected/);
  assert.match(appShell, /const detectedSpeechLanguage=MiyinV5Core\.normalizeSpeechLanguageTag\(input\.dataset\.recognizedLanguage\)/);
  assert.match(appShell, /resolveSpeechTranslationPair\(\{selectedSourceTag:selectedPair\.sourceTag,selectedTargetTag:selectedPair\.targetTag,detectedLanguageTag:detectedSpeechLanguage\}\)/);
});

test('face-to-face rejects unsupported or uncertain speech with a distinct message instead of guessing Chinese or English', () => {
  assert.match(appShell, /async function translateFaceSpeech\(text,sourceTag\)[\s\S]*?resolveSpeechTranslationPair/);
  assert.match(appShell, /当前方向是"\+languageName\(selected\.sourceTag\)\+" ↔ "\+languageName\(selected\.targetTag\)\+"；文字未翻译/);
  assert.match(appShell, /已识别到文字，但无法确认语种；未翻译：/);
});
