import Foundation
import SwiftUI
import WebKit

/// 从 reportaproblem.apple.com 抓取购买记录。
///
/// 认证全程留在 WebView 里：用户在里面登录，Cookie 由 WebKit 自己管，我们既不碰密码
/// 也不搬运会话。抓取时在页面上下文里发同源请求，凭据自动带上。
///
/// 登录成功的判据是 sessionStorage 里出现 `x-apple-xsrf-token`。不去轮询 /api/login
/// 探测状态是有原因的：那个接口每调一次就会轮换 token 和 user-context Cookie，拿它当
/// 心跳会把正在进行的抓取自己挤掉。
@MainActor
final class PurchaseSyncEngine: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case loadingPage
        case needsLogin
        case syncing
        case finished(added: Int, scanned: Int, stoppedEarly: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pagesFetched = 0
    @Published private(set) var itemsScanned = 0
    @Published private(set) var accountLabel = ""

    let webView: WKWebView

    private var loginPollTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private static let endpoint = "https://reportaproblem.apple.com/"

    override init() {
        let configuration = WKWebViewConfiguration()
        // 用默认（持久化）数据仓库，登录状态能跨启动保留，不必每次重登。
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func loadSite() {
        guard let url = URL(string: Self.endpoint) else { return }
        phase = .loadingPage
        webView.load(URLRequest(url: url))
    }

    func signOutAndReload() {
        loginPollTask?.cancel()
        syncTask?.cancel()
        let store = webView.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let apple = records.filter { $0.displayName.contains("apple") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: apple) { [weak self] in
                Task { @MainActor in
                    self?.accountLabel = ""
                    self?.loadSite()
                }
            }
        }
    }

    func cancel() {
        syncTask?.cancel()
        syncTask = nil
        loginPollTask?.cancel()
        loginPollTask = nil
        if case .syncing = phase { phase = .idle }
    }

    // MARK: 登录检测

    private func startLoginPolling() {
        loginPollTask?.cancel()
        loginPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let token = await currentToken(), !token.isEmpty {
                    if case .syncing = phase {} else { phase = .idle }
                    loginPollTask = nil
                    return
                }
                phase = .needsLogin
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func currentToken() async -> String? {
        let script = "return sessionStorage.getItem('x-apple-xsrf-token');"
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
        return result as? String
    }

    var isSignedIn: Bool {
        if case .needsLogin = phase { return false }
        if case .loadingPage = phase { return false }
        return true
    }

    // MARK: 抓取

    func sync(into database: PurchaseDatabase, fullResync: Bool) {
        syncTask?.cancel()
        pagesFetched = 0
        itemsScanned = 0
        phase = .syncing

        syncTask = Task { @MainActor in
            defer { syncTask = nil }
            do {
                let session = try await beginSession()
                accountLabel = session.label

                let cursorDay = fullResync
                    ? ""
                    : String((try database.newestPliDate(dsid: session.dsid)).prefix(10))

                var batchId: String?
                var added = 0
                var stoppedEarly = false

                while !Task.isCancelled {
                    let page = try await fetchPage(token: session.token, dsid: session.dsid, batchId: batchId)
                    pagesFetched += 1

                    let items = page.purchases?.flatMap { purchase in
                        (purchase.plis ?? []).compactMap {
                            PurchaseDatabase.LineItem(purchase: purchase, item: $0, dsid: session.dsid)
                        }
                    } ?? []
                    itemsScanned += items.count

                    // 每页即时落库：会话只有约半小时，中途被打断也不该丢掉已抓到的部分。
                    if !items.isEmpty {
                        added += try database.upsert(items)
                    }

                    // 增量停止：结果按时间倒序，一旦这页触到已同步过的日期就说明追平了。
                    // 整页抓完再停，保证重叠的那一天是完整的 —— 同一天可能跨页。
                    if !cursorDay.isEmpty,
                       items.contains(where: { String($0.pliDate.prefix(10)) <= cursorDay }) {
                        stoppedEarly = true
                        break
                    }

                    guard let next = page.nextBatchId, !next.isEmpty else { break }
                    batchId = next
                    try await Task.sleep(nanoseconds: 100_000_000)
                }

                guard !Task.isCancelled else { return }
                try database.recordSync(dsid: session.dsid, name: session.name, email: session.email)
                phase = .finished(added: added, scanned: itemsScanned, stoppedEarly: stoppedEarly)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private struct Session {
        let dsid: String
        let token: String
        let name: String
        let email: String
        var label: String { email.isEmpty ? name : "\(name) <\(email)>" }
    }

    private enum SyncError: LocalizedError {
        case notSignedIn
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return String(localized: "尚未登录 Apple 账户。")
            case .http(let code): return String(localized: "Apple 返回 HTTP \(code)。请重新登录后再试。")
            case .malformed: return String(localized: "无法解析 Apple 返回的数据。")
            }
        }
    }

    /// 取 dsid 与一枚新鲜的 token。
    ///
    /// 已建立会话后再调 /api/login 必须带上当前 token —— 它是双提交 CSRF：
    /// header 里的 token 要和 HttpOnly 的 user-context Cookie 配对，缺了就是 400。
    private func beginSession() async throws -> Session {
        guard let token = await currentToken(), !token.isEmpty else {
            throw SyncError.notSignedIn
        }
        let script = """
            const res = await fetch('/api/login', {
                headers: {
                    accept: 'application/json, text/plain, */*',
                    'x-apple-rap2-api': '3.0.0',
                    'x-apple-xsrf-token': token,
                },
                credentials: 'include',
            });
            if (!res.ok) return { status: res.status };
            const body = await res.json();
            return { status: 200, dsid: body.dsid, token: body.token, name: body.name, email: body.email };
            """
        let raw = try await webView.callAsyncJavaScript(script, arguments: ["token": token], contentWorld: .page)
        guard let dictionary = raw as? [String: Any],
              let status = dictionary["status"] as? Int
        else { throw SyncError.malformed }
        guard status == 200 else { throw SyncError.http(status) }
        guard let dsid = dictionary["dsid"] as? String else { throw SyncError.malformed }

        let fresh = (dictionary["token"] as? String) ?? token
        // /api/login 会轮换 token，写回 sessionStorage 让页面自身保持可用。
        _ = try? await webView.callAsyncJavaScript(
            "sessionStorage.setItem('x-apple-xsrf-token', token); return true;",
            arguments: ["token": fresh],
            contentWorld: .page
        )
        return Session(dsid: dsid,
                       token: fresh,
                       name: (dictionary["name"] as? String) ?? "",
                       email: (dictionary["email"] as? String) ?? "")
    }

    private func fetchPage(token: String, dsid: String, batchId: String?) async throws -> RAPSearchResponse {
        let script = """
            const body = batchId ? { batchId, dsid } : { dsid };
            const res = await fetch('/api/purchase/search', {
                method: 'POST',
                headers: {
                    'content-type': 'application/json',
                    accept: 'application/json, text/plain, */*',
                    'x-apple-rap2-api': '3.0.0',
                    'x-apple-xsrf-token': token,
                },
                credentials: 'include',
                body: JSON.stringify(body),
            });
            if (!res.ok) return JSON.stringify({ __status: res.status });
            return await res.text();
            """
        let raw = try await webView.callAsyncJavaScript(
            script,
            arguments: ["token": token, "dsid": dsid, "batchId": batchId ?? NSNull()],
            contentWorld: .page
        )
        guard let text = raw as? String, let data = text.data(using: .utf8) else {
            throw SyncError.malformed
        }
        if let failure = try? JSONDecoder().decode([String: Int].self, from: data),
           let status = failure["__status"] {
            throw SyncError.http(status)
        }
        guard let page = try? JSONDecoder().decode(RAPSearchResponse.self, from: data) else {
            throw SyncError.malformed
        }
        return page
    }
}

extension PurchaseSyncEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startLoginPolling()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        phase = .failed(error.localizedDescription)
    }
}

/// 把 WKWebView 放进 SwiftUI。登录界面要真实可交互，不能只是后台跑。
struct PurchaseLoginWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
