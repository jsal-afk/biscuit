import { describe, expect, test } from "bun:test";
import type { AdapterEvent, CodexParsedRequest } from "../../codex-chatgpt-web/src/types";
import { providerEventCategory, safeProviderErrorCategory } from "../error-categories";
import { sanitizeBrowserStorageState, type BrowserStorageState } from "../../codex-chatgpt-web/src/browser-storage-state";
import { abortActiveRun, executeAdapterTurn } from "../run-turn";
import { abortActiveRequest, awaitActiveStep, MAX_INSTRUCTIONS_CHARS, MAX_TEXT_CHARS, MODEL_SLUG, reconcileUnconfirmedStop, settleRequestError, validateRequest, waitForStableStop, type StopOutcome, type StopRecoveryObservation } from "../request-lifecycle";
import { readChatGptAuthSession } from "../../codex-chatgpt-web/launcher/electron/chatgpt-auth-session.cjs";

function parsedFixture(): CodexParsedRequest {
  return {} as CodexParsedRequest;
}

function eventRecords(events: Record<string, unknown>[]): Record<string, unknown>[] {
  return events.filter(event => event.type === "done" || event.type === "error");
}
function deferred<T>() {
  const { promise, resolve } = Promise.withResolvers<T>();
  return { promise, resolve };
}

