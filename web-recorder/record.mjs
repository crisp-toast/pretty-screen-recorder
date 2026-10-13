// Pretty Studio web recorder.
// Drives the installed Google Chrome (headless) through a storyboard, captures frames with the
// CDP screencast (~60 fps at Retina scale), and logs cursor / click / key / scroll telemetry so
// the renderer can draw a beautiful synthetic cursor, ripples, keystrokes and Smart Zooms.
//
//   node record.mjs <storyboard.json> <outDir>
//
// Writes outDir/screen.mp4, outDir/events.json, outDir/meta.json. Prints meta JSON on stdout.

import { chromium } from 'playwright-core';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const [, , storyboardPath, outDirArg] = process.argv;
if (!storyboardPath || !outDirArg) {
  console.error('usage: node record.mjs <storyboard.json> <outDir>');
  process.exit(64);
}
const sb = JSON.parse(fs.readFileSync(storyboardPath, 'utf8'));
const outDir = path.resolve(outDirArg);
const framesDir = path.join(outDir, 'frames');
fs.mkdirSync(framesDir, { recursive: true });

// ---------- devices ----------
const UA_IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const UA_IPAD = 'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const UA_ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const DEVICES = {
  desktop: { viewport: { width: 1440, height: 900 }, scale: 2, kind: 'web' },
  laptop: { viewport: { width: 1280, height: 800 }, scale: 2, kind: 'web' },
  wide: { viewport: { width: 1680, height: 945 }, scale: 2, kind: 'web' },
  // iPhone 16/17 Pro: 402x874pt screen. The frame draws the status bar (54pt) and Safari bar (82pt).
  iphone: { viewport: { width: 402, height: 874 - 54 - 82 }, scale: 3, kind: 'mobile-web', mobile: true, ua: UA_IPHONE },
  'iphone-max': { viewport: { width: 440, height: 956 - 54 - 82 }, scale: 3, kind: 'mobile-web', mobile: true, ua: UA_IPHONE },
  ipad: { viewport: { width: 1032, height: 1376 }, scale: 2, kind: 'ios', mobile: true, ua: UA_IPAD },
  android: { viewport: { width: 412, height: 915 }, scale: 2.625, kind: 'android', mobile: true, ua: UA_ANDROID },
};
const dev = { ...(DEVICES[sb.device ?? 'desktop'] ?? DEVICES.desktop) };
if (sb.viewport) dev.viewport = { ...dev.viewport, ...sb.viewport };
if (sb.scale) dev.scale = sb.scale;
const DPR = dev.scale;
const VW = dev.viewport.width, VH = dev.viewport.height;
const PX_W = Math.round(VW * DPR), PX_H = Math.round(VH * DPR);
const touch = !!dev.mobile;

