// CI ANE plan probe for the device-v2 UNet+ControlNet package.
//
// Answers, without an iPad install (see sdxl/teacher/device_v2/ci/ANE_PROBE.md
// in the Linux repo):
//   * does the Neural Engine accept our graph, per `MLComputeUnits` setting
//     (`MLComputePlan` op placement: ANE / GPU / CPU per preferred device);
//   * which operations have no device at all — the reconversion suspects;
//   * whether the palettized (LUT) weight ops keep a device placement;
//   * does one real `.cpuAndNeuralEngine` forward survive, how long does it
//     take, and what is the process footprint (`phys_footprint`), which
//     distinguishes packed from de-palettized weights by order of magnitude
//     (~2.9 GB packed / ~7.3 GB fp16 / ~15.3 GB fp32).
//
// It is NOT a timing or a memory verdict: the CI runner is Apple silicon
// macOS, not iPadOS 26 on an M4, and a virtualized runner may expose neither
// the ANE nor the GPU — `MLModel.availableComputeDevices` is printed so the
// log says which devices the plan was actually computed against.
//
// Build (swiftc, no Xcode project; needs the macOS 14.4+ SDK for MLComputePlan):
//   mkdir -p build
//   xcrun swiftc -O -parse-as-library scripts/ane_plan_probe.swift -o build/ane_plan_probe
//
// Run:
//   ./build/ane_plan_probe <path-to.mlmodelc> --label 6bit-split-einsum
//
// Output contract (greppable, one line each):
//   PLAN label=<l> units=<u> ops=<n> pref_ane=<a> pref_gpu=<g> pref_cpu=<c> unsupported=<x>
//     UNSUPPORTED <op-name> x<count>          (up to 10 compute ops with no device)
//     NOT_ANE <op-name>@<device> x<count>     (up to 10, ANE config only)
//   FORWARD label=<l> units=ane ok=<true|false> ms=<t> footprint_mb=<m>
//   FORWARD label=<l> units=ane ok=false ms=<t> footprint_mb=<m> error=<msg>
//   SUMMARY label=<l> ...                     (short block, printed last)
//
// `ops` counts every operation in the plan; weight-materializing ops
// (`const`, `constexpr_lut_to_dense`, …) are reported separately as
// `weight_ops` and never counted as unsupported. `unsupported` therefore means
// "a compute op that no available device can take".
//
// A failed forward is data, not an error: the log is the deliverable. The
// process exits non-zero only when it cannot run at all (bad arguments).

import CoreML
import Darwin
import Foundation

// MARK: - Output

