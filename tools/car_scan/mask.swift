// Writes a mask per frame (white = the car), which align.py uses to carve the garage out of the scan.
// mask <framesDir> <masksOut> [every]   (every N-th frame only, for a quick contact-sheet check)
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: mask <framesDir> <masksOut> [every]"); exit(1) }
let inDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let every = args.count > 3 ? Int(args[3])! : 1
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let names = try FileManager.default.contentsOfDirectory(atPath: inDir.path).filter { $0.hasSuffix(".jpg") }.sorted()
let context = CIContext()
var failed = 0

for (i, name) in names.enumerated() where i % every == 0 {
    autoreleasepool {
        let url = inDir.appendingPathComponent(name)
        guard let image = CIImage(contentsOf: url) else { return }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image)
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty else {
            failed += 1; return
        }
        // The car is the biggest thing Vision finds; props in the garage come back as smaller instances.
        let instanceMask = result.instanceMask
        CVPixelBufferLockBaseAddress(instanceMask, .readOnly)
        let w = CVPixelBufferGetWidth(instanceMask), h = CVPixelBufferGetHeight(instanceMask)
        let row = CVPixelBufferGetBytesPerRow(instanceMask)
        let px = CVPixelBufferGetBaseAddress(instanceMask)!.assumingMemoryBound(to: UInt8.self)
        var counts = [Int: Int]()
        for y in 0..<h { for x in 0..<w { let v = Int(px[y * row + x]); if v > 0 { counts[v, default: 0] += 1 } } }
        CVPixelBufferUnlockBaseAddress(instanceMask, .readOnly)
        let car = counts.max { $0.value < $1.value }!.key
        let mask = try! result.generateScaledMaskForImage(forInstances: IndexSet(integer: car), from: handler)
        try! context.writePNGRepresentation(of: CIImage(cvPixelBuffer: mask), to: outDir.appendingPathComponent(name.replacingOccurrences(of: ".jpg", with: ".png")),
            format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
    }
}
print("masked \(names.count / every - failed), no car found in \(failed)")
