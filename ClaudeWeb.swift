// ClaudeWeb.swift — claude.ai sign-in path so the app works for ANY tier
// (Free / Pro / Team / Max), not just Claude Code (Pro/Max). The user signs in
// to the real claude.ai page in a WebView; we capture the `sessionKey` cookie
// and call claude.ai's own usage endpoint — the same one the website uses.

import AppKit
import WebKit
import Security

// MARK: - Keychain (store the sensitive sessionKey, never on disk in the clear)

enum Keychain {
    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeUsage",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value.data(using: .utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeUsage",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeUsage",
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

func readSessionKey() -> String? { Keychain.get("claudeai-sessionKey") }
func saveSessionKey(_ v: String) { Keychain.set("claudeai-sessionKey", v) }
func clearSessionKey() { Keychain.delete("claudeai-sessionKey") }

// MARK: - Sign-in WebView (captures the sessionKey cookie from claude.ai)

final class ClaudeLogin: NSObject, NSWindowDelegate {
    static let shared = ClaudeLogin()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var poll: Timer?
    private var completion: ((String?) -> Void)?

    func present(_ completion: @escaping (String?) -> Void) {
        if window != nil { window?.makeKeyAndOrderFront(nil); return }   // already open
        self.completion = completion

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 680))
        webView = wv
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Sign in to Claude"
        win.contentView = wv
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkCookie()
        }
    }

    private func checkCookie() {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            if let c = cookies.first(where: { $0.name == "sessionKey" && $0.value.count > 20 }) {
                self?.finish(c.value)
            }
        }
    }

    private func finish(_ key: String?) {
        poll?.invalidate(); poll = nil
        let comp = completion; completion = nil
        window?.delegate = nil
        window?.close(); window = nil; webView = nil
        comp?(key)
    }

    // User closed the window before signing in.
    func windowWillClose(_ notification: Notification) {
        if completion != nil { finish(nil) }
    }
}

// MARK: - claude.ai usage endpoint (works for Free/Pro/Team/Max)

private func claudeWebRequest(_ url: URL, _ sessionKey: String) -> URLRequest {
    var r = URLRequest(url: url, timeoutInterval: 12)
    r.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
               "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
               forHTTPHeaderField: "User-Agent")
    return r
}

func fetchPlanUsageViaCookie(_ sessionKey: String, _ completion: @escaping (PlanUsage?) -> Void) {
    guard let orgsURL = URL(string: "https://claude.ai/api/organizations") else {
        completion(nil); return
    }
    URLSession.shared.dataTask(with: claudeWebRequest(orgsURL, sessionKey)) { data, resp, _ in
        guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let orgId = arr.compactMap({ $0["uuid"] as? String }).first,
              let usageURL = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: claudeWebRequest(usageURL, sessionKey)) { d2, resp2, _ in
            guard let d2, (resp2 as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] else {
                completion(nil); return
            }
            completion(parsePlanUsage(j))
        }.resume()
    }.resume()
}
