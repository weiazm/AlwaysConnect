import Foundation

/// One side of a bidirectional byte relay (DESIGN.md §17.4).
///
/// Read contract: the completion fires exactly once per read call with
/// (data, nil) for a chunk, (nil, nil) for EOF, or (nil, error) for a
/// failure. An empty chunk with no error is treated as EOF. The relay
/// never issues a second read on a side before the previous read's data
/// has been written downstream, so endpoints may assume reads are
/// strictly sequential. Writes are likewise sequential per side.
protocol PumpEndpoint: AnyObject {
    func read(completion: @escaping (Data?, Error?) -> Void)
    func write(_ data: Data, completion: @escaping (Error?) -> Void)
    func closeRead()
    func closeWrite()
    func close()
}

/// Bidirectional relay between two endpoints (DESIGN.md §17.4).
///
/// - Each direction runs its own read -> write loop; a direction reads
///   its next chunk only after the previous chunk's write completed
///   (natural backpressure, no read-ahead buffering).
/// - One side's EOF closes the other side's write side; the other
///   direction keeps draining until its own EOF.
/// - Any write error closes both sides immediately (fail closed: a
///   half-pumped flow is worse than a closed one).
/// - onDone fires exactly once, after both directions terminated.
/// - All state lives on a private serial queue; endpoint callbacks may
///   arrive on any queue.
final class Relay {
    private enum Side { case a, b }

    private let queue = DispatchQueue(label: "com.alwaysconnect.pump.relay")
    private let a: PumpEndpoint
    private let b: PumpEndpoint
    private let onDone: () -> Void
    private var aDone = false
    private var bDone = false
    private var finished = false

    init(a: PumpEndpoint, b: PumpEndpoint, onDone: @escaping () -> Void) {
        self.a = a
        self.b = b
        self.onDone = onDone
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pump(from: self.a, to: self.b, side: .a)
            self.pump(from: self.b, to: self.a, side: .b)
        }
    }

    /// Tear down from the outside (provider stop). Idempotent.
    func stop() {
        queue.async { [weak self] in self?.fail() }
    }

    private func pump(from: PumpEndpoint, to: PumpEndpoint, side: Side) {
        guard !finished else { return }
        from.read { [weak self] data, error in
            self?.queue.async {
                guard let self, !self.finished else { return }
                if let error {
                    self.fail(error: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    // EOF on this side: half-close the other side.
                    to.closeWrite()
                    self.markDone(side)
                    return
                }
                to.write(data) { [weak self] writeError in
                    self?.queue.async {
                        guard let self, !self.finished else { return }
                        if let writeError {
                            self.fail(error: writeError)
                            return
                        }
                        self.pump(from: from, to: to, side: side)
                    }
                }
            }
        }
    }

    private func markDone(_ side: Side) {
        if side == .a { aDone = true } else { bDone = true }
        if aDone && bDone { finish() }
    }

    private func fail(error: Error? = nil) {
        _ = error
        a.closeRead()
        a.closeWrite()
        b.closeRead()
        b.closeWrite()
        finish()
    }

    private func finish() {
        pumpTrace("relay finish enter finished=\(finished)")
        guard !finished else { return }
        finished = true
        a.close()
        b.close()
        onDone()
    }
}

/// Opt-in trace for pump debugging (harness and future Mac runs):
/// set ALWAYSCONNECT_PUMP_TRACE=1 to log endpoint lifecycle calls
/// to stderr. Writes are synchronous (unbuffered) so a crash cannot
/// swallow the last lines, which is the whole point: the lines
/// bracket the trapping call. Off by default; zero cost otherwise
/// (one Bool check per site).
private let pumpTraceEnabled: Bool = {
    ProcessInfo.processInfo.environment["ALWAYSCONNECT_PUMP_TRACE"] == "1"
}()