// ---------- helpers ----------
const now = () => Date.now() / 1000;
const sleep = (s) => new Promise((r) => setTimeout(r, Math.max(0, s * 1000)));
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const smootherstep = (t) => { const x = clamp(t, 0, 1); return x * x * x * (x * (x * 6 - 15) + 10); };
const easeInOut = (t) => { const x = clamp(t, 0, 1); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
const rand = (a, b) => a + Math.random() * (b - a);
const speed = sb.speed ?? 1; // global pacing multiplier (>1 = slower, more deliberate)

const events = { version: 1, width: PX_W, height: PX_H, pointScale: DPR, mouse: [], clicks: [], keys: [], scrolls: [], cursors: [], markers: [] };
const frames = [];
let pending = [];
let mouse = { x: (sb.cursorStart?.x ?? 0.62) * VW, y: (sb.cursorStart?.y ?? 0.7) * VH };
let lastCursorKind = null;

function logMouse(x, y) { events.mouse.push([now(), +(x * DPR).toFixed(1), +(y * DPR).toFixed(1)]); }

// ---------- browser ----------
const browser = await chromium.launch({
  channel: sb.channel ?? 'chrome',
  headless: sb.headless ?? true,
  args: ['--hide-scrollbars', '--disable-features=Translate', '--force-color-profile=srgb', '--font-render-hinting=none'],
});
const context = await browser.newContext({
  viewport: dev.viewport,
  deviceScaleFactor: DPR,
  isMobile: !!dev.mobile,
  hasTouch: touch,
  userAgent: sb.userAgent ?? dev.ua,
  colorScheme: sb.colorScheme ?? 'light',
  locale: sb.locale ?? 'en-US',
  timezoneId: sb.timezone ?? 'America/Los_Angeles',
  reducedMotion: 'no-preference',
});
if (sb.cookies) await context.addCookies(sb.cookies);
const page = await context.newPage();
if (sb.init) await page.addInitScript(sb.init);
if (sb.localStorage) {
  await page.addInitScript((kv) => { for (const [k, v] of Object.entries(kv)) localStorage.setItem(k, typeof v === 'string' ? v : JSON.stringify(v)); }, sb.localStorage);
}
const waitUntil = sb.waitUntil ?? 'load';
// Bare paths are relative to the storyboard file.
const resolveURL = (u) => (!u || /^[a-z][a-z0-9+.-]*:/i.test(u)) ? u : pathToFileURL(path.resolve(path.dirname(path.resolve(storyboardPath)), u)).href;
sb.url = resolveURL(sb.url);
if (sb.url) await page.goto(sb.url, { waitUntil, timeout: 60000 });
else if (sb.html) await page.setContent(sb.html, { waitUntil });
async function injectCSS() {
  // Hide scrollbars/caret blink jitter, plus any storyboard CSS (e.g. hide cookie banners).
  const css = `${sb.css ?? ''}\n::-webkit-scrollbar{display:none}\n*{-webkit-tap-highlight-color:transparent!important}`;
  await page.addStyleTag({ content: css }).catch(() => {});
}
await injectCSS();
page.on('load', () => { injectCSS(); });
await sleep(sb.settle ?? 0.6);

// ---------- capture ----------
const cdp = await context.newCDPSession(page);
let firstFrameResolve;
const firstFrame = new Promise((r) => (firstFrameResolve = r));
cdp.on('Page.screencastFrame', (f) => {
  cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {});
  const i = frames.length;
  const file = `f_${String(i).padStart(6, '0')}.jpg`;
  frames.push({ t: f.metadata.timestamp ?? now(), file });
  pending.push(fs.promises.writeFile(path.join(framesDir, file), Buffer.from(f.data, 'base64')));
  if (i === 0) firstFrameResolve();
});
await cdp.send('Page.startScreencast', { format: 'jpeg', quality: sb.jpegQuality ?? 92, maxWidth: PX_W, maxHeight: PX_H, everyNthFrame: 1 });
// Nudge a repaint so the first frame arrives even on a static page.
await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => { document.body && (document.body.style.outline = '0px solid transparent'); requestAnimationFrame(r); })));
await Promise.race([firstFrame, sleep(3)]);
logMouse(mouse.x, mouse.y);
await sleep((sb.leadIn ?? 0.8) * speed);

// ---------- cursor kind ----------
async function updateCursorKind() {
  if (touch) return;
  const k = await page.evaluate(({ x, y }) => {
    const el = document.elementFromPoint(x, y);
    if (!el) return 'arrow';
    let c = getComputedStyle(el).cursor;
    if (c && c !== 'auto' && c !== 'default') return c;
    if (c === 'default') return 'arrow';
    const tag = el.tagName;
    if ((tag === 'INPUT' && !['button', 'submit', 'checkbox', 'radio', 'range', 'color', 'file', 'image', 'reset'].includes(el.type)) || tag === 'TEXTAREA' || el.isContentEditable) return 'text';
    if (el.closest('a[href]')) return 'pointer';
    const r = document.caretRangeFromPoint?.(x, y);
    if (r && r.startContainer?.nodeType === 3) {
      const range = document.createRange(); range.selectNodeContents(r.startContainer);
      for (const rect of range.getClientRects()) if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return 'text';
    }
    return 'arrow';
  }, mouse).catch(() => 'arrow');
  if (k !== lastCursorKind) { events.cursors.push({ t: now(), kind: k }); lastCursorKind = k; }
}

