import AppKit
import SwiftUI

/// 图标缓存。
///
/// 一个账户可能有几万条购买记录，用字典缓存等于把几万张图钉死在内存里。NSCache 有条数
/// 上限、且在系统内存吃紧时会自动回收，配合行视图滚出视野即释放自己那份强引用，内存
/// 就只跟「可见行数」有关，而不是「记录总数」。
@MainActor
final class PurchaseIconCache {
    static let shared = PurchaseIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
    }

    func cached(_ urlString: String) -> NSImage? {
        cache.object(forKey: urlString as NSString)
    }

    func image(for urlString: String) async -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        if let hit = cached(urlString) { return hit }
        if let running = inFlight[urlString] { return await running.value }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let url = URL(string: urlString) else { return nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)
            else { return nil }
            await MainActor.run { self?.cache.setObject(image, forKey: urlString as NSString) }
            return image
        }
        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil
        return result
    }
}

/// 购买记录页的数据源。按账户分区，按页取数 —— 几万条不可能一次性读进内存。
@MainActor
final class PurchaseLibraryModel: ObservableObject {
    @Published private(set) var accounts: [PurchaseDatabase.Account] = []
    @Published private(set) var rows: [PurchaseDatabase.PurchasedApp] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published var selectedDsid = ""
    @Published var searchText = ""
    @Published var message = ""

    /// 一次取一页；行数远超屏幕容量，滚到接近末尾时才继续取下一页。
    private static let pageSize = 120

    private var database: PurchaseDatabase?
    private var loadTask: Task<Void, Never>?
    private var reachedEnd = false

    func open() {
        guard database == nil else { return }
        do {
            database = try PurchaseDatabase()
        } catch {
            message = error.localizedDescription
        }
        reloadAccounts()
    }

    var db: PurchaseDatabase? { database }

    func reloadAccounts() {
        guard let database else { return }
        do {
            accounts = try database.accounts()
            if selectedDsid.isEmpty || !accounts.contains(where: { $0.id == selectedDsid }) {
                selectedDsid = accounts.first?.id ?? ""
            }
            reloadRows()
        } catch {
            message = error.localizedDescription
        }
    }

