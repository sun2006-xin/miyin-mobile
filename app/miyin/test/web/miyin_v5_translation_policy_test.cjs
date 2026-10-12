const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../../assets/miyin_v5/miyin-v5-core.js');

test('only explicitly supported directions with downloaded models are selectable', () => {
  const supportedPairs = [
    { sourceTag: 'zh-Hans', targetTag: 'en' },
    { sourceTag: 'en', targetTag: 'zh-Hans' },
    { sourceTag: 'ja', targetTag: 'en' },
  ];

  const installed = core.filterInstalledTranslationPairs(supportedPairs, {
    'zh-Hans->en': 'downloaded',
    'en->zh-Hans': 'notDownloaded',
    'ja->en': 'failed',
  });

  assert.deepEqual(installed, [supportedPairs[0]]);
});

test('installed pair filtering preserves exact engine directions and never creates combinations', () => {
  const supportedPairs = [
    { sourceTag: 'zh-Hans', targetTag: 'en' },
    { sourceTag: 'ja', targetTag: 'en' },
  ];

  const installed = core.filterInstalledTranslationPairs(supportedPairs, {
    'zh-Hans->en': 'downloaded',
    'ja->en': 'downloaded',
  });

  assert.deepEqual(installed, supportedPairs);
  assert.equal(installed.some(pair => pair.sourceTag === 'en' && pair.targetTag === 'zh-Hans'), false);
});

test('sentence translation does not require a dictionary, but dictionary mode never falls back', () => {
  assert.equal(core.canRunTranslationMode('sentence', false), true);
  assert.equal(core.canRunTranslationMode('dictionary', false), false);
  assert.equal(core.canRunTranslationMode('dictionary', true), true);
  assert.equal(core.canRunTranslationMode('unknown', true), false);
});

test('language direction decisions never collapse unsupported or unresolved statuses into not-downloaded', () => {
  assert.equal(core.translationDirectionDecision('checking', null), 'checking');
  assert.equal(core.translationDirectionDecision('failed', null), 'unknown');
  assert.equal(core.translationDirectionDecision('partial', 'unknown'), 'unknown');
  assert.equal(core.translationDirectionDecision('ready', 'downloaded'), 'ready');
  assert.equal(core.translationDirectionDecision('ready', 'notDownloaded'), 'notDownloaded');
  assert.equal(core.translationDirectionDecision('ready', 'unsupported'), 'unsupported');
  assert.equal(core.translationDirectionDecision('ready', 'failed'), 'failed');
  assert.equal(core.translationDirectionDecision('ready', 'unexpected-status'), 'unknown');
  assert.equal(core.translationDirectionDecision('ready', 'downloaded', false), 'unsupported');
});

test('dictionary and resource cross-links return to the page that opened the resource area', () => {
  const navigation = core.createScreenReturnStack({
    dictionary: 'home',
    resources: 'settings',
  });

  navigation.push('home', 'dictionary');
  navigation.push('dictionary', 'resources');
  navigation.push('resources', 'dictionary');

  assert.equal(navigation.pop('dictionary'), 'home');
  assert.equal(navigation.depth, 0);
  assert.equal(navigation.pop('dictionary'), 'home');

  navigation.push('settings', 'resources');
  navigation.push('resources', 'dictionary');
  assert.equal(navigation.pop('dictionary'), 'resources');
  assert.equal(navigation.pop('resources'), 'settings');
  assert.equal(navigation.depth, 0);
});