describe("ChatGPT Web sidecar protocol helpers", () => {
  test("establishes authentication from the server session before UI hydration and rejects invalid sessions", async () => {
    const cases = [
      { payload: { user: { id: "synthetic-user" }, accessToken: "synthetic-private-token" }, authenticated: true },
      { payload: { user: null }, authenticated: false },
      { payload: { user: { id: "synthetic-user" }, expires: "1970-01-01T00:00:00.000Z" }, authenticated: false },
      { payload: { user: { id: "synthetic-user" }, error: "RefreshTokenError" }, authenticated: false },
    ];
    for (const { payload, authenticated } of cases) {
      const result = await readChatGptAuthSession(
        async () => Response.json(payload), "https://chatgpt.com", 1_000,
      );
      expect(result.sessionAuthenticated).toBe(authenticated);
      expect(JSON.stringify(result)).not.toContain("synthetic-private-token");
      expect(JSON.stringify(result)).not.toContain("synthetic-user");
    }
    const unauthorized = await readChatGptAuthSession(
      async () => new Response(null, { status: 401 }), "https://chatgpt.com", 1_000,
    );
    expect(unauthorized.sessionAuthenticated).toBe(false);
  });
  test("maps plan limits and reconnect errors without exposing provider diagnostics", () => {
    expect(providerEventCategory({ type: "error", message: "quota detail", status: 429 })).toBe("plan_limit");
    expect(providerEventCategory({ type: "error", message: "account detail", status: 401 })).toBe("reconnect_required");
    expect(providerEventCategory({ type: "error", message: "account=private cookie=secret", code: "unknown_private_code" })).toBe("browser_error");
    expect(providerEventCategory({ type: "error", message: "private code detail", code: "toString" })).toBe("browser_error");
    expect(safeProviderErrorCategory(new Error("cookie=secret account=person@example.com"))).toBe("browser_error");
  });
  test("classifies ordinary-browser login failures without exposing provider diagnostics", () => {
    expect(safeProviderErrorCategory(new Error("Biscuit Chromium runtime is missing"))).toBe("browser_runtime_missing");
    expect(safeProviderErrorCategory(new Error("Timed out waiting for ChatGPT sign-in"))).toBe("timeout");
    expect(safeProviderErrorCategory(new Error("Dedicated Chromium login window closed before Continue"))).toBe("login_browser_closed");
    expect(safeProviderErrorCategory(new Error("cookie=private account=person@example.com"))).toBe("browser_error");
  });
  test("restricts persisted browser state to ChatGPT and OpenAI authentication", () => {
    const storageState = {
      cookies: [
        { name: "chatgpt", value: "synthetic-chat", domain: ".chatgpt.com", path: "/", expires: -1, httpOnly: true, secure: true, sameSite: "Lax" },
        { name: "openai", value: "synthetic-openai", domain: ".openai.com", path: "/", expires: -1, httpOnly: true, secure: true, sameSite: "Lax" },
        { name: "lookalike", value: "synthetic-other", domain: ".notchatgpt.com", path: "/", expires: -1, httpOnly: true, secure: true, sameSite: "Lax" },
        { name: "partitioned", value: "synthetic-partition", domain: ".chatgpt.com", path: "/", expires: -1, httpOnly: true, secure: true, sameSite: "Lax", partitionKey: "https://example.invalid" },
      ],
      origins: [
        { origin: "https://chatgpt.com", localStorage: [{ name: "auth", value: "synthetic-chat" }] },
        { origin: "https://example.invalid", localStorage: [{ name: "unrelated", value: "synthetic-other" }] },
      ],
    } as unknown as BrowserStorageState;

    const sanitized = sanitizeBrowserStorageState(storageState, "https://chatgpt.com");
    expect(sanitized.cookies.map(cookie => cookie.name)).toEqual(["chatgpt", "openai"]);
    expect(sanitized.origins).toEqual([
      { origin: "https://chatgpt.com", localStorage: [{ name: "auth", value: "synthetic-chat" }] },
    ]);
  });

  test("never serializes raw adapter diagnostics", async () => {
    const secret = "cookie=synthetic-secret account=private@example.invalid";
    const events: Record<string, unknown>[] = [];
    await executeAdapterTurn({
      id: "synthetic-redaction",
      parsed: parsedFixture(),
      adapter: {
        async runTurn(_parsed: CodexParsedRequest, _meta: { headers: Headers; abortSignal: AbortSignal }, emit: (event: AdapterEvent) => void) {
          emit({ type: "error", message: secret, code: "unknown_private_code" });
        },
      },
      active: { controller: new AbortController() },
      timeoutMs: 1_000,
      emit: event => events.push(event),
    });
    expect(events).toContainEqual({ type: "error", id: "synthetic-redaction", category: "browser_error" });
    expect(JSON.stringify(events)).not.toContain(secret);
  });

  test("keeps cancellation request-scoped", () => {
    const first = new AbortController();
    const second = new AbortController();
    const active = new Map([
      ["request-first", { controller: first }],
      ["request-second", { controller: second }],
    ]);
    expect(abortActiveRun(active, "request-first")).toBe(true);
    expect(first.signal.aborted).toBe(true);
    expect(second.signal.aborted).toBe(false);
    expect(abortActiveRun(active, "missing-request")).toBe(false);
  });

  test("streams a synthetic success and emits exactly one terminal record", async () => {
    const events: Record<string, unknown>[] = [];
    const adapter = {
      async runTurn(_parsed: CodexParsedRequest, _meta: { headers: Headers; abortSignal: AbortSignal }, emit: (event: AdapterEvent) => void) {
        emit({ type: "text_delta", text: "synthetic answer", phase: "final_answer" });
        emit({ type: "done" });
      },
    };
    await executeAdapterTurn({ id: "synthetic-success", parsed: parsedFixture(), adapter, active: { controller: new AbortController() }, timeoutMs: 1_000, emit: event => events.push(event) });
    expect(events.map(event => event.type)).toEqual(["started", "delta", "done"]);
    expect(events[1]).toEqual({ type: "delta", id: "synthetic-success", text: "synthetic answer" });
    expect(eventRecords(events)).toHaveLength(1);
  });

  test("waits for request-scoped browser cancellation to physically settle", async () => {
    const controller = new AbortController();
    let settleCancellation!: () => void;
    const active = {
      controller,
      cancelExecution: () => new Promise<void>(resolve => { settleCancellation = resolve; }),
    };
    const events: Record<string, unknown>[] = [];
    const adapter = {
      async runTurn(_parsed: CodexParsedRequest, meta: { headers: Headers; abortSignal: AbortSignal }, emit: (event: AdapterEvent) => void) {
        emit({ type: "text_delta", text: "partial", phase: "final_answer" });
        await new Promise<void>(resolve => meta.abortSignal.addEventListener("abort", resolve, { once: true }));
        emit({ type: "text_delta", text: "must-not-escape", phase: "final_answer" });
      },
    };
    const task = executeAdapterTurn({ id: "synthetic-cancel", parsed: parsedFixture(), adapter, active, timeoutMs: 1_000, emit: event => events.push(event) });
    expect(abortActiveRun(new Map([["synthetic-cancel", active]]), "synthetic-cancel")).toBe(true);
    await new Promise<void>(resolve => {
      if (controller.signal.aborted) resolve();
      else controller.signal.addEventListener("abort", resolve, { once: true });
    });
    await Promise.resolve();
    expect(events.filter(event => event.type === "delta")).toEqual([{ type: "delta", id: "synthetic-cancel", text: "partial" }]);
    expect(eventRecords(events)).toEqual([]);
    settleCancellation();
    await task;
    expect(eventRecords(events)).toEqual([{ type: "error", id: "synthetic-cancel", category: "cancelled" }]);
  });

  test("fails closed on tool events and maps rate limits to a safe category", async () => {
    const toolActive = { controller: new AbortController() };
    const toolEvents: Record<string, unknown>[] = [];
    await executeAdapterTurn({
      id: "synthetic-tool",
      parsed: parsedFixture(),
      adapter: { async runTurn(_parsed: CodexParsedRequest, _meta: { headers: Headers; abortSignal: AbortSignal }, emit: (event: AdapterEvent) => void) { emit({ type: "tool_call_start", id: "tool", name: "unavailable" }); } },
      active: toolActive,
      timeoutMs: 1_000,
      emit: event => toolEvents.push(event),
    });
    expect(toolActive.controller.signal.aborted).toBe(true);
    expect(eventRecords(toolEvents)).toEqual([{ type: "error", id: "synthetic-tool", category: "tool_invariant_failed" }]);

    const limitEvents: Record<string, unknown>[] = [];
    await executeAdapterTurn({
      id: "synthetic-limit",
      parsed: parsedFixture(),
      adapter: { async runTurn(_parsed: CodexParsedRequest, _meta: { headers: Headers; abortSignal: AbortSignal }, emit: (event: AdapterEvent) => void) { emit({ type: "error", status: 429, message: "synthetic provider quota detail" }); } },
      active: { controller: new AbortController() },
      timeoutMs: 1_000,
      emit: event => limitEvents.push(event),
    });
    expect(eventRecords(limitEvents)).toEqual([{ type: "error", id: "synthetic-limit", category: "plan_limit" }]);
  });
  test("pre-submission cancellation and timeout cannot reach insertion or send", async () => {
    for (const reason of [
      new DOMException("synthetic cancellation", "AbortError"),
      new DOMException("synthetic timeout", "TimeoutError"),
    ]) {
      const controller = new AbortController();
      const active = { controller, submissionStarted: false, submitted: false };
      const verification = deferred<void>();
      let verificationStarted = false;
      let insertionCalls = 0;
      let sendCalls = 0;
      const request = (async () => {
        await awaitActiveStep(controller.signal, async () => { verificationStarted = true; await verification.promise; });
        await awaitActiveStep(controller.signal, async () => { insertionCalls += 1; });
        await awaitActiveStep(controller.signal, async () => { sendCalls += 1; });
      })();
      expect(verificationStarted).toBe(true);
      abortActiveRequest(active, reason, async () => { throw new Error("pre-submission work must not stop a generation"); });
      verification.resolve(undefined);
      let failure: Error | undefined;
      try { await request; } catch (error) { failure = error as Error; }
      expect(failure?.name).toBe(reason.name);
      await active.cancellationSettlement;
      expect(active.stopOutcome).toBe("not_submitted");
      expect(insertionCalls).toBe(0);
      expect(sendCalls).toBe(0);
    }
  });

  test("cancellation terminal record waits for production Stop settlement", async () => {
    const controller = new AbortController();
    const active = { controller, submissionStarted: false, submitted: true };
    const stop = deferred<StopOutcome>();
    const started = deferred<void>();
    const records: { category: string; remoteStopState?: StopOutcome }[] = [];
    abortActiveRequest(active, new DOMException("synthetic cancellation", "AbortError"), () => {
      started.resolve(undefined);
      return stop.promise;
    });
    const consumer = settleRequestError(active, "request_cancelled", async () => {
      throw new Error("cancellation must reuse its production settlement");
    }, () => {}).then(record => { records.push(record); });
    await started.promise;
    expect(controller.signal.aborted).toBe(true);
    expect(records).toEqual([]);
    stop.resolve("stopped");
    await consumer;
    expect(records).toEqual([{ category: "request_cancelled", remoteStopState: "stopped" }]);
    expect(active.stopOutcome).toBe("stopped");
  });

  test("settles uncertain send failures before releasing a recoverable error", async () => {
    const active = {
      controller: new AbortController(),
      submissionStarted: false,
      submitted: false,
      submissionUncertain: true,
    };
    let stopCalls = 0;
    let unconfirmed = false;
    const settled = await settleRequestError(active, "browser_error", async () => {
      stopCalls += 1;
      return "stopped";
    }, () => { unconfirmed = true; });
    expect(stopCalls).toBe(1);
    expect(unconfirmed).toBe(false);
    expect(settled).toEqual({ category: "browser_error", remoteStopState: "stopped" });

    active.conversationRouteObserved = true;
    const failed = await settleRequestError(active, "browser_error", async () => {
      throw new Error("Stop could not be confirmed");
    }, () => { unconfirmed = true; });
    expect(unconfirmed).toBe(true);
    expect(failed).toEqual({ category: "generation_stop_unconfirmed", remoteStopState: "unconfirmed" });
  });

  test("waits for buffered assistant updates to settle after Stop hides", async () => {
    const frames = [
      "partial",
      "partial",
      "buffered",
      "buffered tail",
      "buffered tail",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
      "final answer",
    ];
    let frameIndex = 0;
    let now = 0;
    await waitForStableStop(
      async () => ({
        stopVisible: false,
        composerReady: true,
        submissionObserved: false,
        assistantFingerprint: frames[Math.min(frameIndex++, frames.length - 1)],
      }),
      async milliseconds => { now += milliseconds; },
      () => now,
    );
    expect(frames[frameIndex - 1]).toBe("final answer");
  });

  test("confirms early cancellation with stable empty output only on a ready page", async () => {
    let now = 0;
    const fingerprint = await waitForStableStop(
      async () => ({ stopVisible: false, composerReady: true, assistantFingerprint: "", submissionObserved: true }),
      async milliseconds => { now += milliseconds; },
      () => now,
    );
    expect(fingerprint).toBe("");

    now = 0;
    let failure: Error | undefined;
    try {
      await waitForStableStop(
        async () => ({ stopVisible: false, composerReady: true, assistantFingerprint: "", submissionObserved: false }),
        async milliseconds => { now += milliseconds; },
        () => now,
      );
    } catch (error) { failure = error as Error; }
    expect(failure?.message).toBe("generation_stop_unconfirmed");
    expect(now).toBe(5_000);
  });

  test("recovers an unconfirmed Stop only on the same page after stable ready output", async () => {
    const expected = {
      pageIdentity: {},
      targetId: "exact-target-123456",
      url: "https://chatgpt.com/c/public-turn",
      submissionObserved: false,
    };
    let now = 0;
    let stopVisible = true;
    let composerReady = true;
    let fingerprint = "7:partial";
    const observe = async (): Promise<StopRecoveryObservation> => ({
      ...expected,
      stopVisible,
      assistantFingerprint: fingerprint,
      composerReady,
    });
    const recover = async (): Promise<boolean> => {
      const confirmed = await reconcileUnconfirmedStop(
        expected,
        observe,
        async milliseconds => {
          now += milliseconds;
          if (now >= 200 && now < 400) fingerprint = "15:buffered-tail";
          else if (now >= 400) fingerprint = "20:final-answer";
        },
        () => now,
      );
      return confirmed;
    };
    expect(await recover()).toBe(false);

    stopVisible = false;
    composerReady = false;
    expect(await recover()).toBe(false);

    composerReady = true;
    expect(await recover()).toBe(true);

    const wrongIdentities = [
      { ...expected, pageIdentity: {} },
      { ...expected, targetId: "different-target-1234" },
      { ...expected, url: "https://chatgpt.com/c/other" },
    ];
    for (const identity of wrongIdentities) {
      const confirmed = await reconcileUnconfirmedStop(
        expected,
        async () => ({
          ...identity,
          stopVisible: false,
          assistantFingerprint: "",
          composerReady: true,
        }),
        async () => {},
        () => now,
      );
      expect(confirmed).toBe(false);
    }
  });

  test("fails closed if Stop reappears or assistant output never settles by deadline", async () => {
    let now = 0;
    let stopChecks = 0;
    let failure: Error | undefined;
    try {
      await waitForStableStop(
        async () => ({
          stopVisible: ++stopChecks === 3,
          composerReady: true,
          submissionObserved: false,
          assistantFingerprint: "answer",
        }),
        async milliseconds => { now += milliseconds; },
        () => now,
      );
    } catch (error) { failure = error as Error; }
    expect(failure?.message).toBe("generation_stop_unconfirmed");

    now = 0;
    let frame = 0;
    failure = undefined;
    try {
      await waitForStableStop(
        async () => ({
          stopVisible: false,
          composerReady: true,
          submissionObserved: false,
          assistantFingerprint: `answer-${frame++}`,
        }),
        async milliseconds => { now += milliseconds; },
        () => now,
      );
    } catch (error) { failure = error as Error; }
    expect(failure?.message).toBe("generation_stop_unconfirmed");
    expect(now).toBe(5_000);
  });

  test("enforces browser request limits at their exact boundaries", () => {
    const textAtLimit = "x".repeat(MAX_TEXT_CHARS);
    const instructionsAtLimit = "i".repeat(MAX_INSTRUCTIONS_CHARS);
    expect(validateRequest(textAtLimit, "i", MODEL_SLUG)).toBeUndefined();
    expect(validateRequest("x", instructionsAtLimit, MODEL_SLUG)).toBeUndefined();
    expect(validateRequest(`${textAtLimit}x`, "i", MODEL_SLUG)).toBe("invalid_request");
    expect(validateRequest("x", `${instructionsAtLimit}i`, MODEL_SLUG)).toBe("invalid_request");
    expect(validateRequest("", "i", MODEL_SLUG)).toBe("invalid_request");
    expect(validateRequest("x", "i", "different-model")).toBe("model_unavailable");
  });

  test("preserves recoverable error precedence for limits and abort reasons", () => {
    expect(providerEventCategory({ type: "error", status: 413, code: "rate_limit_exceeded" })).toBe("prompt_too_long");
    expect(providerEventCategory({ type: "error", status: 429, code: "model_not_available" })).toBe("plan_limit");
    expect(providerEventCategory({ type: "error", status: 403 })).toBe("account_access");

    const timeout = new AbortController();
    timeout.abort(new DOMException("synthetic timeout", "TimeoutError"));
    expect(safeProviderErrorCategory({ status: 429 }, timeout.signal)).toBe("timeout");
    const cancellation = new AbortController();
    cancellation.abort(new DOMException("synthetic cancellation", "AbortError"));
    expect(safeProviderErrorCategory({ status: 429 }, cancellation.signal)).toBe("cancelled");
  });
});
