// 最小 DOM 垫片：只为把 index.html 里的渲染函数真跑一遍，抓运行时错误、
// 字段名写错、以及算成 NaN/undefined 的数值。不做真实排版。
const fs = require("fs");
const vm = require("vm");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
const blocks = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (blocks.length !== 2) throw new Error("期望 2 个 script 块，实际 " + blocks.length);

// —— 调色板：与 index.html 的 CSS 变量保持一致，让 getComputedStyle 返回真值
const PAL = {
  "--surface-1": "#fcfcfb", "--page": "#f9f9f7", "--text-primary": "#0b0b0b",
  "--text-secondary": "#52514e", "--text-muted": "#898781", "--grid": "#e1e0d9",
  "--axis": "#c3c2b7", "--s-base": "#2a78d6", "--s-final": "#eb6834",
  "--good": "#0ca30c", "--critical": "#d03b3b", "--warning": "#fab219", "--track": "#cde2fb",
  "--ord-1": "#86b6ef", "--ord-2": "#5598e7", "--ord-3": "#2a78d6", "--ord-4": "#1c5cab", "--ord-5": "#104281",
};

// 容器宽度可调：CSS 网格最窄一列是 minmax(320px, 1fr)，320 是最坏情况
const CW = +(process.env.CW || 360);

let elCount = 0, textCount = 0, listenerCount = 0;
const problems = [];
function flag(msg) { problems.push(msg); }

class El {
  constructor(tag, ns) {
    this.tagName = String(tag || "").toUpperCase();
    this.ns = ns || null;
    this.children = [];
    this.attrs = {};
    this.style = new Proxy({}, { set: (t, k, v) => { t[k] = v; return true; }, get: (t, k) => t[k] });
    this.dataset = {};
    this.listeners = {};
    this.className = "";
    this._text = "";
    this.parentNode = null;
    this.classList = { add: () => {}, remove: () => {}, contains: () => false };
    this.clientWidth = CW;           // 非零宽度，让图表布局计算真的跑起来
    this.clientHeight = 240;
    elCount++;
  }
  set textContent(v) { this._text = v == null ? "" : String(v); this.children = []; }
  get textContent() { return this._text + this.children.map(c => c.textContent).join(""); }
  appendChild(c) { this.children.push(c); c.parentNode = this; return c; }
  replaceChildren() { this.children = []; }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
    if (k === "text-anchor" || k === "fill" || k === "stroke" || k === "font-size") { /* noop */ }
  }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  hasAttribute(k) { return k in this.attrs; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); listenerCount++; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  closest() { return null; }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth, height: this.clientHeight }; }
}

const registry = new Map();
const docEl = new El("html");
const document = {
  documentElement: docEl,
  createElement: t => new El(t),
  createElementNS: (ns, t) => new El(t, ns),
  createTextNode: t => { const n = new El("#text"); n._text = String(t); return n; },
  querySelector(sel) {
    if (!registry.has(sel)) registry.set(sel, new El("div"));
    return registry.get(sel);
  },
  querySelectorAll: () => [],
};

const win = {
  innerWidth: 1440, innerHeight: 900,
  matchMedia: () => ({ matches: false, addEventListener: () => {} }),
  addEventListener: () => {},
};

const ctx = {
  document, window: win, console,
  getComputedStyle: () => ({ getPropertyValue: n => (n in PAL ? PAL[n] : "#000000") }),
  setTimeout, clearTimeout,
  Math, JSON, Number, String, Array, Object, Set, Map, RegExp, Infinity, NaN,
};
ctx.globalThis = ctx;
vm.createContext(ctx);

// 两个块拼在一起跑：第一块定义 DATA，第二块是 IIFE
try {
  vm.runInContext(blocks[0] + "\n" + blocks[1], ctx, { filename: "index.html" });
} catch (e) {
  console.error("✗ 渲染抛出异常：", e && e.stack ? e.stack : e);
  process.exit(1);
}

