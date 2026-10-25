(() => {
  const root = document.documentElement;
  const screen = document.querySelector('#screen-appearance');
  const settingsCard = document.querySelector('#theme-current')?.closest('.setting-card');
  const scroll = screen?.querySelector('.orb-style-scroll');
  if (!screen || !settingsCard || !scroll) return;

  const videoStatus = document.querySelector('#video-status');
  const videoActions = document.querySelector('#screen-video .subtitle-head-actions');
  if (videoStatus && videoActions) videoActions.prepend(videoStatus);

  const prefix = 'miyin.full.preview.v5.';
  const options = {
    material: ['liquid', 'crystal', 'ceramic', 'metal', 'soft'],
    feedback: ['bounce', 'press', 'glow', 'none'],
    typography: ['serif-head', 'sans', 'rounded']
  };
  const labels = {
    material: { liquid: '凝露琉璃', crystal: '澄透玻璃', ceramic: '温润陶釉', metal: '柔光金属', soft: '云绒微光' },
    feedback: { bounce: '轻弹回馈', press: '轻压回馈', glow: '柔光回馈', none: '简洁无动效' },
    typography: { 'serif-head': '思源宋体标题＋黑体正文', sans: '全黑体', rounded: '圆润黑体' }
  };
  const storageKey = { material: 'button-material', feedback: 'press-feedback', typography: 'appearance-typography' };
  const defaults = { material: 'liquid', feedback: 'bounce', typography: 'serif-head' };
  const read = kind => {
    try {
      const value = JSON.parse(localStorage.getItem(prefix + storageKey[kind]));
      return options[kind].includes(value) ? value : defaults[kind];
    } catch { return defaults[kind]; }
  };
  const write = (kind, value) => {
    try { localStorage.setItem(prefix + storageKey[kind], JSON.stringify(value)); } catch {}
  };
  const status = document.createElement('span');
  status.className = 'appearance-status';
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');

  const settingPanel = settingsCard.querySelector('.setting-panel');
  const themeLists = [...settingPanel.querySelectorAll('.theme-choice-list')];
  if (themeLists[0] && !themeLists[0].querySelector('[data-theme-choice="palette-cloud-jade"]')) {
    const jade = document.createElement('button');
    jade.type = 'button';
    jade.className = 'theme-choice';
    jade.dataset.themeChoice = 'palette-cloud-jade';
    jade.setAttribute('aria-pressed', String(root.dataset.theme === 'palette-cloud-jade'));
    jade.innerHTML = '<span class="theme-swatch"><i style="background:#F1F7F8"></i><i style="background:#FFFFFF"></i><i style="background:#0C6D73"></i><i style="background:#B9DBDA"></i></span><span>云玉雾玻</span>';
    themeLists[0].prepend(jade);
  }
  const captionRow = [...settingPanel.querySelectorAll('.setting-row')].find(row => row.textContent.includes('字幕文字大小'));
  settingPanel.replaceChildren();
  const entry = document.createElement('div');
  entry.className = 'setting-row';
  entry.innerHTML = '<div class="setting-copy"><b>觅音外观</b><small>主题、按钮、字体与 AI 球体</small></div><button class="value-control" type="button" data-screen="appearance">打开外观</button>';
  settingPanel.append(entry);
  if (captionRow) settingPanel.append(captionRow);

  const themeSection = document.createElement('section');
  themeSection.className = 'appearance-section appearance-theme-section appearance-page';
  themeSection.dataset.appearancePage = 'themes';
  themeSection.id = 'appearance-themes';
  themeSection.innerHTML = '<div class="appearance-section-head"><h2>界面主题</h2><span id="theme-current">自由搭配</span></div><p>配色与背景独立选择；按钮材质可与任意主题组合。</p>';
  // Theme buttons are kept as the original nodes, so the existing theme handler and saved choice continue to work.
  const themesByType = [
    ['配色主题', themeLists[0]],
    ['特殊材质主题', themeLists[1]]
  ];
  themesByType.forEach(([title, list]) => {
    if (!list) return;
    const heading = document.createElement('h3');
    heading.textContent = title;
    themeSection.append(heading, list);
  });
  const selectedTheme = themeSection.querySelector('[data-theme-choice][aria-pressed="true"]');
  themeSection.querySelector('#theme-current').textContent = selectedTheme?.lastElementChild?.textContent || '自由搭配';
  const controls = document.createElement('section');
  controls.className = 'appearance-controls appearance-page';
  controls.dataset.appearancePage = 'controls';
  controls.id = 'appearance-controls';
  controls.innerHTML = `
    <div class="appearance-section-head"><h2>按钮质感</h2><span>独立于主题</span></div>
    <div class="appearance-choice-grid" role="group" aria-label="按钮材质">
      <button type="button" data-appearance-kind="material" data-appearance-value="liquid"><i class="appearance-sample sample-liquid"></i><strong>凝露琉璃</strong><small>柔和透明 · 推荐</small></button>
      <button type="button" data-appearance-kind="material" data-appearance-value="crystal"><i class="appearance-sample sample-crystal"></i><strong>澄透玻璃</strong><small>清晰折光 · 更像玻璃</small></button>
      <button type="button" data-appearance-kind="material" data-appearance-value="ceramic"><i class="appearance-sample sample-ceramic"></i><strong>温润陶釉</strong><small>细腻高光</small></button>
      <button type="button" data-appearance-kind="material" data-appearance-value="metal"><i class="appearance-sample sample-metal"></i><strong>柔光金属</strong><small>低调拉丝</small></button>
      <button type="button" data-appearance-kind="material" data-appearance-value="soft"><i class="appearance-sample sample-soft"></i><strong>云绒微光</strong><small>轻盈柔软</small></button>
    </div>
    <div class="appearance-section-head"><h2>按压反馈</h2><span>可单独更换</span></div>
    <div class="appearance-choice-grid appearance-feedback-grid" role="group" aria-label="按压反馈">
      <button type="button" data-appearance-kind="feedback" data-appearance-value="bounce"><strong>轻弹回馈</strong><small>松开后轻轻回弹</small></button>
      <button type="button" data-appearance-kind="feedback" data-appearance-value="press"><strong>轻压回馈</strong><small>按下时短暂下沉</small></button>
      <button type="button" data-appearance-kind="feedback" data-appearance-value="glow"><strong>柔光回馈</strong><small>边缘亮起</small></button>
      <button type="button" data-appearance-kind="feedback" data-appearance-value="none"><strong>简洁无动效</strong><small>静态反馈</small></button>
    </div>
    <div class="appearance-section-head"><h2>字体</h2><span>即时应用</span></div>
    <div class="appearance-choice-grid appearance-font-grid" role="group" aria-label="界面字体">
      <button type="button" data-appearance-kind="typography" data-appearance-value="serif-head"><strong class="serif-sample">觅音外观</strong><small>思源宋体标题＋黑体正文</small></button>
      <button type="button" data-appearance-kind="typography" data-appearance-value="sans"><strong>觅音外观</strong><small>全黑体</small></button>
      <button type="button" data-appearance-kind="typography" data-appearance-value="rounded"><strong class="rounded-sample">觅音外观</strong><small>圆润黑体</small></button>
    </div>
    <div class="appearance-live-preview" aria-label="按钮组合预览"><span>效果预览</span><button type="button">开始同传</button><button type="button">选择语言</button></div>`;
  controls.append(status);
  const hub = document.createElement('section');
  hub.className = 'appearance-hub appearance-page';
  hub.dataset.appearancePage = 'hub';
  hub.innerHTML = '<div class="appearance-hub-list"><button type="button" data-appearance-open="themes"><span><strong>界面主题</strong><small id="appearance-theme-summary">选择配色与背景</small></span><span aria-hidden="true">›</span></button><button type="button" data-appearance-open="controls"><span><strong>按钮与字体</strong><small id="appearance-controls-summary">调整质感与触感</small></span><span aria-hidden="true">›</span></button><button type="button" data-appearance-open="orb"><span><strong>AI 球体</strong><small id="appearance-orb-summary">调整球体外观</small></span><span aria-hidden="true">›</span></button></div>';
  const intro = scroll.querySelector('.orb-style-intro');
  if (intro) hub.prepend(intro);
  const orbPage = document.createElement('section');
  orbPage.className = 'appearance-orb-page appearance-page';
  orbPage.dataset.appearancePage = 'orb';
  const orbHeading = document.createElement('div');
  orbHeading.className = 'appearance-section-head appearance-orb-head';
  orbHeading.id = 'appearance-orb';
  orbHeading.innerHTML = '<h2>AI 球体</h2><span>材质、波形、配色自由组合</span>';
  orbPage.append(orbHeading);
  [...scroll.children].filter(child => child.matches('.orb-current-preview,.orb-style-group,.orb-style-note,#orb-appearance-status')).forEach(child => orbPage.append(child));
  scroll.replaceChildren(hub, themeSection, controls, orbPage);
  const title = screen.querySelector('.orb-style-head h1');
  const backButton = screen.querySelector('[data-action="appearance-back"]');
  const pageTitles = { hub: '觅音外观', themes: '界面主题', controls: '按钮与字体', orb: 'AI 球体' };
  let currentPage = 'hub';
  const updateHub = () => {
    const activeTheme = themeSection.querySelector('[data-theme-choice][aria-pressed="true"]');
    const themeName = activeTheme?.lastElementChild?.textContent || '选择配色与背景';
    themeSection.querySelector('#theme-current').textContent = themeName;
    hub.querySelector('#appearance-theme-summary').textContent = themeName;
    hub.querySelector('#appearance-controls-summary').textContent = `${labels.material[read('material')]} · ${labels.feedback[read('feedback')]} · ${labels.typography[read('typography')]}`;
    hub.querySelector('#appearance-orb-summary').textContent = document.querySelector('#orb-style-current-name')?.textContent?.trim() || '调整球体外观';
  };
  const showPage = page => {
    if (!pageTitles[page]) return;
    currentPage = page;
    scroll.querySelectorAll('.appearance-page').forEach(section => { section.hidden = section.dataset.appearancePage !== page; });
    title.textContent = pageTitles[page];
    backButton.setAttribute('aria-label', page === 'hub' ? '返回设置' : '返回觅音外观');
    updateHub();
    scroll.scrollTop = 0;
  };
  window.MiyinAppearance = {
    showHub: () => showPage('hub'),
    back: () => { if (currentPage === 'hub') return false; showPage('hub'); return true; }
  };
  let appearanceWasActive = screen.classList.contains('active');
  window.addEventListener('miyin:surface-visibility-change', () => {
    const active = screen.classList.contains('active');
    if (active && !appearanceWasActive) showPage('hub');
    appearanceWasActive = active;
  });

  // Resolve palette colors to ordinary rgba values for older Android WebViews.
  // CSS color-mix() is unavailable in WebView 97, including on the review OPPO.
  const colorCanvas = document.createElement('canvas');
  colorCanvas.width = colorCanvas.height = 1;
  const colorContext = colorCanvas.getContext('2d', { willReadFrequently: true });
  const rgba = value => {
    colorContext.clearRect(0, 0, 1, 1);
    colorContext.fillStyle = value;
    colorContext.fillRect(0, 0, 1, 1);
    return [...colorContext.getImageData(0, 0, 1, 1).data].map((v, i) => i === 3 ? v / 255 : v);
  };
  const colorText = values => `rgba(${values.slice(0, 3).map(Math.round).join(',')},${values[3].toFixed(3)})`;
  const blend = (a, b, ratio) => a.map((v, i) => v * ratio + b[i] * (1 - ratio));
  const luminance = color => color.slice(0, 3).map(v => v / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4).reduce((sum, v, i) => sum + v * [.2126, .7152, .0722][i], 0);
  const syncPalette = () => {
    const style = getComputedStyle(root);
    const readColor = (name, fallback) => rgba(style.getPropertyValue(name).trim() || fallback);
    const surface = readColor('--surface', '#ffffff');
    const accent = readColor('--accent', '#0c6d73');
    const ink = readColor('--ink', '#214b52');
    const muted = readColor('--muted', '#547781');
    const white = [255, 255, 255, 1], black = [0, 0, 0, 1];
    const dark = luminance(surface) < .18;
    const shine = dark ? [.20, .08] : [.85, .60];
    const values = {
      edge: blend(accent, surface, dark ? .63 : .48),
      'input-edge': blend(accent, surface, dark ? .35 : .22),
      wash: blend(surface, accent, .89),
      raised: blend(surface, accent, .96),
      selected: blend(surface, accent, dark ? .76 : .80),
      highlight: [...white.slice(0, 3), shine[0]],
      shadow: [...ink.slice(0, 3), dark ? .28 : .15],
      'shadow-soft': [...ink.slice(0, 3), dark ? .18 : .08],
      'accent-glow': [...accent.slice(0, 3), .22]
    };
    Object.entries(values).forEach(([key, value]) => root.style.setProperty('--appearance-' + key, colorText(value)));
    const s = (a, b, weight) => colorText(blend(a, b, weight));
    const backgrounds = {
      liquid: `linear-gradient(145deg,${s(surface, white, dark ? .94 : .75)},${s(surface, accent, .77)} 52%,${s(surface, white, dark ? .96 : .90)})`,
      crystal: `linear-gradient(120deg,${s(surface, white, dark ? .85 : .62)},${s(surface, accent, .91)} 26%,${s(surface, accent, .78)} 55%,${s(surface, white, dark ? .91 : .75)} 82%)`,
      ceramic: `linear-gradient(160deg,${s(surface, white, .92)},${s(surface, accent, .92)})`,
      metal: `repeating-linear-gradient(112deg,rgba(255,255,255,.06) 0 1px,transparent 1px 3px),linear-gradient(112deg,${s(surface, white, .85)},${s(surface, muted, .74)} 36%,${s(surface, white, .92)} 62%,${s(surface, ink, .86)})`,
      soft: s(surface, accent, .91)
    };
    root.style.setProperty('--appearance-button-bg', backgrounds[read('material')]);
    const primary = blend(accent, surface, dark ? .50 : .97);
    const whiteContrast = (1.05) / (luminance(primary) + .05);
    const blackContrast = (luminance(primary) + .05) / .05;
    root.style.setProperty('--appearance-primary-ink', whiteContrast >= blackContrast ? '#ffffff' : '#102227');
    root.style.setProperty('--appearance-primary-bg', `linear-gradient(145deg,${s(primary, white, .92)},${colorText(primary)} 52%,${s(primary, black, .92)})`);
    document.querySelectorAll('.setting-trigger,.value-control,.theme-choice,.orb-style-choice,.orb-wave-choice,.orb-palette-choice,.language-pill,.source-pills button,.subtitle-style,.video-start,.subtitle-record-toggle,.subtitle-record-files,.subtitle-language-pair button,.appearance-live-preview button,.appearance-hub-list button').forEach(button => button.classList.add('appearance-surface'));
  };
  new MutationObserver(syncPalette).observe(root, { attributes: true, attributeFilter: ['data-theme'] });

  const sync = () => {
    root.dataset.buttonMaterial = read('material');
    root.dataset.pressFeedback = read('feedback');
    root.dataset.appearanceTypography = read('typography');
    syncPalette();
    document.querySelectorAll('[data-appearance-kind]').forEach(button => {
      button.setAttribute('aria-pressed', String(button.dataset.appearanceValue === read(button.dataset.appearanceKind)));
    });
    updateHub();
  };
  sync();
  showPage('hub');
  document.addEventListener('click', event => {
    const openButton = event.target.closest('[data-appearance-open]');
    if (openButton && screen.contains(openButton)) {
      showPage(openButton.dataset.appearanceOpen);
      return;
    }
    if (screen.contains(event.target) && event.target.closest('[data-theme-choice],[data-orb-style-choice],[data-orb-palette-choice],[data-orb-wave-choice],[data-orb-appearance-reset]')) requestAnimationFrame(updateHub);
    const button = event.target.closest('[data-appearance-kind]');
    if (!button || !screen.contains(button)) return;
    const kind = button.dataset.appearanceKind;
    const value = button.dataset.appearanceValue;
    if (!options[kind]?.includes(value)) return;
    write(kind, value);
    sync();
    status.textContent = labels[kind][value] + '已应用';
  });
  const pressable = 'button:not(.switch):not(:disabled)';
  document.addEventListener('pointerup', event => {
    if (read('feedback') !== 'bounce' || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const button = event.target.closest(pressable);
    if (!button) return;
    button.classList.remove('appearance-rebound');
    void button.offsetWidth;
    button.classList.add('appearance-rebound');
  });
  document.addEventListener('animationend', event => {
    if (event.animationName === 'appearance-bounce') event.target.classList.remove('appearance-rebound');
  });
})();
