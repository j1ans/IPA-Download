import Foundation
import SQLite3

// MARK: - reportaproblem.apple.com 的响应模型

/// `POST /api/purchase/search` 的一页结果。游标分页：把 nextBatchId 回传即取下一页，
/// 为空即到底。
struct RAPSearchResponse: Decodable {
    let purchases: [RAPPurchase]?
    let nextBatchId: String?
}

struct RAPPurchase: Decodable {
    let purchaseId: String?
    let purchaseDate: String?
    let plis: [RAPLineItem]?
}

struct RAPLineItem: Decodable {
    let itemId: String?
    let adamId: String?
    let storefrontId: String?
    let lineItemType: String?
    let pliDate: String?
    let amountPaid: String?
    let isFreePurchase: Bool?
    let localizedContent: RAPLocalizedContent?
}

struct RAPLocalizedContent: Decodable {
    let nameForDisplay: String?
    /// App 记录里是开发者名；内购记录里是所属 App 的名字。
    let detailForDisplay: String?
    let artworkURL: String?
    let mediaType: String?
}

/// 明细行的类别。
///
/// 判据用 `lineItemType` 而不是 `mediaType`：前者是机器枚举，后者是给人看的字符串，
/// 实测同为 `IOSApp` 的记录，mediaType 有的写 `iOS App`、有的只写 `App`，不可靠。
enum PurchaseItemKind: String {
    case iosApp        // IOSApp —— 唯一能拿去下 IPA 的
    case macApp        // MacApp —— 不是 iOS 包
    case subscription  // BaseSubscription
    case inAppPurchase // BaseLineItem
    case other

    init(lineItemType: String) {
        switch lineItemType {
        case "IOSApp": self = .iosApp
        case "MacApp": self = .macApp
        case "BaseSubscription": self = .subscription
        case "BaseLineItem": self = .inAppPurchase
        default: self = .other
        }
    }

    var localizedName: String {
        switch self {
        case .iosApp: return String(localized: "iOS App")
        case .macApp: return String(localized: "Mac App")
        case .subscription: return String(localized: "订阅")
        case .inAppPurchase: return String(localized: "应用内购买")
        case .other: return String(localized: "其他")
        }
    }
}

// MARK: - 本地库

/// 购买记录的本地 SQLite 库。
///
/// 分两层存：`line_items` 保存 Apple 返回的原始明细，主键就是它自己的 itemId，所以
/// 重复同步是幂等的；App 列表在其上聚合得出。如果只维护一张聚合表、每次同步给计数
/// 加一，重抓一次数字就翻倍 —— 分层能从根上避免这类问题。
final class PurchaseDatabase {
    struct LineItem {
        let itemId: String
        let purchaseId: String
        let adamId: String
        let lineItemType: String
        let mediaType: String
        let name: String
        let detail: String
        let artworkURL: String
        let storefrontId: String
        let amountPaid: String
        let isFree: Bool
        let pliDate: String
        let dsid: String

        var kind: PurchaseItemKind { PurchaseItemKind(lineItemType: lineItemType) }
    }

    struct PurchasedApp: Identifiable, Hashable {
        let id: String           // adamId，即 App ID
        let name: String
        let developer: String
        let artworkURL: String
        let storefrontId: String
        /// 同一个 App 有多条购买记录时取最早的那次 —— 那才是「何时拥有」。
        let firstPurchaseDate: String
        let lastPurchaseDate: String
        let purchaseCount: Int
        let isFree: Bool
    }

    struct Stats {
        var iosApps = 0
        var macApps = 0
        var subscriptions = 0
        var inAppPurchases = 0
        var other = 0
        var lastSyncedAt: String?

        var totalLineItems: Int { iosApps + macApps + subscriptions + inAppPurchases + other }
    }

    /// 一个已同步过的 Apple 账户。侧栏按它分组。
    struct Account: Identifiable, Hashable {
        let id: String          // dsid
        let name: String
        let email: String
        let lastSyncedAt: String
        /// 已抓到的最新一条明细的时间，增量同步的起点。
        let newestPliDate: String
        let appCount: Int
    }

