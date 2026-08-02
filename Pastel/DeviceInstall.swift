import Foundation
import SwiftUI

/// libimobiledevice 的命令行工具。
///
/// 走命令行而不是链接动态库：这几个工具的输出格式稳定，而把 libimobiledevice 连同
/// libusbmuxd、libplist 一起打进 App 还要处理签名与路径重写，代价远大于收益。
enum MobileDeviceTools {
    /// Homebrew 在 Apple 芯片上装到 /opt/homebrew，Intel 上是 /usr/local。
    /// App 自己的进程不继承登录 shell 的 PATH，所以要显式找。
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func path(for tool: String) -> String? {
        for directory in searchPaths {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isAvailable: Bool {
        path(for: "idevice_id") != nil && path(for: "ideviceinfo") != nil
    }

    static var installerAvailable: Bool {
        path(for: "ideviceinstaller") != nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 20) -> (output: String, status: Int32)? {
        guard let executable = path(for: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }

        let handle = pipe.fileHandleForReading
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            data.append(handle.availableData)
            usleep(50_000)
        }
        if process.isRunning { process.terminate() }
        data.append(handle.readDataToEndOfFile())
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// 比较点分版本号，用于判断 MinimumOSVersion 与设备系统版本的高低。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// 机型标识到人类可读名称。覆盖到 iPhone/iPad/iPod 的常见型号，查不到就原样显示标识。
enum AppleDeviceNames {
    private static let table: [String: String] = [
        "iPod1,1": "iPod touch", "iPod2,1": "iPod touch 2", "iPod3,1": "iPod touch 3",
        "iPod4,1": "iPod touch 4", "iPod5,1": "iPod touch 5", "iPod7,1": "iPod touch 6",
        "iPod9,1": "iPod touch 7",
        "iPhone1,1": "iPhone", "iPhone1,2": "iPhone 3G", "iPhone2,1": "iPhone 3GS",
        "iPhone3,1": "iPhone 4", "iPhone3,2": "iPhone 4", "iPhone3,3": "iPhone 4",
        "iPhone4,1": "iPhone 4s", "iPhone5,1": "iPhone 5", "iPhone5,2": "iPhone 5",
        "iPhone5,3": "iPhone 5c", "iPhone5,4": "iPhone 5c",
        "iPhone6,1": "iPhone 5s", "iPhone6,2": "iPhone 5s",
        "iPhone7,2": "iPhone 6", "iPhone7,1": "iPhone 6 Plus",
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,5": "iPhone 8 Plus", "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,8": "iPhone XR", "iPhone11,2": "iPhone XS", "iPhone11,6": "iPhone XS Max",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE 2",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE 3",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPad1,1": "iPad", "iPad2,1": "iPad 2", "iPad3,1": "iPad 3", "iPad3,4": "iPad 4",
        "iPad4,1": "iPad Air", "iPad5,3": "iPad Air 2", "iPad11,3": "iPad Air 3",
        "iPad13,1": "iPad Air 4", "iPad13,16": "iPad Air 5",
        "iPad2,5": "iPad mini", "iPad4,4": "iPad mini 2", "iPad4,7": "iPad mini 3",
        "iPad5,1": "iPad mini 4", "iPad11,1": "iPad mini 5", "iPad14,1": "iPad mini 6",
        "iPad6,3": "iPad Pro 9.7", "iPad6,7": "iPad Pro 12.9", "iPad7,1": "iPad Pro 12.9 (2)",
        "iPad8,1": "iPad Pro 11", "iPad8,5": "iPad Pro 12.9 (3)",
    ]

    static func name(for productType: String) -> String {
        table[productType] ?? productType
    }
}

/// 一台已连接的设备。
struct ConnectedDevice: Identifiable, Hashable {
    let id: String          // UDID
    let name: String
    let productType: String
    let osVersion: String
    let deviceClass: String

    var modelName: String { AppleDeviceNames.name(for: productType) }

    /// 系统大版本，用来对上时间轴里的世代。
    var majorOSVersion: Int {
        Int(osVersion.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    /// 这台设备对应的系统世代 —— 「完美兼容版」筛选就是按它的版本 ID 窗口来的。
    var generation: CompatibilityGeneration? {
        VersionIDTimeline.generations.first { $0.osName == "iOS \(majorOSVersion)" }
    }

    var summary: String { "\(modelName) · iOS \(osVersion)" }
}

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published var selectedUDID = ""
    @Published private(set) var isRefreshing = false
    @Published var message = ""

    private var pollTask: Task<Void, Never>?

    var selectedDevice: ConnectedDevice? {
        devices.first { $0.id == selectedUDID }
    }

    var toolsAvailable: Bool { MobileDeviceTools.isAvailable }

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard MobileDeviceTools.isAvailable else {
            message = String(localized: "未找到 libimobiledevice。请先执行 brew install libimobiledevice ideviceinstaller。")
            devices = []
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let found = await Task.detached { () -> [ConnectedDevice] in
            guard let listing = MobileDeviceTools.run("idevice_id", ["-l"]) else { return [] }
            let udids = listing.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return udids.compactMap { udid in
                func value(_ key: String) -> String {
                    MobileDeviceTools.run("ideviceinfo", ["-u", udid, "-k", key])?
                        .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                let name = value("DeviceName")
                guard !name.isEmpty else { return nil }
                return ConnectedDevice(
                    id: udid,
                    name: name,
                    productType: value("ProductType"),
                    osVersion: value("ProductVersion"),
                    deviceClass: value("DeviceClass")
                )
            }
        }.value

        devices = found
        if selectedUDID.isEmpty || !found.contains(where: { $0.id == selectedUDID }) {
            selectedUDID = found.first?.id ?? ""
        }
        message = found.isEmpty
            ? String(localized: "没有检测到设备。用数据线连接并在设备上选择「信任」。")
            : ""
    }
}

/// 安装清单里一项的状态。
enum InstallState: Equatable {
    case pending
    case installing(Double?)
    case done
    case failed(String)
}

@MainActor
final class InstallQueue: ObservableObject {
    @Published private(set) var order: [String] = []      // IPA 文件路径
    @Published private(set) var states: [String: InstallState] = [:]
    @Published private(set) var isRunning = false
    @Published var message = ""

    private var task: Task<Void, Never>?

    func contains(_ path: String) -> Bool { order.contains(path) }

    func add(_ path: String) {
        guard !contains(path) else { return }
        order.append(path)
        states[path] = .pending
    }

    func remove(_ path: String) {
        order.removeAll { $0 == path }
        states[path] = nil
    }

    func removeAll() {
        guard !isRunning else { return }
        order.removeAll()
        states.removeAll()
    }

    func state(_ path: String) -> InstallState { states[path] ?? .pending }

    /// 整体进度。已完成与失败都按 100% 计 —— 失败的不会再前进，不计满会让进度条卡住。
    var progress: (fraction: Double, done: Int, failed: Int, total: Int) {
        guard !order.isEmpty else { return (0, 0, 0, 0) }
        var accumulated = 0.0
        var done = 0
        var failed = 0
        for path in order {
            switch state(path) {
            case .done: done += 1; accumulated += 1
            case .failed: failed += 1; accumulated += 1
            case .installing(let value): accumulated += min(max(value ?? 0, 0), 1)
            case .pending: break
            }
        }
        return (accumulated / Double(order.count), done, failed, order.count)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// 逐个安装。设备一次只能处理一个安装事务，并发只会互相打断。
    func start(udid: String) {
        guard !isRunning, !order.isEmpty else { return }
        guard MobileDeviceTools.installerAvailable else {
            message = String(localized: "未找到 ideviceinstaller。请先执行 brew install ideviceinstaller。")
            return
        }
        isRunning = true
        message = ""

        task = Task { @MainActor in
            defer { isRunning = false; task = nil }
            for path in order {
                if Task.isCancelled { return }
                if case .done = state(path) { continue }
                states[path] = .installing(nil)
                let result = await Self.install(path: path, udid: udid) { fraction in
                    Task { @MainActor in
                        if case .installing = self.states[path] { self.states[path] = .installing(fraction) }
                    }
                }
                states[path] = result
            }
            let summary = progress
            message = String(localized: "安装结束：成功 \(summary.done) 个，失败 \(summary.failed) 个。")
        }
    }

    nonisolated private static func install(path: String,
                                udid: String,
                                onProgress: @escaping (Double) -> Void) async -> InstallState {
        await Task.detached { () -> InstallState in
            guard let executable = MobileDeviceTools.path(for: "ideviceinstaller") else {
                return .failed(String(localized: "找不到 ideviceinstaller"))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-u", udid, "-i", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch {
                return .failed(error.localizedDescription)
            }

            var transcript = ""
            let handle = pipe.fileHandleForReading
            while process.isRunning {
                let chunk = handle.availableData
                if chunk.isEmpty { usleep(80_000); continue }
                let text = String(data: chunk, encoding: .utf8) ?? ""
                transcript += text
                // ideviceinstaller 会打印形如 "Install: CreatingStagingDirectory (5%)" 的行。
                if let percent = Self.lastPercent(in: text) { onProgress(percent / 100) }
            }
            transcript += String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()

            if process.terminationStatus == 0, !transcript.lowercased().contains("error") {
                return .done
            }
            return .failed(Self.failureReason(from: transcript))
        }.value
    }

    nonisolated private static func lastPercent(in text: String) -> Double? {
        var latest: Double?
        var scanner = text[...]
        while let range = scanner.range(of: #"\((\d+)%\)"#, options: .regularExpression) {
            let digits = scanner[range].filter(\.isNumber)
            if let value = Double(digits) { latest = value }
            scanner = scanner[range.upperBound...]
        }
        return latest
    }

    nonisolated private static func failureReason(from transcript: String) -> String {
        let lines = transcript
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.lowercased().contains("error") }) {
            return error
        }
        return lines.last ?? String(localized: "安装失败")
    }
}

// MARK: - 界面

struct DeviceInstallWorkspace: View {
    @ObservedObject var devices: DeviceManager
    @ObservedObject var queue: InstallQueue
    let library: [DownloadedItem]
    @Binding var perfectOnly: Bool

    var body: some View {
        NavigationSplitView {
            deviceSidebar
                .navigationSplitViewColumnWidth(min: 236, ideal: 262, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    libraryPane
                    Divider()
                    queuePane
                        .frame(width: 320)
                }
                Divider()
                globalProgress
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onAppear { devices.startMonitoring() }
        .onDisappear { devices.stopMonitoring() }
    }

    // MARK: 侧栏：设备

    private var deviceSidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 54)

            List(selection: $devices.selectedUDID) {
                Section(String(localized: "已连接设备")) {
                    ForEach(devices.devices) { device in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.body)
                                .lineLimit(1)
                            Text(device.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(device.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if devices.devices.isEmpty {
                    Text(devices.message.isEmpty
                         ? String(localized: "正在查找设备…")
                         : devices.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }
            }

            Divider()

            VStack(spacing: 8) {
                Toggle(isOn: $perfectOnly) {
                    Text(String(localized: "只看完美兼容版"))
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(devices.selectedDevice?.generation == nil)

                if let generation = devices.selectedDevice?.generation {
                    Text(String(localized: "按 \(generation.osName) 的版本窗口筛选"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await devices.refresh() }
                } label: {
                    Label(String(localized: "刷新设备"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 左：本地 IPA

    private var filteredLibrary: [DownloadedItem] {
        guard let device = devices.selectedDevice else { return library }
        guard perfectOnly, let generation = device.generation else { return library }
        return library.filter { item in
            guard let value = Int64(item.versionId.trimmingCharacters(in: .whitespaces)) else { return false }
            return generation.contains(versionID: value)
        }
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(String(localized: "本地 IPA"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "\(filteredLibrary.count) 个"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    for item in filteredLibrary where !queue.contains(item.id) {
                        queue.add(item.id)
                    }
                } label: {
                    Label(String(localized: "全部加入"), systemImage: "text.badge.plus")
                }
                .disabled(filteredLibrary.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 62)
            .padding(.bottom, 10)

            Divider()

            if filteredLibrary.isEmpty {
                emptyHint(perfectOnly
                          ? String(localized: "没有与该设备完美兼容的本地 IPA。关掉筛选看看全部。")
                          : String(localized: "下载目录里还没有 IPA。"))
            } else {
                List(filteredLibrary) { item in
                    libraryRow(item)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func libraryRow(_ item: DownloadedItem) -> some View {
        let device = devices.selectedDevice
        let installable = device.map { isInstallable(item, on: $0) } ?? true
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.appName.isEmpty ? String(localized: "未知 App") : item.appName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !item.version.isEmpty { Text("v\(item.version)") }
                    if !item.minimumOSVersion.isEmpty {
                        Text("·")
                        Text(String(localized: "最低 iOS \(item.minimumOSVersion)"))
                            .foregroundStyle(installable ? Color.secondary : Color.red)
                    }
                    Text("·")
                    Text(item.sizeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !installable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(String(localized: "该包要求的系统版本高于此设备，装不上"))
            }

            Button {
                if queue.contains(item.id) { queue.remove(item.id) } else { queue.add(item.id) }
            } label: {
                Label(queue.contains(item.id) ? String(localized: "已加入") : String(localized: "加入安装"),
                      systemImage: queue.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(queue.contains(item.id) ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
    }

    private func isInstallable(_ item: DownloadedItem, on device: ConnectedDevice) -> Bool {
        // 包里没写最低版本就不拦 —— 拿不准的时候让用户自己试。
        guard !item.minimumOSVersion.isEmpty, !device.osVersion.isEmpty else { return true }
        return MobileDeviceTools.compare(item.minimumOSVersion, device.osVersion) != .orderedDescending
    }

    // MARK: 右：安装清单

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(localized: "安装清单"))
                    .font(.title3.weight(.semibold))
                Text("\(queue.order.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !queue.order.isEmpty && !queue.isRunning {
                    Button(String(localized: "清空")) { queue.removeAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 62)
            .padding(.bottom, 10)

            Divider()

            if queue.order.isEmpty {
                emptyHint(String(localized: "从左侧把要装的 IPA 加进来。"))
            } else {
                List(queue.order, id: \.self) { path in
                    queueRow(path)
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(spacing: 8) {
                if queue.isRunning {
                    Button(role: .destructive) { queue.cancel() } label: {
                        Label(String(localized: "停止"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        guard let udid = devices.selectedDevice?.id else { return }
                        queue.start(udid: udid)
                    } label: {
                        Label(String(localized: "开始安装"), systemImage: "iphone.and.arrow.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.order.isEmpty || devices.selectedDevice == nil)
                }

                if !queue.message.isEmpty {
                    Text(queue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }

    private func queueRow(_ path: String) -> some View {
        let name = library.first { $0.id == path }?.appName ?? (path as NSString).lastPathComponent
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout).lineLimit(1)
                switch queue.state(path) {
                case .pending:
                    Text(String(localized: "等待中")).font(.caption2).foregroundStyle(.tertiary)
                case .installing(let fraction):
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.accentColor.opacity(0.16))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.9))
                                .frame(width: proxy.size.width * min(max(fraction ?? 0, 0), 1))
                        }
                    }
                    .frame(height: 3)
                case .done:
                    Text(String(localized: "已安装")).font(.caption2).foregroundStyle(.green)
                case .failed(let reason):
                    Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !queue.isRunning {
                Button { queue.remove(path) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 底部全局进度

    private var globalProgress: some View {
        let summary = queue.progress
        let percent = Int((summary.fraction * 100).rounded())
        return HStack(spacing: 12) {
            Text(String(localized: "总进度"))
                .font(.callout.weight(.semibold))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.16))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: proxy.size.width * summary.fraction)
                }
            }
            .frame(height: 8)
            .animation(.smooth(duration: 0.28), value: summary.fraction)

            Text(String(localized: "完成 \(summary.done)/\(summary.total)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if summary.failed > 0 {
                Text(String(localized: "失败 \(summary.failed)"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("\(percent)%")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}
