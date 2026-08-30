import Testing
import Foundation
@testable import LapelKit

/// Deterministic signal generators so every expectation below is arithmetic, not vibes.
private func sine(amplitude: Float, frequency: Double = 1_000, sampleRate: Double = 48_000, cycles: Int = 100) -> [Float] {
    let samplesPerCycle = sampleRate / frequency
    let count = Int(samplesPerCycle * Double(cycles))
    return (0..<count).map { i in
        amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
    }
}

private func silence(seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * sampleRate))
}

@Suite("LevelMeter")
struct LevelMeterTests {

    @Test("a full-scale sine reads -3.01 dBFS RMS and 0 dBFS peak")
    func fullScaleSine() {
        var meter = LevelMeter()
        let reading = meter.process(sine(amplitude: 1.0), sampleRate: 48_000)

        #expect(abs(reading.rmsDB - (-3.0103)) < 0.05)
        #expect(abs(reading.peakDB - 0.0) < 0.05)
    }

    @Test("halving amplitude drops RMS by 6.02 dB")
    func halfScaleSine() {
        var meter = LevelMeter()
        let reading = meter.process(sine(amplitude: 0.5), sampleRate: 48_000)

        #expect(abs(reading.rmsDB - (-9.03)) < 0.05)
    }

    @Test("silence floors at the meter floor rather than negative infinity")
    func silenceIsFloored() {
        var meter = LevelMeter()
        let reading = meter.process(silence(seconds: 0.1), sampleRate: 48_000)

        #expect(reading.rmsDB == LevelMeter.floorDB)
        #expect(reading.peakDB == LevelMeter.floorDB)
        #expect(reading.rmsDB.isFinite)
    }

    @Test("an empty buffer is treated as silence, not a crash")
    func emptyBuffer() {
        var meter = LevelMeter()
        let reading = meter.process([], sampleRate: 48_000)

        #expect(reading.rmsDB == LevelMeter.floorDB)
    }

    @Test("held peak decays at the configured rate so the UI bar falls smoothly")
    func peakHoldDecays() {
        var meter = LevelMeter(peakHoldDecayDBPerSecond: 20)
        _ = meter.process(sine(amplitude: 1.0), sampleRate: 48_000)   // peak now 0 dBFS

        let afterHalfSecond = meter.process(silence(seconds: 0.5), sampleRate: 48_000)

        // 20 dB/s * 0.5 s = 10 dB of decay from 0 dBFS.
        #expect(abs(afterHalfSecond.peakDB - (-10)) < 0.2)
    }

    @Test("a louder transient overrides the decaying held peak immediately")
    func peakHoldRisesInstantly() {
        var meter = LevelMeter(peakHoldDecayDBPerSecond: 20)
        _ = meter.process(sine(amplitude: 0.1), sampleRate: 48_000)   // ~ -20 dBFS peak
        let loud = meter.process(sine(amplitude: 1.0), sampleRate: 48_000)

        #expect(abs(loud.peakDB - 0.0) < 0.05)
    }

    @Test("peak decay never falls below the floor")
    func peakDecayClampsAtFloor() {
        var meter = LevelMeter(peakHoldDecayDBPerSecond: 20)
        _ = meter.process(sine(amplitude: 1.0), sampleRate: 48_000)
        let reading = meter.process(silence(seconds: 60), sampleRate: 48_000)

        #expect(reading.peakDB == LevelMeter.floorDB)
    }

    @Test("clipping is flagged at or above -0.1 dBFS")
    func clippingDetection() {
        var hot = LevelMeter()
        #expect(hot.process(sine(amplitude: 1.0), sampleRate: 48_000).isClipping)

        var cool = LevelMeter()
        #expect(!cool.process(sine(amplitude: 0.5), sampleRate: 48_000).isClipping)
    }

    @Test("normalized position maps the floor to 0 and full scale to 1")
    func normalizationEndpoints() {
        #expect(LevelReading.normalizedPosition(forDB: 0) == 1.0)
        #expect(LevelReading.normalizedPosition(forDB: LevelMeter.floorDB) == 0.0)
    }

    @Test("normalized position is monotonic and clamps outside the range")
    func normalizationMonotonicAndClamped() {
        let ladder: [Float] = [-80, -60, -40, -20, -12, -6, -3, 0]
        let positions = ladder.map { LevelReading.normalizedPosition(forDB: $0) }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })

        #expect(LevelReading.normalizedPosition(forDB: -200) == 0.0)
        #expect(LevelReading.normalizedPosition(forDB: 12) == 1.0)
    }
}
