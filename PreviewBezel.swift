// PreviewBezel.swift
// 透過 Xcode 選單 Editor ▸ Canvas ▸ Copy Preview Screenshot 取得 preview 截圖
// → 套上 bezel → 複製到剪貼簿
// 用法: preview-bezel <bezel.png> <output.png>
// bezel.png 的螢幕區域必須是透明的；程式會自動偵測透明區域的位置與大小。
// 注意：點擊 Xcode 選單需要「輔助使用」（Accessibility）權限。

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

// MARK: - 參數

let args = CommandLine.arguments
guard args.count >= 3 else { fail("用法: preview-bezel <bezel.png> <output.png>") }
let bezelPath = args[1]
let outputPath = args[2]
guard FileManager.default.fileExists(atPath: bezelPath) else {
    fail("找不到 bezel 圖：\(bezelPath)")
}

// MARK: - 觸發 Xcode 的 Copy Preview Screenshot，從剪貼簿取得截圖

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

let pb = NSPasteboard.general
let baseline = pb.changeCount
let (clickStatus, _) = run(["/usr/bin/osascript", "-e", clickScript])
guard clickStatus == 0 else {
    fail("無法點擊 Editor ▸ Canvas ▸ Copy Preview Screenshot；請確認 Canvas 開著、preview 正在執行，且已授權輔助使用權限")
}

// 等 Xcode 把截圖放進剪貼簿（最多 15 秒）
var shotOpt: CGImage?
for _ in 0..<75 {
    if pb.changeCount != baseline,
       let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
       let src = CGImageSourceCreateWithData(data as CFData, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        shotOpt = img
        break
    }
    Thread.sleep(forTimeInterval: 0.2)
}
guard let shot = shotOpt else {
    fail("等不到剪貼簿出現 preview 截圖，請確認 Canvas 的 preview 有畫面")
}

guard let bezel = loadCGImage(bezelPath) else { fail("bezel 圖讀取失敗") }

// MARK: - 偵測 bezel 的螢幕（透明）區域

let W = bezel.width, H = bezel.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let probe = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: W * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("bezel 圖解析失敗")
}
probe.draw(bezel, in: CGRect(x: 0, y: 0, width: W, height: H))
guard let bufRaw = probe.data else { fail("bezel 圖解析失敗") }
let buf = bufRaw.bindMemory(to: UInt8.self, capacity: W * H * 4)

// buffer 第 0 列 = 圖片最上緣；y 以左上角為原點
func alphaAt(_ x: Int, _ y: Int) -> UInt8 { buf[(y * W + x) * 4 + 3] }
let clearT: UInt8 = 16  // alpha 低於此值視為透明

let cx = W / 2, cy = H / 2
guard alphaAt(cx, cy) < clearT else {
    fail("bezel 圖中央必須是透明的螢幕區域（目前是不透明像素）")
}

// 水平範圍：從中心列往左右走到不透明為止（取多列的最大範圍）
var left = cx, right = cx
for row in [cy - H / 20, cy, cy + H / 20] {
    var l = cx, r = cx
    while l > 0 && alphaAt(l - 1, row) < clearT { l -= 1 }
    while r < W - 1 && alphaAt(r + 1, row) < clearT { r += 1 }
    left = min(left, l); right = max(right, r)
}

// 垂直範圍：避開中央的 Dynamic Island 與圓角，
// 在螢幕寬度 18%–25% 的幾個直欄上往上下走（取最大範圍）
let span = right - left + 1
var top = cy, bottom = cy
for frac in [0.18, 0.22, 0.78, 0.82] {
    let x = left + Int(Double(span) * frac)
    var t = cy, b = cy
    while t > 0 && alphaAt(x, t - 1) < clearT { t -= 1 }
    while b < H - 1 && alphaAt(x, b + 1) < clearT { b += 1 }
    top = min(top, t); bottom = max(bottom, b)
}

// 轉成 CG 座標（原點在左下）
let screenRect = CGRect(x: CGFloat(left), y: CGFloat(H - 1 - bottom),
                        width: CGFloat(span), height: CGFloat(bottom - top + 1))

// screenRect 只是外接矩形；螢幕有圓角，矩形四個角落會落在手機外框輪廓之外。
// 從影像邊界 flood fill 透明像素，找出「外框輪廓以外」的區域，合成後把溢出清掉。
// （螢幕內緣的半透明陰影不受影響，內容照樣墊在下面，不會產生黑邊。）
var outside = [Bool](repeating: false, count: W * H)
var stack = [Int]()
for x in 0..<W {
    for y in [0, H - 1] where alphaAt(x, y) < clearT {
        let i = y * W + x
        if !outside[i] { outside[i] = true; stack.append(i) }
    }
}
for y in 0..<H {
    for x in [0, W - 1] where alphaAt(x, y) < clearT {
        let i = y * W + x
        if !outside[i] { outside[i] = true; stack.append(i) }
    }
}
while let idx = stack.popLast() {
    let x = idx % W, y = idx / W
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
        guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
        let n = ny * W + nx
        if !outside[n] && alphaAt(nx, ny) < clearT {
            outside[n] = true
            stack.append(n)
        }
    }
}

// MARK: - 合成

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
    for i in 0..<(W * H) where outside[i] {
        px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
    }
}

canvas.draw(bezel, in: CGRect(x: 0, y: 0, width: W, height: H))

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

pb.clearContents()
pb.setData(pngData, forType: .png)
if let tiff = NSImage(data: pngData)?.tiffRepresentation {
    pb.setData(tiff, forType: .tiff)
}

notify("✅ 已合成並複製到剪貼簿")
