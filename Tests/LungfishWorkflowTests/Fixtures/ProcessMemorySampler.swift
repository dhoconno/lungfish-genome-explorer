import Darwin
import Foundation

final class ProcessMemorySampler: @unchecked Sendable {
    enum SamplerError: Error, Equatable {
        case timedOut(String)
        case sampleFailed(String)
        case cadenceExceeded(maxGapNanoseconds: UInt64)
    }

    typealias Sample = @Sendable () throws -> UInt64
    typealias MonotonicNow = @Sendable () -> UInt64
    typealias WaitUntil = @Sendable (_ deadlineNanoseconds: UInt64) -> Bool
    typealias Wake = @Sendable () -> Void

    struct CadenceControl: Sendable {
        let monotonicNow: MonotonicNow
        let waitUntil: WaitUntil
        let wake: Wake

        init(
            monotonicNow: @escaping MonotonicNow,
            waitUntil: @escaping WaitUntil,
            wake: @escaping Wake
        ) {
            self.monotonicNow = monotonicNow
            self.waitUntil = waitUntil
            self.wake = wake
        }
    }

    static let targetSampleIntervalNanoseconds: UInt64 = 500_000
    static let maximumAllowedSampleGapNanoseconds: UInt64 = 1_000_000

    private let condition = NSCondition()
    private let sample: Sample
    private let cadenceControl: CadenceControl
    private var thread: Thread?
    private var shouldStop = false
    private var finished = false
    private var failure: SamplerError?
    private var terminalRequest = 0
    private var terminalAcknowledgement = 0
    private var peak: UInt64 = 0
    private var baseline: UInt64 = 0
    private var samples: UInt64 = 0
    private var firstSampleTimestamp: UInt64?
    private var lastSampleTimestamp: UInt64?
    private var maximumSampleGap: UInt64 = 0

    init(
        sample:
            @escaping Sample =
            ProcessMemorySampler.currentResidentFootprint,
        cadenceControl: CadenceControl? = nil
    ) {
        self.sample = sample
        if let cadenceControl {
            self.cadenceControl = cadenceControl
        } else {
            let wake = DispatchSemaphore(value: 0)
            self.cadenceControl = CadenceControl(
                monotonicNow: {
                    DispatchTime.now().uptimeNanoseconds
                },
                waitUntil: { deadlineNanoseconds in
                    wake.wait(
                        timeout: DispatchTime(
                            uptimeNanoseconds: deadlineNanoseconds
                        )
                    ) == .timedOut
                },
                wake: {
                    wake.signal()
                }
            )
        }
    }

    var baselineResidentBytes: UInt64 {
        condition.withLock { baseline }
    }

    var peakResidentBytes: UInt64 {
        condition.withLock { peak }
    }

    var sampleCount: UInt64 {
        condition.withLock { samples }
    }

    var firstSampleTimestampNanoseconds: UInt64? {
        condition.withLock { firstSampleTimestamp }
    }

    var lastSampleTimestampNanoseconds: UInt64? {
        condition.withLock { lastSampleTimestamp }
    }

    var maximumObservedSampleGapNanoseconds: UInt64 {
        condition.withLock { maximumSampleGap }
    }

    var isJoined: Bool {
        condition.withLock { thread == nil && finished }
    }

    func arm(timeout: TimeInterval = 5) throws {
        condition.lock()
        precondition(thread == nil)
        shouldStop = false
        finished = false
        failure = nil
        terminalRequest = 0
        terminalAcknowledgement = 0
        peak = 0
        baseline = 0
        samples = 0
        firstSampleTimestamp = nil
        lastSampleTimestamp = nil
        maximumSampleGap = 0
        let worker = Thread { [weak self] in
            self?.sampleUntilStopped()
        }
        thread = worker
        worker.start()
        do {
            try waitLocked(
                timeout: timeout,
                barrier: "first-sample",
                until: { samples > 0 || failure != nil || finished }
            )
        } catch {
            condition.unlock()
            throw error
        }
        let observedFailure = failure
        condition.unlock()
        if let observedFailure {
            throw observedFailure
        }
    }

