import AppKit

/// Base class for full-screen terminal-style renderers.
///
/// The window owns the shared glass background and Commander tint. Terminal
/// surfaces stay transparent and paint only semantic chrome such as headers,
/// selections, borders, and function-key buttons.
@MainActor
class TerminalSurfaceView: NSView {
    override var isOpaque: Bool { false }
}
