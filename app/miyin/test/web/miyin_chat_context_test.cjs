const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../assets/miyin_v5/miyin-chat-context.js'), 'utf8');
function api() { const window = {}; vm.runInNewContext(source, {window}); return window.MiyinChatContext; }

test('memory presentation distinguishes phone, cloud and automatic summary capability', () => {
  const view=api().memoryPresentation;
  const context={providerId:'phone',model:'phone-model',summarySupported:false,privacy:{sendHistory:true,useMemory:true,saveLocalHistory:true}};
  assert.match(view(null,context).description,/近期原文/);
  assert.match(view(null,context).description,/暂不自动整理摘要/);
  assert.match(view(null,{...context,providerId:'deepseek'}).description,/云端模型/);
  const local={...context,providerId:'ollama',summarySupported:true};
  assert.match(view(null,local).description,/接近上下文预算时/);
  assert.match(view(null,{...local,privacy:{...local.privacy,useMemory:false}}).description,/自动整理已关闭/);
  assert.match(view(null,{...local,privacy:{...local.privacy,sendHistory:false}}).description,/不引用较早对话或摘要/);
  assert.match(view(null,{...local,privacy:{...local.privacy,saveLocalHistory:false}}).description,/历史保存：已关闭/);
});

test('saved summaries remain inspectable without claiming the current model uses them', () => {
  const memory={model:'old-computer-model',summary:'旧摘要',sourceQuotes:'原文',updatedAt:123};
  const view=api().memoryPresentation(memory,{providerId:'phone',model:'phone-model',summarySupported:false,privacy:{sendHistory:true,saveLocalHistory:true}});
  assert.match(view.description,/当前模型不使用下方摘要/);
  assert.match(view.content,/old-computer-model/);assert.match(view.content,/旧摘要/);
  assert.match(view.content,/原文/);assert.equal(view.hasSummary,true);
  const local={providerId:'ollama',model:'different-model',summarySupported:true,privacy:{sendHistory:true,useMemory:true,saveLocalHistory:true}};
  assert.match(api().memoryPresentation(memory,local).description,/来自其他模型/);
  for(const flag of ['sendHistory','useMemory']) {
    assert.match(api().memoryPresentation(memory,{...local,privacy:{...local.privacy,[flag]:false}}).description,/当前模型不使用下方摘要/);
  }
  const unknown=api().memoryPresentation(null,{});
  assert.match(unknown.description,/尚未取得当前模型的上下文状态/);
  assert.doesNotMatch(unknown.description,/会自动/);
});

test('plain prompt does not gain unrelated context', () => {
  assert.equal(api().assemble({text: '你好'}), '你好');
});
test('explicit meeting snapshots retain time and audio source but exclude media and nested references', () => {
  const text = api().assemble({text: '总结', contextAttachments: [{title: '会议', category: 'video',
    sourceRecordId: 'meeting-1', selectedContentSnapshot: {createdAt: '2026-10-25', entries: [
      {source: '决定周五交付', translation: 'Deliver Friday', at: '10:22:33', audioSource: 'mic',
        capturedAtMs: 123, audioId: 'PRIVATE_AUDIO', videoUri: 'PRIVATE_VIDEO',
        contextAttachments: [{text: 'UNSELECTED_HISTORY'}]},
    ]}}]});
  for (const item of ['资料1', 'meeting-1', '10:22:33', 'mic', '决定周五交付']) assert.ok(text.includes(item));
  for (const item of ['PRIVATE_AUDIO', 'PRIVATE_VIDEO', 'UNSELECTED_HISTORY']) assert.ok(!text.includes(item));
});
test('file text is labeled and numbered after history', () => {
  const text = api().assemble({text: '比较', contextAttachments: [{title: '历史', selectedContentSnapshot: '甲'}],
    attachments: [{name: 'note.md', extraction: '文件正文', text: '乙'}]});
  assert.ok(text.includes('[资料2] note.md'));
  assert.ok(text.includes('乙'));
});
test('metadata-only old attachments are rejected rather than silently omitted', () => {
  assert.throws(() => api().assemble({attachments: [{name: 'old.pdf'}]}), /没有可发送的正文/);
});
test('empty history snapshots are rejected', () => {
  assert.throws(() => api().assemble({contextAttachments: [{title: '空', selectedContentSnapshot: {audioId: 'only-audio'}}]}), /没有可发送的正文/);
});
test('message and selection budgets are explicit, never silently truncated', () => {
  assert.throws(() => api().assemble({text: 'a'.repeat(32001)}), /32,000/);
  assert.throws(() => api().assemble({attachments: Array(5).fill({text: 'a'})}), /最多/);
  assert.throws(() => api().assemble({contextAttachments: Array(9).fill({selectedContentSnapshot: 'a'})}), /最多/);
});
