// Renders an SVG file to a square PNG with the system SVG renderer (NSImage), so making the app
// icon needs no third-party tools. Used by scripts/make-app-icon.sh.
//
// usage: swift scripts/render-svg.swift <input.svg> <output.png> <pixels>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let pixels = Int(args[3]), pixels > 0 else {
    FileHandle.standardError.write(Data("usage: render-svg.swift <input.svg> <output.png> <pixels>\n".utf8))
    exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("render-svg: cannot load \(args[1])\n".utf8))
    exit(1)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("render-svg: cannot create a \(pixels) px bitmap\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.set()
NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render-svg: PNG encoding failed\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write(Data("render-svg: \(error)\n".utf8))
    exit(1)
}
