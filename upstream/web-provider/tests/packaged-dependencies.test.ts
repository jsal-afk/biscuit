import { describe, expect, test } from "bun:test";
import { createRequire } from "node:module";
import { estimateTokens } from "../../codex-chatgpt-web/src/lib/token-estimate";

const driver = process.env.BISCUIT_ELECTRON_CONTRACT_DRIVER;

describe.skipIf(!driver)("packaged dependency consumers", () => {
  const packaged = (specifier: string) => createRequire(driver!)(specifier);

  test("packaged tokenizer preserves multilingual IDs and chunk boundaries", () => {
    const { get_encoding } = packaged("tiktoken");
    const encoding = get_encoding("o200k_base");
    try {
      for (const [text, tokens] of [
        ["Hello world.", [13225, 2375, 13]],
        ["안녕하세요 세계 🌍", [14307, 171731, 75755, 130321, 235]],
        ["日本語と中文、العربية café 👨‍👩‍👧‍👦", [9048, 40909, 5330, 10667, 1395, 55206, 22635, 30469, 61138, 101, 2524, 28823, 102, 2524, 28823, 100, 2524, 28823, 99]],
        ["<|endoftext|>", [27, 91, 419, 1440, 919, 91, 29]],
      ] as const) {
        expect(Array.from(encoding.encode_ordinary(text))).toEqual([...tokens]);
        expect(new TextDecoder().decode(encoding.decode(new Uint32Array(tokens)))).toBe(text);
        expect(estimateTokens(text)).toBe(tokens.length);
      }
      expect(estimateTokens("")).toBe(0);
      expect(estimateTokens("x".repeat(4095) + "😀Z")).toBe(515);
      expect(estimateTokens("a".repeat(8192))).toBe(1024);
      expect(estimateTokens(JSON.stringify({ text: "한글😀".repeat(1100), data: "AQIDBAUGBwgJ".repeat(400) }))).toBe(6107);
    } finally {
      encoding.free();
    }
  });

  test("packaged DOM and GFM preserve structured multilingual Markdown", () => {
    const { createDocument } = packaged("@mixmark-io/domino");
    const Turndown = packaged("turndown");
    const { gfm } = packaged("turndown-plugin-gfm");
    const document = createDocument('<h2>Title</h2><p><del>old</del> <a href="https://example.invalid">link</a></p><table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>한글</td><td><code>x_y</code></td></tr></tbody></table>');
    const converter = new Turndown({ headingStyle: "atx", codeBlockStyle: "fenced" });
    converter.use(gfm);
    expect(Array.from(document.querySelectorAll("td"), (cell: { textContent: string }) => cell.textContent)).toEqual(["한글", "x_y"]);
    expect(converter.turndown(document.body.innerHTML)).toBe("## Title\n\n~old~ [link](https://example.invalid)\n\n| A | B |\n| --- | --- |\n| 한글 | `x_y` |");
  });

  test("packaged Playwright loads its deferred WebP codec and preserves pixels", () => {
    const { utils } = packaged("playwright-core/lib/coreBundle");
    const pixels = Buffer.from([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 12, 34, 56, 255]);
    const encoded = utils.encodeWebp({ data: pixels, width: 2, height: 2 }, { lossless: true });
    expect(utils.isLosslessWebp(encoded)).toBe(true);
    const decoded = utils.decodeWebp(encoded);
    expect({ width: decoded.width, height: decoded.height, data: Buffer.from(decoded.data) }).toEqual({ width: 2, height: 2, data: pixels });
  });

  test("packaged Playwright CDP connects and disconnects without closing its browser", async () => {
    const { chromium } = packaged("playwright-core");
    const methods: string[] = [];
    const unexpected: string[] = [];
    const version = { protocolVersion: "1.3", product: "Chrome/148.0.0.0", userAgent: "Offline fixture", jsVersion: "fixture", revision: "fixture" };
    const { z } = packaged("zod") as typeof import("zod");
    const commandSchema = z.object({ id: z.number().int().positive(), method: z.string(), sessionId: z.string().optional() }).passthrough();
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(request, listener) {
        const pathname = new URL(request.url).pathname;
        if (pathname === "/json/version/" || pathname === "/json/version") {
          return Response.json({ webSocketDebuggerUrl: `ws://127.0.0.1:${listener.port}/devtools/browser/fixture` });
        }
        if (pathname === "/devtools/browser/fixture" && listener.upgrade(request)) return;
        return new Response("Unknown offline fixture route", { status: 404 });
      },
      websocket: {
        message(socket, raw) {
          const command = commandSchema.parse(JSON.parse(String(raw)));
          methods.push(command.method);
          let result: Record<string, unknown> = {};
          switch (command.method) {
            case "Browser.getVersion": result = version; break;
            case "Target.getBrowserContexts": result = { browserContextIds: [] }; break;
            case "Target.getTargetInfo": result = { targetInfo: { targetId: "fixture-browser", type: "browser", title: "Offline fixture", url: "", attached: true, canAccessOpener: false } }; break;
            case "Target.attachToBrowserTarget": result = { sessionId: "fixture-browser-session" }; break;
            case "Target.setAutoAttach":
            case "Target.detachFromTarget":
            case "Runtime.runIfWaitingForDebugger":
            case "Browser.setDownloadBehavior": break;
            default: unexpected.push(command.method);
          }
          socket.send(JSON.stringify({ id: command.id, result, ...(command.sessionId ? { sessionId: command.sessionId } : {}) }));
        },
      },
    });
    let browser;
    try {
      browser = await chromium.connectOverCDP(server.url.href, { timeout: 3_000 });
      expect(browser.version()).toBe("148.0.0.0");
      expect(browser.contexts().length).toBe(1);
      expect(browser.contexts()[0].pages()).toEqual([]);
      const session = await browser.newBrowserCDPSession();
      expect(await session.send("Browser.getVersion")).toEqual(version);
      await session.detach();
      await browser.close();
      expect(browser.isConnected()).toBe(false);
      expect(methods).not.toContain("Browser.close");
      expect(methods).not.toContain("Target.closeTarget");
      expect(unexpected).toEqual([]);
    } finally {
      if (browser?.isConnected()) await browser.close();
      server.stop(true);
    }
  });
});
