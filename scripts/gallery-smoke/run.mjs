/**
 * Gallery full-cycle smoke test (regression guard for the Curator's Walk).
 *
 * Boots the smoke.html harness under vite, drives it with puppeteer-core
 * against the system Chrome, and walks the engine through a complete cycle,
 * screenshotting each phase into artifacts/ (gitignored). Every phase asserts;
 * any console 'error' or uncaught page error across the whole run fails it.
 *
 * Phases (fixture posters render the engine's procedural fallback — bright
 * serif title text, a stable luminance target):
 *
 *   1. Hall start — settle at stop 0.
 *   2. Idle-snap travel — drive a full-corridor travel the travelToTier way
 *      (target-only, back-dated input) and assert it settles at the far
 *      destination, not stalled mid-corridor. Guards the snap-anchors-to-target
 *      fix.
 *   3. Curator's Walk turn — stand at a right-wall stop (self-verified via
 *      slot.x > 0) and assert the poster reads bright/frontal (max luminance
 *      > 0.35) AND the camera drifted toward the opposite wall (camera.x < 0).
 *      The Task 3 turn-to-face guard.
 *   4. Inspect brightness — fly the first case to the inspect anchor and assert
 *      the brightest pixel in a 60×60 block at the poster's center reads > 0.35.
 *      A dim-layer-over-poster regression lands far below the threshold.
 *   5. Esc → hall — dispatch a real Escape keydown on the canvas and assert the
 *      engine's mode machine returns to 'hall'.
 *   6. Tier fast-travel — call the real GalleryEngine.travelToTier for the
 *      fixture's second tier (via __smoke.travelToSecondTier()) and assert it
 *      arrives at the stop that control targeted. Skipped (as a failure) if
 *      phase 5 left the engine out of 'hall', so a phase-5 miss can't masquerade
 *      as a phase-6 miss.
 *
 * Usage:
 *   node scripts/gallery-smoke/run.mjs [--label before|after]
 *   SMOKE_CHROME=/path/to/chromium node scripts/gallery-smoke/run.mjs
 *
 * Screenshots land in scripts/gallery-smoke/artifacts/ (gitignored).
 * Exit code 0 = PASS, 1 = FAIL, 2 = harness error (Chrome/WebGL unavailable).
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const PORT = 5199;
const URL = `http://localhost:${PORT}/smoke.html`;
const CHROME =
  process.env.SMOKE_CHROME ??
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LUMINANCE_THRESHOLD = 0.35;
const SETTLE_MS = 900;

const label =
  process.argv.includes('--label')
    ? process.argv[process.argv.indexOf('--label') + 1]
    : 'run';

// Collected across the whole run; any entry fails the smoke (Three.js perf
// warnings arrive as 'warning'/'log' and are ignored — only 'error' counts).
const consoleErrors = [];

function attachErrorCollector(page) {
  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(`console.error: ${msg.text()}`);
  });
  page.on('pageerror', (err) => {
    consoleErrors.push(`pageerror: ${err.message}`);
    console.error('[page]', err.message);
  });
}

function startVite() {
  const vite = spawn(
    process.execPath,
    [
      path.join(REPO, 'node_modules', 'vite', 'bin', 'vite.js'),
      '--config',
      path.join(HERE, 'vite.config.ts'),
    ],
    { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  vite.stderr.on('data', (d) => process.stderr.write(`[vite] ${d}`));
  return vite;
}

async function waitForServer(timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(URL);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`vite dev server did not come up on :${PORT}`);
}

async function launchBrowser(extraArgs) {
  return puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--hide-scrollbars', ...extraArgs],
    defaultViewport: { width: 1280, height: 800 },
  });
}

async function tryHarness(browser) {
  const page = await browser.newPage();
  attachErrorCollector(page);
  await page.goto(URL, { waitUntil: 'networkidle0', timeout: 30000 });
  try {
    await page.waitForFunction(
      () => window.__smoke && (window.__smoke.ready || window.__smoke.fatal),
      { timeout: 15000 },
    );
  } catch {
    await page.close();
    return { page: null, fatal: 'harness-timeout' };
  }
  const fatal = await page.evaluate(() => window.__smoke.fatal);
  if (fatal) {
    await page.close();
    return { page: null, fatal };
  }
  return { page, fatal: null };
}

const shot = (page, name) =>
  page.screenshot({ path: path.join(HERE, 'artifacts', `${label}-${name}.png`) });

async function main() {
  if (!existsSync(CHROME)) {
    console.error(
      process.env.SMOKE_CHROME
        ? `FATAL: SMOKE_CHROME is set but no binary exists there: ${CHROME}`
        : `FATAL: Chrome not found at the default path: ${CHROME}\n` +
            'set SMOKE_CHROME to your Chrome/Chromium binary',
    );
    process.exitCode = 2;
    return;
  }

  mkdirSync(path.join(HERE, 'artifacts'), { recursive: true });
  const vite = startVite();
  let browser = null;
  try {
    await waitForServer();

    // Plain headless first; SwiftShader fallback when WebGL init fails.
    browser = await launchBrowser([]);
    let { page, fatal } = await tryHarness(browser);
    if (!page) {
      console.log(
        `plain headless WebGL unavailable (${fatal}) — retrying with SwiftShader`,
      );
      await browser.close();
      consoleErrors.length = 0; // discard the failed page's noise
      browser = await launchBrowser([
        '--use-angle=swiftshader',
        '--enable-unsafe-swiftshader',
      ]);
      ({ page, fatal } = await tryHarness(browser));
      if (!page) {
        console.error(`FATAL: headless WebGL unavailable even with SwiftShader (${fatal})`);
        process.exitCode = 2;
        return;
      }
    }

    // ── Phase 1: hall start ────────────────────────────────────────────────
    await page.evaluate(() => window.__smoke.walkTo(0));
    await new Promise((r) => setTimeout(r, SETTLE_MS));
    await shot(page, '01-hall');
    const hallMode = await page.evaluate(() => window.__smoke.mode);
    if (hallMode === 'hall') {
      console.log('PASS — phase 1: settled in hall at stop 0');
    } else {
      console.error(`FAIL — phase 1: expected mode 'hall', got '${hallMode}'`);
      process.exitCode = 1;
    }

    // ── Phase 2: idle-snap travel (target-only, must reach the far stop) ────
    // The bug this guards: snapping to the CURRENT station drags targetWalk
    // back toward the start, stalling the travel mid-corridor. The 10-item
    // fixture has stops 0…9; travelling 0 → 9 must actually arrive at 9.
    const TRAVEL_TARGET = 9;
    await page.evaluate((i) => window.__smoke.travelTo(i), TRAVEL_TARGET);
    await new Promise((r) => setTimeout(r, 1600));
    await shot(page, '02-travel');
    const travel = await page.evaluate(() => window.__smoke.walkState());
    const arrived = Math.round(travel.walk);
    console.log(
      `travel 0 → ${TRAVEL_TARGET}: settled walk ${travel.walk.toFixed(3)} ` +
        `(target ${travel.targetWalk.toFixed(3)}) → station ${arrived}`,
    );
    if (arrived === TRAVEL_TARGET) {
      console.log(
        `PASS — phase 2: travel reached station ${TRAVEL_TARGET} (snap follows the target)`,
      );
    } else {
      console.error(
        `FAIL — phase 2: travel stalled at station ${arrived}, expected ${TRAVEL_TARGET} ` +
          '(idle snap is dragging the target back toward the current station)',
      );
      process.exitCode = 1;
    }

    // ── Phase 3: Curator's Walk turn ───────────────────────────────────────
    // Stand at a right-wall stop and confirm the camera turns to face it. The
    // fixture side pattern per tier is L, R, L, … so walk stop index 1 (the
    // second stop) is a right-wall case. A correct turn drifts the eye toward
    // the opposite (left) wall — camera.x < 0 — and points it at the poster so
    // its bright text projects near screen center. The slot.x > 0 check makes
    // the "right wall" claim self-verifying instead of comment-enforced.
    const RIGHT_WALL_STOP = 1;
    await page.evaluate((i) => window.__smoke.walkTo(i), RIGHT_WALL_STOP);
    await new Promise((r) => setTimeout(r, SETTLE_MS));
    await shot(page, '03-stop');
    const turn = await page.evaluate(
      (i) => window.__smoke.sample(60, i),
      RIGHT_WALL_STOP,
    );
    console.log(
      `stop ${RIGHT_WALL_STOP} (slot.x ${turn.slotX.toFixed(2)}) poster center ` +
        `(${turn.centerX}, ${turn.centerY}) — max luminance ` +
        `${turn.max.toFixed(3)}, camera.x ${turn.cameraX.toFixed(3)}`,
    );

    const rightWall = turn.slotX > 0; // self-check: is this actually a right case?
    const turnBright = turn.max > LUMINANCE_THRESHOLD;
    const turnDrift = turn.cameraX < -0.2; // drifted toward the far (left) wall
    if (rightWall && turnBright && turnDrift) {
      console.log(
        `PASS — phase 3: walk-turn right-wall case (slot.x ${turn.slotX.toFixed(2)}), ` +
          `poster frontal (max ${turn.max.toFixed(3)} > ${LUMINANCE_THRESHOLD}), ` +
          `eye drifted to x ${turn.cameraX.toFixed(3)}`,
      );
    } else {
      console.error(
        `FAIL — phase 3: rightWall=${rightWall} (slot.x ${turn.slotX.toFixed(2)}), ` +
          `bright=${turnBright} (max ${turn.max.toFixed(3)}), ` +
          `drift=${turnDrift} (camera.x ${turn.cameraX.toFixed(3)} — expected < -0.2)`,
      );
      process.exitCode = 1;
    }

    // ── Phase 4: inspect brightness ────────────────────────────────────────
    // Fly the first fixture case to the inspect anchor and let it settle.
    await page.evaluate(() => window.__smoke.inspectFirst());
    await page.waitForFunction(() => window.__smoke.mode === 'inspect', {
      timeout: 5000,
    });
    await new Promise((r) => setTimeout(r, SETTLE_MS));
    await shot(page, '04-inspect');

    const sample = await page.evaluate(() => window.__smoke.sample(60));
    console.log(
      `inspected poster center (${sample.centerX}, ${sample.centerY}) ` +
        `${sample.blockSize}×${sample.blockSize}px — ` +
        `mean luminance ${sample.mean.toFixed(3)}, max ${sample.max.toFixed(3)}`,
    );
    if (sample.max > LUMINANCE_THRESHOLD) {
      console.log(
        `PASS — phase 4: max luminance ${sample.max.toFixed(3)} > ${LUMINANCE_THRESHOLD}`,
      );
    } else {
      console.error(
        `FAIL — phase 4: max luminance ${sample.max.toFixed(3)} <= ${LUMINANCE_THRESHOLD} ` +
          '(inspected poster is being dimmed with the world)',
      );
      process.exitCode = 1;
    }

    // ── Phase 5: Esc → hall ────────────────────────────────────────────────
    // Dispatch a real Escape keydown on the canvas (the engine's own handler
    // wiring, not the React GalleryView layer) and assert the mode machine
    // damps all the way back to 'hall'.
    await page.evaluate(() => {
      const canvas = document.getElementById('stage');
      canvas.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
      );
    });
    try {
      await page.waitForFunction(() => window.__smoke.mode === 'hall', {
        timeout: 5000,
      });
    } catch {
      // fall through to the assertion below for a descriptive failure
    }
    await new Promise((r) => setTimeout(r, SETTLE_MS));
    await shot(page, '05-hall-return');
    const returnedMode = await page.evaluate(() => window.__smoke.mode);
    if (returnedMode === 'hall') {
      console.log("PASS — phase 5: Esc returned the engine to mode 'hall'");
    } else {
      console.error(
        `FAIL — phase 5: expected mode 'hall' after Esc, got '${returnedMode}'`,
      );
      process.exitCode = 1;
    }

    // ── Phase 6: tier fast-travel ──────────────────────────────────────────
    // Drive the real GalleryEngine.travelToTier (room lookup + hall-mode guard
    // + reducedMotion branch) for the fixture's second tier and assert we land
    // on the stop it targeted. travelToTier no-ops unless the engine is in
    // 'hall', so if phase 5 failed to return there this would silently target
    // nothing — skip with an explicit failure rather than mis-diagnose it.
    if (returnedMode !== 'hall') {
      console.error(
        `SKIP — phase 6: engine not in hall (mode '${returnedMode}' from phase 5); ` +
          'cannot exercise tier fast-travel',
      );
      process.exitCode = 1;
    } else {
      const secondTierStop = await page.evaluate(() =>
        window.__smoke.travelToSecondTier(),
      );
      await new Promise((r) => setTimeout(r, 1600));
      await shot(page, '06-tier');
      const tierTravel = await page.evaluate(() => window.__smoke.walkState());
      const tierArrived = Math.round(tierTravel.walk);
      console.log(
        `tier fast-travel → stop ${secondTierStop} (second tier's first case): ` +
          `settled walk ${tierTravel.walk.toFixed(3)} → station ${tierArrived}`,
      );
      if (tierArrived === secondTierStop) {
        console.log(
          `PASS — phase 6: travelToTier reached the second tier at stop ${secondTierStop}`,
        );
      } else {
        console.error(
          `FAIL — phase 6: tier travel settled at ${tierArrived}, expected ${secondTierStop}`,
        );
        process.exitCode = 1;
      }
    }

    // ── Console-error guard ────────────────────────────────────────────────
    if (consoleErrors.length > 0) {
      console.error(
        `FAIL — ${consoleErrors.length} console error(s) during the run:`,
      );
      for (const e of consoleErrors) console.error(`  • ${e}`);
      process.exitCode = 1;
    } else {
      console.log('PASS — zero console errors across the run');
    }
  } catch (err) {
    console.error('harness error:', err);
    process.exitCode = 2;
  } finally {
    if (browser) await browser.close().catch(() => undefined);
    vite.kill('SIGTERM');
  }
}

await main();
