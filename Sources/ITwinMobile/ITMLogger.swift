/*---------------------------------------------------------------------------------------------
* Copyright (c) Bentley Systems, Incorporated. All rights reserved.
* See LICENSE.md in the project root for license terms and full copyright notice.
*--------------------------------------------------------------------------------------------*/

import Foundation

/// Default ITwinMobile logger class that uses NSLog to log messages.
open class ITMLogger {
    /// Set this to `false` to completely disable logging.
    public var enabled = true

    public enum Severity: String, Sendable {
        case fatal
        case error
        case warning
        case info
        case debug
        case trace

        public init?(_ value: String?) {
            guard var lowercaseValue = value?.lowercased() else {
                return nil
            }
            lowercaseValue = switch lowercaseValue {
            case "log": "debug"
            case "assert": "fatal"
            case "warn": "warning"
            default: lowercaseValue
            }
            if let result = Severity(rawValue: lowercaseValue) {
                self = result
            } else {
                return nil
            }
        }

        public var description: String { return rawValue.uppercased() }
    }

    /// Creates a logger.
    public init() {
        // do nothing, just here so it can be sub-classed
    }

    /// If ``enabled`` is `true`, log a message. This default implementation uses `NSLog`. Replace ITMMessenger's
    /// static `logger` instance with a subclass that overrides this function to change the logging behavior.
    /// - Note: NSLog truncates all log messages to 1024 bytes.
    /// - Parameters:
    ///   - severity: The severity of the log message.
    ///   - logMessage: The message to log.
    open func log(_ severity: Severity?, _ logMessage: String) {
        guard enabled else { return }
        NSLog("%@  %@", severity?.description ?? "<UNKNOWN>", logMessage)
    }
}
