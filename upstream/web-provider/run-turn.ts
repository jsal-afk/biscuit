import type { AdapterEvent, CodexParsedRequest } from "../codex-chatgpt-web/src/types";
import { providerEventCategory, safeProviderErrorCategory } from "./error-categories";

interface TurnAdapter {
  runTurn(
    parsed: CodexParsedRequest,
    meta: { headers: Headers; abortSignal: AbortSignal },
    emit: (event: AdapterEvent) => void,
  ): Promise<unknown>;
}

export interface ActiveRunLike {
  controller: AbortController;
  cancelExecution?: () => Promise<void>;
  cancellationSettlement?: Promise<void>;
}

export interface ProtocolOutput {
  (record: Record<string, unknown>): void;
}

function abortRun(active: ActiveRunLike, reason: Error): void {
  if (active.controller.signal.aborted) return;
  let settlement: Promise<void>;
  try {
    settlement = Promise.resolve(active.cancelExecution?.());
  } catch (error) {
    settlement = Promise.reject(error);
  }
  active.cancellationSettlement = settlement;
  void settlement.catch(() => {});
  active.controller.abort(reason);
}

export function abortActiveRun<T extends ActiveRunLike>(activeRuns: ReadonlyMap<string, T>, id: string): boolean {
  const active = activeRuns.get(id);
  if (!active) return false;
  abortRun(active, new DOMException("ChatGPT Web request cancelled", "AbortError"));
  return true;
}

type TerminalResult = { type: "done" } | { type: "error"; category: string };

export async function executeAdapterTurn(options: {
  id: string;
  parsed: CodexParsedRequest;
  adapter: TurnAdapter;
  active: ActiveRunLike;
  timeoutMs: number;
  emit: ProtocolOutput;
}): Promise<void> {
  const { id, parsed, adapter, active, timeoutMs, emit } = options;
  const { controller } = active;
  let terminalResult: TerminalResult | undefined;
  let responseChars = 0;
  const timeout = setTimeout(
    () => abortRun(active, new DOMException("Web turn timed out", "TimeoutError")),
    timeoutMs,
  );
  try {
    emit({ type: "started", id });
    await adapter.runTurn(
      parsed,
      { headers: new Headers(), abortSignal: controller.signal },
      (event: AdapterEvent) => {
        if (terminalResult || controller.signal.aborted) return;
        if (event.type === "text_delta") {
          if (event.phase === "commentary" || event.text.length === 0) return;
          responseChars += event.text.length;
          emit({ type: "delta", id, text: event.text });
          return;
        }
        if (event.type === "done") {
          terminalResult = responseChars > 0 ? { type: "done" } : { type: "error", category: "empty_response" };
          return;
        }
        if (event.type === "incomplete") {
          terminalResult = { type: "error", category: "incomplete_response" };
          return;
        }
        if (event.type === "error") {
          terminalResult = { type: "error", category: providerEventCategory(event) };
          return;
        }
        if (event.type === "tool_call_start" || event.type === "tool_call_delta" || event.type === "tool_call_end") {
          terminalResult = { type: "error", category: "tool_invariant_failed" };
          abortRun(active, new Error("tool_invariant_failed"));
        }
      },
    );
  } catch (error) {
    if (!terminalResult) {
      terminalResult = { type: "error", category: safeProviderErrorCategory(error, controller.signal) };
    }
  } finally {
    clearTimeout(timeout);
  }

  let cancellationFailed = false;
  if (active.cancellationSettlement) {
    try {
      await active.cancellationSettlement;
    } catch {
      cancellationFailed = true;
    }
  }

  const toolInvariant = terminalResult?.type === "error" && terminalResult.category === "tool_invariant_failed";
  if (controller.signal.aborted && !toolInvariant) {
    emit({
      type: "error",
      id,
      category: cancellationFailed ? "browser_error" : safeProviderErrorCategory(undefined, controller.signal),
    });
  } else if (terminalResult?.type === "done") {
    emit({ type: "done", id });
  } else if (terminalResult?.type === "error") {
    emit({ type: "error", id, category: cancellationFailed ? "browser_error" : terminalResult.category });
  } else if (controller.signal.aborted) {
    emit({ type: "error", id, category: cancellationFailed ? "browser_error" : safeProviderErrorCategory(undefined, controller.signal) });
  } else {
    emit({ type: "error", id, category: "incomplete_response" });
  }
}
