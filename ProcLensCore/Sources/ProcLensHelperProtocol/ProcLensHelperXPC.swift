import Foundation

/// XPC surface of the privileged helper. Every request and reply is a JSON-encoded `Codable`
/// (see `HelperCodec`), so the interface needs no custom `NSSecureCoding` classes and the
/// reply blocks are `Sendable`. Replies are `HelperReply<T>` envelopes.
@objc public protocol ProcLensHelperXPC {
    /// Reply: `HelperReply<HelperVersionInfo>`.
    func helperVersion(reply: @escaping @Sendable (Data) -> Void)
    /// Request: `HelperPIDRequest`. Reply: `HelperReply<[HelperRusage]>`.
    func readRusage(request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Request: `HelperPIDRequest`. Reply: `HelperReply<[HelperProcessInfo]>`.
    func readProcessInfo(request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Request: `HelperPIDRequest` (empty list = all processes). Reply: `HelperReply<[HelperListeningSocket]>`.
    func listListeningSockets(request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Request: `HelperSignalRequest`. Reply: `HelperReply<HelperEmpty>`.
    func signalProcess(request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Request: `HelperLaunchctlRequest` (system domain only). Reply: `HelperReply<HelperCommandOutput>`.
    func launchctl(request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Output of `sfltool dumpbtm` (needs root). Reply: `HelperReply<HelperCommandOutput>`.
    func dumpBTM(reply: @escaping @Sendable (Data) -> Void)
}
