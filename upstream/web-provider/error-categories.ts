import type { AdapterEvent } from "../codex-chatgpt-web/src/types";

const SAFE_ERROR_CODES: Record<string, "plan_limit" | "model_unavailable" | "prompt_too_long" | "reconnect_required"> = {
  billing_hard_limit_reached: "plan_limit",
  insufficient_quota: "plan_limit",
  rate_limit_exceeded: "plan_limit",
  usage_limit_reached: "plan_limit",
  model_access_denied: "model_unavailable",
  model_not_available: "model_unavailable",
  model_not_enabled: "model_unavailable",
  model_not_found: "model_unavailable",
  context_length_exceeded: "prompt_too_long",
  request_too_large: "prompt_too_long",
  chatgpt_session_expired: "reconnect_required",
  authentication_required: "reconnect_required",
  invalid_authentication: "reconnect_required",
};

function safeMappedErrorCode(code: unknown): string | undefined {
  return typeof code === "string" && Object.prototype.hasOwnProperty.call(SAFE_ERROR_CODES, code)
    ? SAFE_ERROR_CODES[code]
    : undefined;
}


export function safeProviderErrorCategory(error: unknown, signal?: AbortSignal): string {
  if (signal?.aborted) {
    const reason = signal.reason;
    return reason instanceof Error && reason.name === "TimeoutError" ? "timeout" : "cancelled";
  }
  if (error !== null && typeof error === "object") {
    const value = error as { name?: unknown; message?: unknown; status?: unknown; code?: unknown };
    if (typeof value.status === "number") {
      if (value.status === 401) return "reconnect_required";
      if (value.status === 403) return "account_access";
      if (value.status === 413) return "prompt_too_long";
      if (value.status === 429) return "plan_limit";
    }
    const codeCategory = safeMappedErrorCode(value.code);
    if (codeCategory) return codeCategory;
    if (value.name === "TimeoutError") return "timeout";
    if (value.name === "AbortError") return "cancelled";
    if (typeof value.message === "string") {
      if (value.message.startsWith("ChatGPT authentication could not be verified")) return "reconnect_required";
      if (value.message === "ChatGPT login state is missing or unverified") return "reconnect_required";
      if (value.message === "Timed out waiting for ChatGPT sign-in") return "timeout";
      if (value.message === "Dedicated Chromium login window closed before Continue") return "login_browser_closed";
      if (value.message.startsWith("Configured Chromium executable does not exist")
        || value.message === "ChatGPT Web browser executable path is required"
        || value.message === "Biscuit Chromium runtime is missing") return "browser_runtime_missing";
      if (value.message.startsWith("ChatGPT web model is not enabled:")) return "model_unavailable";
    }
  }
  return "browser_error";
}

export function providerEventCategory(event: Extract<AdapterEvent, { type: "error" }>): string {
  if (typeof event.status === "number") {
    if (event.status === 401) return "reconnect_required";
    if (event.status === 403) return "account_access";
    if (event.status === 413) return "prompt_too_long";
    if (event.status === 429) return "plan_limit";
  }
  return safeMappedErrorCode(event.code) ?? "browser_error";
}
