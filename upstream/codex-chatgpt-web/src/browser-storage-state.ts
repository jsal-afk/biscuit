export interface BrowserStorageCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number;
  httpOnly: boolean;
  secure: boolean;
  sameSite: "Strict" | "Lax" | "None";
  partitionKey?: string;
}

export interface BrowserStorageOrigin {
  origin: string;
  localStorage: { name: string; value: string }[];
}

export interface BrowserStorageState {
  cookies: BrowserStorageCookie[];
  origins: BrowserStorageOrigin[];
}

const LOGIN_STORAGE_ROOT_DOMAINS = ["chatgpt.com", "openai.com"] as const;

export function isAllowedChatGptLoginHostname(rawHostname: string): boolean {
  const hostname = rawHostname.toLowerCase();
  if (!/^[a-z0-9.-]+$/.test(hostname)
    || hostname.startsWith(".")
    || hostname.endsWith(".")
    || hostname.includes("..")) return false;
  try {
    const parsed = new URL(`https://${hostname}/`);
    if (parsed.hostname !== hostname
      || parsed.host !== hostname
      || parsed.username
      || parsed.password
      || parsed.pathname !== "/"
      || parsed.search
      || parsed.hash) return false;
  } catch {
    return false;
  }
  return LOGIN_STORAGE_ROOT_DOMAINS.some(root => hostname === root || hostname.endsWith(`.${root}`));
}

export function sanitizeBrowserStorageState(
  storageState: BrowserStorageState,
  chatGptOrigin: string,
): BrowserStorageState {
  return {
    cookies: storageState.cookies
      .filter(cookie => !Object.prototype.hasOwnProperty.call(cookie, "partitionKey")
        && isAllowedChatGptLoginHostname(cookie.domain.replace(/^\.+/, "")))
      .map(cookie => ({ ...cookie })),
    origins: storageState.origins
      .filter(origin => origin.origin === chatGptOrigin)
      .map(origin => ({
        origin: origin.origin,
        localStorage: origin.localStorage.map(item => ({ ...item })),
      })),
  };
}
