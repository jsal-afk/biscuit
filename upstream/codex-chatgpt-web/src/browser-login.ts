import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { chromium, type BrowserContext, type BrowserContextOptions } from "playwright-core";
import type { AppConfig } from "./config";
import { atomicWriteFile } from "./config";
import {
  assertAuthenticatedChatGptPage,
  assertNewChatPage,
  CHATGPT_NEW_CHAT_URL,
  detectChatGptAccountCapabilities,
} from "./chatgpt-session";
import { CHATGPT_COMPOSER_SELECTOR } from "./chatgpt-ui/composer";
import type { ChatGptWebAccountCapabilities } from "./chatgpt-web-models";
import { sanitizeBrowserStorageState, type BrowserStorageState } from "./browser-storage-state";

export type BrowserLoginStorageState = Exclude<NonNullable<BrowserContextOptions["storageState"]>, string>;

export interface ManagedBrowserLoginCapture {
  storageState: BrowserLoginStorageState;
}

export interface ManagedBrowserLoginOptions {
  continuation: Promise<void>;
  timeoutMs?: number;
  onBrowserOpened?: () => void;
  signal?: AbortSignal;
}

interface LoginVerificationMarker {
  version: 1;
  authenticated: true;
  verifiedAt: string;
  solAvailable?: boolean;
  extraHighAvailable?: boolean;
  proAvailable?: boolean;
}

const MANAGED_LOGIN_TIMEOUT_MS = 10 * 60_000;
const CHATGPT_ORIGIN = new URL(CHATGPT_NEW_CHAT_URL).origin;

function removeTemporaryChromiumTabSessions(profileDir: string): void {
  const defaultProfile = join(profileDir, "Default");
  rmSync(join(defaultProfile, "Sessions"), { recursive: true, force: true });
  for (const name of ["Current Session", "Current Tabs", "Last Session", "Last Tabs"]) {
    rmSync(join(defaultProfile, name), { force: true });
  }
}
function browserProcessExited(browser: ChildProcess): boolean {
  return browser.exitCode !== null || browser.signalCode !== null;
}

async function waitForBrowserExit(browser: ChildProcess, timeoutMs: number): Promise<boolean> {
  if (browserProcessExited(browser)) return true;
  const { promise, resolve } = Promise.withResolvers<boolean>();
  let settled = false;
  const finish = (exited: boolean) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    browser.off("exit", onExit);
    resolve(exited);
  };
  const onExit = () => finish(true);
  const timer = setTimeout(() => finish(false), timeoutMs);
  browser.once("exit", onExit);
  if (browserProcessExited(browser)) finish(true);
  return await promise;
}

async function stopOwnedLoginBrowser(browser: ChildProcess): Promise<void> {
  if (browserProcessExited(browser) || !Number.isInteger(browser.pid)) return;
  const graceful = waitForBrowserExit(browser, 5_000);
  if (!browser.kill() && !browserProcessExited(browser)) {
    throw new Error("The dedicated Chromium login process refused to close");
  }
  if (await graceful) return;
  const forced = waitForBrowserExit(browser, 5_000);
  if (!browser.kill("SIGKILL") && !browserProcessExited(browser)) {
    throw new Error("The dedicated Chromium login process refused forced termination");
  }
  if (!await forced) throw new Error("The dedicated Chromium login process did not exit");
}

export function sanitizeBrowserLoginStorageState(
  storageState: BrowserLoginStorageState,
): BrowserLoginStorageState {
  return sanitizeBrowserStorageState(
    storageState as unknown as BrowserStorageState,
    CHATGPT_ORIGIN,
  ) as unknown as BrowserLoginStorageState;
}

export function loginVerificationMarkerPath(storageStatePath: string): string {
  return `${storageStatePath}.verified.json`;
}

function writeVerificationMarker(
  storageStatePath: string,
  capabilities: ChatGptWebAccountCapabilities,
): void {
  const marker: LoginVerificationMarker = {
    version: 1,
    authenticated: true,
    verifiedAt: new Date().toISOString(),
    ...capabilities,
  };
  atomicWriteFile(loginVerificationMarkerPath(storageStatePath), `${JSON.stringify(marker)}\n`);
}