// ---------- targeting ----------
async function locate(target) {
  if (target && typeof target === 'object' && 'x' in target && 'y' in target) {
    const nx = target.x <= 1 ? target.x * VW : target.x, ny = target.y <= 1 ? target.y * VH : target.y;
    return { x: nx, y: ny, box: { x: nx - 1, y: ny - 1, width: 2, height: 2 } };
  }
  const sel = typeof target === 'string' ? target : target.selector;
  const loc = page.locator(sel).first();
  await loc.waitFor({ state: 'visible', timeout: (target.timeout ?? sb.timeout ?? 10) * 1000 });
  let box = await loc.boundingBox();
  if (!box) throw new Error(`no box for ${sel}`);
  // Bring it into view with a natural scroll if needed.
  const margin = VH * 0.12;
  if (box.y < margin || box.y + box.height > VH - margin) {
    const dy = box.y - VH * 0.32;
    await smoothScroll(dy, clamp(Math.abs(dy) / 1400, 0.5, 1.4));
    await sleep(0.25);
    box = await loc.boundingBox();
  }
  const off = target.offset ?? [0.5, 0.5];
  const jx = target.offset ? 0 : rand(-1, 1) * Math.min(4, box.width / 8);
  const jy = target.offset ? 0 : rand(-1, 1) * Math.min(3, box.height / 8);
  return { x: box.x + box.width * off[0] + jx, y: box.y + box.height * off[1] + jy, box, sel };
}

function normRect(box, pad = 0) {
  return { x: +((box.x - pad) / VW).toFixed(4), y: +((box.y - pad) / VH).toFixed(4), w: +((box.width + pad * 2) / VW).toFixed(4), h: +((box.height + pad * 2) / VH).toFixed(4) };
}

// ---------- motion ----------
async function moveTo(x, y, dur) {
  const from = { ...mouse };
  const d = Math.hypot(x - from.x, y - from.y);
  if (touch) { mouse = { x, y }; return; }
  if (d < 1) return;
  const T = (dur ?? clamp(0.24 + 0.17 * Math.log2(1 + d / 45), 0.3, 0.95)) * speed;
  const bow = Math.min(0.08 * d, 60) * (x >= from.x ? -1 : 1);
  const dx = (x - from.x) / d, dy = (y - from.y) / d;
  const c1 = { x: from.x + (x - from.x) * 0.3 - dy * bow, y: from.y + (y - from.y) * 0.3 + dx * bow };
  const c2 = { x: from.x + (x - from.x) * 0.72 - dy * bow * 0.6, y: from.y + (y - from.y) * 0.72 + dx * bow * 0.6 };
  const start = now();
  let steps = 0;
  for (;;) {
    const t = Math.min(1, (now() - start) / T);
    const u = smootherstep(Math.pow(t, 0.9)), a = 1 - u;
    const px = a * a * a * from.x + 3 * a * a * u * c1.x + 3 * a * u * u * c2.x + u * u * u * x;
    const py = a * a * a * from.y + 3 * a * a * u * c1.y + 3 * a * u * u * c2.y + u * u * u * y;
    await page.mouse.move(px, py);
    mouse = { x: px, y: py };
    logMouse(px, py);
    if (++steps % 12 === 0) await updateCursorKind();
    if (t >= 1) break;
    await sleep(0.008);
  }
  await updateCursorKind();
}

