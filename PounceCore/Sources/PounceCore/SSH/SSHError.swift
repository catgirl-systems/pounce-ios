import Foundation
import NIOCore
import NIOSSH
import Network

/// messages are meant for people, not logs.
public enum SSHError: Error, LocalizedError, Equatable, Sendable {
    case unreachable(String)
    case timedOut
    case hostKeyRejected
    case authenticationFailed
    case noCredentials
    case channelRejected
    case forwardingRejected
    case portUnavailable(Int)
    case protocolError(String)
    case disconnected
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason): "Couldn't reach the host. \(reason)"
        case .timedOut: "The connection timed out."
        case .hostKeyRejected: "The host key wasn't trusted, so pounce didn't connect."
        case .authenticationFailed: "The server didn't accept any of the credentials for this host."
        case .noCredentials: "This host has no key or password to sign in with."
        case .channelRejected: "The server refused to open the session."
        case .forwardingRejected: "The server refused to forward that port."
        case .portUnavailable(let port): "Port \(port) is already in use on this device."
        case .protocolError(let detail): "The SSH connection failed: \(detail)."
        case .disconnected: "The connection was closed."
        case .cancelled: "Cancelled."
        }
    }

    static func wrap(_ error: any Error) -> SSHError {
        if let error = error as? SSHError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? NWError {
            switch error {
            case .posix(.ECONNREFUSED): return .unreachable("The connection was refused.")
            case .posix(.ETIMEDOUT): return .timedOut
            case .posix(.EADDRINUSE): return .portUnavailable(0)
            case .dns: return .unreachable("The host name couldn't be found.")
            default: return .unreachable(error.localizedDescription)
            }
        }
        if let error = error as? ChannelError {
            switch error {
            case .connectTimeout: return .timedOut
            case .eof, .ioOnClosedChannel, .alreadyClosed, .outputClosed: return .disconnected
            default: return .protocolError(String(describing: error))
            }
        }
        if let error = error as? NIOSSHError {
            return .protocolError(String(describing: error.type))
        }
        return .protocolError(error.localizedDescription)
    }
}