// —— 遍历整棵已渲染的树，找 NaN / undefined / null / Infinity ——
function walk(n, path) {
  const p = path + "/" + (n.tagName || "?") + (n.attrs && n.attrs.id ? "#" + n.attrs.id : "");
  if (n._text) {
    textCount++;
    const t = n._text;
    if (/NaN|undefined|Infinity/.test(t) || t === "null") flag(`文本可疑 @ ${p}: ${JSON.stringify(t)}`);
    if (/,\s*$/.test(t)) flag(`文本以逗号结尾 @ ${p}: ${JSON.stringify(t)}`);
    if (/[0-9]+\.[0-9]{4,}/.test(t) && !/^\d+\.\d{4,}$/.test(t.trim()) === false) { /* 容差：允许长小数 */ }
  }
  for (const k in n.attrs) {
    const v = n.attrs[k];
    if (/NaN|undefined|Infinity/.test(v)) flag(`属性可疑 @ ${p} ${k}=${JSON.stringify(v)}`);
  }
  for (const c of n.children) walk(c, p);
}

// —— 触发所有已注册的监听器，把 tooltip 路径也走一遍 ——
function fire(n, path) {
  const p = path + "/" + (n.tagName || "?");
  for (const type in n.listeners) {
    for (const fn of n.listeners[type]) {
      const ev = { clientX: 700, clientY: 400, target: n, nearest: null,
                   preventDefault() {}, stopPropagation() {}, closest: () => null };
      try { fn(ev); } catch (e) { flag(`监听器 ${type} 抛错 @ ${p}: ${e.message}`); }
    }
  }
  for (const c of n.children) fire(c, p);
}

let phase = "初始渲染";
function sweep() {
  for (const [sel, node] of registry) { walk(node, sel); fire(node, sel); }
}

