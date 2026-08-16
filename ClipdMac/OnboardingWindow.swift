import AppKit

/// First run. Asks for Accessibility once, up front, and watches for the answer.
///
/// The flow this replaces had four steps and a restart: launch Clipd, copy
/// something, open the panel, press Enter, get a system prompt because that
/// paste was the first synthesised event, open System Settings, grant, then
/// quit and reopen the app because nothing had noticed. The paste the user
/// actually asked for was lost somewhere in the middle of that.
///
/// Now the permission is asked for before anything else, in a window that says
/// why, and `AccessibilityMonitor` turns "waiting" into "ready" the moment the
/// switch is flipped. There is no restart step, and the relaunch button exists
/// only as a fallback for the case where macOS holds a stale answer anyway.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let monitor: AccessibilityMonitor
    private let settings: AppSettings

    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let steps = NSTextField(wrappingLabelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let relaunchButton = NSButton(title: "", target: nil, action: nil)
    private let suppress = NSButton(checkboxWithTitle: "Do not show this again",
                                    target: nil, action: nil)

    /// Shown only after a wait. Offering a relaunch immediately would teach the
    /// restart habit this window exists to remove.
    private var stillWaitingTimer: Timer?

    /// Held so the window can be resized to whichever state it is showing. The
    /// ready state has three fewer rows than the waiting one, and a fixed
    /// height left it sitting above a block of empty window.
    private var stack: NSStackView?

    init(monitor: AccessibilityMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Clipd"
        super.init(window: window)

        window.contentView = buildContent()
        applyState(trusted: monitor.isTrusted)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
        ])

        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.alignment = .center
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        steps.textColor = .secondaryLabelColor
        steps.font = .systemFont(ofSize: 12)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let status = NSStackView(views: [spinner, statusIcon, statusLabel])
        status.orientation = .horizontal
        status.spacing = 6
        status.alignment = .centerY

        primary.bezelStyle = .push
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryTapped)

        secondary.bezelStyle = .push
        secondary.target = self
        secondary.action = #selector(secondaryTapped)

        relaunchButton.bezelStyle = .inline
        relaunchButton.isBordered = false
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunchTapped)
        relaunchButton.isHidden = true
        relaunchButton.attributedTitle = NSAttributedString(
            string: "Turned it on and nothing changed? Relaunch Clipd",
            attributes: [.foregroundColor: NSColor.linkColor,
                         .font: NSFont.systemFont(ofSize: 11)])

        suppress.target = self
        suppress.action = #selector(suppressToggled)
        suppress.state = settings.showAccessibilityOnboarding ? .off : .on

        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, heading, body, steps, status,
                                        buttons, relaunchButton, suppress])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: heading)
        stack.setCustomSpacing(18, after: steps)
        stack.setCustomSpacing(20, after: status)
        stack.setCustomSpacing(10, after: buttons)

        self.stack = stack
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 400),
            steps.widthAnchor.constraint(equalToConstant: 400),
        ])
        return container
    }

    // MARK: - State

    /// One function for both states, so the window can never show a granted
    /// tick above a button that still says "Open Accessibility Settings".
    private func applyState(trusted: Bool) {
        if trusted {
            heading.stringValue = "Clipd is ready"
            body.stringValue = """
                Press Cmd+Shift+V anywhere to open your clipboard history. \
                Type to search it, press Enter to paste, or hold Cmd and press \
                the number in the corner of a card.
                """
            steps.stringValue = ""
            steps.isHidden = true
            spinner.stopAnimation(nil)
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                       accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemGreen
            statusLabel.stringValue = "Accessibility granted."
            statusLabel.textColor = .labelColor
            primary.title = "Done"
            secondary.isHidden = true
            relaunchButton.isHidden = true
            suppress.isHidden = true
            stillWaitingTimer?.invalidate()
            stillWaitingTimer = nil
        } else {
            heading.stringValue = "One permission, then you are done"
            body.stringValue = """
                Clipd pastes by sending Cmd+V to the app you were just using, \
                and macOS only allows that with Accessibility permission. \
                Without it Clipd still records everything you copy, it just \
                cannot paste any of it back.
                """
            steps.stringValue = """
                1.  Click Open Accessibility Settings below.
                2.  Turn on the switch next to Clipd.

                That is the whole setup. This window notices as soon as you \
                flip the switch, so there is nothing to restart.
                """
            steps.isHidden = false
            spinner.startAnimation(nil)
            statusIcon.image = nil
            statusLabel.stringValue = "Waiting for permission"
            statusLabel.textColor = .secondaryLabelColor
            primary.title = "Open Accessibility Settings"
            secondary.title = "Not now"
            secondary.isHidden = false
            suppress.isHidden = false
        }
        fitWindow()
    }

    /// Shrinks or grows the window to whatever the current state needs, keeping
    /// it centred on the point it already occupied rather than jumping.
    private func fitWindow() {
        guard let window, let stack else { return }
        window.layoutIfNeeded()
        let height = stack.fittingSize.height
        let old = window.frame
        window.setContentSize(NSSize(width: 480, height: height))
        let new = window.frame
        window.setFrameOrigin(NSPoint(x: old.midX - new.width / 2,
                                      y: old.midY - new.height / 2))
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        guard !monitor.isTrusted else {
            close()
            return
        }
        AccessibilityMonitor.prompt()
        AccessibilityMonitor.openSettings()
        // Sixty seconds is long enough that nobody who simply took a while to
        // find the switch is ever offered a restart they did not need.
        stillWaitingTimer?.invalidate()
        stillWaitingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.monitor.isTrusted else { return }
                self.relaunchButton.isHidden = false
            }
        }
    }

    @objc private func secondaryTapped() { close() }

    @objc private func relaunchTapped() { AccessibilityMonitor.relaunch() }

    @objc private func suppressToggled() {
        settings.showAccessibilityOnboarding = suppress.state == .off
    }

    /// Called by the app delegate when the permission changes under us.
    func permissionChanged(trusted: Bool) {
        applyState(trusted: trusted)
        if trusted { Sounds.pasted() }
    }

    func show() {
        // The app is .accessory, so without this the window opens behind
        // whatever the user was doing and first run looks like nothing
        // happened at all.
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
