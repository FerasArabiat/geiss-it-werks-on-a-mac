/// Simple sound-energy beat detector: flags a beat when the current bass-band
/// level exceeds a rolling mean by a multiple of the rolling standard deviation.
/// Geiss's own changelog calls its original detector mediocre ("beat det. still
/// sucks, especially w/high fps"), so this is a clean reimplementation rather
/// than a port — tune `sensitivity`/`historySize` once we can see it react live.
final class BeatDetector {
    private var history: [Float] = []
    private let historySize: Int
    private let sensitivity: Float
    private let minimumLevel: Float

    init(historySize: Int = 43, sensitivity: Float = 1.3, minimumLevel: Float = 0.02) {
        self.historySize = historySize
        self.sensitivity = sensitivity
        self.minimumLevel = minimumLevel
    }

    func detectBeat(bassLevel: Float) -> Bool {
        defer {
            history.append(bassLevel)
            if history.count > historySize {
                history.removeFirst(history.count - historySize)
            }
        }

        guard history.count >= historySize / 2, bassLevel > minimumLevel else { return false }

        let mean = history.reduce(0, +) / Float(history.count)
        let variance = history.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(history.count)
        let threshold = mean + sensitivity * variance.squareRoot()

        return bassLevel > threshold
    }
}
