import CoreGraphics

/// Sizes the three capture pages (Overview, Call flow, Radio) share.
///
/// The cursor bar is a floating glass bar: it is laid out as a bottom safe-area inset, but it is rounded and
/// inset from the edges, and a scroll view whose last row ends exactly at the safe area ends up tucked under
/// its glass. So every scrollable capture page adds `scrollBottomInset` under its content and the last row is
/// always readable.
public enum CapturePageLayout {
    /// The cursor bar's own height on an iPhone 17: two 40 pt control rows, the slider, and 8 pt of padding.
    public static let cursorBarHeight: CGFloat = 96
    /// What each scrollable page keeps clear under its last row, on top of the safe-area inset.
    public static let scrollBottomInset: CGFloat = 28
}
