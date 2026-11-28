#!/usr/bin/env node
// Runs one viewer check (jolt | jolt_worker | gpu) in headless Chromium and prints {ok, detail}.
// usage: node tools/web_check.mjs <check> [--expect=<native-output.json>] [--port=8765]
// Needs `playwright` resolvable (npm i -g playwright@<pin>, or PLAYWRIGHT_MODULE=<path to its index.mjs>).
import { spawn, execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const check = process.argv[2];
const opt = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) || '').slice(k.length + 3) || d;
const port = Number(opt('port', '8765'));
const expectFile = opt('expect', '');
if (!check || check.startsWith('--')) {
  console.error('usage: web_check.mjs <check> [--expect=file] [--port=n]');
  process.exit(2);
}

async function loadPlaywright() {
  const path = process.env.PLAYWRIGHT_MODULE;
  if (path) return import(path);
  try {
    return await import('playwright');
  } catch {
    const root = execSync('npm root -g').toString().trim();
    const req = (await import('node:module')).createRequire(`${root}/noop.js`);
    return req(req.resolve('playwright', { paths: [root] }));
  }
}

const server = spawn('python3', ['tools/bench_collector.py', 'build/viewer', String(port), 'build/bench-results'], { stdio: 'ignore' });
let result = { ok: false, detail: 'did not finish' };
let exitCode = 1;
try {
  const { chromium } = await loadPlaywright();
  for (let i = 0; ; i++) {
    try { await fetch(`http://localhost:${port}/`); break; } catch { if (i > 50) throw new Error('server did not start'); await new Promise((r) => setTimeout(r, 100)); }
  }
  const browser = await chromium.launch({
    args: ['--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader', '--enable-features=Vulkan'],
  });
  const page = await browser.newPage();
  page.on('console', (m) => console.error(`[page] ${m.text()}`));
  page.on('pageerror', (e) => console.error(`[pageerror] ${e}`));
  await page.goto(`http://localhost:${port}/?check=${check}`);
  await page.waitForFunction(() => window.__check, null, { timeout: 120000 });
  result = await page.evaluate(() => window.__check);
  await browser.close();
  if (result.ok && expectFile) {
    const want = JSON.parse(readFileSync(expectFile, 'utf8'));
    if (want.detail !== result.detail) result = { ok: false, detail: `differs from ${expectFile}\n${result.detail}` };
  }
  exitCode = result.ok ? 0 : 1;
} catch (e) {
  result = { ok: false, detail: String(e) };
} finally {
  server.kill();
}
console.log(JSON.stringify(result));
process.exit(exitCode);
