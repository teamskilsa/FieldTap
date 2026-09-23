/// Every screen a launch argument (-FTScreen) or a screen report can name.
public enum Route: String, CaseIterable, Codable, Hashable, Sendable {
    case captures, guide, settings, importSheet, overview, callflow, radio, security, message

    /// The capture-detail page this route shows, if it is one.
    public var page: DetailPage? {
        switch self {
        case .overview: .overview
        case .callflow, .message: .callflow
        case .radio: .radio
        case .security: .security
        default: nil
        }
    }

    /// The root tab the route lives on.
    public var tab: RootTab {
        switch self {
        case .guide: .guide
        case .settings: .settings
        default: .captures
        }
    }
}

/// The pages of an open capture, switched by the toolbar picker.
public enum DetailPage: String, CaseIterable, Codable, Hashable, Sendable {
    case overview, callflow, radio, security

    public var route: Route {
        switch self {
        case .overview: .overview
        case .callflow: .callflow
        case .radio: .radio
        case .security: .security
        }
    }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .callflow: "Call flow"
        case .radio: "Radio"
        case .security: "Security"
        }
    }
}

/// The tabs of the root TabView.
public enum RootTab: String, CaseIterable, Hashable, Sendable {
    case captures, guide, settings
}
