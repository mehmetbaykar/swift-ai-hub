// swift-ai-hub — Apache-2.0
//
// Ported from Apple/HuggingFace AnyLanguageModel (Apache-2.0).
// See NOTICE for attribution.

#if HUB_USE_ASYNC_HTTP
  // AsyncHTTPClient.HTTPHandler introduces a Task type that clashes with Swift's Task.
  // Bind Swift's structured-concurrency Task before importing AsyncHTTPClient.
  private typealias SwiftTask = Task

  private final class HTTPClientBodyReaderTaskBox: @unchecked Sendable {
    var task: SwiftTask<Void, Never>?
  }

  import AsyncHTTPClient
  import EventSource
  import Foundation
  import NIOCore
  import NIOFoundationCompat
  import NIOHTTP1

  extension HTTPClient {
    func fetch<T: Decodable>(
      _ method: HTTP.Method,
      url: URL,
      headers: [String: String] = [:],
      body: Data? = nil,
      dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) async throws -> T {
      var request = HTTPClientRequest(url: url.absoluteString)
      request.method = HTTPMethod(rawValue: method.rawValue)
      request.headers.add(name: "Accept", value: "application/json")

      for (key, value) in headers {
        request.headers.add(name: key, value: value)
      }

      if let body {
        request.body = .bytes(ByteBuffer(data: body))
        request.headers.add(name: "Content-Type", value: "application/json")
      }

      let response = try await self.execute(request, timeout: .seconds(180))

      guard (200..<300).contains(response.status.code) else {
        let bodyData = try await Data(buffer: response.body.collect(upTo: 1024 * 1024))
        let detail =
          String(data: bodyData, encoding: .utf8)
          .map(redactSensitiveHeaders) ?? "Invalid response"
        throw URLSessionError.httpError(
          statusCode: Int(response.status.code),
          detail: detail,
          headers: headerDictionary(from: response.headers)
        )
      }

      let bodyData = try await Data(buffer: response.body.collect(upTo: 1024 * 1024))

      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = dateDecodingStrategy

      do {
        return try decoder.decode(T.self, from: bodyData)
      } catch {
        throw URLSessionError.decodingError(detail: error.localizedDescription)
      }
    }

    func fetchStream<T: Decodable & Sendable>(
      _ method: HTTP.Method,
      url: URL,
      headers: [String: String] = [:],
      body: Data? = nil,
      dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate
    ) -> AsyncThrowingStream<T, any Error> {
      AsyncThrowingStream { continuation in
        let task = SwiftTask { @Sendable in
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = dateDecodingStrategy

          do {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = HTTPMethod(rawValue: method.rawValue)
            request.headers.add(name: "Accept", value: "application/json")

            for (key, value) in headers {
              request.headers.add(name: key, value: value)
            }

            if let body {
              request.body = .bytes(ByteBuffer(data: body))
              request.headers.add(name: "Content-Type", value: "application/json")
            }

            let response = try await self.execute(request, timeout: .seconds(60))

            guard (200..<300).contains(response.status.code) else {
              let bodyData = try await Data(buffer: response.body.collect(upTo: 1024 * 1024))
              let detail =
                String(data: bodyData, encoding: .utf8)
                .map(redactSensitiveHeaders) ?? "Invalid response"
              throw URLSessionError.httpError(
                statusCode: Int(response.status.code),
                detail: detail,
                headers: headerDictionary(from: response.headers)
              )
            }

            var buffer = Data()

            for try await chunk in response.body {
              try SwiftTask.checkCancellation()
              buffer.append(contentsOf: chunk.readableBytesView)

              while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                if !line.isEmpty {
                  let decoded = try decoder.decode(T.self, from: line)
                  continuation.yield(decoded)
                }
              }
            }

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

    func fetchEventStream<T: Decodable & Sendable>(
      _ method: HTTP.Method,
      url: URL,
      headers: [String: String] = [:],
      body: Data? = nil
    ) -> AsyncThrowingStream<T, any Error> {
      AsyncThrowingStream { continuation in
        let bodyReaderBox = HTTPClientBodyReaderTaskBox()

        let task = SwiftTask { @Sendable in
          do {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = HTTPMethod(rawValue: method.rawValue)
            request.headers.add(name: "Accept", value: "text/event-stream")

            for (key, value) in headers {
              request.headers.add(name: key, value: value)
            }

            if let body {
              request.body = .bytes(ByteBuffer(data: body))
              request.headers.add(name: "Content-Type", value: "application/json")
            }

            let response = try await self.execute(request, timeout: .seconds(60))

            guard (200..<300).contains(response.status.code) else {
              let bodyData = try await Data(buffer: response.body.collect(upTo: 1024 * 1024))
              let detail =
                String(data: bodyData, encoding: .utf8)
                .map(redactSensitiveHeaders) ?? "Invalid response"
              throw URLSessionError.httpError(
                statusCode: Int(response.status.code),
                detail: detail,
                headers: headerDictionary(from: response.headers)
              )
            }

            let asyncBytes = AsyncStream<UInt8> { byteContinuation in
              bodyReaderBox.task = SwiftTask {
                do {
                  for try await buffer in response.body {
                    try SwiftTask.checkCancellation()
                    for byte in buffer.readableBytesView {
                      byteContinuation.yield(byte)
                    }
                  }
                  byteContinuation.finish()
                } catch {
                  byteContinuation.finish()
                }
              }
              byteContinuation.onTermination = { _ in
                bodyReaderBox.task?.cancel()
              }
            }

            try await self.decodeAndYieldEventStream(asyncBytes, to: continuation)
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }

        continuation.onTermination = { _ in
          bodyReaderBox.task?.cancel()
          task.cancel()
        }
      }
    }

    private func decodeAndYieldEventStream<T: Decodable & Sendable, Bytes>(
      _ asyncBytes: Bytes,
      to continuation: AsyncThrowingStream<T, any Error>.Continuation
    ) async throws where Bytes: AsyncSequence, Bytes.Element == UInt8 {
      let decoder = JSONDecoder()
      for try await event in asyncBytes.events {
        guard let data = event.data.data(using: .utf8) else { continue }
        if let decoded = try? decoder.decode(T.self, from: data) {
          continuation.yield(decoded)
        }
      }
    }
  }

  /// Extract a `[String: String]` header dictionary from NIO's `HTTPHeaders`.
  private func headerDictionary(from headers: HTTPHeaders) -> [String: String] {
    var out: [String: String] = [:]
    for (name, value) in headers {
      out[name] = value
    }
    return out
  }
#endif