    func reloadRows() {
        loadTask?.cancel()
        rows = []
        reachedEnd = false
        guard let database, !selectedDsid.isEmpty else {
            totalCount = 0
            return
        }
        let dsid = selectedDsid
        let query = searchText
        loadTask = Task {
            do {
                let count = try await Task.detached { try database.purchasedAppCount(dsid: dsid, matching: query) }.value
                guard !Task.isCancelled else { return }
                totalCount = count
                await loadNextPage()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// 滚到离末尾还有一屏时预取下一页，避免滚动时卡顿。
    func loadMoreIfNeeded(currentItemID: String) {
        guard !isLoading, !reachedEnd,
              let index = rows.firstIndex(where: { $0.id == currentItemID }),
              index >= rows.count - 20
        else { return }
        Task { await loadNextPage() }
    }

    private func loadNextPage() async {
        guard let database, !selectedDsid.isEmpty, !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }

        let dsid = selectedDsid
        let query = searchText
        let offset = rows.count
        do {
            let page = try await Task.detached {
                try database.purchasedApps(dsid: dsid, matching: query, limit: Self.pageSize, offset: offset)
            }.value
            guard !Task.isCancelled, dsid == selectedDsid, query == searchText else { return }
            if page.count < Self.pageSize { reachedEnd = true }
            rows.append(contentsOf: page)
        } catch {
            message = error.localizedDescription
            reachedEnd = true
        }
    }

    /// 当前筛选下的全部 App，用于「全部加入清单」。不经过 rows，避免要求先滚到底。
    func allMatchingApps() async -> [PurchaseDatabase.PurchasedApp] {
        guard let database, !selectedDsid.isEmpty else { return [] }
        let dsid = selectedDsid
        let query = searchText
        return await Task.detached {
            var collected: [PurchaseDatabase.PurchasedApp] = []
            var offset = 0
            while true {
                guard let page = try? database.purchasedApps(dsid: dsid, matching: query, limit: 500, offset: offset),
                      !page.isEmpty
                else { break }
                collected.append(contentsOf: page)
                offset += page.count
                if page.count < 500 { break }
            }
            return collected
        }.value
    }

    func removeAccount(_ dsid: String) {
        guard let database else { return }
        do {
            try database.remove(dsid: dsid)
            reloadAccounts()
        } catch {
            message = error.localizedDescription
        }
    }

    static func displayDate(_ raw: String) -> String {
        guard raw.count >= 10 else { return raw }
        return String(raw.prefix(10))
    }
}

extension BatchListEntry {
    init(purchased app: PurchaseDatabase.PurchasedApp) {
        self.init(id: app.id, name: app.name, developer: app.developer,
                  artworkUrl: app.artworkURL, bundleId: "",
                  platform: "", addedAt: Date())
    }
}

/// 单行。图标在行出现时才取、消失时立刻放掉自己的强引用 —— 内存只跟可见行数有关。
struct PurchaseAppRow: View {
    let app: PurchaseDatabase.PurchasedApp
    let isInList: Bool
    let onToggleList: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 11) {
            iconView
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name.isEmpty ? String(localized: "未知 App") : app.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(PurchaseLibraryModel.displayDate(app.firstPurchaseDate))
                        .monospacedDigit()
                    Text("·")
                    Text(app.id).monospacedDigit()
                    if app.purchaseCount > 1 {
                        Text("·")
                        Text(String(localized: "\(app.purchaseCount) 次"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onToggleList) {
                Label(isInList ? String(localized: "已在清单") : String(localized: "加入清单"),
                      systemImage: isInList ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isInList ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
        .task(id: app.artworkURL) {
            if icon == nil { icon = await PurchaseIconCache.shared.image(for: app.artworkURL) }
        }
        .onDisappear {
            // 滚出视野即放掉这一份引用；缓存自身有上限，超出的会被系统回收。
            icon = nil
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        }
    }
}

/// 购买记录页：左侧按 Apple 账户分区，右侧是该账户买过的 App。
struct PurchaseLibraryWorkspace: View {
    @ObservedObject var model: PurchaseLibraryModel
    @ObservedObject var sync: PurchaseSyncEngine
    @ObservedObject var batchList: BatchListStore
    @State private var showingLogin = false
    @State private var isAddingAll = false

    var body: some View {
        NavigationSplitView {
            accountSidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 268, max: 320)
        } detail: {
            appList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onAppear { model.open() }
        .sheet(isPresented: $showingLogin) { loginSheet }
    }

    // MARK: 侧栏：按账户分区

    private var accountSidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedDsid },
                set: { newValue in
                    guard newValue != model.selectedDsid else { return }
                    model.selectedDsid = newValue
                    model.reloadRows()
                }
            )) {
                Section(String(localized: "Apple 账户")) {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name.isEmpty ? account.id : account.name)
                                .font(.body)
                                .lineLimit(1)
                            Text(account.email.isEmpty
                                 ? String(localized: "\(account.appCount) 个 App")
                                 : "\(account.email) · \(account.appCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(account.id)
                        .contextMenu {
                            Button(String(localized: "删除此账户的记录"), role: .destructive) {
                                model.removeAccount(account.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(spacing: 8) {
                Button {
                    sync.loadSite()
                    showingLogin = true
                } label: {
                    Label(model.accounts.isEmpty
                          ? String(localized: "登录并导入购买记录")
                          : String(localized: "同步 / 添加账户"),
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
        }
    }

    // MARK: 右侧：App 列表

    private var appList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()

            if model.accounts.isEmpty {
                emptyState(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: String(localized: "还没有导入购买记录"),
                    message: String(localized: "登录 Apple 账户后可以取回全部购买过的 App —— 包括已下架、搜不到的那些。")
                )
            } else if model.rows.isEmpty && !model.isLoading {
                emptyState(
                    systemImage: "magnifyingglass",
                    title: String(localized: "没有匹配的 App"),
                    message: String(localized: "换个关键词，或同步这个账户的购买记录。")
                )
            } else {
                // List 会回收行视图，配合行内图标的按需加载与释放，
                // 内存只跟可见行数有关，几万条也不会线性膨胀。
                List(model.rows) { app in
                    PurchaseAppRow(
                        app: app,
                        isInList: batchList.contains(app.id),
                        onToggleList: {
                            if batchList.contains(app.id) {
                                batchList.remove(app.id)
                            } else {
                                batchList.add(BatchListEntry(purchased: app))
                            }
                        }
                    )
                    .onAppear { model.loadMoreIfNeeded(currentItemID: app.id) }
                }
                .listStyle(.inset)
            }
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(localized: "购买记录"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "\(model.totalCount) 个 App"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button {
                    addAllToBatchList()
                } label: {
                    Label(String(localized: "全部加入清单"), systemImage: "text.badge.plus")
                }
                .disabled(model.totalCount == 0 || isAddingAll)
            }

            TextField(String(localized: "搜索名称、开发者或 App ID"), text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.reloadRows() }
                .onChange(of: model.searchText) { _, _ in model.reloadRows() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func addAllToBatchList() {
        isAddingAll = true
        Task {
            let apps = await model.allMatchingApps()
            var added = 0
            for app in apps where !batchList.contains(app.id) {
                batchList.add(BatchListEntry(purchased: app))
                added += 1
            }
            model.message = String(localized: "已加入清单 \(added) 个 App。")
            isAddingAll = false
        }
    }

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 登录 / 同步面板

    private var loginSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(localized: "导入购买记录"))
                    .font(.headline)
                Spacer()
                syncStatusLabel
                Button(String(localized: "完成")) {
                    sync.cancel()
                    showingLogin = false
                    model.reloadAccounts()
                }
            }
            .padding(12)

            Divider()

            PurchaseLoginWebView(webView: sync.webView)
                .frame(minWidth: 720, minHeight: 520)

            Divider()

            HStack(spacing: 10) {
                Button(String(localized: "退出登录")) { sync.signOutAndReload() }

                Spacer()

                if case .syncing = sync.phase {
                    Button(String(localized: "停止")) { sync.cancel() }
                } else {
                    Button(String(localized: "增量同步")) { startSync(full: false) }
                    Button(String(localized: "全量重抓")) { startSync(full: true) }
                        .help(String(localized: "忽略已同步的进度，从头抓一遍"))
                }
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 660)
    }

    @ViewBuilder
    private var syncStatusLabel: some View {
        switch sync.phase {
        case .idle:
            if !sync.accountLabel.isEmpty {
                Text(sync.accountLabel).font(.caption).foregroundStyle(.secondary)
            }
        case .loadingPage:
            Text(String(localized: "正在加载…")).font(.caption).foregroundStyle(.secondary)
        case .needsLogin:
            Text(String(localized: "请在下方登录 Apple 账户")).font(.caption).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "已抓 \(sync.pagesFetched) 页 / \(sync.itemsScanned) 条"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished(let added, let scanned, let stoppedEarly):
            Text(stoppedEarly
                 ? String(localized: "增量完成：扫描 \(scanned) 条，写入 \(added) 条")
                 : String(localized: "全量完成：扫描 \(scanned) 条，写入 \(added) 条"))
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func startSync(full: Bool) {
        guard let database = model.db else { return }
        sync.sync(into: database, fullResync: full)
    }
}