/// Unbuffered writes: if the forward attempt gets memory-killed, the PLAN lines
/// already written must survive in the CI log.
func emit(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

func number(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ; ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
}

struct ProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Device classification

/// Classify a compute device without pattern-matching its enum cases.
///
/// `MLComputeDevice` carries associated device objects and its
/// `String(describing:)` prints the payload (e.g. `MLCPUComputeDevice: 0x…`,
/// `MLNeuralEngineComputeDevice`), and the optionality of
/// `MLComputePlan.DeviceUsage.preferred` differs between SDK releases. Matching
/// on the description keeps this compiling and correct across both shapes.
func deviceKind(_ value: Any?) -> String {
    guard let value else { return "none" }
    var text = String(describing: value)
    while text.hasPrefix("Optional(") && text.hasSuffix(")") {
        text = String(text.dropFirst("Optional(".count).dropLast())
    }
    if text.isEmpty || text == "nil" { return "none" }
    let lowered = text.lowercased()
    if lowered.contains("neuralengine") { return "ane" }
    if lowered.contains("gpu") { return "gpu" }
    if lowered.contains("cpu") { return "cpu" }
    return text
}

// MARK: - Plan walk

struct PlanStats {
    var ops = 0
    var ane = 0
    var gpu = 0
    var cpu = 0
    /// Compute ops that no available device can take.
    var unsupported = 0
    /// Weight-materializing ops (`const`, LUT/affine dequantization): packing
    /// bookkeeping, not compute — never counted as unsupported.
    var weightOps = 0
    var unsupportedByName: [String: Int] = [:]
    /// Placement of palettized weight ops, e.g. ["none": 1194].
    var lutByDevice: [String: Int] = [:]
    /// Non-ANE placement, keyed "<operator>@<device>".
    var nonANE: [String: Int] = [:]
}

func isWeightOp(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered == "const" || lowered.hasPrefix("constexpr_") || lowered.hasPrefix("const_")
}

@available(macOS 15.0, *)
func record(usage: MLComputePlan.DeviceUsage?, name: String, into stats: inout PlanStats) {
    stats.ops += 1
    var kind = "none"
    if let usage, !usage.supported.isEmpty {
        kind = deviceKind(usage.preferred)
    }
    let isWeight = isWeightOp(name)
    if isWeight {
        stats.weightOps += 1
        if name.lowercased().contains("lut") {
            stats.lutByDevice[kind, default: 0] += 1
        }
        return
    }
    switch kind {
    case "ane":
        stats.ane += 1
    case "gpu":
        stats.gpu += 1
        stats.nonANE["\(name)@gpu", default: 0] += 1
    case "cpu":
        stats.cpu += 1
        stats.nonANE["\(name)@cpu", default: 0] += 1
    case "none":
        stats.unsupported += 1
        stats.unsupportedByName[name, default: 0] += 1
    default:
        stats.unsupported += 1
        stats.unsupportedByName["\(name)@\(kind)", default: 0] += 1
        stats.nonANE["\(name)@\(kind)", default: 0] += 1
    }
}

@available(macOS 15.0, *)
func walk(block: MLModelStructure.Program.Block, plan: MLComputePlan, into stats: inout PlanStats) {
    for operation in block.operations {
        record(usage: plan.deviceUsage(for: operation), name: operation.operatorName, into: &stats)
        for nested in operation.blocks {
            walk(block: nested, plan: plan, into: &stats)
        }
    }
}

/// Returns a short structural description (e.g. `program(functions=2)`).
@available(macOS 15.0, *)
func walk(structure: MLModelStructure, plan: MLComputePlan, into stats: inout PlanStats) -> String {
    switch structure {
    case .program(let program):
        for (_, function) in program.functions {
            walk(block: function.block, plan: plan, into: &stats)
        }
        return "program(functions=\(program.functions.count))"
    case .neuralNetwork(let network):
        for layer in network.layers {
            record(usage: plan.deviceUsage(for: layer), name: "layer.\(layer.name)", into: &stats)
        }
        return "neuralNetwork(layers=\(network.layers.count))"
    case .pipeline(let pipeline):
        var parts: [String] = []
        for (name, sub) in zip(pipeline.subModelNames, pipeline.subModels) {
            let kind = walk(structure: sub, plan: plan, into: &stats)
            parts.append("\(name):\(kind)")
        }
        return "pipeline[\(parts.joined(separator: ","))]"
    default:
        return "unsupported"
    }
}

func elapsedMS(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000.0
}

// MARK: - Footprint

/// Resident footprint of this process (`task_vm_info.phys_footprint`), in MiB.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / (1024 * 1024)
}

// MARK: - Forward

/// Contract shapes from sdxl/teacher/device_v2_io_contract.json (sample 2x4x96x96,
/// timestep 2, encoder_hidden_states 2x77x2048, text_embeds 2x1280, time_ids 2x6,
/// controlnet_cond 2x3x768x768; row 0 is the positive prompt). The declared
/// model shape wins when it is concrete; the contract fills flexible inputs.
func contractShape(_ name: String) -> [Int]? {
    switch name {
    case "sample": return [2, 4, 96, 96]
    case "timestep": return [2]
    case "encoder_hidden_states": return [2, 77, 2048]
    case "text_embeds": return [2, 1280]
    case "time_ids": return [2, 6]
    case "controlnet_cond": return [2, 3, 768, 768]
    default: return nil
    }
}

func elementSize(_ dataType: MLMultiArrayDataType) -> Int? {
    switch dataType {
    case .float16: return 2
    case .float32: return 4
    case .double: return 8
    case .int32: return 4
    default: return nil
    }
}

