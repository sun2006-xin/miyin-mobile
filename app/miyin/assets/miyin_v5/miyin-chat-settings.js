/* Public settings only. API credentials never enter this page. */
(() => {
  'use strict';
  let data,draft,page,busy=false,notice='',parent=null,focusBefore,selectedService,selectedModel,session=0;
  const rpc=(method,params={})=>MiyinNativeBridge.request(method,params),ui=()=>window.MiyinChatUI;
  const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!=null)n.textContent=text;if(cls)n.className=cls;return n;};
  const arrow='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="m14 5-7 7 7 7M7 12h13"/></svg>';
  const view=el('section',null,'chat-config-view');view.hidden=true;view.id='chat-config-view';document.querySelector('#app').append(view);
  function btn(label,action,cls=''){const n=el('button',label,cls+' appearance-surface');n.type='button';n.disabled=busy;n.onclick=action;return n;}
  function field(label,value,change,placeholder=''){const wrap=el('label',null,'chat-config-field');wrap.append(el('span',label));const n=el('input');n.value=value||'';n.placeholder=placeholder;n.autocomplete='off';n.spellcheck=false;n.disabled=busy;n.oninput=()=>change(n.value);wrap.append(n);return wrap;}
  function toggle(label,value,action,detail=''){const row=btn('',action,'chat-config-toggle');row.setAttribute('role','switch');row.setAttribute('aria-checked',String(value));const text=el('span',null,'chat-config-copy');text.append(el('strong',label));if(detail)text.append(el('small',detail));const track=el('span',null,'chat-config-switch');track.setAttribute('aria-hidden','true');row.append(text,track);return row;}
  function modelRow(s,id){
    const configuring=page==='config';
    const chosen=configuring?(s.visibleModels||[]).includes(id):s.id===selectedService&&id===selectedModel;
    const row=btn('',()=>{
      if(configuring){const visible=new Set(s.visibleModels||[]);visible.has(id)?visible.delete(id):visible.add(id);s.visibleModels=[...visible];}
      else{selectedService=s.id;selectedModel=id;if(!['phone','ollama'].includes(s.id))draft.thinking=false;}
      notice='';render();
    },'chat-config-model');
    row.dataset.serviceId=s.id;row.dataset.modelId=id;
    row.setAttribute('role',configuring?'checkbox':'radio');row.setAttribute('aria-checked',String(chosen));
    row.setAttribute('aria-label',configuring?'在聊天列表显示 '+id:id);
    row.append(el('span',id),el('span',chosen?'✓':'',configuring?'chat-config-check':'chat-config-radio'));return row;
  }
  async function saveVisibility(){
    const owner=draft;
    const result=await rpc('chat.settings.visibility',{services:owner.services.map(s=>({service:s.id,endpoint:s.endpoint,models:s.visibleModels||[]}))});
    if(draft!==owner)return;
    for(const s of owner.services){const fresh=result.services.find(x=>x.id===s.id);s.visibleModels=fresh?.visibleModels||[];}
    if(parent==='picker'){parent=null;page='picker';notice='显示列表已保存，当前聊天模型未改变。';}
    else{close();ui().announce('显示列表已保存，当前聊天模型未改变。');}
  }

  function colors(){const css=getComputedStyle(document.documentElement),out={};for(const [name,key] of [['accent','--accent'],['ink','--ink'],['panel','--surface']]){const value=css.getPropertyValue(key).trim();if(/^#[a-f\d]{6}$/i.test(value))out[name]=value;}return out;}
  function close(){session++;busy=false;view.hidden=true;document.querySelector('#app').classList.remove('chat-config-open');document.querySelectorAll('[data-chat-config-inert]').forEach(n=>{n.inert=false;n.removeAttribute('data-chat-config-inert');});draft=null;parent=null;focusBefore?.focus?.({preventScroll:true});}
  function setPage(next){page=next;notice='';render();view.querySelector('h1,h2')?.focus({preventScroll:true});}
  function closeSearchMenu(){const menu=view.querySelector(".chat-search-menu:not([hidden])");if(!menu)return false;menu.hidden=true;const select=view.querySelector(".chat-search-select");select?.setAttribute("aria-expanded","false");select?.focus();return true;}
  function back(){if(closeSearchMenu())return;if(page==='config'&&parent==='picker'){parent=null;setPage('picker');}else close();}
  async function run(action){if(busy)return;const ticket=session;busy=true;notice='';render();try{await action();}catch(e){if(ticket===session)notice=e.message||'操作未完成，请重试。';}finally{if(ticket===session){busy=false;if(draft)render();}}}
  function apply(current){window.MiyinChat?.applyStatus(current);if(ui().getActiveId())ui().pinModel(ui().getActiveId(),current.model);}
  async function useSelected(){
    const owner=draft,id=selectedModel,s=owner.services.find(x=>x.id===selectedService);
    if(!s||!id)throw new Error('请先选择一个模型。');
    if(!['phone','ollama'].includes(s.id)&&!s.hasKey)throw new Error('请先为这个服务配置 API 密钥。');
    await rpc('chat.settings.save',{service:s.id,endpoint:s.endpoint,model:id,models:s.models,thinking:owner.thinking,contextWindow:owner.window});
    if(draft!==owner)return;
    if(data.status.providerId!==s.id||data.services.find(x=>x.id===s.id)?.endpoint!==s.endpoint)owner.privacy.allowNetwork=false;
    const current=await rpc('chat.privacy',owner.privacy);if(draft!==owner)return;
    apply(current);close();ui().announce('已使用 '+id+'。');
  }

  function footer(label,action){const n=el('footer',null,'chat-config-footer');n.append(btn('返回',back),btn(busy?'正在处理…':label,()=>void run(action),'chat-config-primary'));view.append(n);}
  function shell(title,compact){view.replaceChildren();view.classList.toggle('is-picker',compact);view.setAttribute('role',compact?'dialog':'region');view.setAttribute('aria-label',title);if(compact)view.setAttribute('aria-modal','true');else view.removeAttribute('aria-modal');const panel=el('div',null,'chat-config-panel');view.append(panel);const head=el('header',null,compact?'chat-config-sheet-head':'settings-head');const b=btn('',back,'back-button');b.disabled=false;b.innerHTML=arrow;b.setAttribute('aria-label','返回');const h=el(compact?'h2':'h1',title);h.tabIndex=-1;head.append(b,h,el('span',null,'chat-config-head-spacer'));panel.append(head);const body=el('div',null,'chat-config-scroll');panel.append(body);const status=el('p',notice,'chat-config-notice');status.setAttribute('role','status');status.hidden=!notice;body.append(status);return body;}
  function models(root,s){const group=el('div',null,'chat-config-model-list');group.setAttribute('role',page==='config'?'group':'radiogroup');group.setAttribute('aria-label',s.label+'模型');const filterKey=page+':'+s.id;const ids=page==='picker'?(s.visibleModels||[]):[...new Set(s.models||[])],list=el('div',null,'chat-config-model-items');const draw=(query='')=>{list.replaceChildren();const rows=ids.filter(id=>id.toLowerCase().includes(query.toLowerCase()));rows.slice(0,100).forEach(id=>list.append(modelRow(s,id)));if(!rows.length)list.append(el('p','暂无匹配模型','chat-config-hint'));if(rows.length>100)list.append(el('p','显示前 100 项，请输入名称筛选。','chat-config-hint'));};if(ids.length>6)group.append(field('筛选模型',draft.filters[filterKey]||'',v=>{draft.filters[filterKey]=v;draw(v);},'输入模型名称'));draw(draft.filters[filterKey]||'');list.dataset.modelService=s.id;group.append(list);root.append(group);}
  function picker(root){root.append(toggle('联网搜索',draft.privacy.webMode!=='off',()=>{draft.privacy.webMode=draft.privacy.webMode==='off'?'auto':'off';render();}));const thinking=toggle('深度思考',draft.thinking,()=>{draft.thinking=!draft.thinking;render();});thinking.disabled=busy||!['phone','ollama'].includes(selectedService);if(thinking.disabled)thinking.title='此服务的思考模式由模型配置决定';root.append(thinking);const group=el('section',null,'chat-config-picker-models appearance-surface');group.append(el('h3','模型选择'));for(const s of draft.services.filter(s=>(s.visibleModels||[]).length&&(['phone','ollama'].includes(s.id)||s.hasKey))){group.append(el('p',s.label,'chat-config-group-label'));models(group,s);}group.append(btn('配置其他模型  →',()=>{parent='picker';setPage('config');},'chat-config-add'));root.append(group);footer('确认',useSelected);}
  const modes=[['off','关闭'],['auto','自动判断'],['always','每次搜索']];
  function privacy(root){for(const [key,label,detail] of [['allowNetwork','允许发送','允许向所选云端或电脑模型发送消息；本机模型不需要此项。'],['sendHistory','携带当前上下文','发送当前会话内容，便于连续对话。'],['saveLocalHistory','保存会话历史','仅保存在本机；关闭不会删除已有记录。'],['useMemory','整理较早会话','电脑模型支持摘要记忆；本机模型保留近期原文。']])root.append(toggle(label,!!draft.privacy[key],()=>{draft.privacy[key]=!draft.privacy[key];render();},detail));const box=el('div',null,'chat-config-search appearance-surface'),label=el('strong','联网搜索'),selector=el('div',null,'chat-search-selector');
    const select=btn((modes.find(x=>x[0]===draft.privacy.webMode)||modes[0])[1]+' ⌄',()=>{const opened=select.getAttribute('aria-expanded')==='true';select.setAttribute('aria-expanded',String(!opened));menu.hidden=opened;if(!opened)menu.querySelector('[aria-selected="true"]')?.focus();},'chat-search-select');
    select.setAttribute('aria-haspopup','listbox');select.setAttribute('aria-expanded','false');select.setAttribute('aria-label','选择联网搜索方式');
    const menu=el('div',null,'chat-search-menu appearance-surface');menu.hidden=true;menu.setAttribute('role','listbox');menu.setAttribute('aria-label','联网搜索方式');
    for(const [value,name] of modes){const option=btn(name,()=>{draft.privacy.webMode=value;render();view.querySelector('.chat-search-select')?.focus();},'chat-config-mode');option.setAttribute('role','option');option.setAttribute('aria-selected',String(value===draft.privacy.webMode));menu.append(option);}
    selector.append(select,menu);box.append(label,selector);root.append(box);footer('保存',async()=>{const owner=draft;const current=await rpc('chat.privacy',owner.privacy);if(draft!==owner)return;apply(current);close();ui().announce('隐私设置已保存。');});}
  async function check(s){if(!draft?.services.includes(s))return;const owner=draft;const result=await rpc('chat.settings.check',{service:s.id,endpoint:s.endpoint});if(draft!==owner)return;s.models=result.models||[];if(!['phone','ollama'].includes(s.id)&&s.models.length){if(!s.models.includes(s.model))s.model=s.models[0];await rpc('chat.settings.catalog',{service:s.id,endpoint:s.endpoint,model:s.model,models:s.models});}notice=s.id==='phone'?'本机发现 '+s.models.length+' 个内置聊天模型。':'连接成功，已读取 '+s.models.length+' 个模型；可选择后使用。';}
  function config(root){root.append(el('p','勾选要显示在聊天列表中的模型，可多选；这里不会切换当前聊天模型。','chat-config-hint'));for(const s of draft.services){const section=el('details',null,'chat-config-provider');section.open=draft.expanded.has(s.id);section.ontoggle=()=>{if(!section.isConnected||!draft)return;section.open?draft.expanded.add(s.id):draft.expanded.delete(s.id);};const summary=el('summary',null,'appearance-surface');summary.append(el('h2',s.id==='phone'?'本机模型':s.label),el('span','⌄','chat-config-chevron'));section.append(summary);const card=el('div',null,'chat-config-provider-body appearance-surface');section.append(card);
    if(['phone','ollama'].includes(s.id)){card.append(btn(s.id==='phone'?'搜索本机':'搜索电脑模型',()=>void run(()=>check(s)),'chat-config-test'));if(s.id==='ollama')card.append(el('p','通过 USB 连接电脑 Ollama。','chat-config-hint'));}
    else{if(s.id==='custom')card.append(field('API 服务地址',s.endpoint,v=>s.endpoint=v,'https://服务地址/v1'));const row=el('div',null,'chat-config-key-row');row.append(btn(s.hasKey?'API 密钥  ••••••••':'添加 API 密钥',()=>void run(async()=>{const saved=await rpc('chat.configure',{page:'key',service:s.id,endpoint:s.endpoint,colors:colors()});if(!saved.settingsSaved)return;const fresh=await rpc('chat.settings');if(!draft?.services.includes(s))return;const updated=fresh.services.find(x=>x.id===s.id);s.hasKey=updated.hasKey;s.endpoint=updated.endpoint;s.visibleModels=updated.visibleModels||[];if(s.hasKey)await check(s);else notice='尚未保存密钥。';}),'chat-config-key'),btn('测试连接',()=>void run(()=>check(s)),'chat-config-test'));card.append(row);}
    if(s.models?.length)models(card,s);else card.append(el('p','无已添加模型','chat-config-hint'));
    if(s.id!=='phone'){const add=el('div',null,'chat-config-manual');add.append(field('手动添加模型 ID',s.manual||'',v=>s.manual=v,'服务提供的完整模型 ID'),btn('添加',()=>void run(async()=>{const id=(s.manual||'').trim();if(!id)throw new Error('请填写模型 ID。');const ids=[...new Set([...(s.models||[]),id])];await rpc('chat.settings.catalog',{service:s.id,endpoint:s.endpoint,model:s.model||id,models:ids});s.models=ids;notice='模型已添加，勾选后保存到聊天列表。';}),'chat-config-test'));card.append(add);}root.append(section);}footer('保存显示列表',saveVisibility);}
  function render(){
    if(!draft)return;
    const scroll=view.querySelector('.chat-config-scroll')?.scrollTop||0;
    const positions=new Map([...view.querySelectorAll('[data-model-service]')].map(n=>[n.dataset.modelService,n.scrollTop]));
    const focused=document.activeElement,modelFocus=focused?.dataset.modelId,serviceFocus=focused?.dataset.serviceId;
    const root=shell(page==='picker'?'选择 AI 模型':page==='privacy'?'隐私设置':'模型设置',page==='picker');
    view.classList.toggle('is-privacy',page==='privacy');
    if(page==='picker')picker(root);else if(page==='privacy')privacy(root);else config(root);
    view.querySelector('.chat-config-scroll').scrollTop=scroll;
    view.querySelectorAll('[data-model-service]').forEach(n=>n.scrollTop=positions.get(n.dataset.modelService)||0);
    if(modelFocus)[...view.querySelectorAll('[data-model-id]')].find(n=>n.dataset.modelId===modelFocus&&n.dataset.serviceId===serviceFocus)?.focus({preventScroll:true});
  }

  async function open(which='models'){if(busy)return;const ticket=++session;try{const loaded=await rpc('chat.settings');if(ticket!==session)return;data=loaded;draft={services:JSON.parse(JSON.stringify(data.services)),privacy:{...data.status.privacy,webMode:data.status.privacy.webMode||'off'},thinking:data.status.thinking,window:data.status.localContextWindow||8192,filters:{},expanded:new Set(data.services.filter(s=>s.id==='phone'||s.id===data.status.providerId||s.hasKey).map(s=>s.id))};selectedService=data.status.providerId;selectedModel=data.status.model||draft.services.find(s=>s.id===selectedService)?.model||'';if(!data.status.configured&&selectedService==='deepseek'){selectedService='phone';selectedModel=draft.services.find(s=>s.id==='phone').model;}focusBefore=document.activeElement;parent=null;page=which==='privacy'?'privacy':which==='models'?'picker':'config';notice='';ui().closeModal();view.hidden=false;document.querySelector('#app').classList.add('chat-config-open');document.querySelectorAll('#app > .screen').forEach(n=>{if(!n.inert){n.inert=true;n.setAttribute('data-chat-config-inert','');}});render();view.querySelector('h1,h2')?.focus({preventScroll:true});}catch(e){ui().announce(e.message||'设置未能打开。');}}
  document.addEventListener('keydown',e=>{if(view.hidden)return;const menu=view.querySelector('.chat-search-menu:not([hidden])');if(menu&&['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();const rows=[...menu.querySelectorAll('[role=option]')],i=rows.indexOf(document.activeElement);rows[e.key==='Home'?0:e.key==='End'?rows.length-1:(i+(e.key==='ArrowDown'?1:-1)+rows.length)%rows.length]?.focus();return;}if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();const menu=view.querySelector('.chat-search-menu:not([hidden])');if(menu){menu.hidden=true;view.querySelector('.chat-search-select')?.setAttribute('aria-expanded','false');view.querySelector('.chat-search-select')?.focus();}else back();}if(e.key==='Tab'){const controls=[...view.querySelectorAll('button:not(:disabled),input,summary')].filter(n=>n.getClientRects().length);const first=controls[0],last=controls.at(-1);if(e.shiftKey&&(document.activeElement===first||!view.contains(document.activeElement))){e.preventDefault();last?.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}}},true);
  document.addEventListener('click',e=>{if(!e.target.closest('.chat-search-selector')){const menu=view.querySelector('.chat-search-menu');if(menu)menu.hidden=true;view.querySelector('.chat-search-select')?.setAttribute('aria-expanded','false');}});
  window.MiyinChatSettings=Object.freeze({open,handleBack(){if(view.hidden)return false;back();return true;}});
})();
