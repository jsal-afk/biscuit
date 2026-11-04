import { expect, mock, test } from "bun:test";
import * as fs from "node:fs";
import { delimiter, dirname, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { ChatGptWebAdapterError } from "../../codex-chatgpt-web/src/adapters/chatgpt-web/adapter-error";

type RecordValue = Record<string, unknown>;
type NetworkRequestEvent = { request: { method: string; url: string } };

class LineQueue implements AsyncIterable<string> {
  private values: string[] = [];
  private waiters: ((value: IteratorResult<string>) => void)[] = [];
  private closed = false;

  push(value: string): void {
    const waiter = this.waiters.shift();
    if (waiter) waiter({ value, done: false });
    else this.values.push(value);
  }

  close(): void {
    this.closed = true;
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<string> {
    return {
      next: () => {
        const value = this.values.shift();
        if (value !== undefined) return Promise.resolve({ value, done: false });
        if (this.closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise(resolve => this.waiters.push(resolve));
      },
    };
  }
}

class FakeLocator {
  constructor(readonly page: FakePage, readonly kind: string) {}

  filter(): FakeLocator { return this; }
  first(): FakeLocator { return this; }
  last(): FakeLocator { return this; }
  nth(): FakeLocator { return this; }
  getByTestId(testId: string): FakeLocator {
    return new FakeLocator(this.page, testId === "regenerate-thread-error-button" && this.page.scenario === "model-error" ? "model-error" : "hidden");
  }
  getByText(): FakeLocator { return new FakeLocator(this.page, "hidden"); }
  getByRole(): FakeLocator { return new FakeLocator(this.page, "hidden"); }
  locator(selector: string): FakeLocator {
    if (selector === "xpath=ancestor::form[1]") return new FakeLocator(this.page, "form");
    if (selector === "fixture-send") return new FakeLocator(this.page, "send");
    if (selector === "fixture-complete") return new FakeLocator(this.page, "complete");
    return this.page.locator(selector);
  }
  async count(): Promise<number> {
    switch (this.kind) {
      case "composer": case "send": return 1;
      case "user": return 0;
      case "assistant": return this.page.assistantPresent ? 1 : 0;
      case "complete": return this.page.completeVisible ? 1 : 0;
      default: return 0;
    }
  }
  async innerText(): Promise<string> {
    return this.kind === "composer" ? "" : this.page.assistantText;
  }
  async isVisible(): Promise<boolean> {
    if (this.kind === "stop") return this.page.stopVisible;
    if (this.kind === "complete") return this.page.completeVisible;
    if (this.kind === "model-error") return this.page.scenario === "model-error";
    if (this.kind.includes('[role="dialog"]')) {
      return this.kind.includes('[role="alert"]')
        ? ["auth-error", "unconfirmed-auth"].includes(this.page.scenario)
        : ["plan-limit", "cleanup-error"].includes(this.page.scenario);
    }
    return this.kind === "composer" && this.page.composerReady;
  }
  async isEnabled(): Promise<boolean> { return this.page.composerReady; }
  async isEditable(): Promise<boolean> { return this.page.composerReady; }
  async waitFor(options: { state: string }): Promise<void> {
    const visible = this.kind === "stop" ? this.page.stopVisible : this.page.composerReady;
    if ((options.state === "hidden" && visible) || (options.state === "visible" && !visible)) {
      const error = new Error("synthetic locator wait did not settle");
      error.name = "TimeoutError";
      throw error;
    }
  }
  async evaluate(_fn: unknown, _argument?: unknown): Promise<unknown> {
    if (this.kind === "composer") return true;
    if (this.kind === "assistant") {
      return {
        text: this.page.assistantText,
        html: `<div>${this.page.assistantText}</div>`,
        complete: this.page.completeVisible,
      };
    }
    return undefined;
  }
  async click(): Promise<void> {
    if (this.kind === "send") return this.page.submit();
    if (this.kind === "stop") return this.page.stop();
  }
}

class FakePage {
  scenario = "success";
  urlValue = "https://chatgpt.com/";
  composerReady = true;
  stopVisible = false;
  assistantPresent = false;
  assistantText = "";
  completeVisible = false;
  sendCount = 0;
  totalSendCount = 0;

  constructor(private readonly record: (value: RecordValue) => void, private readonly originalSetTimeout: typeof setTimeout) {}

  configure(scenario: string): void {
    this.scenario = scenario;
    this.sendCount = 0;
  }
  url(): string { return this.urlValue; }
  async goto(url: string): Promise<void> {
    this.urlValue = url;
    this.composerReady = true;
    this.stopVisible = false;
    this.assistantPresent = false;
    this.assistantText = "";
    this.completeVisible = false;
    if (this.scenario === "timeout-before-send") {
      await new Promise<void>(resolve => this.originalSetTimeout(resolve, 35));
    }
  }
  locator(selector: string): FakeLocator {
    const kind = selector === "fixture-composer" || selector.includes('data-testid="prompt-textarea"') ? "composer"
      : selector === "fixture-assistant" || selector.includes('[data-turn="assistant"]') ? "assistant"
        : selector === "fixture-user" || selector.includes('[data-turn="user"]') ? "user"
          : selector === "fixture-stop" || selector.includes('data-testid="stop-button"') ? "stop"
            : selector === "fixture-complete" || selector.includes('data-testid="copy-turn-action-button"') ? "complete"
              : selector === "fixture-send" || selector.includes('data-testid="send-button"') || selector.includes('button[type="submit"]') ? "send"
                : selector;
    return new FakeLocator(this, kind);
  }
  async evaluate(script: unknown): Promise<unknown> {
    if (typeof script === "string") return { sessionAuthenticated: true };
    return undefined;
  }
  async submit(): Promise<void> {
    this.sendCount += 1;
    this.totalSendCount += 1;
    const route = "https://chatgpt.com/backend-api/f/conversation";
    this.record({ type: "fixture_trace", event: "submission", scenario: this.scenario, route });
    currentNetworkSession?.requestWillBeSent({ request: { method: "POST", url: route } });

    if (this.scenario === "timeout-after-uncertain-send") {
      this.stopVisible = true;
      return new Promise((_, reject) => this.originalSetTimeout(() => reject(new Error("synthetic uncertain send")), 20));
    }
    if (this.scenario === "unconfirmed-auth") {
      this.stopVisible = true;
      return;
    }
    if (["plan-limit", "auth-error", "cleanup-error"].includes(this.scenario)) {
      this.stopVisible = true;
      return;
    }
    if (this.scenario === "model-error") {
      this.stopVisible = true;
      this.assistantPresent = true;
      this.assistantText = "synthetic model error response";
      return;
    }
    this.assistantPresent = true;
    this.assistantText = `answer:${this.scenario}`;
    this.completeVisible = true;
  }
  async stop(): Promise<void> {
    if (this.scenario !== "unconfirmed-auth") {
      this.stopVisible = false;
      this.record({ type: "fixture_trace", event: "stop_settled", scenario: this.scenario });
    }
  }
}

class FakeCDPSession {
  private listeners = new Map<string, (event: NetworkRequestEvent) => void>();
  private networkEnabled = false;
  private networkScenario: string | undefined;

  constructor(private readonly page: FakePage, private readonly record: (value: RecordValue) => void, private readonly getTargetId: () => string) {}
  on(event: string, listener: (event: NetworkRequestEvent) => void): void { this.listeners.set(event, listener); }
  async send(method: string): Promise<unknown> {
    if (method === "Target.getTargetInfo") return { targetInfo: { targetId: this.getTargetId() } };
    if (method === "Network.enable") {
      this.networkEnabled = true;
      this.networkScenario = this.page.scenario;
      currentNetworkSession = this;
    }
    return {};
  }
  requestWillBeSent(event: NetworkRequestEvent): void { this.listeners.get("Network.requestWillBeSent")?.(event); }
  async detach(): Promise<void> {
    if (!this.networkEnabled) return;
    this.networkEnabled = false;
    if (["cleanup-gate", "cleanup-error"].includes(String(this.networkScenario)) && cleanupGate) {
      this.record({ type: "fixture_trace", event: "network_detach_waiting", scenario: this.networkScenario });
      await cleanupGate.promise;
      this.record({ type: "fixture_trace", event: "network_detach_released", scenario: this.networkScenario });
    }
    this.record({ type: "fixture_trace", event: "network_detached", scenario: this.networkScenario });
  }
}

let currentNetworkSession: FakeCDPSession | undefined;
let cleanupGate: ReturnType<typeof Promise.withResolvers<void>> | undefined;

async function runConsumerContract(): Promise<void> {
  const packagedDriverPath = process.env.BISCUIT_ELECTRON_CONTRACT_DRIVER;
  const originalSetTimeout = globalThis.setTimeout;
  const originalEnvironment = {
    home: process.env.BISCUIT_CHATGPT_WEB_HOME,
    descriptor: process.env.BISCUIT_CHATGPT_WEB_DESCRIPTOR,
  };
  const fixtureHome = fs.mkdtempSync(join(tmpdir(), "biscuit-electron-contract-"));
  const profilePath = join(fixtureHome, "profile");
  fs.mkdirSync(profilePath, { recursive: true, mode: 0o700 });
  const profileMarker = join(profilePath, "preserved-marker");
  fs.writeFileSync(profileMarker, "synthetic authenticated-profile marker");
  const descriptorPath = join(fixtureHome, "electron-host.json");
  const expectedTargetId = "fixture-target-123456";
  fs.writeFileSync(descriptorPath, `${JSON.stringify({
    schema: "biscuit.chatgpt-web.electron-host.v1",
    mode: "adopted",
    pid: process.pid,
    executablePath: process.execPath,
    userDataPath: profilePath,
    appName: "Fixture",
    partition: "persist:fixture",
    cdpEndpoint: process.env.BISCUIT_ELECTRON_CONTRACT_DRIVER ? "http://127.0.0.1:1" : "http://127.0.0.1:9222",
    targetId: expectedTargetId,
    sessionVerified: true,
  })}\n`);
  process.env.BISCUIT_CHATGPT_WEB_HOME = fixtureHome;
  process.env.BISCUIT_CHATGPT_WEB_DESCRIPTOR = descriptorPath;

  const lines = new LineQueue();
  const output: RecordValue[] = [];
  const page = new FakePage(recordOutput, originalSetTimeout);
  let activePages: FakePage[] = [page];
  let targetId = expectedTargetId;
  let automaticNext: { afterId: string; id: string; scenario: string } | undefined;
  let browserClosed = false;
  const timeoutScenarios = new Set(["timeout-before-send", "timeout-after-uncertain-send"]);

  function recordOutput(value: RecordValue): void {
    output.push(value);
    if (automaticNext && (value.type === "done" || value.type === "error") && value.id === automaticNext.afterId) {
      const next = automaticNext;
      automaticNext = undefined;
      page.configure(next.scenario);
      lines.push(JSON.stringify({ type: "run", id: next.id, text: next.scenario, instructions: "offline fixture", modelSlug: "browser-selected" }));
    }
  }
  function protocolWrite(_fd: number, data: string | Uint8Array): number {
    const raw = typeof data === "string" ? data : Buffer.from(data).toString("utf8");
    for (const row of raw.split("\n")) {
      if (!row) continue;
      recordOutput(JSON.parse(row) as RecordValue);
    }
    return Buffer.byteLength(raw);
  }
  function send(value: RecordValue): void {
    if (value.type === "run") page.configure(String(value.text));
    lines.push(JSON.stringify(value));
  }
  async function waitFor(predicate: (value: RecordValue) => boolean, from = 0, timeoutMs = 5_000): Promise<{ value: RecordValue; index: number }> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = output.findIndex((value, position) => position >= from && predicate(value));
      if (index >= 0) return { value: output[index]!, index };
      await new Promise<void>(resolveWait => originalSetTimeout(resolveWait, 5));
    }
    throw new Error(`fixture protocol event timed out; observed=${JSON.stringify(output.slice(from))}`);
  }
  function runRecord(id: string, scenario: string): RecordValue {
    return { type: "run", id, text: scenario, instructions: "offline fixture", modelSlug: "browser-selected" };
  }

  const electron = {
    app: {
      setName() {},
      setPath() {},
      commandLine: { appendSwitch() {} },
      async whenReady() {},
      getPath() { return fixtureHome; },
      quit() {},
    },
    BrowserWindow: class {},
    session: { fromPartition() { return { setPermissionRequestHandler() {}, async clearStorageData() {} }; } },
  };
  const context = {
    pages: () => activePages,
    async newCDPSession(candidate: FakePage) { return new FakeCDPSession(candidate, recordOutput, () => targetId); },
  };
  const browser = {
    isConnected: () => true,
    contexts: () => [context],
    async close() { browserClosed = true; },
  };
  const chromium = { async connectOverCDP() { return browser; } };
  const upstreamRoot = resolve(import.meta.dir, "../../codex-chatgpt-web/src");

  cleanupGate = undefined;
  currentNetworkSession = undefined;
  mock.module("electron", () => electron);
  if (!packagedDriverPath) {
    mock.module("node:fs", () => ({ ...fs, writeSync: protocolWrite }));
    mock.module("node:readline", () => ({ createInterface: () => lines }));
    mock.module("playwright-core", () => ({ chromium }));
    mock.module(resolve(upstreamRoot, "chatgpt-session.ts"), () => ({
      assertAuthenticatedChatGptPage: async () => {},
      assertNewChatPage: async () => {},
      chatGptNewChatUrl: () => "https://chatgpt.com/",
    }));
    mock.module(resolve(upstreamRoot, "chatgpt-ui/composer.ts"), () => ({
      CHATGPT_COMPOSER_SELECTOR: "fixture-composer",
      CHATGPT_SEND_BUTTON_SELECTOR: "fixture-send",
      chatGptStopButton: (candidate: FakePage) => candidate.locator("fixture-stop"),
    }));
    mock.module(resolve(upstreamRoot, "chatgpt-ui/turns.ts"), () => ({
      CHATGPT_ASSISTANT_TURN_SELECTOR: "fixture-assistant",
      CHATGPT_COMPLETION_ACTION_SELECTOR: "fixture-complete",
      CHATGPT_USER_TURN_SELECTOR: "fixture-user",
    }));
    mock.module(resolve(upstreamRoot, "adapters/chatgpt-web/browser-worker.ts"), () => ({
      ChatGptCompletionTracker: class {
        update(value: { responsePresent: boolean; running: boolean; completionActionVisible: boolean }) {
          return value.responsePresent && !value.running && value.completionActionVisible;
        }
      },
      insertPlainTextIntoComposer: () => true,
      async throwIfChatGptRateLimitDialog(candidate: FakePage) {
        if (["plan-limit", "cleanup-error"].includes(candidate.scenario)) {
          throw new ChatGptWebAdapterError("quota=synthetic-secret", { status: 429, errorType: "rate_limit_error", code: "model_not_available", retryable: false });
        }
      },
      async throwIfChatGptSessionFailureAlert(candidate: FakePage) {
        if (["auth-error", "unconfirmed-auth"].includes(candidate.scenario)) {
          throw new ChatGptWebAdapterError("account=synthetic-secret", { status: 401, errorType: "authentication_error", code: "rate_limit_exceeded", retryable: false });
        }
      },
      async throwIfChatGptTerminalErrorAlert(scope: FakeLocator) {
        if (scope.page.scenario === "model-error") {
          throw new ChatGptWebAdapterError("model=synthetic-secret", { status: 400, errorType: "invalid_request_error", code: "model_not_available", retryable: false });
        }
      },
      async throwIfChatGptToolApprovalRequired() {},
    }));
  }

  const setTimeoutWithShortTurnDeadline: typeof setTimeout = (...parameters) => {
    const [callback, delay, ...args] = parameters;
    const mappedDelay = delay === 300_000 && timeoutScenarios.has(page.scenario) ? 10 : delay;
    return originalSetTimeout(callback, mappedDelay, ...args);
  };
  globalThis.setTimeout = setTimeoutWithShortTurnDeadline;

  let startTask: Promise<void> | undefined;
  let restoreCommonJsBuiltins: (() => void) | undefined;
  try {
    let driver: { start(): Promise<void> };
    if (packagedDriverPath) {
      const packagedRequire = createRequire(packagedDriverPath);
      const commonJsFs = packagedRequire("node:fs") as { writeSync: typeof fs.writeSync };
      const commonJsReadline = packagedRequire("node:readline") as { createInterface: (...args: unknown[]) => unknown };
      const originalWriteSync = commonJsFs.writeSync;
      const originalCreateInterface = commonJsReadline.createInterface;
      commonJsFs.writeSync = protocolWrite as typeof commonJsFs.writeSync;
      commonJsReadline.createInterface = (() => lines) as typeof commonJsReadline.createInterface;
      restoreCommonJsBuiltins = () => {
        commonJsFs.writeSync = originalWriteSync;
        commonJsReadline.createInterface = originalCreateInterface;
      };
      const packagedZodRoot = fs.realpathSync(resolve(dirname(packagedDriverPath), "node_modules", "zod"));
      const packagedZodPath = fs.realpathSync(packagedRequire.resolve("zod"));
      const packagedZodRelative = relative(packagedZodRoot, packagedZodPath);
      if (packagedZodRelative === ".." || packagedZodRelative.startsWith(`..${sep}`)) {
        throw new Error("packaged Electron driver resolved zod outside its frozen resources");
      }
      mock.module(packagedRequire.resolve("playwright-core"), () => ({ chromium }));
      driver = await import(pathToFileURL(packagedDriverPath).href) as { start(): Promise<void> };
    } else {
      // Resolve the actual locked package for Bun's transitive source import; never stub validation.
      const nodePathRoots = [
        ...(process.env.NODE_PATH?.split(delimiter) ?? []),
        resolve(import.meta.dir, "../../node_modules"),
      ];
      const zodModulePath = nodePathRoots
        .map(root => resolve(root, "zod/index.cjs"))
        .find(candidate => fs.existsSync(candidate));
      if (!zodModulePath) throw new Error("The actual locked zod package must be available through NODE_PATH or local node_modules");
      const zodModule = await import(pathToFileURL(zodModulePath).href);
      mock.module("zod", () => zodModule);
      driver = await import("../electron-driver");
    }
    startTask = driver.start();
    void startTask.catch(() => recordOutput({ type: "fixture_trace", event: "driver_start_failed" }));
    await waitFor(value => value.type === "ready");

    let from = output.length;
    automaticNext = { afterId: "invalid-first", id: "after-invalid", scenario: "after-invalid" };
    send({ type: "run", id: "invalid-first", text: "", instructions: "offline fixture", modelSlug: "browser-selected" });
    const invalid = await waitFor(value => value.type === "error" && value.id === "invalid-first", from);
    expect(invalid.value.category).toBe("invalid_request");
    const afterInvalidStarted = await waitFor(value => value.type === "started" && value.id === "after-invalid", invalid.index + 1);
    const afterInvalidDelta = await waitFor(value => value.type === "delta" && value.id === "after-invalid", afterInvalidStarted.index + 1);
    expect(afterInvalidDelta.value.text).toBe("answer:after-invalid");
    await waitFor(value => value.type === "done" && value.id === "after-invalid", afterInvalidDelta.index + 1);
    from = output.length;
    send(runRecord("before-timeout", "timeout-before-send"));
    const beforeTimeout = await waitFor(value => value.type === "error" && value.id === "before-timeout", from);
    expect(beforeTimeout.value).toEqual({ type: "error", id: "before-timeout", category: "timeout", remoteStopState: "not_submitted" });
    expect(page.sendCount).toBe(0);

    from = output.length;
    send(runRecord("uncertain-timeout", "timeout-after-uncertain-send"));
    const uncertainTimeout = await waitFor(value => value.type === "error" && value.id === "uncertain-timeout", from);
    expect(uncertainTimeout.value).toEqual({ type: "error", id: "uncertain-timeout", category: "timeout", remoteStopState: "stopped" });
    expect(page.sendCount).toBe(1);

    cleanupGate = Promise.withResolvers<void>();
    const cleanupStart = output.length;
    automaticNext = { afterId: "reuse-id", id: "distinct-next", scenario: "cleanup-second" };
    send(runRecord("reuse-id", "cleanup-gate"));
    await waitFor(value => value.type === "fixture_trace" && value.event === "network_detach_waiting", cleanupStart);
    const cleanupTerminalBeforeDetach = output.slice(cleanupStart).some(value => value.type === "done" && value.id === "reuse-id");
    cleanupGate.resolve(undefined);
    const firstDone = await waitFor(value => value.type === "done" && value.id === "reuse-id", cleanupStart);
    const firstDetach = (await waitFor(value => value.type === "fixture_trace" && value.event === "network_detached"
      && value.scenario === "cleanup-gate", cleanupStart)).index;
    const nextRun = await waitFor(value => value.type === "started" && value.id === "distinct-next"
      || value.type === "error" && value.id === "distinct-next" && value.category === "busy", firstDone.index + 1);
    const cleanupNextRequestAccepted = nextRun.value.type === "started";
    if (cleanupNextRequestAccepted) {
      const secondDelta = await waitFor(value => value.type === "delta" && value.id === "distinct-next", nextRun.index + 1);
      expect(secondDelta.value.text).toBe("answer:cleanup-second");
      await waitFor(value => value.type === "done" && value.id === "distinct-next", secondDelta.index + 1);
    }
    const cleanupTerminalAfterDetach = firstDetach < firstDone.index;

    cleanupGate = Promise.withResolvers<void>();
    const errorCleanupStart = output.length;
    automaticNext = { afterId: "cleanup-error", id: "after-error", scenario: "after-error" };
    send(runRecord("cleanup-error", "cleanup-error"));
    const stopSettled = await waitFor(value => value.type === "fixture_trace"
      && value.event === "stop_settled" && value.scenario === "cleanup-error", errorCleanupStart);
    await waitFor(value => value.type === "fixture_trace" && value.event === "network_detach_waiting"
      && value.scenario === "cleanup-error", errorCleanupStart);
    const errorTerminalBeforeDetach = output.slice(errorCleanupStart).some(value => value.type === "error" && value.id === "cleanup-error");
    cleanupGate.resolve(undefined);
    const cleanupError = await waitFor(value => value.type === "error" && value.id === "cleanup-error", errorCleanupStart);
    const errorDetach = (await waitFor(value => value.type === "fixture_trace" && value.event === "network_detached"
      && value.scenario === "cleanup-error", errorCleanupStart)).index;
    const afterError = await waitFor(value => value.type === "started" && value.id === "after-error"
      || value.type === "error" && value.id === "after-error" && value.category === "busy", cleanupError.index + 1);
    const errorNextRequestAccepted = afterError.value.type === "started";
    if (errorNextRequestAccepted) {
      const afterErrorDelta = await waitFor(value => value.type === "delta" && value.id === "after-error", afterError.index + 1);
      expect(afterErrorDelta.value.text).toBe("answer:after-error");
      await waitFor(value => value.type === "done" && value.id === "after-error", afterErrorDelta.index + 1);
    }
    const errorTerminalAfterDetach = errorDetach < cleanupError.index;
    const stopSettledBeforeErrorTerminal = stopSettled.index < cleanupError.index;

    const sameIdStart = output.length;
    automaticNext = { afterId: "same-id", id: "same-id", scenario: "same-id-reuse" };
    send(runRecord("same-id", "same-id-first"));
    const firstSameIdDone = await waitFor(value => value.type === "done" && value.id === "same-id", sameIdStart);
    const sameIdNext = await waitFor(value => value.type === "started" && value.id === "same-id"
      || value.type === "error" && value.id === "same-id" && value.category === "busy", firstSameIdDone.index + 1);
    const sameIdReuseAccepted = sameIdNext.value.type === "started";
    let sameIdReuseEmittedFullDelta = false;
    if (sameIdReuseAccepted) {
      const reusedResponse = await waitFor(value => (value.type === "delta" || value.type === "snapshot") && value.id === "same-id", sameIdNext.index + 1);
      sameIdReuseEmittedFullDelta = reusedResponse.value.type === "delta" && reusedResponse.value.text === "answer:same-id-reuse";
      await waitFor(value => value.type === "done" && value.id === "same-id", reusedResponse.index + 1);
    }

    for (const [id, scenario, expectedCategory] of [
      ["limit", "plan-limit", "plan_limit"],
      ["auth", "auth-error", "reconnect_required"],
      ["model", "model-error", "model_unavailable"],
    ] as const) {
      from = output.length;
      const sendsBefore = page.totalSendCount;
      send(runRecord(id, scenario));
      const result = await waitFor(value => value.type === "error" && value.id === id, from);
      const expectedObservedCategory = packagedDriverPath && scenario === "model-error" ? "browser_error" : expectedCategory;
      expect(result.value.category).toBe(expectedObservedCategory);
      expect(result.value.remoteStopState).toBe("stopped");
      expect(page.totalSendCount - sendsBefore).toBe(1);
    }
    expect(JSON.stringify(output)).not.toContain("synthetic-secret");
    expect(fs.existsSync(profileMarker)).toBe(true);
    expect(output.some(value => value.type === "login_succeeded" || value.type === "disconnected")).toBe(false);

    from = output.length;
    send({ type: "status", id: "status-after-auth", reconcileStopState: false });
    const authenticatedStatus = await waitFor(value => value.type === "status" && value.id === "status-after-auth", from);
    expect(authenticatedStatus.value.connected).toBe(true);

    from = output.length;
    send(runRecord("unconfirmed", "unconfirmed-auth"));
    const unconfirmed = await waitFor(value => value.type === "error" && value.id === "unconfirmed", from);
    expect(unconfirmed.value.category).toBe("generation_stop_unconfirmed");
    const blockedSubmissions = page.totalSendCount;
    send(runRecord("blocked-run", "success"));
    expect((await waitFor(value => value.type === "error" && value.id === "blocked-run", unconfirmed.index + 1)).value.category).toBe("generation_stop_unconfirmed");
    send({ type: "login", id: "blocked-login" });
    expect((await waitFor(value => value.type === "error" && value.id === "blocked-login", unconfirmed.index + 1)).value.category).toBe("generation_stop_unconfirmed");
    expect(page.totalSendCount).toBe(blockedSubmissions);

    const originalPage = page;
    const recoveryUrl = originalPage.urlValue;
    const wrongPage = new FakePage(recordOutput, originalSetTimeout);
    wrongPage.urlValue = originalPage.urlValue;
    activePages = [wrongPage];
    from = output.length;
    send({ type: "status", id: "wrong-page", reconcileStopState: true });
    expect((await waitFor(value => value.type === "error" && value.id === "wrong-page", from)).value.category).toBe("generation_stop_unconfirmed");

    activePages = [originalPage];
    targetId = "different-target-123456";
    from = output.length;
    send({ type: "status", id: "wrong-target", reconcileStopState: true });
    expect((await waitFor(value => value.type === "error" && value.id === "wrong-target", from)).value.category).toBe("generation_stop_unconfirmed");

    targetId = expectedTargetId;
    originalPage.urlValue = "https://chatgpt.com/c/wrong-url";
    from = output.length;
    send({ type: "status", id: "wrong-url", reconcileStopState: true });
    expect((await waitFor(value => value.type === "error" && value.id === "wrong-url", from)).value.category).toBe("generation_stop_unconfirmed");

    originalPage.urlValue = recoveryUrl;
    originalPage.stopVisible = false;
    originalPage.composerReady = true;
    from = output.length;
    send({ type: "status", id: "recovered-status", reconcileStopState: true });
    const recoveredStatus = await waitFor(value => value.type === "status" && value.id === "recovered-status", from);
    expect(recoveredStatus.value.connected).toBe(true);
    from = output.length;
    send(runRecord("after-recovery", "success-after-recovery"));
    await waitFor(value => value.type === "done" && value.id === "after-recovery", from);
    expect(page.totalSendCount).toBe(blockedSubmissions + 1);
    expect(fs.existsSync(profileMarker)).toBe(true);

    send({ type: "shutdown" });
    lines.close();
    await startTask;
    expect(browserClosed).toBe(true);
    const submissions = output.filter(value => value.type === "fixture_trace" && value.event === "submission");
    expect(submissions.every(value => value.route === "https://chatgpt.com/backend-api/f/conversation")).toBe(true);
    expect(submissions.filter(value => ["plan-limit", "auth-error", "model-error"].includes(String(value.scenario)))).toHaveLength(3);
    expect({
      validationNextAccepted: afterInvalidStarted.value.id === "after-invalid",
      cleanupSuccess: {
        terminalBeforeDetach: cleanupTerminalBeforeDetach,
        terminalAfterDetach: cleanupTerminalAfterDetach,
        distinctNextRequestAccepted: cleanupNextRequestAccepted,
      },
      cleanupError: {
        terminalBeforeDetach: errorTerminalBeforeDetach,
        stopSettledBeforeTerminal: stopSettledBeforeErrorTerminal,
        terminalAfterDetach: errorTerminalAfterDetach,
        distinctNextRequestAccepted: errorNextRequestAccepted,
        category: cleanupError.value.category,
      },
      sameIdReuseAccepted,
      sameIdReuseEmittedFullDelta,
    }).toEqual({
      validationNextAccepted: true,
      cleanupSuccess: { terminalBeforeDetach: false, terminalAfterDetach: true, distinctNextRequestAccepted: true },
      cleanupError: {
        terminalBeforeDetach: false,
        stopSettledBeforeTerminal: true,
        terminalAfterDetach: true,
        distinctNextRequestAccepted: true,
        category: "plan_limit",
      },
      sameIdReuseAccepted: true,
      sameIdReuseEmittedFullDelta: true,
    });
  } finally {
    lines.close();
    cleanupGate?.resolve(undefined);
    if (startTask) await Promise.race([startTask.catch(() => {}), new Promise(resolveWait => originalSetTimeout(resolveWait, 2_000))]);
    globalThis.setTimeout = originalSetTimeout;
    restoreCommonJsBuiltins?.();
    mock.restore();
    cleanupGate = undefined;
    currentNetworkSession = undefined;
    if (originalEnvironment.home === undefined) delete process.env.BISCUIT_CHATGPT_WEB_HOME;
    else process.env.BISCUIT_CHATGPT_WEB_HOME = originalEnvironment.home;
    if (originalEnvironment.descriptor === undefined) delete process.env.BISCUIT_CHATGPT_WEB_DESCRIPTOR;
    else process.env.BISCUIT_CHATGPT_WEB_DESCRIPTOR = originalEnvironment.descriptor;
    fs.rmSync(fixtureHome, { recursive: true, force: true });
  }
}
const sourceDriverPresent = fs.existsSync(resolve(import.meta.dir, "../electron-driver.ts"));
if (!sourceDriverPresent) {
  test.skip("source Electron driver is absent from this staged legacy suite", () => {});
} else if (process.env.BISCUIT_ELECTRON_CONTRACT_CHILD === "1") {
  test("current Electron driver offline consumer contract", runConsumerContract, process.env.BISCUIT_ELECTRON_CONTRACT_DRIVER ? 60_000 : 20_000);
} else {
  test("current Electron driver offline consumer contract in an isolated child", async () => {
    const child = Bun.spawn(
      [process.execPath, "test", join(import.meta.dir, "electron-driver-contract.test.ts")],
      {
        env: { ...process.env, BISCUIT_ELECTRON_CONTRACT_CHILD: "1" },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const [stdout, stderr] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    const exitCode = await child.exited;
    if (exitCode !== 0) throw new Error(`isolated Electron consumer failed (${exitCode})\n${stdout}\n${stderr}`);
  }, process.env.BISCUIT_ELECTRON_CONTRACT_DRIVER ? 75_000 : 30_000);
}
