// wincap: record ONE window with ScreenCaptureKit. It never captures the rest of the screen,
// so private windows can't leak into a take. The system cursor is left out on purpose,
// because render.py draws click rings instead.
//
//   swiftc -O -o .build-wincap/wincap screencasts/_shared/capture/wincap.swift
//   wincap --list [owner-substring]
//   wincap --window <CGWindowID> --out take.mov [--seconds 8] [--fps 60]
//
// Stops after --seconds, or on SIGINT/SIGTERM. The output is ProRes 422 .mov at the window's backing resolution.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Options {
    var list = false
    var owner: String?
    var windowID: CGWindowID?
    var out: URL?
    var seconds: Double?
    var fps = 60
}

func parse() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--list": o.list = true
        case "--window": o.windowID = CGWindowID(it.next() ?? "")
        case "--out": o.out = URL(fileURLWithPath: it.next() ?? "")
        case "--seconds": o.seconds = Double(it.next() ?? "")
        case "--fps": o.fps = Int(it.next() ?? "") ?? 60
        default: if o.list { o.owner = a } else { fail("unknown argument \(a)") }
        }
    }
    return o
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("wincap: \(msg)\n".utf8))
    exit(1)
}

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    var frames = 0
    let queue = DispatchQueue(label: "wincap.frames")

    init(out: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: out)
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sb)
            frames += 1
        }
    }

    func finish() async {
        input.markAsFinished()
        await writer.finishWriting()
    }
}

@main
struct WinCap {
    static func main() async {
        let o = parse()
        // A bare CLI must bring up the window-server connection before ScreenCaptureKit streams.
        _ = NSApplication.shared
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            fail("no screen-recording permission for this process (\(error.localizedDescription))")
        }

        if o.list {
            for w in content.windows where w.frame.width > 200 {
                let app = w.owningApplication?.applicationName ?? "?"
                if let needle = o.owner, !app.localizedCaseInsensitiveContains(needle) { continue }
                print("\(w.windowID)\t\(app)\t\(Int(w.frame.width))x\(Int(w.frame.height))\t\(w.title ?? "")")
            }
            return
        }

        guard let id = o.windowID, let out = o.out else { fail("need --window and --out, or --list") }
        guard let window = content.windows.first(where: { $0.windowID == id }) else { fail("window \(id) not found") }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int(window.frame.width * scale) / 2 * 2
        let height = Int(window.frame.height * scale) / 2 * 2

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.ignoreShadowsSingleWindow = true

        do {
            let recorder = try Recorder(out: out, width: width, height: height)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
            try await stream.startCapture()
            FileHandle.standardError.write(Data("wincap: recording window \(id) at \(width)x\(height)\n".utf8))

            // Stop on a timer or on a signal, whichever comes first.
            let stop = AsyncStream<Void> { cont in
                for sig in [SIGINT, SIGTERM] {
                    signal(sig, SIG_IGN)
                    let src = DispatchSource.makeSignalSource(signal: sig)
                    src.setEventHandler { cont.yield() }
                    src.resume()
                    signalSources.append(src)
                }
                if let s = o.seconds {
                    DispatchQueue.global().asyncAfter(deadline: .now() + s) { cont.yield() }
                }
            }
            for await _ in stop { break }

            try await stream.stopCapture()
            await recorder.finish()
            print("\(out.path)\t\(recorder.frames) frames")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
