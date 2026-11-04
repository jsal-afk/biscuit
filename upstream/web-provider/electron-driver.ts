import { createHash } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { createServer } from "node:net";
import { isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { z } from "zod";
import { chromium, type Browser, type BrowserContext, type CDPSession, type Locator, type Page } from "playwright-core";
import { assertAuthenticatedChatGptPage, assertNewChatPage, chatGptNewChatUrl } from "../codex-chatgpt-web/src/chatgpt-session";
import { CHATGPT_COMPOSER_SELECTOR, CHATGPT_SEND_BUTTON_SELECTOR, chatGptStopButton } from "../codex-chatgpt-web/src/chatgpt-ui/composer";
import { CHATGPT_ASSISTANT_TURN_SELECTOR, CHATGPT_COMPLETION_ACTION_SELECTOR, CHATGPT_USER_TURN_SELECTOR } from "../codex-chatgpt-web/src/chatgpt-ui/turns";
import { ChatGptCompletionTracker, insertPlainTextIntoComposer, throwIfChatGptRateLimitDialog, throwIfChatGptSessionFailureAlert, throwIfChatGptTerminalErrorAlert, throwIfChatGptToolApprovalRequired } from "../codex-chatgpt-web/src/adapters/chatgpt-web/browser-worker";
import { safeProviderErrorCategory } from "./error-categories";
import {
  abortActiveRequest,
  awaitActiveStep,
  MODEL_SLUG,
  reconcileUnconfirmedStop,
  settleRequestError,
  validateRequest,
  waitForStableStop,
  type ActiveRequestLifecycle,
  type StopOutcome,
  type StopRecoveryIdentity,
  type StopRecoveryObservation,
  type StopSettlementObservation,
} from "./request-lifecycle";
import { readChatGptAuthSession } from "../codex-chatgpt-web/launcher/electron/chatgpt-auth-session.cjs";
type ElectronWebContents = {
  on(event: "will-navigate", listener: (event: { preventDefault(): void }, url: string) => void): void;
  on(event: "did-create-window", listener: (window: ElectronWindow) => void): void;
  setWindowOpenHandler(handler: (details: { url: string }) => { action: "allow"; overrideBrowserWindowOptions: { webPreferences: Record<string, unknown> } } | { action: "deny" }): void;
};
type ElectronWindow = {
  webContents: ElectronWebContents & { loadURL(url: string): Promise<void> };
  isDestroyed(): boolean;
  showInactive(): void;
  destroy(): void;
};
type ElectronSession = {
  setPermissionRequestHandler(handler: (_contents: unknown, _permission: unknown, done: (allowed: boolean) => void) => void): void;
  clearStorageData(): Promise<void>;
};
type ElectronApp = {
  setName(name: string): void;
  setPath(name: "userData" | "sessionData", path: string): void;
  commandLine: { appendSwitch(name: string, value: string): void };
  whenReady(): Promise<void>;
  getPath(name: "userData"): string;
  quit(): void;
};
type HostDescriptor = {
  schema: "biscuit.chatgpt-web.electron-host.v1";
  mode: "adopted" | "managed";
  pid: number;
  executablePath: string;
  userDataPath: string;
  appName: string;
  partition: string;
  cdpEndpoint: string;
  targetId: string;
  sessionVerified: boolean;
};
type ProfileIdentity = {
  schema: "biscuit.chatgpt-web.profile-identity.v1";
  userDataPath: string;
  appName: string;
  partition: string;
};
type ActiveRun = ActiveRequestLifecycle & { task: Promise<void>; page?: Page };
type ActiveLogin = { id: string; controller: AbortController; continueRequested: boolean; task: Promise<void> };
const { app, BrowserWindow, session } = require("electron") as {
  app: ElectronApp;
  BrowserWindow: new (options: { width: number; height: number; show: boolean; title: string; webPreferences: Record<string, unknown> }) => ElectronWindow;
  session: { fromPartition(partition: string): ElectronSession };
};
const HostDescriptorSchema = z.object({
  schema: z.literal("biscuit.chatgpt-web.electron-host.v1"),
  mode: z.enum(["adopted", "managed"]),
  pid: z.number().int().positive().safe(),
  executablePath: z.string().refine(isAbsolute),
  userDataPath: z.string().refine(isAbsolute),
  appName: z.string().min(1).max(128),
  partition: z.string().startsWith("persist:"),
  cdpEndpoint: z.string().url(),
  targetId: z.string().regex(/^[A-Za-z0-9_-]{8,128}$/),
  sessionVerified: z.boolean(),
}).strict();
const ProfileIdentitySchema = z.object({
  schema: z.literal("biscuit.chatgpt-web.profile-identity.v1"),
  userDataPath: z.string().refine(isAbsolute),
  appName: z.string().min(1).max(128),
  partition: z.string().startsWith("persist:").max(128),
}).strict();
const DebugTargetListSchema = z.array(z.object({
  id: z.string().min(8).max(128),
  type: z.string(),
  url: z.string(),
}).passthrough());

const MAX_LINE_CHARS = 1_000_000;
const TURN_TIMEOUT_MS = 300_000;
const LOGIN_TIMEOUT_MS = 600_000;
const PARTITION = "persist:biscuit-chatgpt-web";
const CHATGPT_ORIGIN = "https://chatgpt.com";
const CHATGPT_SESSION_CHECK_SCRIPT = `(${readChatGptAuthSession.toString()})(fetch.bind(globalThis), ${JSON.stringify(CHATGPT_ORIGIN)}, 15_000)`;

const webHome = process.env.BISCUIT_CHATGPT_WEB_HOME;
const descriptorPath = process.env.BISCUIT_CHATGPT_WEB_DESCRIPTOR;
if (!webHome || !descriptorPath || !isAbsolute(webHome) || !isAbsolute(descriptorPath)) {
  writeProtocol({ type: "fatal", category: "configuration" });
  process.exit(1);
}
const homePath = resolve(webHome);
const hostDescriptorPath = resolve(descriptorPath);
const expectedDescriptorPath = join(homePath, "electron-host.json");
if (hostDescriptorPath !== expectedDescriptorPath) {
  writeProtocol({ type: "fatal", category: "configuration" });
  process.exit(1);
}

function writeProtocol(value: Record<string, unknown>): void {
  try { writeSync(1, `${JSON.stringify(value)}\n`); }
  catch { try { writeSync(1, '{"type":"fatal","category":"protocol"}\n'); } catch {} }
}
function ensurePrivateDirectory(path: string): void {
  if (!existsSync(path)) mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("private_directory_invalid");
  chmodSync(path, 0o700);
}
function readDescriptor(): HostDescriptor | undefined {
  if (!existsSync(hostDescriptorPath)) return undefined;
  const stat = lstatSync(hostDescriptorPath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16_384) throw new Error("private_directory_invalid");
  const parsed = HostDescriptorSchema.safeParse(JSON.parse(readFileSync(hostDescriptorPath, "utf8")) as unknown);
  if (!parsed.success) throw new Error("private_directory_invalid");
  const value = parsed.data;
  const endpoint = new URL(value.cdpEndpoint);
  if (endpoint.protocol !== "http:" || !["127.0.0.1", "[::1]"].includes(endpoint.hostname)
    || endpoint.username || endpoint.password || endpoint.pathname !== "/") throw new Error("private_directory_invalid");
  return value;
}
function readProfileIdentity(): ProfileIdentity | undefined {
  const profileIdentityPath = join(homePath, "profile-identity.json");
  if (!existsSync(profileIdentityPath)) return undefined;
  const stat = lstatSync(profileIdentityPath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4096) throw new Error("private_directory_invalid");
  const parsed = ProfileIdentitySchema.safeParse(JSON.parse(readFileSync(profileIdentityPath, "utf8")) as unknown);
  if (!parsed.success || resolve(parsed.data.userDataPath) !== parsed.data.userDataPath) {
    throw new Error("private_directory_invalid");
  }
  return parsed.data;
}
function processIsAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error !== null && typeof error === "object" && "code" in error && error.code === "EPERM"; }
}
function writeDescriptor(value: HostDescriptor): void {
  ensurePrivateDirectory(homePath);
  const staging = `${hostDescriptorPath}.${process.pid}.tmp`;
  writeFileSync(staging, `${JSON.stringify(value)}\n`, { mode: 0o600, flag: "wx" });
  chmodSync(staging, 0o600);
  renameSync(staging, hostDescriptorPath);
}
function wait(milliseconds: number, signal?: AbortSignal): Promise<void> {
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  let timer: NodeJS.Timeout;
  const onAbort = (): void => {
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
    reject(signal?.reason);
  };
  timer = setTimeout(() => {
    signal?.removeEventListener("abort", onAbort);
    resolve();
  }, milliseconds);
  if (signal?.aborted) onAbort();
  else signal?.addEventListener("abort", onAbort, { once: true });
  return promise;
}
function errorCategory(error: unknown, signal?: AbortSignal): string {
  const category = safeProviderErrorCategory(error, signal);
  if (category !== "browser_error") return category;
  if (error instanceof Error) {
    if (error.message === "fresh_unambiguous_chat_required" || error.message === "unambiguous_submitter_required") return "browser_error";
    if (error.message === "web_conversation_route_not_observed") return "browser_error";
    if (error.message === "public_response_deadline") return "timeout";
    if (error.message === "ChatGPT browser target is unavailable") return "reconnect_required";
    if (error.message === "browser_runtime_missing") return "browser_runtime_missing";
  }
  return "browser_error";
}
async function visibleAssistantFingerprint(candidate: Page, timeoutMs: number): Promise<string | undefined> {
  const assistants = candidate.locator(CHATGPT_ASSISTANT_TURN_SELECTOR).filter({ visible: true });
  const count = await assistants.count();
  if (count > 1) throw new Error("ambiguous_fresh_response");
  if (count === 0) return "";
  try {
    const text = await assistants.first().innerText({ timeout: timeoutMs });
    return text.length > 0 ? `${text.length}:${createHash("sha256").update(text).digest("hex")}` : "";
  } catch (error) {
    if (error instanceof Error && error.name === "TimeoutError") return undefined;
    throw error;
  }
}
async function stopButtonIsVisible(stop: Locator): Promise<boolean> {
  try { return await stop.isVisible(); }
  catch { throw new Error("generation_stop_unconfirmed"); }
}
async function readStopSettlementObservation(
  candidate: Page,
  stop: Locator,
  submissionObserved: () => boolean,
  timeoutMs: number,
): Promise<StopSettlementObservation> {
  const deadline = Date.now() + timeoutMs;
  const submitted = submissionObserved();
  if (await stopButtonIsVisible(stop)) return { stopVisible: true, composerReady: false, submissionObserved: submitted };
  const composer = candidate.locator(CHATGPT_COMPOSER_SELECTOR).filter({ visible: true });
  const composerCount = await composer.count();
  if (composerCount > 1) throw new Error("generation_stop_unconfirmed");
  if (composerCount !== 1) return { stopVisible: false, composerReady: false, submissionObserved: submitted };
  const editor = composer.first();
  try {
    let remaining = Math.max(1, deadline - Date.now());
    if (!await editor.isEnabled({ timeout: remaining })) return { stopVisible: false, composerReady: false, submissionObserved: submitted };
    remaining = Math.max(1, deadline - Date.now());
    if (!await editor.isEditable({ timeout: remaining })) return { stopVisible: false, composerReady: false, submissionObserved: submitted };
    remaining = Math.max(1, deadline - Date.now());
    return {
      stopVisible: false,
      composerReady: true,
      submissionObserved: submissionObserved(),
      assistantFingerprint: await visibleAssistantFingerprint(candidate, remaining),
    };
  } catch (error) {
    if (error instanceof Error && error.name === "TimeoutError") return { stopVisible: false, composerReady: false, submissionObserved: submissionObserved() };
    throw error;
  }
}
async function stopChatGptGeneration(
  candidate: Page,
  submissionObserved: () => boolean,
): Promise<Exclude<StopOutcome, "not_submitted" | "unconfirmed">> {
  const stop = chatGptStopButton(candidate);
  const deadline = Date.now() + 2_000;
  while (!await stopButtonIsVisible(stop)) {
    const assistants = candidate.locator(CHATGPT_ASSISTANT_TURN_SELECTOR).filter({ visible: true });
    const count = await assistants.count();
    if (count > 1) throw new Error("ambiguous_fresh_response");
    if (count === 1 && await assistants.first().locator(CHATGPT_COMPLETION_ACTION_SELECTOR).filter({ visible: true }).count() > 0) {
      await waitForStableStop(
        timeoutMs => readStopSettlementObservation(candidate, stop, submissionObserved, timeoutMs),
        milliseconds => wait(milliseconds),
        () => Date.now(),
      );
      return "already_settled";
    }
    if (Date.now() >= deadline) throw new Error("generation_stop_unconfirmed");
    await wait(100);
  }
  await stop.click({ timeout: 1_000 });
  await stop.waitFor({ state: "hidden", timeout: 5_000 });
  await waitForStableStop(
    timeoutMs => readStopSettlementObservation(candidate, stop, submissionObserved, timeoutMs),
    milliseconds => wait(milliseconds),
    () => Date.now(),
  );
  return "stopped";
}
function rememberUnconfirmedStop(candidate: Page | undefined, submissionObserved: boolean): void {
  generationStopUnconfirmed = true;
  unconfirmedStopIdentity = undefined;
  if (!candidate || !descriptor) return;
  try {
    const url = candidate.url();
    if (new URL(url).origin === CHATGPT_ORIGIN) {
      unconfirmedStopIdentity = {
        pageIdentity: candidate,
        targetId: descriptor.targetId,
        url,
        submissionObserved,
      };
    }
  } catch {}
}
async function reconcileUnconfirmedPage(): Promise<boolean> {
  const expected = unconfirmedStopIdentity;
  if (!expected) return false;
  try {
    const candidate = await getExactPage();
    if (candidate !== expected.pageIdentity || descriptor?.targetId !== expected.targetId) return false;
    const observe = async (timeoutMs: number): Promise<StopRecoveryObservation> => ({
      pageIdentity: candidate,
      targetId: descriptor?.targetId ?? "",
      url: candidate.url(),
      ...await readStopSettlementObservation(candidate, chatGptStopButton(candidate), () => expected.submissionObserved, timeoutMs),
    });
    return await reconcileUnconfirmedStop(expected, observe, milliseconds => wait(milliseconds), () => Date.now());
  } catch {
    return false;
  }
}
function abortRun(active: ActiveRun, reason: Error): void {
  abortActiveRequest(active, reason, async () => {
    const submission = active.submissionTask;
    if (submission) await submission.catch(() => {});
    if (!active.submitted && !active.submissionUncertain && !active.conversationRouteObserved) return "not_submitted";
    if (!active.page) throw new Error("generation_stop_unconfirmed");
    return await stopChatGptGeneration(active.page, () => active.conversationRouteObserved === true);
  });
}
function isAllowedNavigation(value: string): boolean {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:") return false;
    const host = url.hostname.toLowerCase();
    return host === "chatgpt.com" || host.endsWith(".chatgpt.com")
      || host === "auth.openai.com" || host === "openai.com" || host.endsWith(".openai.com")
      || host === "accounts.google.com" || host === "google.com" || host.endsWith(".google.com")
      || host === "gstatic.com" || host.endsWith(".gstatic.com")
      || host === "googleusercontent.com" || host.endsWith(".googleusercontent.com");
  } catch { return false; }
}

