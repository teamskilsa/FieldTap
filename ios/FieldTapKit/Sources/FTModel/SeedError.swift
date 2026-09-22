/// Thrown by a WP0 seed that stands in for a package's implementation until the owner lands it.
public enum SeedError: Error, Hashable, Sendable {
    case notImplemented(String)
}
