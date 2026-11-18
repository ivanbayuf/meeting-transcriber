// Converts a screen recording to an animated GIF for the README (no ffmpeg needed).
// usage: swift mov2gif.swift in.mov out.gif fps maxWidth cropHeightPts "start-end,start-end,…"
// Segments are stitched in the order given (so a recording can be re-ordered/trimmed).
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 7 else { print("usage: mov2gif in.mov out.gif fps maxWidth cropHeightPts segments"); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let fps = Double(args[3])!, maxWidth = Double(args[4])!, cropHeight = Double(args[5])!
let segments: [(Double, Double)] = args[6].split(separator: ",").map {
    let p = $0.split(separator: "-").map { Double($0)! }; return (p[0], p[1])
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let natural = try! asset.tracks(withMediaType: .video)[0].naturalSize   // pixels (2x on Retina)
let scale = maxWidth / natural.width
generator.maximumSize = CGSize(width: maxWidth, height: natural.height * scale)
// Recording is 760 pt wide; crop height in points → output pixels.
let cropPixels = Int(cropHeight * maxWidth / 760)

let times = segments.flatMap { s, e in stride(from: s, to: e, by: 1 / fps).map { $0 } }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.gif.identifier as CFString, times.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
for t in times {
    guard let full = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil),
          let image = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: min(cropPixels, full.height))) else { continue }
    CGImageDestinationAddImage(dest, image, frameProps)
}
guard CGImageDestinationFinalize(dest) else { print("failed"); exit(1) }
print("wrote \(args[2]): \(times.count) frames, \(String(format: "%.1f", Double(times.count) / fps)) s")
