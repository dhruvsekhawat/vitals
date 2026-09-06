// Renders docs/banner.png, the README hero. Run: swift scripts/make-banner.swift
//
// It is the real terminal output that started this project, verbatim: two Cursor renderer
// processes at 99% CPU for nineteen days, leaked helpers, a load average of 56 on 8 cores,
// swap full. No mockup. Pure AppKit, no dependencies.
import AppKit

let W: CGFloat = 1600, H: CGFloat = 900
let scale: CGFloat = 2
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let outURL = root.appendingPathComponent("docs/banner.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Page: flat near-black, like a terminal fullscreen. Nothing decorative.
NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

let mono = NSFont(name: "SFMono-Regular", size: 23) ?? NSFont(name: "Menlo", size: 23)!
let monoBold = NSFont(name: "SFMono-Bold", size: 23) ?? NSFont(name: "Menlo-Bold", size: 23)!
let dim = NSColor(calibratedWhite: 0.55, alpha: 1)
let fg = NSColor(calibratedWhite: 0.85, alpha: 1)
let red = NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.30, alpha: 1)
let yellow = NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)
let green = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.48, alpha: 1)

func line(_ s: String, y: CGFloat, color: NSColor = fg, font: NSFont = mono, x: CGFloat = 72) {
    (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}

// The session, top to bottom (y grows upward in AppKit, so start high).
var y: CGFloat = H - 90
let lh: CGFloat = 34
line("$ uptime", y: y, color: dim); y -= lh
line("16:47  up 41 days,  8:28, 1 user, load averages: 56.31 45.02 38.77", y: y); y -= lh * 1.4
line("$ sysctl vm.swapusage", y: y, color: dim); y -= lh
line("vm.swapusage: total = 38912.00M  used = 37943.12M  free = 968.88M", y: y); y -= lh * 1.4
line("$ ps -Ao pid,pcpu,etime,comm -r | head -8", y: y, color: dim); y -= lh
line("  PID  %CPU     ELAPSED COMM", y: y, color: dim); y -= lh

// The two lines that were the whole problem. Highlight bar behind them.
NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.30, alpha: 0.13).setFill()
NSRect(x: 56, y: y - lh - 8, width: 1060, height: lh * 2 + 12).fill()
red.setFill(); NSRect(x: 56, y: y - lh - 8, width: 5, height: lh * 2 + 12).fill()
line("99060  99.2 19-04:46:42 Cursor Helper (Renderer)", y: y, color: red, font: monoBold); y -= lh
line("99056  99.2 19-04:46:42 Cursor Helper (Renderer)", y: y, color: red, font: monoBold); y -= lh
line("20114   7.8 10-19:59:34 claude bg-spare", y: y, color: yellow); y -= lh
line("48299   3.6 28-22:19:14 claude bg-spare", y: y, color: yellow); y -= lh
line("50675   1.3 24-01:07:47 claude bg-spare", y: y, color: yellow); y -= lh
line("50529   1.2 17-19:24:04 claude bg-spare", y: y, color: yellow); y -= lh
line("62391   4.1 17-04:52:45 claude", y: y); y -= lh * 1.6

// The point, in the only big type on the page.
let big = NSFont.systemFont(ofSize: 76, weight: .heavy)
("Nineteen days at 100%." as NSString).draw(at: NSPoint(x: 66, y: y - 60), withAttributes: [.font: big, .foregroundColor: NSColor.white, .kern: -2.5])
y -= 60 + lh * 1.9
let sub = NSFont.systemFont(ofSize: 30, weight: .regular)
("Activity Monitor showed 400 processes. Vitals shows the two that matter, and a button." as NSString)
    .draw(at: NSPoint(x: 70, y: y), withAttributes: [.font: sub, .foregroundColor: dim])
y -= lh * 1.9

// What Vitals said about the same machine, in its own words.
NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
let card = NSRect(x: 64, y: y - 92, width: 1180, height: 118)
NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
green.setFill(); NSBezierPath(ovalIn: NSRect(x: 96, y: card.maxY - 44, width: 14, height: 14)).fill()
("Vitals" as NSString).draw(at: NSPoint(x: 124, y: card.maxY - 50), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white])
red.setFill(); NSBezierPath(ovalIn: NSRect(x: 100, y: card.maxY - 84, width: 8, height: 8)).fill()
("Cursor · Cursor Helper (Renderer) is stuck" as NSString).draw(at: NSPoint(x: 124, y: card.maxY - 92), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor.white])
("99% CPU for 19d" as NSString).draw(at: NSPoint(x: 640, y: card.maxY - 92), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: dim])
("Kill" as NSString).draw(at: NSPoint(x: card.maxX - 90, y: card.maxY - 92), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)])

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: outURL)
print("wrote \(outURL.path) \(Int(W * scale))x\(Int(H * scale))")