private func pumpTrace(_ line: String) {
    guard pumpTraceEnabled else { return }
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

/// File-descriptor endpoint for Relay, built on dispatch sources
/// (DESIGN.md §17.4). Used for the outbound socket side and by the
/// PumpTest harness (socketpairs stand in for flows).
///
/// Half-close semantics are real, not faked: closeWrite shuts down
/// SHUT_WR only after the pending out-buffer drains, so the other
/// direction can still deliver its remaining bytes; closeRead shuts
/// down SHUT_RD. The fd itself closes only on close() — cancel
/// handlers deliberately do NOT close it, so a reused fd number can
/// never be closed twice by mistake. All state is confined to the
/// endpoint's serial queue; resume/suspend calls are guarded by flags
/// because unbalanced dispatch source calls crash.
final class FDEndpoint: PumpEndpoint {
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readResumed = false
    private var writeResumed = false
    private var pendingRead: ((Data?, Error?) -> Void)?
    private var outBuffer = Data()
    private var pendingWrites: [(Error?) -> Void] = []
    private var readClosed = false
    private var writeClosed = false
    private var writeShutdownPending = false
    private var closed = false

    /// Takes ownership of fd (must already be non-blocking and, for
    /// sockets, connected). The fd closes when close() runs.
    init(fd: Int32, queue: DispatchQueue? = nil) {
        self.fd = fd
        self.queue = queue ?? DispatchQueue(
            label: "com.alwaysconnect.pump.fd-\(fd)")
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: self.queue)
        readSource.setEventHandler { [weak self] in self?.onReadable() }
        readSource.setCancelHandler {}
        self.readSource = readSource
        let writeSource = DispatchSource.makeWriteSource(
            fileDescriptor: fd, queue: self.queue)
        writeSource.setEventHandler { [weak self] in self?.onWritable() }
        writeSource.setCancelHandler {}
        self.writeSource = writeSource
    }

    func read(completion: @escaping (Data?, Error?) -> Void) {
        pumpTrace("fd=\(fd) read() called")
        queue.async { [weak self] in
            guard let self else { return }
            if self.closed || self.readClosed {
                completion(nil, nil)
                return
            }
            // The relay never double-reads; a duplicate call is dropped
            // rather than queued, so the loop cannot interleave chunks.
            guard self.pendingRead == nil else { return }
            self.pendingRead = completion
            self.resumeRead()
        }
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        pumpTrace("fd=\(fd) write(\(data.count)) called")
        queue.async { [weak self] in
            guard let self else { return }
            if self.closed {
                completion(nil)
                return
            }
            if self.writeClosed {
                // Never silently swallow a write after half-close:
                // fail fast so the relay tears the flow down.
                completion(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE)))
                return
            }
            if data.isEmpty {
                completion(nil)
                return
            }
            self.outBuffer.append(data)
            self.pendingWrites.append(completion)
            self.resumeWrite()
        }
    }

    func closeRead() {
        pumpTrace("fd=\(fd) closeRead() called")
        queue.async { [weak self] in
            guard let self, !self.closed, !self.readClosed else { return }
            pumpTrace("fd=\(fd) closeRead block enter")
            self.readClosed = true
            Darwin.shutdown(self.fd, Int32(SHUT_RD))
            self.suspendRead()
            if let pending = self.pendingRead {
                self.pendingRead = nil
                pending(nil, nil)
            }
            pumpTrace("fd=\(fd) closeRead block done")
        }
    }

    func closeWrite() {
        pumpTrace("fd=\(fd) closeWrite() called")
        queue.async { [weak self] in
            guard let self, !self.closed, !self.writeClosed else { return }
            pumpTrace("fd=\(fd) closeWrite block enter")
            self.writeClosed = true
            if self.outBuffer.isEmpty {
                Darwin.shutdown(self.fd, Int32(SHUT_WR))
            } else {
                // Drain first, then shut down (see onWritable).
                self.writeShutdownPending = true
                self.resumeWrite()
            }
            pumpTrace("fd=\(fd) closeWrite block done")
        }
    }

    func close() {
        pumpTrace("fd=\(fd) close() called")
        // Strong capture is deliberate: the fd must close even if the
        // pump (and relay) are already gone — a weak capture would let
        // this block evaporate with the endpoint and leak the fd.
        queue.async { [self] in
            guard !closed else { return }
            pumpTrace("fd=\(fd) close block enter")
            closed = true
            readSource?.cancel()
            writeSource?.cancel()
            pumpTrace("fd=\(fd) close block cancelled")
            // A cancelled source that is suspended never runs its
            // cancel handler — and is not released cleanly — until it
            // is resumed. Resume any suspended source here so
            // cancellation finalizes on this queue before the
            // endpoint (and its sources) can deallocate: releasing a
            // cancelled-but-suspended source traps (SIGTRAP), which
            // is what killed PumpTest nondeterministically in
            // teardown. The flags are authoritative (all flag changes
            // happen on this queue), so resume only what is
            // suspended; a resumed source is left alone. Handlers
            // that fire after this point see closed == true and
            // return immediately.
            if !readResumed {
                readResumed = true
                readSource?.resume()
            }
            if !writeResumed {
                writeResumed = true
                writeSource?.resume()
            }
            pumpTrace("fd=\(fd) close block resumed")
            // Sources are cancelled on this queue, so no handler can
            // be using the fd concurrently from here on.
            Darwin.close(fd)
            pumpTrace("fd=\(fd) close block done")
        }
    }

    private func resumeRead() {
        pumpTrace("fd=\(fd) resumeRead resumed=\(readResumed)")
        if !readResumed {
            readResumed = true
            readSource?.resume()
        }
        pumpTrace("fd=\(fd) resumeRead done")
    }

    private func suspendRead() {
        pumpTrace("fd=\(fd) suspendRead resumed=\(readResumed)")
        if readResumed {
            readResumed = false
            readSource?.suspend()
        }
        pumpTrace("fd=\(fd) suspendRead done")
    }

    private func resumeWrite() {
        pumpTrace("fd=\(fd) resumeWrite resumed=\(writeResumed)")
        if !writeResumed {
            writeResumed = true
            writeSource?.resume()
        }
        pumpTrace("fd=\(fd) resumeWrite done")
    }

    private func suspendWrite() {
        pumpTrace("fd=\(fd) suspendWrite resumed=\(writeResumed)")
        if writeResumed {
            writeResumed = false
            writeSource?.suspend()
        }
        pumpTrace("fd=\(fd) suspendWrite done")
    }

    private func onReadable() {
        pumpTrace("fd=\(fd) onReadable enter")
        guard !closed, !readClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, 65536)
        }
        pumpTrace("fd=\(fd) onReadable read -> \(n)")
        if n > 0 {
            suspendRead()
            if let pending = pendingRead {
                pendingRead = nil
                pending(Data(buffer[..<n]), nil)
            } else {
                // No consumer: stay suspended until the next read().
                // (The relay always has a read outstanding while the
                // side is alive, so this only happens during teardown.)
            }
        } else if n == 0 {
            // EOF: deliver it once, then stop reading.
            suspendRead()
            if let pending = pendingRead {
                pendingRead = nil
                pending(nil, nil)
            }
        } else {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                let error = NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err))
                suspendRead()
                if let pending = pendingRead {
                    pendingRead = nil
                    pending(nil, error)
                }
            }
            // EAGAIN: the source stays resumed and fires again when
            // data arrives; the pending read is untouched.
        }
    }

    private func onWritable() {
        pumpTrace("fd=\(fd) onWritable enter buf=\(outBuffer.count)")
        guard !closed else { return }
        while !outBuffer.isEmpty {
            let n = outBuffer.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!, outBuffer.count)
            }
            pumpTrace("fd=\(fd) onWritable write -> \(n) remaining=\(outBuffer.count)")
            if n > 0 {
                outBuffer.removeFirst(n)
            } else if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    pumpTrace("fd=\(fd) onWritable EAGAIN, stay resumed")
                    return // Stay resumed; fires again when writable.
                }
                let error = NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err))
                let completions = pendingWrites
                pendingWrites = []
                outBuffer = Data()
                suspendWrite()
                for completion in completions { completion(error) }
                return
            } else {
                // write() returning 0 wrote nothing: do NOT complete
                // the writes as success (the old code fell through to
                // the drained path). Stay resumed and retry on the
                // next writable event, like EAGAIN.
                pumpTrace("fd=\(fd) onWritable zero-write, stay resumed")
                return
            }
        }
        // Buffer drained: complete the writes and honour a pending
        // write-side shutdown (half-close after drain).
        let completions = pendingWrites
        pendingWrites = []
        suspendWrite()
        for completion in completions { completion(nil) }
        if writeShutdownPending {
            writeShutdownPending = false
            Darwin.shutdown(fd, Int32(SHUT_WR))
        }
    }
}
