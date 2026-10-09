import Foundation

final class NvstFrameTiming {
    struct Schedule: Sendable {
        let deadlineNanoseconds: UInt64
        let frameDurationSeconds: Double
        let variableRefreshDurationSeconds: Double
        let arrivalJitterSeconds: Double
        let pinnedQueue: Bool
    }

    private struct History {
        var mean: Double
        var variance = 0.0
        var quantile = 0.0
        let alpha: Double
        let probability: Double
        let convergence: Double

        mutating func update(_ sample: Double) {
            let difference = sample - mean
            variance = (1 - alpha) * (variance + alpha * difference * difference)
            mean = (1 - alpha) * mean + alpha * sample
            guard probability > 0 else { return }
            let magnitude = abs(sample)
            if quantile == 0 {
                quantile = magnitude
            } else if quantile > magnitude {
                quantile -= sqrt(variance) * convergence / probability
            } else if quantile < magnitude {
                quantile += sqrt(variance) * convergence / (1 - probability)
            }
        }
    }

    private var offset = History(mean: 0, alpha: 2 / 61, probability: 0, convergence: 0.001)
    private var captureInterval = History(mean: 1 / 60, alpha: 2 / 11, probability: 0, convergence: 0.001)
    private var arrivalInterval = History(mean: 1 / 240, alpha: 2 / 11, probability: 0, convergence: 0.001)
    private var jitter = History(mean: 0, alpha: 2 / 3601, probability: 0.997, convergence: 0.002)
    private var previousCapture: Double?
    private var previousArrival: Double?
    private var previousDeadline = 0.0
    private var frameCount = 0
    private var minimumQueueSeconds = 0.008
    private var maximumQueueSeconds = 0.032
    private var pinnedQueue = false

    func configure(_ configuration: NvstClientDJBConfig) {
        let usesBounds = configuration.pinned || configuration.mode == .fixed
        pinnedQueue = usesBounds
        minimumQueueSeconds = usesBounds ? min(0.032, Double(configuration.minimumDepthMicroseconds) / 1_000_000) : 0.008
        maximumQueueSeconds = usesBounds ? Double(configuration.maximumDepthMicroseconds) / 1_000_000 : 0.032
        maximumQueueSeconds = max(minimumQueueSeconds, maximumQueueSeconds)
    }

    func nextSchedule(captureMicroseconds: Int64?, arrivalNanoseconds: UInt64) -> Schedule {
        let arrival = Double(arrivalNanoseconds) / 1_000_000_000
        if let previousArrival {
            arrivalInterval.update(min(1 / 15, max(0, arrival - previousArrival)))
        }
        defer { previousArrival = arrival }
        guard let captureMicroseconds, captureMicroseconds >= 0 else {
            return Schedule(deadlineNanoseconds: arrivalNanoseconds,
                frameDurationSeconds: captureInterval.mean,
                variableRefreshDurationSeconds: arrivalInterval.mean,
                arrivalJitterSeconds: max(minimumQueueSeconds, jitter.quantile), pinnedQueue: pinnedQueue)
        }
        let capture = Double(captureMicroseconds) / 1_000_000
        let observation = arrival - capture
        if let previousCapture, let previousArrival, capture >= previousCapture,
           offset.mean != 0, capture > previousCapture {
            offset.update(observation)
            let interval = capture - previousCapture
            captureInterval.update(min(1 / 15, max(1 / 240, interval)))
            if frameCount >= 100 {
                jitter.update(min(0.075, max(-0.075, arrival - (previousArrival + interval))))
            }
        } else {
            offset.mean = observation
            offset.variance = 0
            offset.quantile = 0
            captureInterval.mean = 1 / 60
            captureInterval.variance = 0
            jitter.mean = 0
            jitter.variance = 0
            jitter.quantile = 0
            frameCount = 0
        }
        previousCapture = capture
        let bounded = min(maximumQueueSeconds, max(minimumQueueSeconds, jitter.quantile))
        let advance: Double
        if frameCount < 100 {
            advance = 0.02
        } else if frameCount < 200 {
            advance = 0.02 + (bounded - 0.02) * Double(frameCount - 100) / 100
        } else {
            advance = bounded
        }
        let candidate = min(arrival + advance, max(arrival - advance, capture + offset.mean + advance))
        previousDeadline = max(previousDeadline, candidate)
        frameCount += 1
        return Schedule(deadlineNanoseconds: UInt64(max(0, previousDeadline) * 1_000_000_000),
            frameDurationSeconds: captureInterval.mean,
            variableRefreshDurationSeconds: arrivalInterval.mean,
            arrivalJitterSeconds: max(minimumQueueSeconds, jitter.quantile), pinnedQueue: pinnedQueue)
    }
}