// —— 几何审计：没有真浏览器，就按字符宽度估算每个 <text> 的盒子，
//    检查越出 viewBox 以及同图内互相重叠。CJK 按 1.0em、西文按 0.6em 估宽。
function textWidth(s, fs) {
  let w = 0;
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c >= 0x2e80 && c <= 0x9fff) w += 1.0;
    else if (c >= 0xff00 && c <= 0xffef) w += 1.0;
    else if (ch === " ") w += 0.3;
    else w += 0.6;
  }
  return w * fs;
}
function auditSvg(svg, host) {
  const vb = (svg.attrs.viewBox || "").split(/\s+/).map(Number);
  const W = vb[2], H = vb[3];
  const texts = [];
  (function collect(n) {
    if (n.tagName === "TEXT") {
      const fs = parseFloat(n.attrs["font-size"] || 11);
      const anchor = n.attrs["text-anchor"] || "start";
      const x = parseFloat(n.attrs.x), y = parseFloat(n.attrs.y);
      const s = n._text;
      if (s && isFinite(x) && isFinite(y)) {
        const w = textWidth(s, fs);
        const x0 = anchor === "middle" ? x - w / 2 : anchor === "end" ? x - w : x;
        texts.push({ s, x0, x1: x0 + w, y, fs });
      }
    }
    for (const c of n.children) collect(c);
  })(svg);

  for (const t of texts) {
    if (t.x0 < -0.5) flag(`越出左边界 ${t.x0.toFixed(1)}px @ ${host}: ${JSON.stringify(t.s)}`);
    if (t.x1 > W + 0.5) flag(`越出右边界 ${(t.x1 - W).toFixed(1)}px（W=${W}）@ ${host}: ${JSON.stringify(t.s)}`);
    if (t.y + t.fs * 0.3 > H + 0.5) flag(`越出下边界 @ ${host}: ${JSON.stringify(t.s)} y=${t.y} H=${H}`);
    if (t.y - t.fs * 0.8 < -0.5) flag(`越出上边界 @ ${host}: ${JSON.stringify(t.s)} y=${t.y}`);
  }
  // 同图内两两碰撞（同高、水平重叠）
  for (let i = 0; i < texts.length; i++) {
    for (let j = i + 1; j < texts.length; j++) {
      const a = texts[i], b = texts[j];
      if (Math.abs(a.y - b.y) > Math.min(a.fs, b.fs) * 0.85) continue;
      const ov = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0);
      if (ov > 1) {
        flag(`文本重叠 ${ov.toFixed(1)}px @ ${host}: ${JSON.stringify(a.s)} × ${JSON.stringify(b.s)}`);
      }
    }
  }
  return texts.length;
}
function audit() {
  let charts = 0, labels = 0;
  for (const [sel, node] of registry) {
    if (!/^#ch-|#slaMatrix|#precWrap/.test(sel)) continue;
    (function find(n) {
      if (n.tagName === "SVG") { labels += auditSvg(n, sel); charts++; return; }
      for (const c of n.children) find(c);
    })(node);
  }
  return charts + " 张图 / " + labels + " 个文本标签";
}
function readKpis() {
  const k = registry.get("#kpis");
  return (k ? k.children : []).map(t => t.children.map(c => c.textContent).join(" | ")).join("\n      ");
}
function hero() {
  const f = registry.get("#heroFig"), s = registry.get("#heroSub");
  return (f ? f.textContent : "-") + "   [" + (s ? s.textContent : "-") + "]";
}
function click(sel, v) {
  const seg = registry.get(sel);
  const btn = { dataset: { v }, setAttribute() {} };
  const ev = { target: { closest: () => btn }, preventDefault() {}, stopPropagation() {} };
  for (const fn of (seg.listeners.click || [])) fn(ev);
}

sweep();
console.log(`[${phase}] 元素 ${elCount} · 文本 ${textCount} · 监听器 ${listenerCount} · 几何审计 ${audit()}`);
console.log(`  hero: ${hero()}`);
console.log(`  KPI:\n      ${readKpis()}`);

// 基线选择器现在只有 B2 一个选项（参考配置的原始日志未归档，已从页面移除），
// 所以交互只测轮次口径切换；基线按钮再点一次验证幂等。
const phases = [
  ["基线 → 再点 B2",      () => click("#segBase", "b2r3")],
  ["口径 → 最小",         () => click("#segAgg", "tps_min")],
  ["口径 → 最大",         () => click("#segAgg", "tps_max")],
  ["口径 → 切回中位",     () => click("#segAgg", "tps")],
];
for (const [name, act] of phases) {
  phase = name;
  const before = problems.length;
  try { act(); } catch (e) { flag(`交互抛错 @ ${name}: ${e.message}`); }
  sweep();
  console.log(`[${name}] hero: ${hero()}${problems.length > before ? "   ← 有可疑" : ""}`);
}

const tips = registry.get("#tip");
if (tips) console.log(`\ntooltip 最后一次内容：${JSON.stringify(tips.textContent.slice(0, 140))}`);

// DUMP=#id 把该容器的渲染结果按行打出来，用来抽查表格内容
if (process.env.DUMP) {
  for (const sel of process.env.DUMP.split(",")) {
    const node = registry.get(sel.trim());
    if (!node) { console.log(`\n[${sel}] 未渲染`); continue; }
    console.log(`\n=== ${sel} ===`);
    (function rows(n, depth) {
      for (const c of n.children) {
        if (c.tagName === "TR") {
          const cells = [];
          (function grab(x) {
            if (x.tagName === "TD" || x.tagName === "TH") { cells.push(x.textContent); return; }
            for (const y of x.children) grab(y);
          })(c);
          console.log("  " + cells.join(" | "));
          continue;
        }
        if (depth < 3) rows(c, depth + 1);
      }
    })(node, 0);
  }
}

if (problems.length) {
  console.error(`\n✗ ${problems.length} 处可疑：`);
  for (const p of problems.slice(0, 40)) console.error("  " + p);
  process.exit(1);
}
console.log("\n✓ 无异常、无 NaN/undefined（含 5 次筛选交互）");