    enum DatabaseError: LocalizedError {
        case open(String)
        case statement(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): return String(localized: "无法打开购买记录数据库：\(message)")
            case .statement(let message): return String(localized: "购买记录数据库操作失败：\(message)")
            }
        }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.allenmiao.pastel.purchasedb")

    static func defaultURL() -> URL {
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPA Download", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("purchases.sqlite")
    }

    init(url: URL? = nil) throws {
        let target = url ?? Self.defaultURL()
        var db: OpaquePointer?
        guard sqlite3_open_v2(target.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK,
              let opened = db
        else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        handle = opened
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS line_items (
                item_id        TEXT PRIMARY KEY,
                purchase_id    TEXT NOT NULL DEFAULT '',
                adam_id        TEXT NOT NULL DEFAULT '',
                line_item_type TEXT NOT NULL DEFAULT '',
                media_type     TEXT NOT NULL DEFAULT '',
                name           TEXT NOT NULL DEFAULT '',
                detail         TEXT NOT NULL DEFAULT '',
                artwork_url    TEXT NOT NULL DEFAULT '',
                storefront_id  TEXT NOT NULL DEFAULT '',
                amount_paid    TEXT NOT NULL DEFAULT '',
                is_free        INTEGER NOT NULL DEFAULT 0,
                pli_date       TEXT NOT NULL DEFAULT '',
                dsid           TEXT NOT NULL DEFAULT '',
                synced_at      TEXT NOT NULL DEFAULT ''
            );
            """)
        // 列表按 (账户, 类型) 过滤后再按购买时间排序，复合索引让几万行也不用整表扫。
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_lookup ON line_items(dsid, line_item_type, adam_id);")
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_date ON line_items(dsid, line_item_type, pli_date);")
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_adam ON line_items(adam_id);")
        try execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                dsid            TEXT PRIMARY KEY,
                name            TEXT NOT NULL DEFAULT '',
                email           TEXT NOT NULL DEFAULT '',
                last_synced_at  TEXT NOT NULL DEFAULT '',
                newest_pli_date TEXT NOT NULL DEFAULT ''
            );
            """)
    }

    // MARK: 写入

    /// 幂等写入：主键是 Apple 自己的 itemId，同一批记录重复同步只会覆盖、不会重复累计。
    @discardableResult
    func upsert(_ items: [LineItem]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try queue.sync {
            try executeRaw("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let sql = """
                    INSERT INTO line_items
                        (item_id, purchase_id, adam_id, line_item_type, media_type, name, detail,
                         artwork_url, storefront_id, amount_paid, is_free, pli_date, dsid, synced_at)
                    VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
                    ON CONFLICT(item_id) DO UPDATE SET
                        purchase_id=excluded.purchase_id, adam_id=excluded.adam_id,
                        line_item_type=excluded.line_item_type, media_type=excluded.media_type,
                        name=excluded.name, detail=excluded.detail, artwork_url=excluded.artwork_url,
                        storefront_id=excluded.storefront_id, amount_paid=excluded.amount_paid,
                        is_free=excluded.is_free, pli_date=excluded.pli_date, dsid=excluded.dsid,
                        synced_at=excluded.synced_at;
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.statement(lastErrorMessage())
                }
                defer { sqlite3_finalize(statement) }

                let now = ISO8601DateFormatter().string(from: Date())
                for item in items {
                    sqlite3_reset(statement)
                    bindText(statement, 1, item.itemId)
                    bindText(statement, 2, item.purchaseId)
                    bindText(statement, 3, item.adamId)
                    bindText(statement, 4, item.lineItemType)
                    bindText(statement, 5, item.mediaType)
                    bindText(statement, 6, item.name)
                    bindText(statement, 7, item.detail)
                    bindText(statement, 8, item.artworkURL)
                    bindText(statement, 9, item.storefrontId)
                    bindText(statement, 10, item.amountPaid)
                    sqlite3_bind_int(statement, 11, item.isFree ? 1 : 0)
                    bindText(statement, 12, item.pliDate)
                    bindText(statement, 13, item.dsid)
                    bindText(statement, 14, now)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.statement(lastErrorMessage())
                    }
                }
                try executeRaw("COMMIT;")
                return items.count
            } catch {
                try? executeRaw("ROLLBACK;")
                throw error
            }
        }
    }

    /// 记录一次同步。newest_pli_date 只增不减 —— 它是下次增量同步的停止线，
    /// 被一次抓得不全的同步往回改会导致后续永远停得太早、漏掉中间的记录。
    func recordSync(dsid: String, name: String, email: String) throws {
        try queue.sync {
            let sql = """
                INSERT INTO accounts (dsid, name, email, last_synced_at, newest_pli_date)
                VALUES (?1, ?2, ?3, ?4,
                        COALESCE((SELECT MAX(pli_date) FROM line_items WHERE dsid = ?1), ''))
                ON CONFLICT(dsid) DO UPDATE SET
                    name = CASE WHEN excluded.name != '' THEN excluded.name ELSE accounts.name END,
                    email = CASE WHEN excluded.email != '' THEN excluded.email ELSE accounts.email END,
                    last_synced_at = excluded.last_synced_at,
                    newest_pli_date = MAX(accounts.newest_pli_date, excluded.newest_pli_date);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, dsid)
            bindText(statement, 2, name)
            bindText(statement, 3, email)
            bindText(statement, 4, ISO8601DateFormatter().string(from: Date()))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.statement(lastErrorMessage())
            }
        }
    }

    /// 增量同步的停止线：该账户已抓到的最新一条明细时间。空串表示从未同步过，需要全量。
    func newestPliDate(dsid: String) throws -> String {
        try queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT newest_pli_date FROM accounts WHERE dsid = ?1;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, dsid)
            guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
            return column(statement, 0)
        }
    }

    func accounts() throws -> [Account] {
        try queue.sync {
            let sql = """
                SELECT a.dsid, a.name, a.email, a.last_synced_at, a.newest_pli_date,
                       (SELECT COUNT(DISTINCT l.adam_id) FROM line_items l
                         WHERE l.dsid = a.dsid AND l.line_item_type = 'IOSApp') AS app_count
                FROM accounts a
                ORDER BY a.last_synced_at DESC;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            var result: [Account] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Account(
                    id: column(statement, 0),
                    name: column(statement, 1),
                    email: column(statement, 2),
                    lastSyncedAt: column(statement, 3),
                    newestPliDate: column(statement, 4),
                    appCount: Int(sqlite3_column_int(statement, 5))
                ))
            }
            return result
        }
    }

    func removeAll() throws {
        try queue.sync {
            try executeRaw("DELETE FROM line_items;")
            try executeRaw("DELETE FROM accounts;")
        }
    }

    func remove(dsid: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM line_items WHERE dsid = ?1;", -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            bindText(statement, 1, dsid)
            sqlite3_step(statement)
            sqlite3_finalize(statement)

            guard sqlite3_prepare_v2(handle, "DELETE FROM accounts WHERE dsid = ?1;", -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            bindText(statement, 1, dsid)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    // MARK: 读取

    /// 按 App 聚合。购买时间取最早的一次（同一个 App 可能因重新下载、家庭共享等出现多条），
    /// 而名称和图标取最新一条 —— App 会改名换图，显示当然要用最近的。
    ///
    /// 这里用到 SQLite 的一个特性：聚合里出现 MAX()/MIN() 时，同一 SELECT 中未聚合的裸列
    /// 取自命中那一行。所以 name/detail/artwork 来自 MAX(pli_date) 那行。
    /// 按购买日期从早到晚返回一页。几万条记录不能一次性读进内存，界面按需取页。
    func purchasedApps(dsid: String,
                       matching query: String = "",
                       limit: Int,
                       offset: Int) throws -> [PurchasedApp] {
        try queue.sync {
            var sql = """
                SELECT adam_id,
                       MAX(pli_date) AS last_date,
                       name, detail, artwork_url, storefront_id, is_free,
                       COUNT(*) AS purchase_count,
                       MIN(pli_date) AS first_date
                FROM line_items
                WHERE line_item_type = 'IOSApp' AND dsid = ?1
                """
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (name LIKE ?2 OR detail LIKE ?2 OR adam_id LIKE ?2)"
            }
            // MIN()/MAX() 同时出现时裸列的归属没有保证，所以名称单独用子查询取最新那条。
            sql += " GROUP BY adam_id ORDER BY first_date ASC, adam_id ASC LIMIT ?\(trimmed.isEmpty ? 2 : 3) OFFSET ?\(trimmed.isEmpty ? 3 : 4);"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, dsid)
            var next: Int32 = 2
            if !trimmed.isEmpty {
                bindText(statement, 2, "%\(trimmed)%")
                next = 3
            }
            sqlite3_bind_int(statement, next, Int32(limit))
            sqlite3_bind_int(statement, next + 1, Int32(offset))

            var results: [PurchasedApp] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let adamId = column(statement, 0)
                let latest = try latestMetadata(adamId: adamId, dsid: dsid)
                results.append(PurchasedApp(
                    id: adamId,
                    name: latest.name.isEmpty ? column(statement, 2) : latest.name,
                    developer: latest.detail.isEmpty ? column(statement, 3) : latest.detail,
                    artworkURL: latest.artwork.isEmpty ? column(statement, 4) : latest.artwork,
                    storefrontId: column(statement, 5),
                    firstPurchaseDate: column(statement, 8),
                    lastPurchaseDate: column(statement, 1),
                    purchaseCount: Int(sqlite3_column_int(statement, 7)),
                    isFree: sqlite3_column_int(statement, 6) != 0
                ))
            }
            return results
        }
    }

    /// App 会改名换图，展示该用最近一次购买记录里的名称与图标。
    private func latestMetadata(adamId: String, dsid: String) throws -> (name: String, detail: String, artwork: String) {
        var statement: OpaquePointer?
        let sql = """
            SELECT name, detail, artwork_url FROM line_items
            WHERE adam_id = ?1 AND dsid = ?2 AND line_item_type = 'IOSApp'
            ORDER BY pli_date DESC LIMIT 1;
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statement(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, adamId)
        bindText(statement, 2, dsid)
        guard sqlite3_step(statement) == SQLITE_ROW else { return ("", "", "") }
        return (column(statement, 0), column(statement, 1), column(statement, 2))
    }

    func purchasedAppCount(dsid: String, matching query: String = "") throws -> Int {
        try queue.sync {
            var sql = """
                SELECT COUNT(DISTINCT adam_id) FROM line_items
                WHERE line_item_type = 'IOSApp' AND dsid = ?1
                """
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (name LIKE ?2 OR detail LIKE ?2 OR adam_id LIKE ?2)"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, dsid)
            if !trimmed.isEmpty { bindText(statement, 2, "%\(trimmed)%") }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func stats(dsid: String = "") throws -> Stats {
        try queue.sync {
            var stats = Stats()
            var statement: OpaquePointer?
            let sql = dsid.isEmpty
                ? "SELECT line_item_type, COUNT(*) FROM line_items GROUP BY line_item_type;"
                : "SELECT line_item_type, COUNT(*) FROM line_items WHERE dsid = ?1 GROUP BY line_item_type;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            if !dsid.isEmpty { bindText(statement, 1, dsid) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(statement, 1))
                switch PurchaseItemKind(lineItemType: column(statement, 0)) {
                case .iosApp: stats.iosApps += count
                case .macApp: stats.macApps += count
                case .subscription: stats.subscriptions += count
                case .inAppPurchase: stats.inAppPurchases += count
                case .other: stats.other += count
                }
            }
            sqlite3_finalize(statement)

            var syncStatement: OpaquePointer?
            if sqlite3_prepare_v2(handle, "SELECT MAX(last_synced_at) FROM accounts;", -1, &syncStatement, nil) == SQLITE_OK {
                if sqlite3_step(syncStatement) == SQLITE_ROW, sqlite3_column_type(syncStatement, 0) != SQLITE_NULL {
                    let value = column(syncStatement, 0)
                    stats.lastSyncedAt = value.isEmpty ? nil : value
                }
            }
            sqlite3_finalize(syncStatement)
            return stats
        }
    }

    // MARK: 底层封装

    private func execute(_ sql: String) throws {
        try queue.sync { try executeRaw(sql) }
    }

    private func executeRaw(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(error)
            throw DatabaseError.statement(message)
        }
    }

    private func lastErrorMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    /// SQLITE_TRANSIENT：让 SQLite 自己拷贝字符串，否则 Swift 的临时缓冲在 step 之前就可能被回收。
    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}

// MARK: - 从 API 响应转成待写入的明细行

extension PurchaseDatabase.LineItem {
    /// Apple 偶尔会返回缺 itemId 的行，那种没法当主键，直接丢弃。
    init?(purchase: RAPPurchase, item: RAPLineItem, dsid: String) {
        guard let itemId = item.itemId, !itemId.isEmpty else { return nil }
        self.init(
            itemId: itemId,
            purchaseId: item.purchaseId(fallback: purchase.purchaseId),
            adamId: item.adamId ?? "",
            lineItemType: item.lineItemType ?? "",
            mediaType: item.localizedContent?.mediaType ?? "",
            name: item.localizedContent?.nameForDisplay ?? "",
            detail: item.localizedContent?.detailForDisplay ?? "",
            artworkURL: item.localizedContent?.artworkURL ?? "",
            storefrontId: item.storefrontId ?? "",
            amountPaid: item.amountPaid ?? "",
            isFree: item.isFreePurchase ?? false,
            pliDate: item.pliDate ?? purchase.purchaseDate ?? "",
            dsid: dsid
        )
    }
}

private extension RAPLineItem {
    func purchaseId(fallback: String?) -> String {
        fallback ?? ""
    }
}