async function click(target, opts = {}) {
  const p = await locate(target);
  await moveTo(p.x, p.y);
  await sleep(rand(0.08, 0.16) * speed);
  const t = now();
  if (touch) {
    logMouse(p.x, p.y);
    await page.touchscreen.tap(p.x, p.y);
    events.clicks.push({ t, x: +(p.x * DPR).toFixed(1), y: +(p.y * DPR).toFixed(1), up: now() + 0.06, button: 'left', touch: true });
  } else {
    await page.mouse.down({ button: opts.button ?? 'left', clickCount: 1 });
    await sleep(0.07);
    await page.mouse.up({ button: opts.button ?? 'left', clickCount: 1 });
    events.clicks.push({ t, x: +(p.x * DPR).toFixed(1), y: +(p.y * DPR).toFixed(1), up: now(), button: opts.button ?? 'left', touch: false });
    if (opts.double) {
      await sleep(0.06);
      const t2 = now();
      await page.mouse.down(); await sleep(0.05); await page.mouse.up({ clickCount: 2 });
      events.clicks.push({ t: t2, x: +(p.x * DPR).toFixed(1), y: +(p.y * DPR).toFixed(1), up: now(), button: 'left' });
    }
  }
  return p;
}

async function smoothScroll(dy, dur = 1.0, dx = 0) {
  const T = dur * speed;
  const start = now();
  let done = 0, doneX = 0;
  events.scrolls.push({ t: start, dx, dy, x: +(mouse.x * DPR).toFixed(1), y: +(mouse.y * DPR).toFixed(1) });
  if (touch) {
    // Finger swipe: page scroll via JS with easing (touch drags are unreliable headless).
    for (;;) {
      const t = Math.min(1, (now() - start) / T);
      const target = dy * easeInOut(t), targetX = dx * easeInOut(t);
      await page.evaluate(([a, b]) => window.scrollBy(b, a), [target - done, targetX - doneX]);
      done = target; doneX = targetX;
      if (t >= 1) break;
      await sleep(0.012);
    }
    return;
  }
  for (;;) {
    const t = Math.min(1, (now() - start) / T);
    const target = dy * easeInOut(t), targetX = dx * easeInOut(t);
    const step = target - done, stepX = targetX - doneX;
    if (Math.abs(step) >= 0.5 || Math.abs(stepX) >= 0.5) {
      await page.mouse.wheel(stepX, step);
      done = target; doneX = targetX;
    }
    if (t >= 1) break;
    await sleep(0.012);
  }
}

function parseCombo(combo) {
  const parts = combo.split('+');
  const key = parts.pop();
  const map = { meta: 'cmd', cmd: 'cmd', command: 'cmd', control: 'ctrl', ctrl: 'ctrl', alt: 'opt', option: 'opt', opt: 'opt', shift: 'shift' };
  const mods = parts.map((m) => map[m.toLowerCase()] ?? m.toLowerCase());
  const pwKey = (k) => ({ cmd: 'Meta', ctrl: 'Control', opt: 'Alt', shift: 'Shift' }[k]);
  const keyName = key.length === 1 ? key : key.replace(/^Arrow/, '').toLowerCase();
  return { mods, key: keyName, playwright: [...mods.map(pwKey), key].join('+') };
}

async function typeText(text, delay) {
  for (const ch of text) {
    const t = now();
    if (ch === '\n') { await page.keyboard.press('Enter'); events.keys.push({ t, key: 'return', mods: [] }); }
    else {
      await page.keyboard.type(ch);
      const upper = ch.length === 1 && ch !== ch.toLowerCase();
      events.keys.push({ t, key: ch === ' ' ? 'space' : ch, mods: upper ? ['shift'] : [] });
    }
    const base = delay ?? 0.065;
    await sleep((base + rand(-0.025, 0.045) + (ch === ' ' ? 0.03 : 0)) * speed);
  }
}

// ---------- steps ----------
const marker = (m) => events.markers.push({ t: now(), ...m });
// Markers don't pause the script unless asked: "hold": true waits the marker's duration, a number waits that many seconds.
const holdFor = async (o, duration) => { const h = o.hold === true ? duration : (typeof o.hold === 'number' ? o.hold : 0); if (h > 0) await sleep(h * speed); };