let descriptor: HostDescriptor | undefined;
let profileIdentity: ProfileIdentity | undefined;
let adoptingLiveHost = false;
let debugPort = 0;
let browser: Browser | undefined;
let browserContext: BrowserContext | undefined;
let page: Page | undefined;
let mainWindow: ElectronWindow | undefined;
let activeLogin: ActiveLogin | undefined;
let shuttingDown = false;
let disconnecting = false;
let generationStopUnconfirmed = false;
let unconfirmedStopIdentity: StopRecoveryIdentity | undefined;
const activeRuns = new Map<string, ActiveRun>();
const outputTail = new Map<string, string>();

try {
  ensurePrivateDirectory(homePath);
  profileIdentity = readProfileIdentity();
  descriptor = readDescriptor();
  if (profileIdentity && descriptor?.mode === "adopted") throw new Error("private_directory_invalid");
  adoptingLiveHost = !profileIdentity && Boolean(descriptor?.mode === "adopted" && processIsAlive(descriptor.pid));
  if (adoptingLiveHost) {
    const bridgeData = join(homePath, "bridge-data");
    ensurePrivateDirectory(bridgeData);
    app.setName("Biscuit Web Bridge");
    app.setPath("userData", bridgeData);
    app.setPath("sessionData", bridgeData);
  } else {
    const profilePath = profileIdentity?.userDataPath ?? descriptor?.userDataPath ?? join(homePath, "profile");
    ensurePrivateDirectory(profilePath);
    const appName = profileIdentity?.appName ?? descriptor?.appName ?? "Biscuit Web";
    app.setName(appName);
    app.setPath("userData", profilePath);
    app.setPath("sessionData", profilePath);
  }
} catch {
  writeProtocol({ type: "fatal", category: "private_directory_invalid" });
  process.exit(1);
}

function reservePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") { server.close(); reject(new Error("configuration")); return; }
      const port = address.port;
      server.close(error => error ? reject(error) : resolvePort(port));
    });
  });
}
async function startApplication(): Promise<void> {
  if (!adoptingLiveHost) {
    debugPort = await reservePort();
    app.commandLine.appendSwitch("remote-debugging-address", "127.0.0.1");
    app.commandLine.appendSwitch("remote-debugging-port", String(debugPort));
  }
  await app.whenReady();
}
function routeSummary() {
  return [{ slug: MODEL_SLUG, displayName: "Browser-selected ChatGPT model", description: "Biscuit leaves the model selection in your ChatGPT browser unchanged. Plan and model availability still apply." }];
}
function publicStatus(connected: boolean, needsReconnect: boolean): Record<string, unknown> {
  return {
    type: "status",
    connected,
    needsReconnect,
    browserRuntimeAvailable: true,
    canDisconnect: descriptor?.mode === "managed",
    modelRoutes: connected ? routeSummary() : [],
    ...(connected ? { defaultModelSlug: MODEL_SLUG } : {}),
  };
}
async function endpointForHost(): Promise<string> {
  if (adoptingLiveHost) {
    if (!descriptor || !processIsAlive(descriptor.pid)) throw new Error("ChatGPT browser target is unavailable");
    return descriptor.cdpEndpoint;
  }
  return `http://127.0.0.1:${debugPort}`;
}
async function connectBrowser(): Promise<Browser> {
  if (browser?.isConnected()) return browser;
  browser = await chromium.connectOverCDP(await endpointForHost(), { timeout: 10_000, noDefaults: true });
  browserContext = browser.contexts()[0];
  if (!browserContext) throw new Error("ChatGPT browser target is unavailable");
  return browser;
}
async function getExactPage(): Promise<Page> {
  if (!adoptingLiveHost && !mainWindow) await createWindow(false);
  const connected = await connectBrowser();
  const context = browserContext ?? connected.contexts()[0];
  if (!context) throw new Error("ChatGPT browser target is unavailable");
  const pages = context.pages();
  for (const candidate of pages) {
    const candidateURL = candidate.url();
    if (!candidateURL || new URL(candidateURL).origin !== CHATGPT_ORIGIN) continue;
    const cdp = await context.newCDPSession(candidate);
    try {
      const { targetInfo } = await cdp.send("Target.getTargetInfo");
      if (adoptingLiveHost && targetInfo.targetId !== descriptor?.targetId) continue;
      if (!adoptingLiveHost && descriptor && descriptor.mode === "managed" && targetInfo.targetId !== descriptor.targetId) continue;
      page = candidate;
      return candidate;
    } finally { await cdp.detach(); }
  }
  throw new Error("ChatGPT browser target is unavailable");
}
async function waitForDebugEndpoint(): Promise<void> {
  const endpoint = `http://127.0.0.1:${debugPort}/json/list`;
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(endpoint, { signal: AbortSignal.timeout(1_000) });
      if (response.ok) return;
    } catch {}
    await wait(100);
  }
  throw new Error("browser_runtime_missing");
}
async function createWindow(visible: boolean): Promise<void> {
  if (adoptingLiveHost) throw new Error("reconnect_required");
  if (!mainWindow || mainWindow.isDestroyed()) {
    const ownedSession = session.fromPartition(profileIdentity?.partition ?? descriptor?.partition ?? PARTITION);
    const webPreferences = { session: ownedSession, sandbox: true, contextIsolation: true, nodeIntegration: false };
    mainWindow = new BrowserWindow({ width: 1080, height: 800, show: false, title: "ChatGPT Web · Biscuit", webPreferences });
    mainWindow.webContents.on("will-navigate", (event: { preventDefault(): void }, url: string) => { if (!isAllowedNavigation(url)) event.preventDefault(); });
    mainWindow.webContents.setWindowOpenHandler(({ url }: { url: string }) => isAllowedNavigation(url)
      ? { action: "allow", overrideBrowserWindowOptions: { webPreferences } }
      : { action: "deny" });
    mainWindow.webContents.on("did-create-window", (child: ElectronWindow) => {
      child.webContents.on("will-navigate", (event: { preventDefault(): void }, url: string) => { if (!isAllowedNavigation(url)) event.preventDefault(); });
      child.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    });
    await waitForDebugEndpoint();
    await mainWindow.loadURL(CHATGPT_ORIGIN);
    const targetResponse = await fetch(`http://127.0.0.1:${debugPort}/json/list`);
    if (!targetResponse.ok) throw new Error("browser_runtime_missing");
    const parsedTargets = DebugTargetListSchema.safeParse(await targetResponse.json());
    if (!parsedTargets.success) throw new Error("browser_runtime_missing");
    const ownedTarget = parsedTargets.data.find(item => {
      try { return item.type === "page" && new URL(item.url).origin === CHATGPT_ORIGIN; }
      catch { return false; }
    });
    if (!ownedTarget) throw new Error("ChatGPT browser target is unavailable");
    const previous = descriptor;
    descriptor = {
      schema: "biscuit.chatgpt-web.electron-host.v1",
      mode: "managed",
      pid: process.pid,
      executablePath: process.execPath,
      userDataPath: app.getPath("userData"),
      appName: profileIdentity?.appName ?? previous?.appName ?? "Biscuit Web",
      partition: profileIdentity?.partition ?? previous?.partition ?? PARTITION,
      cdpEndpoint: `http://127.0.0.1:${debugPort}`,
      targetId: ownedTarget.id,
      sessionVerified: previous?.sessionVerified ?? false,
    };
    writeDescriptor(descriptor);
  }
  if (visible && mainWindow && !mainWindow.isDestroyed()) mainWindow.showInactive();
}
async function authenticatedStatus(): Promise<boolean> {
  try {
    const candidate = await getExactPage();
    if (new URL(candidate.url()).origin !== CHATGPT_ORIGIN) return false;
    const result = await candidate.evaluate(CHATGPT_SESSION_CHECK_SCRIPT);
    return result?.sessionAuthenticated === true;
  } catch { return false; }
}
async function handleStatus(id?: string, reconcileStopState = false): Promise<void> {
  if (!adoptingLiveHost && !mainWindow) await createWindow(false);
  const connected = await authenticatedStatus();
  if (generationStopUnconfirmed && reconcileStopState) {
    if (!connected || !await reconcileUnconfirmedPage()) {
      sendError(id, "generation_stop_unconfirmed");
      return;
    }
    generationStopUnconfirmed = false;
    unconfirmedStopIdentity = undefined;
  }
  writeProtocol({ ...publicStatus(connected, !connected && Boolean(descriptor?.sessionVerified)), ...(id ? { id } : {}) });
}
async function handleLogin(id: string, value: Record<string, unknown>): Promise<void> {
  if (generationStopUnconfirmed) { sendError(id, "generation_stop_unconfirmed"); return; }
  if (shuttingDown || disconnecting || activeLogin || activeRuns.size > 0) { sendError(id, "busy"); return; }
  if (adoptingLiveHost) {
    if (await authenticatedStatus()) writeProtocol({ type: "login_succeeded", id, modelRoutes: routeSummary() });
    else sendError(id, "reconnect_required");
    return;
  }
  const timeoutValue = value.timeoutMs;
  const timeoutMs = typeof timeoutValue === "number" && Number.isFinite(timeoutValue)
    ? Math.max(30_000, Math.min(LOGIN_TIMEOUT_MS, Math.floor(timeoutValue))) : LOGIN_TIMEOUT_MS;
  const controller = new AbortController();
  const active: ActiveLogin = { id, controller, continueRequested: false, task: Promise.resolve() };
  activeLogin = active;
  writeProtocol({ type: "login_started", id });
  active.task = (async () => {
    const deadline = Date.now() + timeoutMs;
    try {
      await createWindow(true);
      await getExactPage();
      writeProtocol({ type: "login_browser_opened", id });
      while (!controller.signal.aborted && Date.now() < deadline) {
        if (active.continueRequested && await authenticatedStatus()) {
          if (descriptor?.mode === "managed") {
            descriptor = { ...descriptor, sessionVerified: true };
            writeDescriptor(descriptor);
          }
          writeProtocol({ type: "login_succeeded", id, modelRoutes: routeSummary() });
          return;
        }
        await wait(250, controller.signal);
      }
      if (controller.signal.aborted) throw controller.signal.reason;
      writeProtocol({ type: "login_failed", id, category: "timeout", previousSessionRetained: false });
    } catch (error) {
      writeProtocol({ type: "login_failed", id, category: errorCategory(error, controller.signal), previousSessionRetained: false });
    } finally {
      if (activeLogin === active) activeLogin = undefined;
    }
  })();
}
function handleLoginContinue(id: string): void {
  if (activeLogin?.id === id) activeLogin.continueRequested = true;
}
function handleLoginCancel(id: string): void {
  if (activeLogin?.id !== id) return;
  activeLogin.controller.abort(new DOMException("ChatGPT Web sign-in canceled", "AbortError"));
}
function emitAnswerSnapshot(id: string, previous: string, current: string): void {
  if (current === previous) return;
  if (current.startsWith(previous)) writeProtocol({ type: "delta", id, text: current.slice(previous.length) });
  else writeProtocol({ type: "snapshot", id, text: current });
  outputTail.set(id, current);
}
async function runRequest(id: string, value: Record<string, unknown>, active: ActiveRun): Promise<Record<string, unknown>> {
  const validation = validateRequest(value.text, value.instructions, value.modelSlug);
  if (validation) return { type: "error", id, category: validation };
  const text = value.text as string;
  const instructions = value.instructions as string;
  const started = Date.now();
  const timer = setTimeout(() => abortRun(active, new DOMException("ChatGPT Web request timed out", "TimeoutError")), TURN_TIMEOUT_MS);
  const routes = new Set<string>();
  let network: CDPSession | undefined;
  let terminal: Record<string, unknown>;
  try {
    const candidate = await awaitActiveStep(active.controller.signal, () => getExactPage());
    active.page = candidate;
    if (new URL(candidate.url()).origin !== CHATGPT_ORIGIN) throw new Error("ChatGPT browser target is unavailable");
    await awaitActiveStep(active.controller.signal, () => candidate.goto(chatGptNewChatUrl(true), { waitUntil: "domcontentloaded", timeout: 60_000 }));
    await awaitActiveStep(active.controller.signal, () => assertNewChatPage(candidate, true));
    const composer = candidate.locator(CHATGPT_COMPOSER_SELECTOR).filter({ visible: true });
    await awaitActiveStep(active.controller.signal, () => composer.waitFor({ state: "visible", timeout: 30_000 }));
    if (!await awaitActiveStep(active.controller.signal, () => authenticatedStatus())) throw new Error("reconnect_required");
    await awaitActiveStep(active.controller.signal, () => assertAuthenticatedChatGptPage(candidate));
    const composerCount = await awaitActiveStep(active.controller.signal, () => composer.count());
    const userTurnCount = await awaitActiveStep(active.controller.signal, () => candidate.locator(CHATGPT_USER_TURN_SELECTOR).count());
    const assistantTurnCount = await awaitActiveStep(active.controller.signal, () => candidate.locator(CHATGPT_ASSISTANT_TURN_SELECTOR).count());
    const composerText = await awaitActiveStep(active.controller.signal, () => composer.innerText());
    if (composerCount !== 1 || userTurnCount !== 0 || assistantTurnCount !== 0 || composerText.trim()) {
      throw new Error("fresh_unambiguous_chat_required");
    }
    network = await awaitActiveStep(active.controller.signal, () => (browserContext ?? candidate.context()).newCDPSession(candidate));
    network.on("Network.requestWillBeSent", (event: { request: { method: string; url: string } }) => {
      try {
        const url = new URL(event.request.url);
        if (event.request.method === "POST" && url.origin === CHATGPT_ORIGIN
          && /^\/backend-api\/f\/conversation(?:\/prepare)?$/.test(url.pathname)) {
          routes.add(url.pathname);
          if (url.pathname === "/backend-api/f/conversation") active.conversationRouteObserved = true;
        }
      } catch {}
    });
    await awaitActiveStep(active.controller.signal, () => network!.send("Network.enable"));
    const prompt = `${instructions}\n\n${text}`;
    await awaitActiveStep(active.controller.signal, () => composer.click());
    if (!await awaitActiveStep(active.controller.signal, () => composer.evaluate(insertPlainTextIntoComposer, prompt))) {
      throw new Error("upstream_composer_insertion_failed");
    }
    const send = composer.locator("xpath=ancestor::form[1]").locator(CHATGPT_SEND_BUTTON_SELECTOR).filter({ visible: true });
    if (await awaitActiveStep(active.controller.signal, () => send.count()) !== 1) throw new Error("unambiguous_submitter_required");
    active.submissionStarted = true;
    try {
      try {
        const click = send.click({ timeout: 5_000 });
        active.submissionTask = click.then(
          () => { active.submitted = true; },
          error => { active.submissionUncertain = true; throw error; },
        );
        await active.submissionTask;
      } catch (error) {
        active.submissionUncertain = true;
        throw error;
      }
    } finally {
      active.submissionStarted = false;
      active.submissionTask = undefined;
    }
    if (active.controller.signal.aborted) {
      throw active.controller.signal.reason ?? new DOMException("ChatGPT Web request canceled", "AbortError");
    }
    writeProtocol({ type: "started", id });
    const tracker = new ChatGptCompletionTracker();
    const deadline = Date.now() + TURN_TIMEOUT_MS;
    let answer: string | undefined;
    while (Date.now() < deadline) {
      if (active.controller.signal.aborted) throw active.controller.signal.reason;
      await throwIfChatGptRateLimitDialog(candidate);
      await throwIfChatGptSessionFailureAlert(candidate);
      await throwIfChatGptToolApprovalRequired(candidate);
      const assistants = candidate.locator(CHATGPT_ASSISTANT_TURN_SELECTOR).filter({ visible: true });
      const count = await assistants.count();
      if (count > 1) throw new Error("ambiguous_fresh_response");
      if (count === 1) {
        const assistant = assistants.first();
        await throwIfChatGptTerminalErrorAlert(assistant);
        const response = await assistant.evaluate((element, completionSelector) => {
          const body = element.querySelector('.markdown, [data-message-author-role="assistant"] .puik-root.not-markdown > [class*="_DilResponseRoot"], [data-markdown-text-style="assistant-message"]');
          if (!(body instanceof HTMLElement)) return null;
          const complete = [...element.querySelectorAll(completionSelector)].some(button => button instanceof HTMLElement
            && button.getClientRects().length > 0 && Boolean(body.compareDocumentPosition(button) & Node.DOCUMENT_POSITION_FOLLOWING));
          return { text: body.innerText, html: body.innerHTML, complete };
        }, CHATGPT_COMPLETION_ACTION_SELECTOR);
        if (response && response.text) {
          const previous = outputTail.get(id) ?? "";
          emitAnswerSnapshot(id, previous, response.text);
          const running = await chatGptStopButton(candidate).isVisible();
          if (tracker.update({ responsePresent: true, running, currentText: response.text, currentHtml: response.html, completionActionVisible: response.complete })) {
            answer = response.text;
            break;
          }
        }
      }
      await wait(200, active.controller.signal);
    }
    if (!answer) throw new Error("public_response_deadline");
    if (!routes.has("/backend-api/f/conversation")) throw new Error("web_conversation_route_not_observed");
    terminal = { type: "done", id, routes: [...routes], milliseconds: Date.now() - started };
  } catch (error) {
    const settlement = await settleRequestError(
      active,
      errorCategory(error, active.controller.signal),
      async () => {
        if (!active.page) throw new Error("generation_stop_unconfirmed");
        return await stopChatGptGeneration(active.page, () => active.conversationRouteObserved === true);
      },
      () => rememberUnconfirmedStop(active.page, active.conversationRouteObserved === true),
    );
    terminal = { type: "error", id, ...settlement };
  } finally {
    clearTimeout(timer);
    if (network) await network.detach().catch(() => {});
    outputTail.delete(id);
  }
  return terminal;
}
function handleRun(id: string, value: Record<string, unknown>): void {
  if (generationStopUnconfirmed) { sendError(id, "generation_stop_unconfirmed"); return; }
  if (shuttingDown || disconnecting || activeLogin) { sendError(id, "busy"); return; }
  if (activeRuns.has(id) || activeRuns.size > 0) { sendError(id, "busy"); return; }
  const active: ActiveRun = {
    controller: new AbortController(), task: Promise.resolve(), submissionStarted: false, submitted: false,
  };
  activeRuns.set(id, active);
  active.task = runRequest(id, value, active).then(
    terminal => {
      if (activeRuns.get(id) === active) activeRuns.delete(id);
      writeProtocol(terminal);
    },
    error => {
      if (activeRuns.get(id) === active) activeRuns.delete(id);
      sendError(id, errorCategory(error, active.controller.signal));
    },
  );
}
function handleRunCancel(id: string): void {
  const active = activeRuns.get(id);
  if (!active) { sendError(id, "cancelled"); return; }
  abortRun(active, new DOMException("ChatGPT Web request canceled", "AbortError"));
}
async function handleDisconnect(id: string): Promise<void> {
  if (adoptingLiveHost || generationStopUnconfirmed) { sendError(id, "disconnect_failed"); return; }
  if (disconnecting) { sendError(id, "busy"); return; }
  disconnecting = true;
  try {
    for (const active of activeRuns.values()) abortRun(active, new DOMException("ChatGPT Web disconnected", "AbortError"));
    if (activeLogin) activeLogin.controller.abort(new DOMException("ChatGPT Web disconnected", "AbortError"));
    if (browser?.isConnected()) await browser.close();
    browser = undefined;
    browserContext = undefined;
    page = undefined;
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.destroy();
    mainWindow = undefined;
    if (descriptor && descriptor.mode === "managed") {
      const profilePath = descriptor.userDataPath;
      if (profilePath === join(homePath, "profile")) rmSync(profilePath, { recursive: true, force: true });
      rmSync(hostDescriptorPath, { force: true });
      descriptor = undefined;
    }
    writeProtocol({ type: "disconnected", id });
  } catch { sendError(id, "disconnect_failed"); }
  finally { disconnecting = false; }
}
async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const active of activeRuns.values()) abortRun(active, new DOMException("Biscuit is shutting down", "AbortError"));
  if (activeLogin) activeLogin.controller.abort(new DOMException("Biscuit is shutting down", "AbortError"));
  await Promise.allSettled([...activeRuns.values()].map(active => active.task));
  try { if (browser?.isConnected()) await browser.close(); }
  catch { writeProtocol({ type: "fatal", category: "cleanup_failed" }); }
  if (!adoptingLiveHost && mainWindow && !mainWindow.isDestroyed()) mainWindow.destroy();
  app.quit();
}
function sendError(id: string | undefined, category: string): void {
  writeProtocol({ type: "error", ...(id ? { id } : {}), category });
}
function dispatch(value: unknown): void {
  if (!value || typeof value !== "object" || Array.isArray(value)) { sendError(undefined, "invalid_protocol_message"); return; }
  const message = value as Record<string, unknown>;
  if (typeof message.type !== "string") { sendError(undefined, "invalid_protocol_message"); return; }
  const id = typeof message.id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(message.id) ? message.id : undefined;
  switch (message.type) {
    case "status": {
      if (message.reconcileStopState !== undefined && typeof message.reconcileStopState !== "boolean") {
        sendError(id, "invalid_request");
        return;
      }
      void handleStatus(id, message.reconcileStopState === true);
      return;
    }
    case "login": if (id) void handleLogin(id, message); else sendError(undefined, "invalid_request_id"); return;
    case "login_continue": if (id) handleLoginContinue(id); return;
    case "login_cancel": if (id) handleLoginCancel(id); return;
    case "run": if (id) handleRun(id, message); else sendError(undefined, "invalid_request_id"); return;
    case "run_cancel": if (id) handleRunCancel(id); else sendError(undefined, "invalid_request_id"); return;
    case "disconnect": if (id) void handleDisconnect(id); else sendError(undefined, "invalid_request_id"); return;
    case "shutdown": void shutdown(); return;
    default: sendError(id, "unsupported_operation");
  }
}

export async function start(): Promise<void> {
  try {
    await startApplication();
    writeProtocol({ type: "ready", protocolVersion: 1 });
    const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
    for await (const line of lines) {
      if (line.length > MAX_LINE_CHARS) { sendError(undefined, "protocol_message_too_large"); continue; }
      try { dispatch(JSON.parse(line)); } catch { sendError(undefined, "invalid_protocol_message"); }
    }
    await shutdown();
  } catch (error) {
    writeProtocol({ type: "fatal", category: errorCategory(error) });
    process.exitCode = 1;
    app.quit();
  }
}
