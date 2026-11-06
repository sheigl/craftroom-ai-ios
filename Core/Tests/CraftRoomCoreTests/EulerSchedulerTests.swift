import XCTest
@testable import CraftRoomCore

/// The baked Euler schedule must reproduce the numpy golden step by step
/// (`x += (sigma[i+1] - sigma[i]) * eps`), so the device runs the same
/// trajectory the frozen eval scored.
final class EulerSchedulerTests: XCTestCase {
    struct Golden: Decodable {
        let sigmas: [Double]
        let steps: Int
        let x0f64: [Double]
        let epsF64: [[Double]]
        let xF64: [[Double]]
        let xF32: [[Double]]
        let tolerance: Double

        enum CodingKeys: String, CodingKey {
            case sigmas, steps
            case x0f64 = "x0_f64"
            case epsF64 = "eps_f64"
            case xF64 = "x_f64"
            case xF32 = "x_f32"
            case tolerance = "tolerance_f32"
        }
    }

    private func golden() throws -> Golden {
        guard let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixtures missing from the test bundle")
        }
        let url = base.appendingPathComponent("scheduler/euler_golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func testBundledBinMatchesGoldenSigmas() throws {
        let sched = try EulerScheduler.bundled()
        let g = try golden()
        XCTAssertEqual(sched.steps, 30)
        XCTAssertEqual(sched.steps, g.steps)
        XCTAssertEqual(sched.sigmas.count, 31)
        XCTAssertEqual(sched.timesteps.count, 30)
        for i in 0..<sched.sigmas.count {
            XCTAssertEqual(Double(sched.sigmas[i]), g.sigmas[i], accuracy: 1e-6,
                           "sigma[\(i)]")
        }
        XCTAssertEqual(sched.sigmas.last, 0, "the schedule must end at zero")
        // Scheduler facts the harness relies on.
        XCTAssertEqual(Double(sched.initNoiseSigma), 11.476851, accuracy: 1e-4)
        XCTAssertEqual(sched.timesteps.first, 958)
        XCTAssertEqual(sched.timesteps.last, 1)
        XCTAssertEqual(sched.timesteps.map { $0.rounded() }, sched.timesteps,
                       "integer timesteps are exact in fp16")
    }

    func testStepReproducesNumpyFloat64Trajectory() throws {
        let sched = try EulerScheduler.bundled()
        let g = try golden()
        let n = g.x0f64.count
        var x = g.x0f64.map { Float($0) }
        var worst = 0.0
        for i in 0..<sched.steps {
            let eps = g.epsF64[i].map { Float($0) }
            sched.step(&x, eps: eps, index: i)
            for k in 0..<n {
                // compare our float32 result against the float64 reference
                let ref = (i + 1 < g.xF64.count) ? g.xF64[i + 1][k] : g.xF64.last![k]
                worst = max(worst, abs(Double(x[k]) - ref))
            }
        }
        print(String(format: "euler: %d steps, worst |Δ| vs float64 = %.3e", sched.steps, worst))
        XCTAssertLessThan(worst, 2e-5, "Euler trajectory drifted from the numpy golden")

        // and against the float32 golden, which is what the device computes
        let ref32 = try XCTUnwrap(g.xF32.last)
        for k in 0..<n {
            XCTAssertEqual(Double(x[k]), ref32[k], accuracy: g.tolerance)
        }
    }

    func testInitNoiseScalingAndDtSign() throws {
        let sched = try EulerScheduler.bundled()
        // dt is negative for this schedule (sigmas descend) and sums to -sigma[0]
        var sum: Float = 0
        for i in 0..<sched.steps {
            let dt = sched.sigmas[i + 1] - sched.sigmas[i]
            XCTAssertLessThan(dt, 0, "Euler sigmas must descend")
            sum += dt
        }
        XCTAssertEqual(Double(sum), -Double(sched.initNoiseSigma), accuracy: 1e-4)
    }

    func testRejectsCorruptBins() {
        XCTAssertThrowsError(try EulerScheduler(data: Data()))
        XCTAssertThrowsError(try EulerScheduler(data: Data("NOPE".utf8) + Data(count: 64)))
        var bad = Data("CRES".utf8)
        bad.append(contentsOf: [UInt8](repeating: 0, count: 12))
        XCTAssertThrowsError(try EulerScheduler(data: bad))
    }

    func testSeededNoiseIsReproducibleAndScaled() {
        var a = SeededGaussian(seed: 42)
        var b = SeededGaussian(seed: 42)
        var sum: Double = 0
        var sq: Double = 0
        let n = 4096
        for _ in 0..<n {
            let v = a.next()
            XCTAssertEqual(v, b.next(), "same seed must give the same noise")
            sum += Double(v)
            sq += Double(v) * Double(v)
        }
        let mean = sum / Double(n)
        let sd = (sq / Double(n) - mean * mean).squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 0.06)
        XCTAssertEqual(sd, 1, accuracy: 0.06)
    }
}