async function runStep(step) {
  const [kind] = Object.keys(step).filter((k) => !['optional', 'after', 'note'].includes(k));
  const v = step[kind];
  switch (kind) {
    case 'wait': case 'pause': await sleep((typeof v === 'number' ? v : 1) * speed); break;
    case 'goto': await page.goto(resolveURL(v), { waitUntil, timeout: 60000 }); await sleep(0.4); break;
    case 'waitFor': await page.locator(typeof v === 'string' ? v : v.selector).first().waitFor({ state: 'visible', timeout: 15000 }); break;
    case 'move': case 'hover': { const p = await locate(v); await moveTo(p.x, p.y, v.duration); await sleep(0.35 * speed); break; }
    case 'click': await click(v, typeof v === 'object' ? v : {}); await sleep((step.after ?? 0.55) * speed); break;
    case 'doubleClick': await click(v, { ...(typeof v === 'object' ? v : {}), double: true }); await sleep((step.after ?? 0.55) * speed); break;
    case 'rightClick': await click(v, { button: 'right' }); await sleep((step.after ?? 0.55) * speed); break;
    case 'type': {
      const o = typeof v === 'string' ? { text: v } : v;
      if (o.selector) { await click(o.selector); await sleep(0.25 * speed); }
      if (o.clear) { await page.keyboard.press('Meta+A'); await page.keyboard.press('Backspace'); }
      await typeText(o.text, o.delay);
      await sleep((step.after ?? 0.4) * speed);
      break;
    }
    case 'press': {
      const c = parseCombo(v);
      events.keys.push({ t: now(), key: c.key, mods: c.mods });
      await page.keyboard.press(c.playwright);
      await sleep((step.after ?? 0.5) * speed);
      break;
    }
    case 'scroll': {
      if (typeof v === 'string' || v.selector) {
        const loc = page.locator(typeof v === 'string' ? v : v.selector).first();
        await loc.waitFor({ state: 'attached', timeout: 10000 });
        const box = await loc.boundingBox();
        const dy = (box?.y ?? 0) - VH * (v.align ?? 0.18);
        await smoothScroll(dy, v.duration ?? clamp(Math.abs(dy) / 1200, 0.6, 1.8));
      } else {
        await smoothScroll(v.y ?? 0, v.duration ?? clamp(Math.abs(v.y ?? 0) / 1000, 0.5, 2), v.x ?? 0);
      }
      await sleep((step.after ?? 0.5) * speed);
      break;
    }
    case 'drag': {
      const a = await locate(v.from), b = await locate(v.to);
      await moveTo(a.x, a.y); await sleep(0.12);
      const t = now();
      await page.mouse.down();
      await moveTo(b.x, b.y, v.duration ?? 0.9);
      await sleep(0.1);
      await page.mouse.up();
      events.clicks.push({ t, x: +(a.x * DPR).toFixed(1), y: +(a.y * DPR).toFixed(1), up: now(), button: 'left' });
      await sleep(0.4 * speed);
      break;
    }
    case 'select': await page.locator(v.selector).first().selectOption(v.value); await sleep(0.5 * speed); break;
    case 'eval': await page.evaluate(v); break;
    case 'css': await page.addStyleTag({ content: v }); break;
    case 'zoom': {
      // Agent-directed Smart Zoom: frame a target (or the cursor) for `duration` seconds.
      const o = typeof v === 'string' ? { target: v } : v;
      const m = { type: 'zoom', duration: o.duration ?? 2.5 };
      if (o.level) m.level = o.level;
      if (o.target) { const p = await locate(o.target); m.rect = normRect(p.box, o.pad ?? 24); }
      else if (o.rect) m.rect = o.rect;
      marker(m);
      await holdFor(o, m.duration);
      break;
    }
    case 'spotlight': case 'highlight': {
      const o = typeof v === 'string' ? { target: v } : v;
      const p = await locate(o.target);
      marker({ type: kind, duration: o.duration ?? 2, rect: normRect(p.box, o.pad ?? 10) });
      await holdFor(o, o.duration ?? 2);
      break;
    }
    case 'caption': case 'title': {
      const o = typeof v === 'string' ? { text: v } : v;
      marker({ type: kind, duration: o.duration ?? 2.5, text: o.text });
      await holdFor(o, o.duration ?? 2.5);
      break;
    }
    default: throw new Error(`unknown step "${kind}"`);
  }
}

