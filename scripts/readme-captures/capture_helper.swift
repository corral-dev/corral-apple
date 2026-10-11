// Small native helper for capture.py.
//   window-id <pid>      prints the largest on-screen layer-0 window id of that process
//   ocr <image>...       prints {"<path>": ["line", ...]} recognized by Vision (privacy gate)
import AppKit
import CoreGraphics
import Foundation
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func windowID(pid: Int32) -> Int? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let candidates = info.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    func area(_ window: [String: Any]) -> Double {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    return candidates.max { area($0) < area($1) }?[kCGWindowNumber as String] as? Int
}

func recognizedLines(_ path: String) -> [String] {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("cannot read \(path)")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        fail("ocr failed for \(path): \(error)")
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "window-id":
    guard arguments.count == 2, let pid = Int32(arguments[1]) else { fail("usage: window-id <pid>") }
    guard let id = windowID(pid: pid) else { fail("no on-screen window for pid \(pid)") }
    print(id)
case "ocr":
    var result: [String: [String]] = [:]
    for path in arguments.dropFirst() { result[path] = recognizedLines(path) }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
default:
    fail("usage: capture_helper window-id <pid> | ocr <image>...")
}
