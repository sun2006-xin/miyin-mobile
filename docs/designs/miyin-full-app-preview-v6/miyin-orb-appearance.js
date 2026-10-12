(() => {
  "use strict";

  const prefix = "miyin.full.preview.v6.";
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const palettes = {
    "deep-sea": { name: "深海蓝", a: "#071a2b", b: "#1f6f9c", c: "#7fd4e8", d: "#eafaff", warm: "#d8f8ff", glow: "#68c9df", second: "#cfe6ff" },
    "mint-aurora": { name: "薄荷极光", a: "#073a38", b: "#187f79", c: "#69d5c0", d: "#effff8", warm: "#baffef", glow: "#54cbb4", second: "#baffef" },
    "moon-pearl": { name: "月白珍珠", a: "#536574", b: "#819fad", c: "#d6e9e8", d: "#fffdf6", warm: "#f5ffff", glow: "#9fc7cf", second: "#f5ffff" },
    "aurora-blue": { name: "极光蓝", a: "#182e67", b: "#307fd4", c: "#64dfff", d: "#9280ff", warm: "#ffc36f", glow: "#56d6ff", second: "#a47aff" },
    ice: { name: "冰蓝白", a: "#548ca8", b: "#9bcfe5", c: "#e7fbff", d: "#b3e7ff", warm: "#ffffff", glow: "#9eeaff", second: "#d4f3ff" },
    "violet-life": { name: "紫罗兰生命", a: "#38265f", b: "#8058ca", c: "#c08bff", d: "#ee80da", warm: "#ff9db9", glow: "#a87aff", second: "#f078d7" },
    "aqua-life": { name: "青绿生命", a: "#084753", b: "#129ca2", c: "#6ce8d6", d: "#bdf6dc", warm: "#ddffc6", glow: "#62ebde", second: "#88dcff" },
    "living-aurora": { name: "生命极光", a: "#14245f", b: "#2675bd", c: "#54d7f2", d: "#8b70e7", warm: "#ffb45e", glow: "#58d9ff", second: "#a77aff" }
  };
  const materials = {
    "picked-orb": { name: "我选定的原球体", desc: "保留你确认的深海蓝流体核心" },
    "flow-glass": { name: "深海流光", desc: "动态色流与清透玻璃质感" },
    "miyin-frosted": { name: "雾面晶透", desc: "静态柔雾与浅色折射" },
    toon: { name: "卡通软胶", desc: "静态软胶与清晰轮廓" },
    frosted: { name: "磨砂玻璃", desc: "柔和细雾与淡化边缘" },
    liquid: { name: "液态玻璃", desc: "透明质感与缓慢色带" },
    mist: { name: "云雾光体", desc: "中心发亮，边缘柔和散开" },
    hybrid: { name: "玻璃流体核", desc: "稳定玻璃壳与独立慢流光核" }
  };
  const waves = {
    sine: { name: "正弦波", desc: "柔和规律" },
    layered: { name: "多频波", desc: "多层流动" },
    pulse: { name: "圆角脉冲", desc: "节奏清楚" },
    rose: { name: "花瓣波", desc: "轻盈起伏" },
    voice: { name: "语音流体", desc: "随会话状态增强" }
  };
  const valid = {
    material: Object.keys(materials),
    family: ["v2", "v4"],
    wave: Object.keys(waves),
    palette: Object.keys(palettes)
  };
  const read = (key, fallback) => {
    try {
      const value = localStorage.getItem(prefix + key);
      return value === null ? fallback : JSON.parse(value);
    } catch { return fallback; }
  };
  const write = (key, value) => {
    try { localStorage.setItem(prefix + key, JSON.stringify(value)); } catch { /* local preview only */ }
  };
  const safeValue = (key, fallback, choices) => {
    const value = read(key, fallback);
    return choices.includes(value) ? value : fallback;
  };
  const setPaletteVariables = (element, paletteKey) => {
    if (!element) return;
    const palette = palettes[paletteKey];
    element.dataset.orbPalette = paletteKey;
    Object.entries(palette).forEach(([key, value]) => {
      if (key !== "name") element.style.setProperty("--orb-" + key, value);
    });
  };
  const waveValue = (type, angle, phase = 0) => {
    const first = Math.sin(angle * 4 + phase);
    const second = Math.sin(angle * 7.45 - phase * .72 + 1.3);
    const third = Math.sin(angle * 10.48 + phase * .46 + 2.2);
    const layered = .61 * first + .26 * second + .13 * third;
    if (type === "sine") return first;
    if (type === "pulse") return Math.tanh(first * 2.5) * .8 + Math.sin(angle * 8 + phase * .6) * .2;
    if (type === "rose") return Math.sin(angle * 5 + phase * .35) * .76 + Math.sin(angle * 10 - phase * .2) * .12;
    if (type === "voice") {
      const drift = .55 * Math.sin(angle * 1.6 + phase * .31) + .28 * Math.sin(angle * 3.15 - phase * .25 + 1.2) + .17 * Math.sin(angle * 5.2 + phase * .18 + 2.4);
      return layered * .78 + drift * .22;
    }
    return layered;
  };
  const closedCurve = points => {
    const count = points.length;
    let path = "M " + points[0].x.toFixed(2) + " " + points[0].y.toFixed(2);
    for (let i = 0; i < count; i += 1) {
      const before = points[(i - 1 + count) % count];
      const current = points[i];
      const next = points[(i + 1) % count];
      const after = points[(i + 2) % count];
      path += " C " + (current.x + (next.x - before.x) / 6 * .72).toFixed(2) + " " + (current.y + (next.y - before.y) / 6 * .72).toFixed(2) +
        ", " + (next.x - (after.x - current.x) / 6 * .72).toFixed(2) + " " + (next.y - (after.y - current.y) / 6 * .72).toFixed(2) +
        ", " + next.x.toFixed(2) + " " + next.y.toFixed(2);
    }
    return path + " Z";
  };
  const svgNode = (name, attributes = {}) => {
    const node = document.createElementNS("http://www.w3.org/2000/svg", name);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
    return node;
  };
  const renderWave = (svg, family, wave) => {
    if (!svg) return;
    svg.replaceChildren();
    svg.setAttribute("viewBox", "0 0 100 100");
    svg.setAttribute("aria-hidden", "true");
    svg.dataset.waveFamily = family;
    svg.dataset.wave = wave;
    if (family === "v2") {
      svg.append(svgNode("circle", { class: "orb-wave-halo", cx: 50, cy: 50, r: 39, fill: "none" }));
      const group = svgNode("g", { class: "orb-wave-bars" });
      for (let index = 0; index < 72; index += 1) {
        const angle = index / 72 * Math.PI * 2 - Math.PI / 2;
        const rhythm = .5 + .5 * Math.sin(index * .57 + .25);
        const accent = .5 + .5 * Math.sin(index * .19 - .8);
        const inner = 40.2;
        const outer = inner + 2.5 + rhythm * 3.9 + accent * 1.2;
        group.append(svgNode("line", {
          class: "orb-wave-bar",
          fill: "none",
          x1: 50 + Math.cos(angle) * inner,
          y1: 50 + Math.sin(angle) * inner,
          x2: 50 + Math.cos(angle) * outer,
          y2: 50 + Math.sin(angle) * outer
        }));
      }
      svg.append(group);
      return;
    }
    const points = [];
    for (let index = 0; index < 56; index += 1) {
      const angle = index / 56 * Math.PI * 2 - Math.PI / 2;
      const radius = 41 + waveValue(wave, angle) * 4.6;
      points.push({ x: 50 + Math.cos(angle) * radius, y: 50 + Math.sin(angle) * radius });
    }
    const path = closedCurve(points);
    svg.append(
      svgNode("path", { class: "orb-wave-halo", d: path, fill: "none" }),
      svgNode("path", { class: "orb-wave-line", d: path, fill: "none" }),
      svgNode("path", { class: "orb-wave-highlight", d: path, fill: "none" })
    );
  };
  const ensureWash = renderer => {
    if (!renderer || $(".ai-orb-palette-wash", renderer)) return;
    const wash = document.createElement("span");
    wash.className = "ai-orb-palette-wash";
    wash.setAttribute("aria-hidden", "true");
    renderer.append(wash);
  };
  const ensureLiveWave = (renderer, family, wave) => {
    if (!renderer) return;
    let svg = $(".orb-wave-svg--live", renderer);
    if (!svg) {
      svg = svgNode("svg", { class: "orb-wave-svg orb-wave-svg--live", focusable: "false" });
      renderer.append(svg);
    }
    renderWave(svg, family, wave);
  };
  const announce = message => {
    const status = $("#orb-appearance-status");
    if (status) status.textContent = message;
  };
  const sync = () => {
    const materialKey = safeValue("orb-style", "picked-orb", valid.material);
    const family = safeValue("orb-wave-family", "v2", valid.family);
    const wave = safeValue("orb-wave", "layered", valid.wave);
    const paletteKey = safeValue("orb-palette", "deep-sea", valid.palette);
    const material = materials[materialKey];
    const palette = palettes[paletteKey];
    const familyName = family === "v2" ? "V2 环形声波" : "V4 " + waves[wave].name;
    const combo = familyName + " · " + palette.name;
    const renderer = $("#voice-overlay .ai-orb-renderer");
    const preview = $("#orb-style-current-preview");
    const stage = $("#orb-style-current-stage");
    const summary = $("#orb-style-summary");

    if (renderer) {
      renderer.dataset.orbMaterial = materialKey;
      renderer.dataset.waveFamily = family;
      renderer.dataset.wave = family === "v2" ? "ring" : wave;
      setPaletteVariables(renderer, paletteKey);
      ensureWash(renderer);
      ensureLiveWave(renderer, family, family === "v2" ? "ring" : wave);
    }
    if (preview) {
      preview.dataset.orbMaterial = materialKey;
      setPaletteVariables(preview, paletteKey);
    }
    if (stage) {
      stage.dataset.waveFamily = family;
      stage.dataset.wave = family === "v2" ? "ring" : wave;
      setPaletteVariables(stage, paletteKey);
      const previewWave = $(".orb-wave-svg--preview", stage);
      renderWave(previewWave, family, family === "v2" ? "ring" : wave);
    }
    $$(".orb-style-orb").forEach(orb => setPaletteVariables(orb, paletteKey));
    const name = $("#orb-style-current-name");
    const copy = $("#orb-style-current-copy");
    const comboNode = $("#orb-current-combo");
    if (name) name.textContent = material.name;
    if (copy) copy.textContent = material.desc;
    if (comboNode) comboNode.textContent = combo;
    if (summary) summary.textContent = materialKey === "picked-orb" ? "觅音原款 · " + combo : material.name + " · " + combo;

    $$("[data-orb-style-choice]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.orbStyleChoice === materialKey)));
    $$("[data-orb-wave-family-choice]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.orbWaveFamilyChoice === family)));
    $$("[data-orb-wave-choice]").forEach(button => {
      const choice = button.dataset.orbWaveChoice;
      const selected = choice === "ring" ? family === "v2" : family === "v4" && choice === wave;
      button.setAttribute("aria-pressed", String(selected));
    });
    $$("[data-orb-palette-choice]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.orbPaletteChoice === paletteKey)));
    const v2Options = $("#orb-wave-options-v2");
    const v4Options = $("#orb-wave-options-v4");
    if (v2Options) v2Options.hidden = family !== "v2";
    if (v4Options) v4Options.hidden = family !== "v4";
    $$(".orb-wave-option-art[data-wave-preview]").forEach(art => {
      let svg = $(".orb-wave-svg--option", art);
      if (!svg) {
        svg = svgNode("svg", { class: "orb-wave-svg orb-wave-svg--option", focusable: "false" });
        art.append(svg);
      }
      setPaletteVariables(art, paletteKey);
      const type = art.dataset.wavePreview;
      renderWave(svg, type === "v2" ? "v2" : "v4", type === "v2" ? "ring" : type);
    });
    window.dispatchEvent(new CustomEvent("miyin:orb-appearance-change", {
      detail: { material: materialKey, waveFamily: family, wave: family === "v2" ? "ring" : wave, palette: paletteKey }
    }));
  };
  const persist = (key, value, message) => {
    write(key, value);
    sync();
    if (message) announce(message);
  };

  document.addEventListener("click", event => {
    const familyButton = event.target.closest("[data-orb-wave-family-choice]");
    if (familyButton) {
      const family = familyButton.dataset.orbWaveFamilyChoice;
      if (!valid.family.includes(family)) return;
      persist("orb-wave-family", family, family === "v2" ? "V2 环形声波已应用到 AI 语音球体" : "V4 柔性轮廓已应用到 AI 语音球体");
      return;
    }
    const waveButton = event.target.closest("[data-orb-wave-choice]");
    if (waveButton) {
      const wave = waveButton.dataset.orbWaveChoice;
      if (wave === "ring") {
        persist("orb-wave-family", "v2", "V2 环形声波已应用到 AI 语音球体");
      } else if (valid.wave.includes(wave)) {
        write("orb-wave", wave);
        write("orb-wave-family", "v4");
        sync();
        announce("V4 " + waves[wave].name + "已应用到 AI 语音球体");
      }
      return;
    }
    const paletteButton = event.target.closest("[data-orb-palette-choice]");
    if (paletteButton) {
      const palette = paletteButton.dataset.orbPaletteChoice;
      if (!valid.palette.includes(palette)) return;
      persist("orb-palette", palette, palettes[palette].name + "已应用到 AI 语音球体");
      return;
    }
    if (event.target.closest("[data-orb-appearance-reset]")) {
      write("orb-style", "picked-orb");
      write("orb-wave-family", "v2");
      write("orb-wave", "layered");
      write("orb-palette", "deep-sea");
      sync();
      announce("已恢复觅音原款：V2 环形声波与深海蓝");
      return;
    }
    if (event.target.closest("[data-orb-style-choice]")) {
      window.requestAnimationFrame(sync);
    }
  });

  sync();
})();
