import AppKit
import SwiftUI

/// Owns the queue of pending banner conditions and drives the shared
/// `HUDBannerPanel`. Shows one banner at a time; pre-empts a lower-priority
/// banner when a higher-priority one arrives; remembers "dismissed this launch"
/// by `BannerContent.id` so the same condition doesn't re-enqueue after a
/// manual dismiss until the app restarts.
///
/// Per UI-SPEC Surface 5 "Per-condition lifecycle" lines 481-486 + priority
/// order lines 218-225.
@MainActor
public final class HUDBannerCoordinator {
    public let panel: HUDBannerPanel
    private var queue: [BannerContent] = []
    private var current: BannerContent?
    private var dismissedThisLaunch: Set<String> = []
    /// WR-05: cancellable handle on the 300ms drain. When `clear()` is
    /// called — or a higher-priority banner enqueues during the drain
    /// window — we cancel this so the drained banner doesn't clobber the
    /// new state.
    private var drainWorkItem: DispatchWorkItem?

    public init(panel: HUDBannerPanel) {
        self.panel = panel
    }

    /// Enqueue a banner. If nothing is showing, render immediately; otherwise
    /// insert sorted by priority. If the incoming banner has strictly higher
    /// priority than the current banner, it pre-empts (current banner goes back
    /// into the queue, new banner renders immediately).
    public func enqueue(_ content: BannerContent) {
        if dismissedThisLaunch.contains(content.id) { return }
        // De-duplicate by id — same condition re-triggering while its banner is
        // in flight is a no-op.
        if current?.id == content.id { return }
        if queue.contains(where: { $0.id == content.id }) { return }

        if current == nil {
            // WR-05: if we arrived here because a drain timer is pending,
            // cancel it — otherwise the drained banner will clobber this
            // new enqueue after the 300ms gap fires.
            drainWorkItem?.cancel()
            drainWorkItem = nil
            showBanner(content)
            return
        }
        // Pre-empt if the new banner has strictly higher priority.
        if let c = current, content.priority < c.priority {
            queue.append(c)
            queue.sort { $0.priority < $1.priority }
            showBanner(content)
            return
        }
        // Otherwise, just insert into the queue in priority order.
        queue.append(content)
        queue.sort { $0.priority < $1.priority }
    }

    /// Dismiss the current banner (remembered dismissed-this-launch) and drain
    /// the next queued banner after a 300ms gap per UI-SPEC line 496.
    public func dismissCurrent() {
        if let c = current { dismissedThisLaunch.insert(c.id) }
        current = nil
        panel.orderOut(nil)
        // WR-05: a prior in-flight drain must be cancelled before we
        // schedule a new one — otherwise two drains can race.
        drainWorkItem?.cancel()
        drainWorkItem = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // WR-05: re-check state at fire time. A higher-priority banner
            // could have enqueued during the drain (and `enqueue` cancelled
            // this work item, but belt-and-suspenders the check here too).
            if self.current != nil { return }
            if self.dismissedThisLaunch.contains(next.id) { return }
            self.showBanner(next)
        }
        drainWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Clear everything — used when the entire app is about to quit or when
    /// a test needs to reset the coordinator.
    public func clear() {
        // WR-05: a pending drain must not fire after clear() — otherwise
        // a banner pops up while the app is quitting.
        drainWorkItem?.cancel()
        drainWorkItem = nil
        queue.removeAll()
        current = nil
        panel.orderOut(nil)
    }

    /// Introspection helpers for tests.
    public var currentBanner: BannerContent? { current }
    public var queuedCount: Int { queue.count }

    // MARK: - Private

    private func showBanner(_ content: BannerContent) {
        current = content
        let view = HUDBanner(
            content: content,
            onAction: { [weak self] in self?.handleAction(for: content) },
            onDismiss: { [weak self] in self?.dismissCurrent() }
        )
        panel.host(view)
        panel.orderFrontRegardless()
    }

    private func handleAction(for content: BannerContent) {
        if let url = content.action?.url {
            NSWorkspace.shared.open(url)
        }
        // Other action paths (Open Setup, Rebind hotkey, Reveal config) wire in
        // Plan 04 where the Setup wizard + hotkey rebinder + config reveal
        // routes exist.
        dismissCurrent()
    }
}