const errors = [];
let hardFail = false;
for (const [i, step] of (sb.steps ?? []).entries()) {
  try { await runStep(step); }
  catch (e) {
    const msg = `step ${i} (${JSON.stringify(step).slice(0, 120)}): ${e.message.split('\n')[0]}`;
    errors.push(msg);
    if (step.optional) continue;
    console.error(msg);
    hardFail = true;
    if (!sb.continueOnError) break;
  }
}
await sleep((sb.tailOut ?? 1.2) * speed);
const endT = now();
await cdp.send('Page.stopScreencast').catch(() => {});
await Promise.all(pending);
const finalURL = page.url();
await browser.close();

if (frames.length === 0) { console.error('no frames captured'); process.exit(2); }

// ---------- assemble ----------
const t0 = frames[0].t;
const rebase = (t) => +(t - t0).toFixed(4);
events.mouse = events.mouse.map(([t, x, y]) => [Math.max(0, rebase(t)), x, y]);
for (const c of events.clicks) { c.t = rebase(c.t); c.up = rebase(c.up); }
for (const k of events.keys) k.t = rebase(k.t);
for (const s of events.scrolls) s.t = rebase(s.t);
for (const c of events.cursors) c.t = Math.max(0, rebase(c.t));
for (const m of events.markers) m.t = rebase(m.t);

const list = frames.map((f, i) => {
  const next = i + 1 < frames.length ? frames[i + 1].t : endT;
  return `file '${path.join(framesDir, f.file).replace(/'/g, "'\\''")}'\nduration ${Math.max(0.001, next - f.t).toFixed(6)}`;
});
list.push(`file '${path.join(framesDir, frames[frames.length - 1].file).replace(/'/g, "'\\''")}'`);
fs.writeFileSync(path.join(outDir, 'frames.txt'), list.join('\n') + '\n');
const fps = sb.fps ?? 60;
const video = path.join(outDir, 'screen.mp4');
const ff = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', path.join(outDir, 'frames.txt'),
  '-vf', `scale=${PX_W}:${PX_H}:flags=lanczos,format=yuv420p`, '-fps_mode', 'cfr', '-r', String(fps),
  '-c:v', 'libx264', '-preset', 'faster', '-crf', String(sb.crf ?? 12), '-tune', 'animation', '-movflags', '+faststart', video], { stdio: ['ignore', 'inherit', 'inherit'] });
if (ff.status !== 0) { console.error('ffmpeg failed'); process.exit(3); }
fs.writeFileSync(path.join(outDir, 'events.json'), JSON.stringify(events));
if (!sb.keepFrames) fs.rmSync(framesDir, { recursive: true, force: true });
fs.rmSync(path.join(outDir, 'frames.txt'), { force: true });

const meta = {
  video, events: path.join(outDir, 'events.json'), kind: dev.kind, device: sb.device ?? 'desktop', url: sb.url ?? finalURL,
  viewport: dev.viewport, scale: DPR, width: PX_W, height: PX_H, frames: frames.length,
  duration: +(endT - t0).toFixed(3), capturedFps: +(frames.length / Math.max(0.001, endT - t0)).toFixed(1),
  clicks: events.clicks.length, keys: events.keys.length, markers: events.markers.length, errors,
};
fs.writeFileSync(path.join(outDir, 'meta.json'), JSON.stringify(meta, null, 2));
console.log(JSON.stringify(meta));
// Exit 4 when a required step failed (the partial recording is still written).
process.exit(hardFail ? 4 : 0);
