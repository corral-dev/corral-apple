import Foundation
import Observation

/// 终端画面状态：订阅 screen.watch 并应用差分帧。
///
/// 手机端永不发 screen.resize——否则会把电脑上正在看的同一个会话挤窄。
@MainActor
@Observable
final class TerminalStore {
    private(set) var cols = 80
    private(set) var rows = 24
    private(set) var cells: [[TerminalCell]] = []
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = false
    private(set) var status = ""
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var hasFrame = false

    private let sessionKey: String
    private weak var client: RemoteClient?
    /// The connection this store subscribes on (containers rebind on reconnect).
    var boundClient: RemoteClient? { client }
    private var eventTask: Task<Void, Never>?
    private var readyHandlerID: UUID?
    private var didWatch = false

    init(sessionKey: String, client: RemoteClient?) {
        self.sessionKey = sessionKey
        self.client = client
        resetGrid(cols: cols, rows: rows)
    }

    func start() async {
        guard let client else {
            loadError = String(localized: String.LocalizationValue("error.not_connected"))
            return
        }
        isLoading = true
        loadError = nil

        // 先订阅事件再发 watch，避免首帧/差分落在订阅前。
        ensureEventSubscription(client)
        registerReadyHandler(client)
        await pullWatch(client, force: !didWatch)
        isLoading = false
    }

    func stop() async {
        if let readyHandlerID {
            client?.removeReadyHandler(readyHandlerID)
            self.readyHandlerID = nil
        }
        eventTask?.cancel()
        eventTask = nil
        if didWatch {
            didWatch = false
            _ = try? await client?.call(WireProtocol.mScreenUnwatch, params: ["key": sessionKey])
        }
    }

    func retry() async {
        await start()
    }

    private func ensureEventSubscription(_ client: RemoteClient) {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.subscribe(channel: WireProtocol.screenChannel(sessionKey: sessionKey)) {
                if Task.isCancelled { break }
                await self.handle(event)
            }
        }
    }

    private func registerReadyHandler(_ client: RemoteClient) {
        guard readyHandlerID == nil else { return }
        readyHandlerID = client.addReadyHandler { [weak self] in
            guard let self else { return }
            Task { await self.repullAfterReconnect() }
        }
    }

    private func repullAfterReconnect() async {
        guard let client else { return }
        // 重连后服务端订阅清空，需要重新 watch 才能再拿到帧。
        didWatch = false
        await pullWatch(client, force: true)
    }

    private func pullWatch(_ client: RemoteClient, force: Bool) async {
        do {
            let response = try await client.call(
                WireProtocol.mScreenWatch,
                params: ["key": sessionKey],
                as: ScreenWatchResponse.self
            )
            didWatch = true
            loadError = nil
            if let frame = response.frame {
                apply(frame)
            } else if force, !hasFrame {
                // 极端情况下仍无首帧：等后续事件；正常路径二次 watch 会拿到整帧 resync。
            }
        } catch {
            if !hasFrame {
                loadError = error.localizedDescription
            }
        }
    }

    private func handle(_ event: RemoteEvent) async {
        // 事件载荷可能是整帧对象，也可能是 {"frame": {...}}。
        let frameDict: Any
        if event.data["cols"] != nil {
            frameDict = event.data
        } else if let nested = event.data["frame"] {
            frameDict = nested
        } else {
            // 仅状态更新（容错）
            if let status = event.data["status"] as? String {
                self.status = status
            }
            return
        }
        do {
            let frame = try RemoteJSONDecoder.decode(ScreenFrame.self, from: frameDict)
            apply(frame)
            loadError = nil
        } catch {
            // 单帧坏掉不清空已有画面，只在从未成功时露出错误。
            if !hasFrame {
                loadError = String(localized: String.LocalizationValue("error.decode_frame"))
            }
        }
    }

    private func apply(_ frame: ScreenFrame) {
        if frame.full || frame.cols != cols || frame.rows != rows {
            resetGrid(cols: frame.cols, rows: frame.rows)
        }
        for line in frame.lines {
            applyLine(line)
        }
        cursorX = frame.cursorX
        cursorY = frame.cursorY
        cursorVisible = frame.cursorVisible
        status = frame.status
        hasFrame = true
    }

    private func resetGrid(cols: Int, rows: Int) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        cells = Array(
            repeating: Array(repeating: TerminalCell(char: " "), count: self.cols),
            count: self.rows
        )
    }

    private func applyLine(_ line: [JSONValue]) {
        guard line.count >= 2 else { return }
        let rowIndex: Int
        switch line[0] {
        case let .int(value): rowIndex = value
        default: return
        }
        guard rowIndex >= 0, rowIndex < rows else { return }
        guard case let .string(text) = line[1] else { return }
        let spans: [TerminalSpan]
        if line.count > 2, case let .array(rawSpans) = line[2] {
            spans = parseSpans(rawSpans)
        } else {
            spans = []
        }
        overwriteRow(rowIndex, text: text, spans: spans)
    }

    private func parseSpans(_ values: [JSONValue]) -> [TerminalSpan] {
        values.compactMap { value in
            guard case let .array(items) = value, items.count >= 2 else { return nil }
            guard case let .int(start) = items[0], case let .int(end) = items[1] else { return nil }
            var fg = TerminalColor.defaultFG
            var bg = TerminalColor.defaultBG
            var attrs = 0
            if items.count > 2, case let .int(f) = items[2] { fg = TerminalColor(raw: f) }
            if items.count > 3, case let .int(b) = items[3] { bg = TerminalColor(raw: b) }
            if items.count > 4, case let .int(a) = items[4] { attrs = a }
            return TerminalSpan(start: start, end: end, fg: fg, bg: bg, attrs: attrs)
        }
    }

    private func overwriteRow(_ row: Int, text: String, spans: [TerminalSpan]) {
        var rowCells = Array(repeating: TerminalCell(char: " "), count: cols)
        for (index, char) in text.prefix(cols).enumerated() {
            rowCells[index] = TerminalCell(char: char)
        }
        for span in spans {
            for col in span.start ..< min(span.end, cols) where col >= 0 && col < rowCells.count {
                rowCells[col].fg = span.fg
                rowCells[col].bg = span.bg
                rowCells[col].bold = span.attrs & 1 != 0
                rowCells[col].dim = span.attrs & 2 != 0
                rowCells[col].underline = span.attrs & 4 != 0
                rowCells[col].reverse = span.attrs & 8 != 0
            }
        }
        cells[row] = rowCells
    }
}

struct TerminalCell: Equatable {
    var char: Character = " "
    var fg: TerminalColor = .defaultFG
    var bg: TerminalColor = .defaultBG
    var bold = false
    var dim = false
    var underline = false
    var reverse = false

    /// 默认终端底色已由画布承接；仅非默认或反色单元格才额外填充。
    var needsBackgroundFill: Bool {
        reverse || bg != .defaultBG
    }

    /// 空白格不需要创建文本布局对象，显著减少全屏刷新时的绘制工作。
    var needsGlyphDraw: Bool {
        char != " "
    }
}

struct TerminalSpan {
    let start: Int
    let end: Int
    let fg: TerminalColor
    let bg: TerminalColor
    let attrs: Int
}

/// 与 daemon `screen.py` 一致：-1 默认、0..255 索引、0x1000000|rgb 真彩。
struct TerminalColor: Equatable {
    let raw: Int

    static let defaultFG = TerminalColor(raw: -1)
    static let defaultBG = TerminalColor(raw: -1)

    init(raw: Int) {
        self.raw = raw
    }

    /// 兼容旧字段名。
    var index: Int { raw }
}
