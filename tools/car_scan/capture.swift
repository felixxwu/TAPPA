// Runs Apple Object Capture on a folder of images: capture <imagesDir> <output.usdz> [preview|reduced|medium|full|raw|poses]
// Also writes <output>.poses.json, where each frame's camera was, so align.py can carve away whatever isn't the car.
// `poses` skips the model and only finds the cameras, which is all the paint video needs.
import Foundation
import RealityKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: capture <imagesDir> <output.usdz> [detail]"); exit(1) }
let input = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[2])
let details: [String: PhotogrammetrySession.Request.Detail] = [
    "preview": .preview, "reduced": .reduced, "medium": .medium, "full": .full, "raw": .raw,
]
let detail = details[args.count > 3 ? args[3] : "full"] ?? .full
let posesOnly = args.count > 3 && args[3] == "poses"

var config = PhotogrammetrySession.Configuration()
config.sampleOrdering = ProcessInfo.processInfo.environment["UNORDERED"] == nil ? .sequential : .unordered
config.featureSensitivity = .high
config.isObjectMaskingEnabled = true

let session = try PhotogrammetrySession(input: input, configuration: config)

func savePoses(_ poses: PhotogrammetrySession.Poses) {
    var out = [String: Any]()
    for (id, pose) in poses.posesBySample {
        guard let url = poses.urlsBySample[id], let k = pose.intrinsics else { continue }
        let q = pose.rotation.vector
        out[url.lastPathComponent] = [
            "translation": [pose.translation.x, pose.translation.y, pose.translation.z],
            "rotation_xyzw": [q.x, q.y, q.z, q.w],
            "intrinsics_columns": [k.columns.0, k.columns.1, k.columns.2].map { [$0.x, $0.y, $0.z] },
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    try! data.write(to: URL(fileURLWithPath: output.path + ".poses.json"))
    print("poses: \(out.count) cameras")
}
Task {
    do { for try await msg in session.outputs {
        switch msg {
        case .requestProgress(_, let f): print(String(format: "progress %.0f%%", f * 100))
        case .requestComplete(_, .poses(let poses)): savePoses(poses)
        case .requestComplete(_, let r): print("done: \(r)")
        case .requestError(_, let e): print("error: \(e)"); exit(1)
        case .processingComplete: exit(0)
        case .invalidSample(let id, let reason): print("invalid sample \(id): \(reason)")
        case .skippedSample(let id): print("skipped sample \(id)")
        default: break
        }
    } } catch { print("error: \(error)"); exit(1) }
}
try session.process(requests: posesOnly ? [.poses] : [.modelFile(url: output, detail: detail), .poses])
RunLoop.main.run()
