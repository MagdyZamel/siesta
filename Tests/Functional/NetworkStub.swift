//
//  NetworkStub.swift
//  Siesta
//
//  Created by Paul on 2020/3/22.
//  Copyright © 2020 Bust Out Solutions. All rights reserved.
//

import Foundation
import Siesta

private let stubPropertyKey = "\(NetworkStub.self).stub"

final class NetworkStub: URLProtocol
    {
    private static var stubs = [RequestStub]()
    private static var requestInitialization = Latch(name: "initialization of requests")

    static var defaultConfiguration: URLSessionConfiguration
        { wrap(URLSessionConfiguration.ephemeral) }

    static func wrap(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration
        {
        configuration.protocolClasses = [Self.self]
        return configuration
        }

    @discardableResult
    static func add(
            _ method: RequestMethod,
            _ resource: @escaping () -> Resource,
            status: Int = 200)
        -> RequestStub
        {
        add(
            method,
            resource,
            returning: HTTPResponse(status: status))
        }

    @discardableResult
    static func add(
            _ method: RequestMethod,
            _ resource: @escaping () -> Resource,
            returning response: NetworkStubResponse)
        -> RequestStub
        {
        add(
            matching: RequestPattern(method, resource),
            returning: response)
        }

    @discardableResult
    static func add(
            matching matcher: RequestPattern,
            returning stubResponse: NetworkStubResponse = HTTPResponse(status: 200))
        -> RequestStub
        {
        let stub = RequestStub(matcher: matcher, response: stubResponse)
        add(stub)
        return stub
        }

    static func add(_ stub: RequestStub)
        {
        synchronized
            { stubs.insert(stub, at: 0) }
        }

    static func clearAll()
        {
        Self.requestInitialization.await
            {
            synchronized { stubs = [] }
            }
        }

    override class func canInit(with request: URLRequest) -> Bool
        {
        Self.requestInitialization.increment()
        return true
        }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest
        {
        defer { Self.requestInitialization.decrement() }

        let body = extractBody(from: request)

        let stubs = synchronized { Self.stubs }
        guard let stub = stubs.first(where: { $0.matcher.matches(request, withBody: body) }) else
            {
            fatalError(
                """
                Unstubbed network request:
                    \(request.httpMethod ?? "<nil method>") \(request.url?.absoluteString ?? "<nil URL>")
                    headers: \(request.allHTTPHeaderFields ?? [:])
                    body: \(body?.description ?? "nil")

                Available stubs:
                    \(stubs.map { $0.description }.joined(separator: "\n    "))

                Halting tests
                """)
            }

        let mutableRequest = request as! NSMutableURLRequest
        URLProtocol.setProperty(stub, forKey: stubPropertyKey, in: mutableRequest)
        return mutableRequest as URLRequest
        }

    private static func extractBody(from request: URLRequest) -> Data?
        {
        if let data = request.httpBody
            { return data }
        if let stream = request.httpBodyStream
            {
            // adapted from https://forums.swift.org/t/pitch-make-inputstream-and-outputstream-methods-safe-and-swifty/23726
            var buffer = [UInt8](repeating: 0, count: 65536)

            stream.open()
            defer { stream.close() }

            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0
                { fatalError("Unable to ready HTTP body stream: \(stream.streamError?.localizedDescription ?? "unknown error")") }
            return Data(buffer.prefix(bytesRead))
            }
        return nil
        }

    override func startLoading()
        {
        let stub = URLProtocol.property(forKey: stubPropertyKey, in: request) as! RequestStub
        stub.awaitPermissionToGo()

        if SiestaSpec.envFlag("RandomTimeDelayInNetworkStubs")
            { Thread.sleep(forTimeInterval: 1.0 / pow(.random(in: 5...100), 2)) }

        stub.response.send(to: self.client!, for: self, url: request.url!)
        }

    override func stopLoading()
        { }

    static func synchronized<T>(_ action: () -> T) -> T
        {
        objc_sync_enter(NetworkStub.self)
        defer { objc_sync_exit(NetworkStub.self) }
        return action()
        }
    }

struct RequestStub
    {
    let matcher: RequestPattern
    let response: NetworkStubResponse

    private let delayLatch = Latch(name: "delayed request")

    fileprivate init(matcher: RequestPattern, response: NetworkStubResponse)
        {
        self.matcher = matcher
        self.response = response
        }

    func delay() -> Self
        {
        delayLatch.increment()
        return self
        }

    func go()
        { delayLatch.decrement() }

    fileprivate func awaitPermissionToGo()
        { delayLatch.await() }

    var description: String
        { "\(matcher) → \(response)" }
    }

struct RequestPattern
    {
    var method: String
    var url: String
    var headers: [String:String?]
    var body: HTTPBodyConvertible?

    init(
            _ method: RequestMethod,
            _ resource: () -> Resource,
            headers: [String:String?] = [:],
            body: HTTPBodyConvertible? = nil)
        {
        self.method = method.rawValue.uppercased()
        self.url = resource().url.absoluteString
        self.headers = headers
        self.body = body
        }

    func matches(_ request: URLRequest, withBody requestBody: Data?) -> Bool
        {
        return request.httpMethod == method
            && request.url?.absoluteString == url
            && headers.allSatisfy
                {
                key, value in
                request.allHTTPHeaderFields?[key] == value
                }
            && body?.httpData == requestBody
        }
    }

protocol NetworkStubResponse
    {
    func send(to client: URLProtocolClient, for sender: URLProtocol, url: URL)
    }

struct ErrorResponse: NetworkStubResponse
    {
    var error: Error

    func send(to client: URLProtocolClient, for sender: URLProtocol, url: URL)
        {
        client.urlProtocol(sender, didFailWithError: error)
        }
    }

struct HTTPResponse: NetworkStubResponse
    {
    var status = 200
    var headers = [String:String]()
    var body: HTTPBodyConvertible?

    func send(to client: URLProtocolClient, for sender: URLProtocol, url: URL)
        {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "1.1",
            headerFields: headers)!

        client.urlProtocol(sender, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let bodyData = body?.httpData
            { client.urlProtocol(sender, didLoad: bodyData) }

        client.urlProtocolDidFinishLoading(sender) // TODO: Should error do this as well?
        }
    }

protocol HTTPBodyConvertible
    {
    var httpData: Data { get }
    }

extension Data: HTTPBodyConvertible
    {
    var httpData: Data
        { self }
    }

extension String: HTTPBodyConvertible
    {
    var httpData: Data
        { data(using: .utf8)! }
    }

private struct Latch
    {
    private var lock = NSConditionLock(condition: 0)

    let name: String

    init(name: String)
        { self.name = name }

    func increment()
        { add(1) }

    func decrement()
        { add(-1) }

    private func add(_ delta: Int)
        {
        lock.lock()
        lock.unlock(withCondition: lock.condition + delta)
        }

    func await(target: Int = 0, whileLocked action: () -> Void = {})
        {
        guard lock.lock(whenCondition: target, before: Date(timeIntervalSinceNow: 1)) else
            { fatalError("timed out waiting for \(name)") }
        action()
        lock.unlock()
        }
    }