func makeInputs(for model: MLModel) throws -> MLDictionaryFeatureProvider {
    var features: [String: MLFeatureValue] = [:]
    for (name, description) in model.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
        guard description.type == .multiArray, let constraint = description.multiArrayConstraint else {
            throw ProbeFailure("input '\(name)' is \(description.type.rawValue), expected multiArray")
        }
        var shape = constraint.shape.map { $0.intValue }
        if shape.isEmpty || shape.contains(where: { $0 <= 0 }) {
            guard let contract = contractShape(name) else {
                throw ProbeFailure("input '\(name)' has a flexible shape and no io-contract entry")
            }
            shape = contract
        }
        guard let size = elementSize(constraint.dataType) else {
            throw ProbeFailure("input '\(name)' has unsupported data type \(constraint.dataType.rawValue)")
        }
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
        let count = array.count
        // Deterministic, non-pathological values: this forward is a placement
        // and footprint test, not a numerics test.
        _ = memset(array.dataPointer, 0, count * size)
        if name == "timestep" {
            let steps = min(count, 2) // both batch rows get the same timestep
            switch constraint.dataType {
            case .float16:
                let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
                for index in 0..<steps { pointer[index] = 500 }
            case .float32:
                let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
                for index in 0..<steps { pointer[index] = 500 }
            case .double:
                let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
                for index in 0..<steps { pointer[index] = 500 }
            default:
                break
            }
        }
        features[name] = MLFeatureValue(multiArray: array)
        emit("INFO input name=\(name) shape=\(shape.map { String($0) }.joined(separator: "x")) dtype=\(constraint.dataType.rawValue)")
    }
    guard !features.isEmpty else { throw ProbeFailure("model declares no multiArray inputs") }
    return try MLDictionaryFeatureProvider(dictionary: features)
}

func attemptForward(modelURL: URL, label: String) -> (ok: Bool, ms: Double) {
    let start = DispatchTime.now()
    do {
        emit("INFO footprint_before_load_mb=\(number(footprintMB()))")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        emit("INFO footprint_loaded_mb=\(number(footprintMB()))")
        let provider = try makeInputs(for: model)
        emit("INFO footprint_prepared_mb=\(number(footprintMB()))")

        let predictionStart = DispatchTime.now()
        let output = try model.prediction(from: provider)
        let ms = elapsedMS(since: predictionStart)
        emit("INFO output=\(output.featureNames.sorted().joined(separator: ","))")
        emit("FORWARD label=\(label) units=ane ok=true ms=\(number(ms)) footprint_mb=\(number(footprintMB()))")

        // A second prediction separates "weights unpacked once" from "unpacked
        // per step": the footprint after it is the real residency. Skipped when
        // the first one was already slow, so the job stays inside its timeout.
        if ms < 120_000 {
            let repeatStart = DispatchTime.now()
            do {
                _ = try model.prediction(from: provider)
                emit("INFO forward_repeat ok=true ms=\(number(elapsedMS(since: repeatStart))) footprint_mb=\(number(footprintMB()))")
            } catch {
                emit("INFO forward_repeat ok=false error=\(oneLine(error.localizedDescription))")
            }
        } else {
            emit("INFO forward_repeat skipped=slow ms=\(number(ms))")
        }
        return (true, ms)
    } catch {
        let ms = elapsedMS(since: start)
        emit("FORWARD label=\(label) units=ane ok=false ms=\(number(ms)) footprint_mb=\(number(footprintMB())) error=\(oneLine(error.localizedDescription))")
        return (false, ms)
    }
}

// MARK: - Entry point

struct UnitsProbe {
    let name: String
    let units: MLComputeUnits
    var stats = PlanStats()
    var structure = "unknown"
    var planMS = 0.0
    var failed = false
}

func topCounts(_ counts: [String: Int], limit: Int) -> [(key: String, value: Int)] {
    counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .prefix(limit)
        .map { (key: $0.key, value: $0.value) }
}

