import Foundation

/// One assembled SSE frame.
///
/// SSE frames are separated by a blank line (`\n\n`). Each frame may carry
/// `event:`, `data:`, `id:`, `retry:` lines. We only consume `event:` (string)
/// and `data:` (bytes — multi-line `data:` values are concatenated with `\n`
/// per the SSE spec).
struct SSEFrame: Sendable, Equatable {
    let event: String
    let data: Data
}

/// Read SSE frames from an arbitrary byte stream.
///
/// Production: pass `URLSession.AsyncBytes` (an `AsyncSequence<UInt8>`).
/// Test: pass any `AsyncStream<UInt8>` constructed from fixture bytes.
///
/// On EOF the reader yields any partially-assembled frame that has data
/// (so the SSE decoder can still see the in-flight tool-use buffer for
/// `partialToolUseAtDisconnect` semantics).
struct SSELineReader<Bytes: AsyncSequence & Sendable>: Sendable
where Bytes.Element == UInt8, Bytes.AsyncIterator: Sendable {
    let bytes: Bytes

    /// Yield frames as they're assembled. Throws if the underlying byte
    /// sequence throws.
    func frames() -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream<SSEFrame, Error> { continuation in
            let task = Task {
                do {
                    var lineBuffer = Data()
                    var currentEvent: String? = nil
                    var currentData = Data()
                    var hadAnyField = false

                    func flushFrame() {
                        if hadAnyField, let event = currentEvent {
                            continuation.yield(SSEFrame(event: event, data: currentData))
                        }
                        currentEvent = nil
                        currentData = Data()
                        hadAnyField = false
                    }

                    func processLine(_ line: Data) {
                        if line.isEmpty {
                            flushFrame()
                            return
                        }
                        // Parse "field: value" — first colon is the separator.
                        // Per SSE spec, leading space after colon is stripped.
                        guard let colonIndex = line.firstIndex(of: 0x3A /* : */) else {
                            // Comment line ("colon-prefixed" or no colon) — ignore.
                            return
                        }
                        let fieldBytes = line[line.startIndex..<colonIndex]
                        var valueStart = line.index(after: colonIndex)
                        if valueStart < line.endIndex, line[valueStart] == 0x20 /* space */ {
                            valueStart = line.index(after: valueStart)
                        }
                        let valueBytes = line[valueStart..<line.endIndex]
                        guard let field = String(data: Data(fieldBytes), encoding: .utf8) else {
                            return
                        }
                        switch field {
                        case "event":
                            currentEvent = String(data: Data(valueBytes), encoding: .utf8)
                            hadAnyField = true
                        case "data":
                            // Multi-line data: concatenate with `\n`.
                            if !currentData.isEmpty {
                                currentData.append(0x0A)
                            }
                            currentData.append(Data(valueBytes))
                            hadAnyField = true
                        default:
                            // Ignore id:, retry:, comments, anything else.
                            break
                        }
                    }

                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A /* LF */ {
                            // Strip optional trailing CR (CRLF support).
                            if lineBuffer.last == 0x0D {
                                lineBuffer.removeLast()
                            }
                            processLine(lineBuffer)
                            lineBuffer.removeAll(keepingCapacity: true)
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                    // Flush any trailing partial line as a final line.
                    if !lineBuffer.isEmpty {
                        processLine(lineBuffer)
                    }
                    // EOF — flush any pending frame so the decoder sees it.
                    flushFrame()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
