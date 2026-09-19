// PreviewBezel.swift
// 取得 Xcode Preview 截圖 → 套上 bezel → 複製到剪貼簿
// 用法: preview-bezel <output.png> <bezel.png> [更多 bezel.png ...]
//
// 截圖來源（依序嘗試）：
// 1. Xcode 官方 MCP server（xcrun mcpbridge）的 RenderPreview 工具
//    — 需在 Xcode ▸ Settings ▸ Intelligence 啟用「Xcode Tools」
// 2. AppleScript 點擊 Editor ▸ Canvas ▸ Copy Preview Screenshot
//    — 需要「輔助使用」（Accessibility）權限
//
// bezel 圖的螢幕區域必須是透明的；程式會自動偵測透明區域的位置與大小。
// 給多張 bezel 時，挑「螢幕長寬比最接近截圖」的那張（例如 iPhone Duo 的內螢幕 vs. 一般 iPhone）。

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 小工具

@discardableResult
func run(_ args: [String]) -> (status: Int32, stdout: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return (1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func notify(_ msg: String) {
    let escaped = msg
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    run(["/usr/bin/osascript", "-e",
         "display notification \"\(escaped)\" with title \"Preview Bezel\""])
}

func fail(_ msg: String) -> Never {
    notify("❌ \(msg)")
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Xcode MCP client（JSON-RPC over stdio，line-delimited）

final class MCPBridge {
    private let proc = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var nextID = 1

    func start() -> Bool {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["mcpbridge"]
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = Pipe()
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.drainLocked()
            self.lock.unlock()
        }
        do { try proc.run() } catch { return false }
        return true
    }

    func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
    }

    // 把 buffer 裡完整的行解析成 JSON 回應（呼叫前須持有 lock）
    private func drainLocked() {
        while let nl = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<nl.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<nl.upperBound)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            replies[id] = obj
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        inputPipe.fileHandleForWriting.write(data + Data([0x0A]))
    }

    func sendNotification(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let id = nextID; nextID += 1
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            lock.lock()
            let msg = replies.removeValue(forKey: id)
            lock.unlock()
            if let msg { return msg["result"] as? [String: Any] }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    // 回傳 tools/call 的 structuredContent（工具錯誤時該欄位會缺少預期的 key）
    func callTool(_ name: String, _ arguments: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let result = request("tools/call", ["name": name, "arguments": arguments],
                                   timeout: timeout) else { return nil }
        return result["structuredContent"] as? [String: Any]
    }
}

// MARK: - 截圖來源 1：MCP RenderPreview

// 正式版 Xcode 對每次新啟動的 agent 連線都會跳授權視窗（沒有跨次的永久允許）。
// 背景開一個 watcher：偵測到「內容包含 preview-bezel 路徑」的授權視窗就自動按
// Allow；比對路徑是為了絕不誤點其他 agent 的授權視窗。找不到就在 30 秒後自行結束。
func startApprovalAutoClicker() {
    let watcher = """
    tell application "System Events"
        tell process "Xcode"
            repeat 60 times
                set clicked to false
                try
                    set targets to windows
                    repeat with w in windows
                        try
                            set targets to targets & (sheets of w)
                        end try
                    end repeat
                    repeat with w in targets
                        set allowButton to missing value
                        try
                            if exists button "Allow" of w then set allowButton to button "Allow" of w
                        end try
                        try
                            if allowButton is missing value and (exists button "Allow" of group 1 of w) then set allowButton to button "Allow" of group 1 of w
                        end try
                        if allowButton is not missing value then
                            set allText to ""
                            try
                                repeat with s in (every static text of w)
                                    try
                                        set allText to allText & (value of s) & " "
                                    end try
                                end repeat
                            end try
                            try
                                repeat with s in (every static text of group 1 of w)
                                    try
                                        set allText to allText & (value of s) & " "
                                    end try
                                end repeat
                            end try
                            if allText contains "preview-bezel" then
                                click allowButton
                                set clicked to true
                                exit repeat
                            end if
                        end if
                    end repeat
                end try
                if clicked then exit repeat
                delay 0.5
            end repeat
        end tell
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", watcher]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try? p.run()  // 不等待；點到或逾時後自行結束
}

func captureViaMCP() -> CGImage? {
    startApprovalAutoClicker()
    let bridge = MCPBridge()
    guard bridge.start() else { return nil }
    defer { bridge.stop() }

    guard bridge.request("initialize", [
        "protocolVersion": "2025-06-18",
        "capabilities": [String: Any](),
        "clientInfo": ["name": "preview-bezel", "version": "1.0"],
    ], timeout: 15) != nil else { return nil }
    bridge.sendNotification("notifications/initialized")

    // 沒啟用 Xcode Tools 時，tools/call 不會回應，靠 timeout 走備援
    guard let windows = bridge.callTool("XcodeListWindows", [:], timeout: 30),
          let message = windows["message"] as? String else { return nil }

    // 訊息格式：「* tabIdentifier: windowtab5, workspacePath: /path/to/App.xcodeproj」（每視窗一行）
    var tabs: [String] = []
    var rest = Substring(message)
    while let r = rest.range(of: "tabIdentifier: ") {
        let after = rest[r.upperBound...]
        let tab = after.prefix(while: { $0 != "," && $0 != " " && !$0.isNewline })
        if !tab.isEmpty { tabs.append(String(tab)) }
        rest = after
    }

    // 逐一嘗試每個視窗：目前檔案是 .swift 就渲染它的第一個 #Preview
    for tab in tabs {
        guard let current = bridge.callTool("XcodeGetCurrentFile",
                ["tabIdentifier": tab, "includeContent": false, "includeSelection": false],
                timeout: 30),
              let filePath = current["filePath"] as? String,
              filePath.hasSuffix(".swift") else { continue }
        guard let render = bridge.callTool("RenderPreview",
                ["sourceFilePath": filePath, "tabIdentifier": tab], timeout: 180),
              let snapshotPath = render["previewSnapshotPath"] as? String,
              let image = loadCGImage(snapshotPath) else { continue }
        return image
    }
    return nil
}

// MARK: - 截圖來源 2：點擊 Xcode 選單 Copy Preview Screenshot

// Editor 選單有兩個「Canvas」項目（顯示開關與子選單）。同名引用會解析到
// 開關那個，而且把 menu item 存進變數時 AppleScript 會把索引改寫成名稱引用
// （又撞回開關），所以整條路徑都必須用行內索引鏈。子選單是懶載入的，
// 用「count of menu items of menu 1 of menu item i」強迫 AX 建立，
// 不需要真的把選單打開，也不用搶焦點。
let clickScript = """
tell application "System Events"
    tell process "Xcode"
        set editorMenu to menu "Editor" of menu bar item "Editor" of menu bar 1
        set clicked to false
        set sawDisabled to false
        repeat with i from 1 to count of menu items of editorMenu
            set miName to name of menu item i of editorMenu
            if miName is not missing value and miName is "Canvas" then
                try
                    if (count of menu items of menu 1 of menu item i of editorMenu) > 0 then
                        if (enabled of menu item "Copy Preview Screenshot" of menu 1 of menu item i of editorMenu) then
                            click menu item "Copy Preview Screenshot" of menu 1 of menu item i of editorMenu
                            set clicked to true
                            exit repeat
                        else
                            set sawDisabled to true
                        end if
                    end if
                end try
            end if
        end repeat
        if clicked then return "ok"
        if sawDisabled then error "Copy Preview Screenshot 目前不可用"
        error "找不到 Copy Preview Screenshot 選單項目"
    end tell
end tell
"""

func captureViaMenu() -> CGImage? {
    let pb = NSPasteboard.general
    let baseline = pb.changeCount
    let (clickStatus, _) = run(["/usr/bin/osascript", "-e", clickScript])
    guard clickStatus == 0 else { return nil }

    // 等 Xcode 把截圖放進剪貼簿（最多 15 秒）
    for _ in 0..<75 {
        if pb.changeCount != baseline,
           let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

// MARK: - bezel 分析：找出螢幕（透明）區域

// 螢幕不一定在圖片正中央——摺疊機的 bezel 是「背面 ＋ 內螢幕」的攤開圖，螢幕只佔右半邊。
// 所以先從影像四邊 flood fill 透明像素，標出「手機輪廓以外」；剩下的透明像素就是螢幕
// 挖空處，取其中最大的連通區塊，外接矩形即螢幕範圍。
// （Dynamic Island／鏡頭挖孔是螢幕裡的不透明小島，被透明區包住，不影響外接矩形。）
struct Bezel {
    let path: String
    let image: CGImage
    let screenRect: CGRect  // CG 座標（原點在左下）
    let outside: [Bool]     // row-major、第 0 列為最上緣；true = 手機輪廓以外的透明像素
    var name: String { (path as NSString).lastPathComponent }
    var aspect: CGFloat { screenRect.width / screenRect.height }
}

func analyzeBezel(_ path: String) -> Bezel? {
    guard let image = loadCGImage(path) else { return nil }
    let W = image.width, H = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let probe = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: W * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    probe.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    guard let bufRaw = probe.data else { return nil }
    let buf = bufRaw.bindMemory(to: UInt8.self, capacity: W * H * 4)

    // buffer 第 0 列 = 圖片最上緣；y 以左上角為原點
    let clearT: UInt8 = 16  // alpha 低於此值視為透明
    func isClear(_ x: Int, _ y: Int) -> Bool { buf[(y * W + x) * 4 + 3] < clearT }

    var stack = [Int]()

    // 1. 從四邊往內 flood fill 透明像素 → 手機輪廓以外的區域
    //    （合成後用它把 aspect-fill 溢出、又落在輪廓外的像素清掉）
    var outside = [Bool](repeating: false, count: W * H)
    func seed(_ x: Int, _ y: Int) {
        let i = y * W + x
        if !outside[i] && isClear(x, y) { outside[i] = true; stack.append(i) }
    }
    for x in 0..<W { seed(x, 0); seed(x, H - 1) }
    for y in 0..<H { seed(0, y); seed(W - 1, y) }
    while let idx = stack.popLast() {
        let x = idx % W, y = idx / W
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
            guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
            let n = ny * W + nx
            if !outside[n] && isClear(nx, ny) { outside[n] = true; stack.append(n) }
        }
    }

    // 2. 剩下的透明像素＝螢幕挖空處；取最大連通區塊
    var seen = outside
    var best = (count: 0, minX: 0, minY: 0, maxX: 0, maxY: 0)
    for sy in 0..<H {
        for sx in 0..<W where !seen[sy * W + sx] && isClear(sx, sy) {
            seen[sy * W + sx] = true
            stack.append(sy * W + sx)
            var cur = (count: 0, minX: sx, minY: sy, maxX: sx, maxY: sy)
            while let idx = stack.popLast() {
                let x = idx % W, y = idx / W
                cur.count += 1
                cur.minX = min(cur.minX, x); cur.maxX = max(cur.maxX, x)
                cur.minY = min(cur.minY, y); cur.maxY = max(cur.maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                    let n = ny * W + nx
                    if !seen[n] && isClear(nx, ny) { seen[n] = true; stack.append(n) }
                }
            }
            if cur.count > best.count { best = cur }
        }
    }
    guard best.count > 0 else { return nil }

    let screenRect = CGRect(x: CGFloat(best.minX), y: CGFloat(H - 1 - best.maxY),
                            width: CGFloat(best.maxX - best.minX + 1),
                            height: CGFloat(best.maxY - best.minY + 1))
    return Bezel(path: path, image: image, screenRect: screenRect, outside: outside)
}

// MARK: - 參數

let args = CommandLine.arguments
guard args.count >= 3 else { fail("用法: preview-bezel <output.png> <bezel.png> [更多 bezel.png ...]") }
let outputPath = args[1]
let bezelPaths = Array(args.dropFirst(2))

// MARK: - 取得截圖（選單優先，MCP 備援）
// 選單的 Copy Preview Screenshot 擷取「Canvas 目前顯示的畫面」（含互動後的狀態），
// 且為原生 3x 解析度；MCP 的 RenderPreview 則是重新建置並渲染 #Preview 的初始狀態，
// 不會反映 Canvas 互動現況、解析度也較低，所以只當備援。

var shotSource = "選單"
var shotOpt = captureViaMenu()
if shotOpt == nil {
    shotSource = "MCP"
    shotOpt = captureViaMCP()
}
guard let shot = shotOpt else {
    fail("兩種方案都無法取得 preview 截圖。選單：請確認已授權輔助使用權限，且 Canvas 的 preview 有畫面；MCP：請確認 Xcode ▸ Settings ▸ Intelligence 已啟用 Xcode Tools")
}

// MARK: - 挑 bezel：螢幕長寬比最接近截圖的那個
// 截圖尺寸就代表裝置：iPhone Duo 的內螢幕比一般 iPhone 方，兩者長寬比差很遠，
// 直接比長寬比即可對號入座（放新的 bezel 進來也自動生效，不必改程式）。

let bezels = bezelPaths.compactMap(analyzeBezel)
guard !bezels.isEmpty else {
    fail("沒有可用的 bezel 圖（螢幕區域必須是透明的）：\(bezelPaths.joined(separator: ", "))")
}
let shotAspect = CGFloat(shot.width) / CGFloat(shot.height)
let bezel = bezels.min { abs($0.aspect - shotAspect) < abs($1.aspect - shotAspect) }!

// MARK: - 合成

let W = bezel.image.width, H = bezel.image.height
let screenRect = bezel.screenRect
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let canvas = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                             bytesPerRow: W * 4, space: space,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("無法建立輸出畫布")
}
canvas.interpolationQuality = .high

// 截圖以 aspect-fill 填滿螢幕區域（超出部分裁掉，方角會被上層 bezel 蓋住）
canvas.saveGState()
canvas.clip(to: screenRect)
let sw = CGFloat(shot.width), sh = CGFloat(shot.height)
let scale = max(screenRect.width / sw, screenRect.height / sh)
let drawRect = CGRect(x: screenRect.midX - sw * scale / 2,
                      y: screenRect.midY - sh * scale / 2,
                      width: sw * scale, height: sh * scale)
canvas.draw(shot, in: drawRect)
canvas.restoreGState()

// 清掉溢出到外框輪廓以外的截圖像素（canvas buffer 第 0 列 = 最上緣，與 outside 索引一致）
if let canvasRaw = canvas.data {
    let px = canvasRaw.bindMemory(to: UInt8.self, capacity: W * H * 4)
    for i in 0..<(W * H) where bezel.outside[i] {
        px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
    }
}

canvas.draw(bezel.image, in: CGRect(x: 0, y: 0, width: W, height: H))

guard let composed = canvas.makeImage() else { fail("合成失敗") }

// MARK: - 輸出 PNG + 剪貼簿

let outURL = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("無法寫入輸出檔")
}
CGImageDestinationAddImage(dest, composed, nil)
guard CGImageDestinationFinalize(dest), let pngData = try? Data(contentsOf: outURL) else {
    fail("PNG 輸出失敗")
}

let pb = NSPasteboard.general
pb.clearContents()
pb.setData(pngData, forType: .png)
if let tiff = NSImage(data: pngData)?.tiffRepresentation {
    pb.setData(tiff, forType: .tiff)
}

notify("✅ 已合成並複製到剪貼簿（來源：\(shotSource)、外框：\(bezel.name)）")
