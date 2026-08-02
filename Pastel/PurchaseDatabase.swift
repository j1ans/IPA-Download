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
        // 聚合重算时按 (账户, App, 时间) 连回最新那行，靠这条索引避免逐组排序。
        try execute("CREATE INDEX IF NOT EXISTS idx_line_items_latest ON line_items(dsid, adam_id, pli_date);")
        // 按 App 聚合的结果物化成表。
        //
        // 直接在 line_items 上 GROUP BY 翻页，代价与账户总量成正比而不是页大小：
        // 实测 5 万个 App 时首页要 890ms、中段翻页 371ms，滚动根本跟不上。物化之后
        // 排序键进了索引，翻页退化成索引扫描，与总量无关。
        //
        // 计数不是累加而是每次从 line_items 重算，所以重复同步依然幂等。
        try execute("""
            CREATE TABLE IF NOT EXISTS purchased_apps (
                dsid           TEXT NOT NULL,
                adam_id        TEXT NOT NULL,
                first_date     TEXT NOT NULL DEFAULT '',
                last_date      TEXT NOT NULL DEFAULT '',
                purchase_count INTEGER NOT NULL DEFAULT 0,
                name           TEXT NOT NULL DEFAULT '',
                developer      TEXT NOT NULL DEFAULT '',
                artwork_url    TEXT NOT NULL DEFAULT '',
                storefront_id  TEXT NOT NULL DEFAULT '',
                is_free        INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (dsid, adam_id)
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_apps_order ON purchased_apps(dsid, first_date, adam_id);")
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
                try refreshAggregate(for: items)
                try executeRaw("COMMIT;")
                return items.count
            } catch {
                try? executeRaw("ROLLBACK;")
                throw error
            }
        }
    }

    /// 重算受影响 App 的聚合行。
    ///
    /// 一次同步只碰十几个 App 时逐个点查最快；首次全量导入一次会带进几万个，那时
    /// 单条语句整账户重算反而更划算 —— 几万次点查的开销远大于一次全表扫描。
    private func refreshAggregate(for items: [PurchaseDatabase.LineItem]) throws {
        let touched = Set(items.filter { $0.kind == .iosApp }.map { AccountApp(dsid: $0.dsid, adamId: $0.adamId) })
        guard !touched.isEmpty else { return }

        if touched.count > 2000 {
            for dsid in Set(touched.map(\.dsid)) {
                try rebuildAggregateRaw(dsid: dsid, adamId: nil)
            }
        } else {
            for entry in touched {
                try rebuildAggregateRaw(dsid: entry.dsid, adamId: entry.adamId)
            }
        }
    }

    private struct AccountApp: Hashable {
        let dsid: String
        let adamId: String
    }

    /// adamId 为 nil 时重算整个账户。名称与图标取最近一次购买记录 —— App 会改名换图。
    private func rebuildAggregateRaw(dsid: String, adamId: String?) throws {
        let scope = adamId == nil ? "" : " AND adam_id = ?2"
        // 名称/图标要取「最近一次购买」那行。用相关子查询逐组去捞，每组都得排一次序，
        // 五万组能跑上几分钟；改成先一次分组求出 MIN/MAX，再按 (dsid, adam_id, pli_date)
        // 索引连回最新那行，全程只有一次扫描加一次索引连接。
        let sql = """
            INSERT OR REPLACE INTO purchased_apps
                (dsid, adam_id, first_date, last_date, purchase_count,
                 name, developer, artwork_url, storefront_id, is_free)
            SELECT g.dsid, g.adam_id, g.first_date, g.last_date, g.cnt,
                   n.name, n.detail, n.artwork_url, n.storefront_id, g.is_free
            FROM (
                SELECT dsid, adam_id,
                       MIN(pli_date) AS first_date, MAX(pli_date) AS last_date,
                       COUNT(*) AS cnt, MIN(is_free) AS is_free
                FROM line_items
                WHERE dsid = ?1 AND line_item_type = 'IOSApp'\(scope)
                GROUP BY dsid, adam_id
            ) g
            JOIN line_items n
              ON n.dsid = g.dsid AND n.adam_id = g.adam_id
             AND n.line_item_type = 'IOSApp' AND n.pli_date = g.last_date
            GROUP BY g.dsid, g.adam_id;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statement(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, dsid)
        if let adamId { bindText(statement, 2, adamId) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.statement(lastErrorMessage())
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
                       (SELECT COUNT(*) FROM purchased_apps p WHERE p.dsid = a.dsid) AS app_count
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
            try executeRaw("DELETE FROM purchased_apps;")
            try executeRaw("DELETE FROM accounts;")
        }
    }

    func remove(dsid: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            for sql in ["DELETE FROM line_items WHERE dsid = ?1;", "DELETE FROM purchased_apps WHERE dsid = ?1;"] {
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.statement(lastErrorMessage())
                }
                bindText(statement, 1, dsid)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }

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
                SELECT adam_id, name, developer, artwork_url, storefront_id,
                       first_date, last_date, purchase_count, is_free
                FROM purchased_apps
                WHERE dsid = ?1
                """
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (name LIKE ?2 OR developer LIKE ?2 OR adam_id LIKE ?2)"
            }
            sql += " ORDER BY first_date ASC, adam_id ASC LIMIT ?\(trimmed.isEmpty ? 2 : 3) OFFSET ?\(trimmed.isEmpty ? 3 : 4);"

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
                results.append(PurchasedApp(
                    id: column(statement, 0),
                    name: column(statement, 1),
                    developer: column(statement, 2),
                    artworkURL: column(statement, 3),
                    storefrontId: column(statement, 4),
                    firstPurchaseDate: column(statement, 5),
                    lastPurchaseDate: column(statement, 6),
                    purchaseCount: Int(sqlite3_column_int(statement, 7)),
                    isFree: sqlite3_column_int(statement, 8) != 0
                ))
            }
            return results
        }
    }

    func purchasedAppCount(dsid: String, matching query: String = "") throws -> Int {
        try queue.sync {
            var sql = "SELECT COUNT(*) FROM purchased_apps WHERE dsid = ?1"
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (name LIKE ?2 OR developer LIKE ?2 OR adam_id LIKE ?2)"
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
