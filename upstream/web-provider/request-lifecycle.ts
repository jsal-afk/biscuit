export const MAX_TEXT_CHARS = 200_000;
export const MAX_INSTRUCTIONS_CHARS = 8_000;
export const MODEL_SLUG = "browser-selected";

export type StopOutcome = "not_submitted" | "stopped" | "already_settled" | "unconfirmed";

export interface ActiveRequestLifecycle {
  controller: AbortController;
  submissionStarted: boolean;
  submitted: boolean;
  submissionUncertain?: boolean;
  conversationRouteObserved?: boolean;
  submissionTask?: Promise<void>;
  cancellationSettlement?: Promise<void>;
  stopOutcome?: StopOutcome;
}

export function validateRequest(text: unknown, instructions: unknown, modelSlug: unknown): "invalid_request" | "model_unavailable" | undefined {
  if (modelSlug !== MODEL_SLUG) return "model_unavailable";
  if (typeof text !== "string" || text.length === 0 || text.length > MAX_TEXT_CHARS
    || typeof instructions !== "string" || instructions.length === 0 || instructions.length > MAX_INSTRUCTIONS_CHARS) {
    return "invalid_request";
  }
  return undefined;
}

export async function awaitActiveStep<T>(signal: AbortSignal, operation: () => Promise<T>): Promise<T> {
  if (signal.aborted) throw signal.reason ?? new DOMException("ChatGPT Web request canceled", "AbortError");
  const value = await operation();
  if (signal.aborted) throw signal.reason ?? new DOMException("ChatGPT Web request canceled", "AbortError");
  return value;
}

export function abortActiveRequest(
  active: ActiveRequestLifecycle,
  reason: Error,
  stopExecution: () => Promise<StopOutcome>,
): void {
  if (active.controller.signal.aborted) return;
  const mustStop = active.submissionStarted || active.submitted || active.submissionUncertain || active.conversationRouteObserved;
  active.cancellationSettlement = mustStop
    ? Promise.resolve().then(stopExecution).then(outcome => { active.stopOutcome = outcome; })
    : Promise.resolve().then(() => { active.stopOutcome = "not_submitted"; });
  void active.cancellationSettlement.catch(() => {});
  active.controller.abort(reason);
}

export interface RequestErrorSettlement {
  category: string;
  remoteStopState?: StopOutcome;
}

export async function settleRequestError(
  active: ActiveRequestLifecycle,
  category: string,
  stopExecution: () => Promise<StopOutcome>,
  onUnconfirmed: () => void,
): Promise<RequestErrorSettlement> {
  let unconfirmed = false;
  if (active.controller.signal.aborted && active.cancellationSettlement) {
    try {
      await active.cancellationSettlement;
      unconfirmed = active.stopOutcome === "unconfirmed";
    } catch {
      unconfirmed = true;
    }
  } else if (active.submissionStarted || active.submitted || active.submissionUncertain || active.conversationRouteObserved) {
    try {
      active.stopOutcome = await stopExecution();
      unconfirmed = active.stopOutcome === "unconfirmed";
    } catch {
      unconfirmed = true;
    }
  }
  if (unconfirmed) {
    active.stopOutcome = "unconfirmed";
    onUnconfirmed();
    return { category: "generation_stop_unconfirmed", remoteStopState: "unconfirmed" };
  }
  return { category, ...(active.stopOutcome ? { remoteStopState: active.stopOutcome } : {}) };
}

export interface StopRecoveryIdentity {
  pageIdentity: object;
  targetId: string;
  url: string;
  submissionObserved: boolean;
}

export interface StopSettlementObservation {
  stopVisible: boolean;
  assistantFingerprint?: string;
  composerReady: boolean;
  submissionObserved: boolean;
}

export interface StopRecoveryObservation extends StopRecoveryIdentity, StopSettlementObservation {}

const STOP_SETTLEMENT_TIMEOUT_MS = 5_000;
const STOP_SETTLEMENT_STABLE_MS = 750;
const STOP_SETTLEMENT_POLL_MS = 100;

export async function waitForStableStop(
  observe: (timeoutMs: number) => Promise<StopSettlementObservation>,
  wait: (milliseconds: number) => Promise<void>,
  now: () => number,
): Promise<string> {
  const deadline = now() + STOP_SETTLEMENT_TIMEOUT_MS;
  let previousFingerprint: string | undefined;
  let stableSince: number | undefined;
  while (now() < deadline) {
    const observation = await observe(Math.max(1, deadline - now()));
    const observedAt = now();
    if (observation.stopVisible) throw new Error("generation_stop_unconfirmed");
    const currentFingerprint = observation.assistantFingerprint;
    if (!observation.composerReady || currentFingerprint === undefined
      || (currentFingerprint.length === 0 && !observation.submissionObserved)) {
      previousFingerprint = undefined;
      stableSince = undefined;
    } else if (stableSince === undefined || currentFingerprint !== previousFingerprint) {
      previousFingerprint = currentFingerprint;
      stableSince = observedAt;
    } else if (observedAt - stableSince >= STOP_SETTLEMENT_STABLE_MS) {
      return currentFingerprint;
    }
    const remaining = deadline - now();
    if (remaining <= 0) break;
    await wait(Math.min(STOP_SETTLEMENT_POLL_MS, remaining));
  }
  throw new Error("generation_stop_unconfirmed");
}

export async function reconcileUnconfirmedStop(
  expected: StopRecoveryIdentity,
  observe: (timeoutMs: number) => Promise<StopRecoveryObservation>,
  wait: (milliseconds: number) => Promise<void>,
  now: () => number,
): Promise<boolean> {
  try {
    await waitForStableStop(async timeoutMs => {
      const observation = await observe(timeoutMs);
      if (observation.pageIdentity === expected.pageIdentity
        && observation.targetId === expected.targetId
        && observation.url === expected.url
        && observation.composerReady) return observation;
      return { stopVisible: true, composerReady: false, submissionObserved: false };
    }, wait, now);
    return true;
  } catch {
    return false;
  }
}
