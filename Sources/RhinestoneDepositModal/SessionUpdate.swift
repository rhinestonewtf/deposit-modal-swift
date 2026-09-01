import Foundation

/// Decisions a live session makes when the app changes its mind, kept out of
/// the view so they can be tested where there is no web view.
public enum SessionUpdate {
    /**
     Whether a config change moves the corridor the deposit watch is polling.

     Only these two fields: everything else in a config repaints the page and is
     none of the watch's business, and restarting on a theme change would take a
     fresh baseline for no reason — suppressing, as history, a deposit that was
     already in flight.
     */
    public static func corridorMoved(from old: EmbedConfig, to new: EmbedConfig) -> Bool {
        old.backendUrl != new.backendUrl || old.recipient != new.recipient
    }
}
