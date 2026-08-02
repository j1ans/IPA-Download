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
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_type ON line_items(line_item_type);")
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_adam ON line_items(adam_id);")
        try execute("""
            CREATE TABLE IF NOT EXISTS sync_state (
                dsid            TEXT PRIMARY KEY,
                last_synced_at  TEXT NOT NULL DEFAULT '',
                line_item_count INTEGER NOT NULL DEFAULT 0
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

    func recordSync(dsid: String, lineItemCount: Int) throws {
        try queue.sync {
            let sql = """
                INSERT INTO sync_state (dsid, last_synced_at, line_item_count) VALUES (?1, ?2, ?3)
                ON CONFLICT(dsid) DO UPDATE SET last_synced_at=excluded.last_synced_at,
                                               line_item_count=excluded.line_item_count;
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, dsid)
            bindText(statement, 2, ISO8601DateFormatter().string(from: Date()))
            sqlite3_bind_int(statement, 3, Int32(lineItemCount))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.statement(lastErrorMessage())
            }
        }
    }

    func removeAll() throws {
        try queue.sync {
            try executeRaw("DELETE FROM line_items;")
            try executeRaw("DELETE FROM sync_state;")
        }
    }

    // MARK: 读取

    /// 按 App 聚合。购买时间取最早的一次（同一个 App 可能因重新下载、家庭共享等出现多条），
    /// 而名称和图标取最新一条 —— App 会改名换图，显示当然要用最近的。
    ///
    /// 这里用到 SQLite 的一个特性：聚合里出现 MAX()/MIN() 时，同一 SELECT 中未聚合的裸列
    /// 取自命中那一行。所以 name/detail/artwork 来自 MAX(pli_date) 那行。
    func purchasedApps(matching query: String = "") throws -> [PurchasedApp] {
        try queue.sync {
            var sql = """
                SELECT adam_id,
                       MAX(pli_date) AS last_date,
                       name, detail, artwork_url, storefront_id, is_free,
                       COUNT(*) AS purchase_count,
                       (SELECT MIN(x.pli_date) FROM line_items x
                         WHERE x.adam_id = l.adam_id AND x.line_item_type = 'IOSApp') AS first_date
                FROM line_items l
                WHERE line_item_type = 'IOSApp'
                """
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (name LIKE ?1 OR detail LIKE ?1 OR adam_id LIKE ?1)"
            }
            sql += " GROUP BY adam_id ORDER BY first_date DESC;"

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            if !trimmed.isEmpty { bindText(statement, 1, "%\(trimmed)%") }

            var results: [PurchasedApp] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(PurchasedApp(
                    id: column(statement, 0),
                    name: column(statement, 2),
                    developer: column(statement, 3),
                    artworkURL: column(statement, 4),
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

    func stats() throws -> Stats {
        try queue.sync {
            var stats = Stats()
            var statement: OpaquePointer?
            let sql = "SELECT line_item_type, COUNT(*) FROM line_items GROUP BY line_item_type;"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.statement(lastErrorMessage())
            }
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
            if sqlite3_prepare_v2(handle, "SELECT MAX(last_synced_at) FROM sync_state;", -1, &syncStatement, nil) == SQLITE_OK {
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