    func requestTerminalSampleAndWait(
        timeout: TimeInterval = 5
    ) throws {
        condition.lock()
        if let failure {
            condition.unlock()
            throw failure
        }
        guard thread != nil, !finished else {
            condition.unlock()
            throw SamplerError.sampleFailed(
                "terminal sample requested while sampler was not running"
            )
        }
        terminalRequest += 1
        let requested = terminalRequest
        cadenceControl.wake()
        condition.broadcast()
        do {
            try waitLocked(
                timeout: timeout,
                barrier: "terminal-sample",
                until: {
                    terminalAcknowledgement >= requested
                        || failure != nil
                        || finished
                }
            )
        } catch {
            condition.unlock()
            throw error
        }
        let observedFailure = failure
        condition.unlock()
        if let observedFailure {
            throw observedFailure
        }
    }

    func stop() {
        condition.withLock {
            shouldStop = true
            condition.broadcast()
        }
        cadenceControl.wake()
    }

    func join(timeout: TimeInterval = 5) throws {
        condition.lock()
        do {
            try waitLocked(
                timeout: timeout,
                barrier: "join",
                until: { finished }
            )
        } catch {
            condition.unlock()
            throw error
        }
        let observedFailure = failure
        thread = nil
        condition.unlock()
        if let observedFailure {
            throw observedFailure
        }
    }

    private func sampleUntilStopped() {
        let firstTimestamp = cadenceControl.monotonicNow()
        do {
            let first = try sample()
            recordSample(
                first,
                timestamp: firstTimestamp,
                terminalRequest: 0
            )
        } catch {
            finish(with: error)
            return
        }
        var nextDeadline = deadline(after: firstTimestamp)

        while true {
            condition.lock()
            let requested = terminalRequest
            let stopping = shouldStop
            let terminalSampleRequired =
                terminalAcknowledgement < requested
            condition.unlock()

            if stopping && !terminalSampleRequired {
                finish()
                return
            }
            if !terminalSampleRequired {
                guard cadenceControl.waitUntil(nextDeadline) else {
                    continue
                }
                condition.lock()
                let stoppedWhileWaiting = shouldStop
                    && terminalAcknowledgement >= terminalRequest
                condition.unlock()
                if stoppedWhileWaiting {
                    finish()
                    return
                }
            }

            let timestamp = cadenceControl.monotonicNow()
            do {
                let current = try sample()
                if let cadenceFailure = recordSample(
                    current,
                    timestamp: timestamp,
                    terminalRequest: requested
                ) {
                    finish(with: cadenceFailure)
                    return
                }
                nextDeadline = deadline(after: timestamp)
            } catch {
                finish(with: error)
                return
            }
        }
    }

    @discardableResult
    private func recordSample(
        _ value: UInt64,
        timestamp: UInt64,
        terminalRequest requested: Int
    ) -> SamplerError? {
        condition.withLock {
            var cadenceFailure: SamplerError?
            if let previous = lastSampleTimestamp {
                let gap = timestamp >= previous
                    ? timestamp - previous
                    : UInt64.max
                maximumSampleGap = max(maximumSampleGap, gap)
                if gap > Self.maximumAllowedSampleGapNanoseconds {
                    cadenceFailure = .cadenceExceeded(
                        maxGapNanoseconds: gap
                    )
                }
            } else {
                baseline = value
                firstSampleTimestamp = timestamp
            }
            lastSampleTimestamp = timestamp
            peak = max(peak, value)
            samples += 1
            terminalAcknowledgement = max(
                terminalAcknowledgement,
                requested
            )
            condition.broadcast()
            return cadenceFailure
        }
    }

    private func deadline(after timestamp: UInt64) -> UInt64 {
        let (deadline, overflow) = timestamp.addingReportingOverflow(
            Self.targetSampleIntervalNanoseconds
        )
        return overflow ? UInt64.max : deadline
    }

    private func finish(with error: Error? = nil) {
        condition.withLock {
            if let samplerError = error as? SamplerError {
                failure = samplerError
            } else if let error {
                failure = .sampleFailed(String(describing: error))
            }
            finished = true
            condition.broadcast()
        }
    }

    private func waitLocked(
        timeout: TimeInterval,
        barrier: String,
        until predicate: () -> Bool
    ) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate() {
            guard condition.wait(until: deadline) else {
                throw SamplerError.timedOut(barrier)
            }
        }
    }

    static func currentResidentFootprint() throws -> UInt64 {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) {
            pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw POSIXError(.EIO)
        }
        return UInt64(information.phys_footprint)
    }
}