@main
struct ANEPlanProbe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var label = "unlabeled"
        if let index = arguments.firstIndex(of: "--label"), index + 1 < arguments.count {
            label = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }
        guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
            emit("ERROR usage: ane_plan_probe <path-to.mlmodelc|mlpackage> [--label NAME]")
            exit(2)
        }
        let modelURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            emit("ERROR model path not found: \(modelURL.path)")
            exit(2)
        }

        emit("INFO tool=ane_plan_probe v2 label=\(label) model=\(modelURL.path)")
        emit("INFO host=\(ProcessInfo.processInfo.operatingSystemVersionString) footprint_start_mb=\(number(footprintMB()))")

        var probes = [
            UnitsProbe(name: "cpuAndNeuralEngine", units: .cpuAndNeuralEngine),
            UnitsProbe(name: "cpuAndGPU", units: .cpuAndGPU),
            UnitsProbe(name: "all", units: .all),
        ]

        if #available(macOS 15.0, *) {
            // Which devices the plan is actually computed against: a virtualized
            // runner may expose neither the ANE nor the GPU, in which case every
            // op can only be preferred to the CPU.
            let devices = MLModel.availableComputeDevices
            emit("INFO available_compute_devices="
                + devices.map { deviceKind($0) }.joined(separator: ",")
                + " raw=\(devices)")
            if !devices.contains(where: { deviceKind($0) == "ane" }) {
                emit("WARN no_ane_device_on_host plausible=false for ANE placement")
            }

            for index in probes.indices {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = probes[index].units
                let start = DispatchTime.now()
                do {
                    let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: configuration)
                    var stats = PlanStats()
                    let structure = walk(structure: plan.modelStructure, plan: plan, into: &stats)
                    probes[index].stats = stats
                    probes[index].structure = structure
                    probes[index].planMS = elapsedMS(since: start)
                } catch {
                    probes[index].failed = true
                    probes[index].planMS = elapsedMS(since: start)
                    emit("INFO plan_error units=\(probes[index].name) error=\(oneLine(error.localizedDescription))")
                }

                let probe = probes[index]
                emit("PLAN label=\(label) units=\(probe.name) ops=\(probe.stats.ops) "
                    + "pref_ane=\(probe.stats.ane) pref_gpu=\(probe.stats.gpu) "
                    + "pref_cpu=\(probe.stats.cpu) unsupported=\(probe.stats.unsupported)")
                for (name, count) in topCounts(probe.stats.unsupportedByName, limit: 10) {
                    emit("  UNSUPPORTED \(name) x\(count)")
                }
                if probe.units == .cpuAndNeuralEngine {
                    for (name, count) in topCounts(probe.stats.nonANE, limit: 10) {
                        emit("  NOT_ANE \(name) x\(count)")
                    }
                }
                let lut = probe.stats.lutByDevice.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ",")
                emit("INFO plan_detail units=\(probe.name) structure=\(probe.structure) "
                    + "plan_load_ms=\(number(probe.planMS)) weight_ops=\(probe.stats.weightOps) "
                    + "lut_placement=\(lut.isEmpty ? "none" : lut)")
            }
        } else {
            emit("ERROR MLComputePlan requires macOS 15.0 or newer — plan lines skipped")
        }

        let forward = attemptForward(modelURL: modelURL, label: label)

        // Short summary block.
        emit("SUMMARY label=\(label)")
        for probe in probes {
            emit("  SUMMARY units=\(probe.name) ops=\(probe.stats.ops) pref_ane=\(probe.stats.ane) "
                + "pref_gpu=\(probe.stats.gpu) pref_cpu=\(probe.stats.cpu) "
                + "unsupported=\(probe.stats.unsupported) weight_ops=\(probe.stats.weightOps) "
                + "structure=\(probe.structure)")
        }
        let ane = probes[0].stats
        let topUnsupported = topCounts(ane.unsupportedByName, limit: 3)
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: ",")
        emit("  SUMMARY ane_units ops=\(ane.ops) ane_share=\(number(ane.ops == 0 ? 0 : 100.0 * Double(ane.ane) / Double(ane.ops)))% "
            + "unsupported_top=\(topUnsupported.isEmpty ? "none" : topUnsupported)")
        emit("  SUMMARY forward ok=\(forward.ok) ms=\(number(forward.ms)) footprint_mb=\(number(footprintMB()))")
        emit("  SUMMARY verdict ane_preferred=\(ane.ane > 0) unsupported_total=\(ane.unsupported)")
        exit(0)
    }
}
