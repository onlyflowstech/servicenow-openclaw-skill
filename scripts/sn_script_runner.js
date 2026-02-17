#!/usr/bin/env node
/**
 * sn_script_runner.js — Execute ServiceNow background scripts via Playwright
 *
 * Automates the sys.scripts.do page using a headless Chromium browser because
 * that page requires full browser rendering (JS execution, cookies, CSRF, etc.)
 * and returns empty responses via plain HTTP/curl.
 *
 * Environment variables:
 *   SN_INSTANCE      — instance hostname (no https://)
 *   SN_USER          — username
 *   SN_PASSWORD       — password
 *   SN_SCRIPT        — JavaScript code to execute (inline)
 *   SN_SCRIPT_FILE   — path to file containing the script (alternative)
 *   SN_TIMEOUT       — timeout in ms (default 30000)
 *   SN_SCOPE         — application scope (default: global)
 *
 * Output: script output on stdout, status/debug on stderr.
 * Exit codes: 0 = success, 1 = error
 */

const { chromium } = require('playwright');
const fs = require('fs');

// ── Helpers ──────────────────────────────────────────────────────────

function log(msg) {
  process.stderr.write(`[sn_script_runner] ${msg}\n`);
}

function die(msg) {
  process.stderr.write(`[sn_script_runner] ERROR: ${msg}\n`);
  process.exit(1);
}

// ── Main ─────────────────────────────────────────────────────────────

(async () => {
  // Read config from env
  const instance = process.env.SN_INSTANCE;
  const user = process.env.SN_USER;
  const password = process.env.SN_PASSWORD;
  const scope = process.env.SN_SCOPE || 'global';
  const timeout = parseInt(process.env.SN_TIMEOUT || '30000', 10);

  if (!instance) die('SN_INSTANCE is required');
  if (!user) die('SN_USER is required');
  if (!password) die('SN_PASSWORD is required');

  // Get script code
  let scriptCode = process.env.SN_SCRIPT || '';
  const scriptFile = process.env.SN_SCRIPT_FILE || '';
  if (!scriptCode && scriptFile) {
    if (!fs.existsSync(scriptFile)) die(`Script file not found: ${scriptFile}`);
    scriptCode = fs.readFileSync(scriptFile, 'utf8');
  }
  if (!scriptCode) die('SN_SCRIPT or SN_SCRIPT_FILE is required');

  // Ensure instance URL has https://
  const baseUrl = instance.startsWith('http') ? instance : `https://${instance}`;

  let browser;
  try {
    // ── Launch browser ───────────────────────────────────────────
    log('Launching headless Chromium...');
    browser = await chromium.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
    });

    const context = await browser.newContext({
      ignoreHTTPSErrors: true,
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    });
    context.setDefaultNavigationTimeout(timeout);
    context.setDefaultTimeout(timeout);

    const page = await context.newPage();

    // ── Step 1: Login ────────────────────────────────────────────
    log(`Logging in to ${baseUrl}/login.do ...`);
    await page.goto(`${baseUrl}/login.do`, { waitUntil: 'domcontentloaded' });

    await page.fill('#user_name', user);
    await page.fill('#user_password', password);
    await page.click('#sysverb_login');
    await page.waitForTimeout(3000);

    // Verify login succeeded
    const postLoginUrl = page.url();
    if (postLoginUrl.includes('login.do') || postLoginUrl.includes('login_redirect.do')) {
      die('Login failed — still on login page. Check credentials.');
    }
    log('Login successful.');

    // ── Step 2: Navigate to sys.scripts.do ───────────────────────
    log('Navigating to sys.scripts.do ...');
    await page.goto(`${baseUrl}/sys.scripts.do`, { waitUntil: 'networkidle' });

    // Verify we didn't get redirected
    if (page.url().includes('login.do')) {
      die('Session lost — redirected to login from sys.scripts.do');
    }

    // ── Step 3: Select scope ─────────────────────────────────────
    log(`Selecting scope: ${scope}`);
    await page.selectOption('select[name="sys_scope"]', scope);
    await page.waitForTimeout(500);

    // ── Step 4: Fill in the script ───────────────────────────────
    log('Filling script textarea...');
    await page.fill('textarea#runscript', scriptCode);

    // ── Step 5: Submit ───────────────────────────────────────────
    log('Running script...');
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'networkidle' }),
      page.click('input[name="runscript"][type="submit"]'),
    ]);

    // ── Step 6: Extract output ───────────────────────────────────
    log('Extracting output...');

    const preText = await page.$eval('pre', el => el.textContent).catch(() => '');

    if (!preText) {
      log('No <pre> tag found — script may have produced no output.');
      await browser.close();
      process.exit(0);
    }

    // Check for execution errors
    if (preText.includes('Script execution error:')) {
      // Extract the error description
      const errorMatch = preText.match(/Script execution error:[^\n]*(?:\n(?!\*\*\*).*)*/);
      const errorMsg = errorMatch ? errorMatch[0].trim() : preText.trim();
      process.stderr.write(`[sn_script_runner] SCRIPT ERROR:\n${errorMsg}\n`);
      process.stdout.write(errorMsg + '\n');
      await browser.close();
      process.exit(1);
    }

    // Filter lines starting with "*** Script: " and strip prefix
    const lines = preText.split('\n');
    const outputLines = [];
    for (const line of lines) {
      if (line.startsWith('*** Script: ')) {
        outputLines.push(line.substring('*** Script: '.length));
      }
    }

    const cleanOutput = outputLines.join('\n');
    if (cleanOutput) {
      process.stdout.write(cleanOutput + '\n');
    }

    log('Done.');
    await browser.close();
    process.exit(0);

  } catch (err) {
    if (browser) {
      try { await browser.close(); } catch (_) {}
    }
    die(err.message || String(err));
  }
})();
