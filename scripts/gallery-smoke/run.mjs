/**
 * Gallery inspect-brightness smoke test (regression guard for the near-black
 * inspected poster).
 *
 * Boots the smoke.html harness under vite, drives it with puppeteer-core
 * against the system Chrome, and runs three checks against the fixture posters
 * (the engine's procedural fallback — bright serif text on the poster center):
 *
 *   1. Idle-snap target — drive a full-corridor travel (target-only, the
 *      travelToTier way) and assert it settles at the destination station, not
 *      stalled mid-corridor. Guards the snap-anchors-to-target fix.
 *   2. Curator's Walk turn — stand at a right-wall stop (self-verified via
 *      slot.x > 0) and assert the poster reads bright/frontal (max luminance
 *      > 0.35) AND the camera drifted toward the opposite wall (camera.x < 0).
 *      The Task 3 turn-to-face guard.
 *   3. Inspect brightness — fly the first case to the inspect anchor and
 *      assert the brightest pixel in a 60×60 block at the poster's center
 *      reads > 0.35 luminance. A dim-layer-over-poster regression lands far
 *      below the threshold.
 *
 * Usage:
 *   node scripts/gallery-smoke/run.mjs [--label before|after]
 *
 * Screenshots land in scripts/gallery-smoke/artifacts/ (gitignored).
 * Exit code 0 = PASS, 1 = FAIL, 2 = harness error (WebGL unavailable etc).
 */
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import puppeteer from 'puppeteer-core';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..', '..');
const PORT = 5199;
const URL = `http://localhost:${PORT}/smoke.html`;
const CHROME =
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const LUMINANCE_THRESHOLD = 0.35;
const SETTLE_MS = 900;

const label =
  process.argv.includes('--label')
    ? process.argv[process.argv.indexOf('--label') + 1]
    : 'run';

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
  page.on('pageerror', (err) => console.error('[page]', err.message));
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

async function main() {
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

    // ── Idle-snap anchors to the walk target (regression) ──────────────────
    // Drive a full-corridor travel the travelToTier way — set ONLY the target
    // and back-date input — then let it settle through the real damp+snap loop.
    // The bug this guards: snapping to the CURRENT station drags targetWalk back
    // toward the start, stalling the travel mid-corridor. The 10-item fixture
    // has stops 0…9; travelling 0 → 9 must actually arrive at 9.
    const TRAVEL_TARGET = 9;
    await page.evaluate(() => window.__smoke.walkTo(0)); // known start
    await new Promise((r) => setTimeout(r, 200));
    await page.evaluate((i) => window.__smoke.travelTo(i), TRAVEL_TARGET);
    await new Promise((r) => setTimeout(r, 1600));
    const travel = await page.evaluate(() => window.__smoke.walkState());
    const arrived = Math.round(travel.walk);
    console.log(
      `travel 0 → ${TRAVEL_TARGET}: settled walk ${travel.walk.toFixed(3)} ` +
        `(target ${travel.targetWalk.toFixed(3)}) → station ${arrived}`,
    );
    if (arrived === TRAVEL_TARGET) {
      console.log(
        `PASS — travel reached station ${TRAVEL_TARGET} (snap follows the target)`,
      );
    } else {
      console.error(
        `FAIL — travel stalled at station ${arrived}, expected ${TRAVEL_TARGET} ` +
          '(idle snap is dragging the target back toward the current station)',
      );
      process.exitCode = 1;
    }

    // ── Curator's Walk turn ────────────────────────────────────────────────
    // Stand at a right-wall stop and confirm the camera turns to face it. The
    // fixture side pattern per tier is L, R, L, … so walk stop index 1 (the
    // second stop) is a right-wall case. A correct turn drifts the eye toward
    // the opposite (left) wall — camera.x < 0 — and points it at the poster so
    // its bright text projects near screen center. The slot.x > 0 check makes
    // the "right wall" claim self-verifying instead of comment-enforced.
    const RIGHT_WALL_STOP = 1;
    await page.evaluate((i) => window.__smoke.walkTo(i), RIGHT_WALL_STOP);
    await new Promise((r) => setTimeout(r, SETTLE_MS));

    const turnShot = path.join(HERE, 'artifacts', `${label}-stop.png`);
    await page.screenshot({ path: turnShot });
    const turn = await page.evaluate(
      (i) => window.__smoke.sample(60, i),
      RIGHT_WALL_STOP,
    );
    console.log(
      `stop ${RIGHT_WALL_STOP} (slot.x ${turn.slotX.toFixed(2)}) poster center ` +
        `(${turn.centerX}, ${turn.centerY}) — max luminance ` +
        `${turn.max.toFixed(3)}, camera.x ${turn.cameraX.toFixed(3)}`,
    );
    console.log(`screenshot: ${turnShot}`);

    const rightWall = turn.slotX > 0; // self-check: is this actually a right case?
    const turnBright = turn.max > LUMINANCE_THRESHOLD;
    const turnDrift = turn.cameraX < -0.2; // drifted toward the far (left) wall
    if (rightWall && turnBright && turnDrift) {
      console.log(
        `PASS — walk-turn: right-wall case (slot.x ${turn.slotX.toFixed(2)}), ` +
          `poster frontal (max ${turn.max.toFixed(3)} > ${LUMINANCE_THRESHOLD}), ` +
          `eye drifted to x ${turn.cameraX.toFixed(3)}`,
      );
    } else {
      console.error(
        `FAIL — walk-turn: rightWall=${rightWall} (slot.x ${turn.slotX.toFixed(2)}), ` +
          `bright=${turnBright} (max ${turn.max.toFixed(3)}), ` +
          `drift=${turnDrift} (camera.x ${turn.cameraX.toFixed(3)} — expected < -0.2)`,
      );
      process.exitCode = 1;
    }

    // ── Inspect brightness ─────────────────────────────────────────────────
    // Fly the first fixture case to the inspect anchor and let it settle.
    await page.evaluate(() => window.__smoke.inspectFirst());
    await page.waitForFunction(() => window.__smoke.mode === 'inspect', {
      timeout: 5000,
    });
    await new Promise((r) => setTimeout(r, SETTLE_MS));

    const screenshotPath = path.join(HERE, 'artifacts', `${label}.png`);
    await page.screenshot({ path: screenshotPath });

    const sample = await page.evaluate(() => window.__smoke.sample(60));
    console.log(
      `inspected poster center (${sample.centerX}, ${sample.centerY}) ` +
        `${sample.blockSize}×${sample.blockSize}px — ` +
        `mean luminance ${sample.mean.toFixed(3)}, max ${sample.max.toFixed(3)}`,
    );
    console.log(`screenshot: ${screenshotPath}`);

    if (sample.max > LUMINANCE_THRESHOLD) {
      console.log(
        `PASS — max luminance ${sample.max.toFixed(3)} > ${LUMINANCE_THRESHOLD}`,
      );
    } else {
      console.error(
        `FAIL — max luminance ${sample.max.toFixed(3)} <= ${LUMINANCE_THRESHOLD} ` +
          '(inspected poster is being dimmed with the world)',
      );
      process.exitCode = 1;
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
