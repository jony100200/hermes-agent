const fs = require("fs");
const path = require("path");
const { _electron: electron } = require("playwright");

const APP_ROOT = path.resolve(__dirname, "..");
const REPO_ROOT = path.resolve(APP_ROOT, "..");
const REPORT_PATH = path.join(APP_ROOT, "smoke-ui-report.json");
const PROMPT = "Create a simple Python hello world script and run it";

function nowIso() {
  return new Date().toISOString();
}

function listRecentHelloPyFiles(sinceMs) {
  const files = [];
  const topLevel = fs.readdirSync(REPO_ROOT, { withFileTypes: true });
  for (const entry of topLevel) {
    if (!entry.isFile() || !entry.name.endsWith(".py")) continue;
    const fullPath = path.join(REPO_ROOT, entry.name);
    const stat = fs.statSync(fullPath);
    if (stat.mtimeMs < sinceMs) continue;
    let content = "";
    try {
      content = fs.readFileSync(fullPath, "utf-8");
    } catch {
      content = "";
    }
    files.push({
      name: entry.name,
      fullPath,
      modifiedAt: new Date(stat.mtimeMs).toISOString(),
      looksLikeHello: /hello\s*,?\s*world/i.test(content) || /print\(/i.test(content),
    });
  }
  return files;
}

async function isVisible(page, selector) {
  const loc = page.locator(selector);
  const count = await loc.count();
  if (!count) return false;
  try {
    return await loc.first().isVisible();
  } catch {
    return false;
  }
}

async function maybeHandleWelcomeInstallSetup(page) {
  if (await isVisible(page, ".setup-screen")) {
    const cards = page.locator(".setup-provider-card");
    const count = await cards.count();
    if (count > 0) {
      await cards.nth(count - 1).click();
    }
    const continueBtn = page.locator("button.setup-continue");
    if (await continueBtn.isVisible()) {
      await continueBtn.click();
    }
    return "setup";
  }

  if (await isVisible(page, ".welcome-screen")) {
    const startBtn = page.locator("button.welcome-button");
    if (await startBtn.count()) {
      await startBtn.first().click();
      return "welcome-start";
    }
    const recheckBtn = page.locator("button.welcome-recheck-btn");
    if (await recheckBtn.count()) {
      await recheckBtn.first().click();
      return "welcome-recheck";
    }
    return "welcome-visible";
  }

  if (await isVisible(page, ".install-screen")) {
    const err = page.locator(".install-error-banner");
    if (await err.count()) {
      const msg = await err.first().innerText();
      throw new Error(`Install screen reported failure: ${msg}`);
    }
    const doneBtn = page.locator(".install-done button");
    if (await doneBtn.count()) {
      await doneBtn.first().click();
      return "install-done";
    }
    return "install-running";
  }

  return "none";
}

async function waitForChatReady(page, timeoutMs) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (await isVisible(page, "textarea.chat-input")) {
      return;
    }
    await maybeHandleWelcomeInstallSetup(page);
    await page.waitForTimeout(1500);
  }
  throw new Error("Timed out waiting for chat input to appear");
}

async function runSmoke() {
  const runStartedAt = Date.now();
  const report = {
    startedAt: nowIso(),
    prompt: PROMPT,
    status: "running",
    events: [],
    createdFiles: [],
    agentMessages: [],
    checks: {
      chatReady: false,
      promptSent: false,
      runCompleted: false,
      outputMentionsHelloWorld: false,
      helloPyFileDetected: false,
    },
    error: null,
    finishedAt: null,
  };

  function logEvent(message) {
    report.events.push({ at: nowIso(), message });
    console.log(`[smoke-ui] ${message}`);
  }

  let app;
  try {
    app = await electron.launch({
      args: [APP_ROOT],
      timeout: 120000,
    });

    const page = await app.firstWindow();
    await page.waitForLoadState("domcontentloaded", { timeout: 120000 });
    logEvent("Electron window opened");

    await waitForChatReady(page, 180000);
    report.checks.chatReady = true;
    logEvent("Chat input ready");

    const input = page.locator("textarea.chat-input");
    await input.fill(PROMPT);
    await page.locator("button.chat-send-btn").click();
    report.checks.promptSent = true;
    logEvent("Smoke prompt sent from UI");

    await page.waitForTimeout(800);

    try {
      await page.waitForSelector(".chat-stop-btn", {
        state: "visible",
        timeout: 30000,
      });
    } catch {
      // Some responses complete too quickly to observe the stop button.
    }

    const completionStart = Date.now();
    const completionTimeoutMs = 600000;
    while (Date.now() - completionStart < completionTimeoutMs) {
      const isLoading = (await page.locator(".chat-stop-btn").count()) > 0;
      const agentCount = await page
        .locator(".chat-message-agent .chat-bubble-agent")
        .count();
      if (!isLoading && agentCount > 0) {
        break;
      }
      await page.waitForTimeout(1000);
    }

    const isStillLoading = (await page.locator(".chat-stop-btn").count()) > 0;
    if (isStillLoading) {
      throw new Error("Timed out waiting for chat run completion (spinner still active).");
    }

    report.checks.runCompleted = true;
    logEvent("Chat run completed");

    const agentBubbles = page.locator(".chat-message-agent .chat-bubble-agent");
    const count = await agentBubbles.count();
    for (let i = 0; i < count; i += 1) {
      const text = (await agentBubbles.nth(i).innerText()).trim();
      if (text) report.agentMessages.push(text);
    }

    const allAgentText = report.agentMessages.join("\n\n");
    report.checks.outputMentionsHelloWorld = /hello\s*,?\s*world/i.test(allAgentText);

    const createdFiles = listRecentHelloPyFiles(runStartedAt - 5000);
    report.createdFiles = createdFiles;
    report.checks.helloPyFileDetected = createdFiles.some((f) => f.looksLikeHello);

    const success =
      report.checks.runCompleted &&
      report.checks.outputMentionsHelloWorld &&
      report.checks.helloPyFileDetected;

    report.status = success ? "pass" : "fail";
    if (!success) {
      report.error =
        "Smoke task did not satisfy all checks (run completion, hello output mention, hello python file detection).";
    }
  } catch (err) {
    report.status = "fail";
    report.error = err && err.message ? err.message : String(err);
  } finally {
    report.finishedAt = nowIso();
    fs.writeFileSync(REPORT_PATH, JSON.stringify(report, null, 2), "utf-8");
    if (app) {
      try {
        await app.close();
      } catch {
        // ignore close errors
      }
    }
  }

  if (report.status !== "pass") {
    console.error("SMOKE_UI_STATUS=FAIL");
    console.error(`SMOKE_UI_REPORT=${REPORT_PATH}`);
    process.exit(1);
  }

  console.log("SMOKE_UI_STATUS=PASS");
  console.log(`SMOKE_UI_REPORT=${REPORT_PATH}`);
}

runSmoke();
