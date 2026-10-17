import AVFoundation

/// Procedural gas hiss: filtered noise whose loudness follows the thrusters.
final class Hiss {
    private final class Level: @unchecked Sendable {
        var target: Float = 0
    }

    // Starting and stopping AVAudioEngine can block for tens of milliseconds, so the engine
    // lives on its own queue and the frame loop only flips `isRunning`.
    private let queue = DispatchQueue(label: "run.lil.liftoff.hiss")
    private let engine = AVAudioEngine()
    private let level = Level()
    private var isConfigured = false
    private var isRunning = false
    private var idleSince: Date?

    var isEnabled = true {
        didSet { if !isEnabled { stop() } }
    }

    /// Spin the engine up while the window is still in hand, so it's ready when the jets fire.
    func prewarm() {
        guard isEnabled else { return }
        idleSince = nil
        start()
    }

    /// 0 is silent, around 1 is all four jets at full throttle.
    func set(_ throttle: Double) {
        guard isEnabled else { return }
        level.target = Float(min(throttle, 1.5)) * 0.12
        if throttle > 0.01 {
            idleSince = nil
            start()
        } else if isRunning {
            if idleSince == nil { idleSince = Date() }
            if let idleSince, Date().timeIntervalSince(idleSince) > 1.5 { stop() }
        }
    }

    /// A short burst for touchdown.
    func puff() {
        guard isEnabled else { return }
        level.target = 0.2
        idleSince = nil
        start()
    }

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [self] in
            if !isConfigured { configure() }
            try? engine.start()
        }
    }

    private func stop() {
        level.target = 0
        idleSince = nil
        guard isRunning else { return }
        isRunning = false
        queue.async { [self] in engine.stop() }
    }

    private func configure() {
        let sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48_000, channels: 1)
        else { return }
        let level = self.level
        var current: Float = 0, low: Float = 0, seed: UInt32 = 0x9E37_79B9

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            let output = UnsafeMutableAudioBufferListPointer(buffers)
            let target = level.target
            for frame in 0..<Int(frameCount) {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                let white = Float(seed) / Float(UInt32.max) * 2 - 1
                low += 0.06 * (white - low)
                // Rise quickly when the jets fire, die away slowly when they stop.
                current += (target - current) * (target > current ? 0.0008 : 0.00008)
                let sample = (white * 0.3 + low * 1.4) * current
                for buffer in output {
                    buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        isConfigured = true
    }
}