async function awaitWithAbort<T>(
  operation: Promise<T>,
  signal?: AbortSignal,
  closeLate?: (value: T) => void | Promise<void>,
): Promise<T> {
  if (!signal) return operation;
  if (signal.aborted) {
    if (closeLate) void operation.then(
      value => { void Promise.resolve(closeLate(value)).catch(() => {}); },
      () => {},
    );
    else void operation.catch(() => {});
    throw signal.reason instanceof Error ? signal.reason : new Error("ChatGPT Web operation aborted");
  }
  let onAbort!: () => void;
  const { promise: aborted, reject: rejectAbort } = Promise.withResolvers<never>();
  onAbort = () => rejectAbort(signal.reason instanceof Error ? signal.reason : new Error("ChatGPT Web operation aborted"));
  signal.addEventListener("abort", onAbort, { once: true });
  try {
    return await Promise.race([operation, aborted]);
  } catch (error) {
    if (signal.aborted && closeLate) void operation.then(
      value => { void Promise.resolve(closeLate(value)).catch(() => {}); },
      () => {},
    );
    throw error;
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

async function inspectStoredState(
  config: Pick<AppConfig, "chromeExecutablePath">,
  storageState: NonNullable<BrowserContextOptions["storageState"]>,
  signal?: AbortSignal,
): Promise<ChatGptWebAccountCapabilities & { url: string }> {
  const launch = chromium.launch({
    executablePath: config.chromeExecutablePath,
    headless: false,
    chromiumSandbox: true,
    args: ["--no-first-run", "--no-default-browser-check"],
  });
  const verifierBrowser = await awaitWithAbort(launch, signal, browser => browser.close());
  try {
    const verify = async () => {
      const verifierContext = await verifierBrowser.newContext({ storageState });
      try {
        const verifierPage = await verifierContext.newPage();
        await verifierPage.goto(CHATGPT_NEW_CHAT_URL, { waitUntil: "domcontentloaded", timeout: 60_000 });
        await verifierPage.locator(CHATGPT_COMPOSER_SELECTOR).filter({ visible: true }).first().waitFor({ state: "visible", timeout: 60_000 });
        await assertAuthenticatedChatGptPage(verifierPage);
        await assertNewChatPage(verifierPage);
        return { ...await detectChatGptAccountCapabilities(verifierPage), url: verifierPage.url() };
      } finally {
        await verifierContext.close();
      }
    };
    return await awaitWithAbort(verify(), signal);
  } finally {
    await verifierBrowser.close();
  }
}


export async function inspectBrowserLoginCapabilities(config: AppConfig): Promise<ChatGptWebAccountCapabilities> {
  if (!browserLoginStateExists(config)) throw new Error("ChatGPT login state is missing or unverified");
  const inspected = await inspectStoredState(config, config.storageStatePath);
  writeVerificationMarker(config.storageStatePath, inspected);
  return { solAvailable: inspected.solAvailable, extraHighAvailable: inspected.extraHighAvailable, proAvailable: inspected.proAvailable };
}

export function storedBrowserLoginCapabilities(
  config: AppConfig,
): Partial<ChatGptWebAccountCapabilities> {
  if (!browserLoginStateExists(config)) return {};
  try {
    const marker = JSON.parse(readFileSync(loginVerificationMarkerPath(config.storageStatePath), "utf8")) as Partial<LoginVerificationMarker>;
    return {
      ...(typeof marker.solAvailable === "boolean" ? { solAvailable: marker.solAvailable } : {}),
      ...(typeof marker.extraHighAvailable === "boolean" ? { extraHighAvailable: marker.extraHighAvailable } : {}),
      ...(typeof marker.proAvailable === "boolean" ? { proAvailable: marker.proAvailable } : {}),
    };
  } catch {
    return {};
  }
}

export async function captureManagedBrowserLogin(
  config: Pick<AppConfig, "chromeExecutablePath" | "storageStatePath">,
  options: ManagedBrowserLoginOptions,
): Promise<ManagedBrowserLoginCapture> {
  if (process.platform !== "darwin") {
    throw new Error("Biscuit managed Chromium login is supported only on macOS");
  }
  if (!existsSync(config.chromeExecutablePath)) {
    throw new Error("Biscuit Chromium runtime is missing");
  }
  const timeoutMs = options.timeoutMs ?? MANAGED_LOGIN_TIMEOUT_MS;
  if (!Number.isFinite(timeoutMs) || timeoutMs < 1) {
    throw new Error("ChatGPT sign-in timeout must be a positive finite number");
  }
  if (options.signal?.aborted) {
    throw options.signal.reason instanceof Error ? options.signal.reason : new Error("ChatGPT Web operation aborted");
  }
  const deadline = Date.now() + timeoutMs;
  const remainingTime = () => {
    const remaining = deadline - Date.now();
    if (remaining < 1) throw new Error("Timed out waiting for ChatGPT sign-in");
    return remaining;
  };

  const profileParent = dirname(config.storageStatePath);
  mkdirSync(profileParent, { recursive: true, mode: 0o700 });
  try { chmodSync(profileParent, 0o700); } catch {}
  const profileDir = mkdtempSync(join(profileParent, "login-profile-"));
  try { chmodSync(profileDir, 0o700); } catch {}
  let capture: ManagedBrowserLoginCapture | undefined;
  let context: BrowserContext | undefined;
  let loginBrowser: ChildProcess | undefined;
  let primaryError: unknown;
  try {
    loginBrowser = spawn(config.chromeExecutablePath, [
      `--user-data-dir=${profileDir}`,
      "--new-window",
      "--disable-background-mode",
      "--no-first-run",
      "--no-default-browser-check",
      CHATGPT_NEW_CHAT_URL,
    ], { env: process.env, stdio: "ignore" });
    const browser = loginBrowser;
    const { promise: browserExited, reject: rejectBrowserExit } = Promise.withResolvers<never>();
    const { promise: browserStarted, resolve: resolveBrowserStarted } = Promise.withResolvers<void>();
    browser.once("spawn", resolveBrowserStarted);
    browser.once("exit", () => rejectBrowserExit(new Error("Dedicated Chromium login window closed before Continue")));
    browser.once("error", () => rejectBrowserExit(new Error("Dedicated Chromium login could not be started")));
    const { promise: timeoutPromise, reject: rejectTimeout } = Promise.withResolvers<never>();
    const timeout = setTimeout(() => rejectTimeout(new Error("Timed out waiting for ChatGPT sign-in")), remainingTime());
    try {
      await awaitWithAbort(Promise.race([browserStarted, browserExited, timeoutPromise]), options.signal);
      options.signal?.throwIfAborted();
      options.onBrowserOpened?.();
      await awaitWithAbort(Promise.race([options.continuation, browserExited, timeoutPromise]), options.signal);
    } finally {
      clearTimeout(timeout);
    }

    await stopOwnedLoginBrowser(browser);
    loginBrowser = undefined;
    removeTemporaryChromiumTabSessions(profileDir);
    context = await awaitWithAbort(chromium.launchPersistentContext(profileDir, {
      executablePath: config.chromeExecutablePath,
      headless: true,
      chromiumSandbox: true,
      offline: true,
      serviceWorkers: "block",
      ignoreDefaultArgs: [
        "--no-sandbox",
        "--enable-automation",
        "--password-store=basic",
        "--use-mock-keychain",
      ],
      args: [
        "--disable-background-mode",
        "--disable-background-networking",
        "--no-first-run",
        "--no-default-browser-check",
        "--restore-last-session",
      ],
      timeout: Math.min(30_000, remainingTime()),
    }), options.signal, launchedContext => launchedContext.close());
    await awaitWithAbort(context.setOffline(true), options.signal);
    await context.route("**/*", route => route.fulfill({
      status: 200,
      contentType: "text/html",
      body: "<!doctype html><meta charset=\"utf-8\"><title>Private login-state capture</title>",
    }));
    const capturePage = context.pages()[0] ?? await awaitWithAbort(context.newPage(), options.signal);
    await awaitWithAbort(capturePage.goto(CHATGPT_NEW_CHAT_URL, {
      waitUntil: "domcontentloaded",
      timeout: Math.min(60_000, remainingTime()),
    }), options.signal);
    if (new URL(capturePage.url()).origin !== CHATGPT_ORIGIN) {
      throw new Error("Offline ChatGPT login-state capture reached an unexpected origin");
    }
    const storageState = sanitizeBrowserLoginStorageState(await awaitWithAbort(context.storageState(), options.signal));
    if (storageState.cookies.length === 0) {
      throw new Error("The Biscuit Chromium profile contains no ChatGPT/OpenAI cookies");
    }
    capture = { storageState };
  } catch (error) {
    primaryError = error;
  }

  let cleanupError: unknown;
  try {
    if (loginBrowser && !browserProcessExited(loginBrowser)) await stopOwnedLoginBrowser(loginBrowser);
  } catch (error) {
    cleanupError = error;
  }
  try {
    if (context && !context.isClosed()) await context.close();
  } catch (error) {
    cleanupError ??= error;
  }
  try {
    rmSync(profileDir, { recursive: true, force: true });
  } catch (error) {
    cleanupError ??= error;
  }
  if (primaryError) {
    if (cleanupError) {
      throw new Error(
        `${primaryError instanceof Error ? primaryError.message : String(primaryError)}; temporary-profile cleanup also failed:`
        + ` ${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`,
      );
    }
    throw primaryError;
  }
  if (cleanupError) throw cleanupError;
  if (!capture) throw new Error("ChatGPT sign-in completed without capture evidence");
  return capture;
}

export async function captureManagedBrowserLoginToVerifiedFile(
  config: Pick<AppConfig, "chromeExecutablePath" | "storageStatePath">,
  options: ManagedBrowserLoginOptions,
): Promise<ChatGptWebAccountCapabilities> {
  const capture = await captureManagedBrowserLogin(config, options);
  if (options.signal?.aborted) {
    throw options.signal.reason instanceof Error ? options.signal.reason : new Error("ChatGPT Web operation aborted");
  }
  const inspected = await inspectStoredState(config, capture.storageState, options.signal);
  if (options.signal?.aborted) {
    throw options.signal.reason instanceof Error ? options.signal.reason : new Error("ChatGPT Web operation aborted");
  }
  const markerPath = loginVerificationMarkerPath(config.storageStatePath);
  const previousState = existsSync(config.storageStatePath) ? readFileSync(config.storageStatePath) : undefined;
  const previousMarker = existsSync(markerPath) ? readFileSync(markerPath) : undefined;
  rmSync(markerPath, { force: true });
  try {
    atomicWriteFile(config.storageStatePath, `${JSON.stringify(capture.storageState)}\n`);
    writeVerificationMarker(config.storageStatePath, {
      solAvailable: inspected.solAvailable,
      extraHighAvailable: inspected.extraHighAvailable,
      proAvailable: inspected.proAvailable,
    });
  } catch (error) {
    try {
      if (previousState) atomicWriteFile(config.storageStatePath, previousState);
      else rmSync(config.storageStatePath, { force: true });
      if (previousMarker) atomicWriteFile(markerPath, previousMarker);
      else rmSync(markerPath, { force: true });
    } catch (restoreError) {
      throw new AggregateError([error, restoreError], "ChatGPT Web session commit and rollback failed");
    }
    throw error;
  }
  return {
    solAvailable: inspected.solAvailable,
    extraHighAvailable: inspected.extraHighAvailable,
    proAvailable: inspected.proAvailable,
  };
}


export function browserLoginStateExists(config: AppConfig): boolean {
  if (!existsSync(config.storageStatePath)) return false;
  const markerPath = loginVerificationMarkerPath(config.storageStatePath);
  if (!existsSync(markerPath)) return false;
  try {
    const marker = JSON.parse(readFileSync(markerPath, "utf8")) as Partial<LoginVerificationMarker>;
    return marker.version === 1 && marker.authenticated === true && typeof marker.verifiedAt === "string";
  } catch {
    return false;
  }
}

