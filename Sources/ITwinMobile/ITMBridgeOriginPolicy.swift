import Foundation

/// Shared origin rules for native WebView bridges, including standalone bridge instances.
public enum ITMBridgeOriginPolicy {
    public static let defaultAllowedOrigins: Set<String> = ["imodeljs://app"]

    /// Gets an exact origin for a supported frontend URL. File and opaque origins are not supported.
    public static func origin(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty, !host.contains("*"),
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        guard scheme == "http" || scheme == "https" ||
                (scheme == "imodeljs" && host == "app" && components.port == nil) else { return nil }
        var result = URLComponents()
        result.scheme = scheme
        result.host = host
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        result.port = components.port == defaultPort ? nil : components.port
        return result.string
    }

    /// Keeps only canonical origins without paths, credentials, wildcards, or default ports.
    public static func validOrigins(_ origins: Set<String>) -> Set<String> {
        Set(origins.filter { value in
            guard let url = URL(string: value) else { return false }
            return origin(for: url) == value
        })
    }
}
