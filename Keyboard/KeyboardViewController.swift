import UIKit
import SwiftUI
import Shared
import os.log

/// M5: a real typing keyboard with a GBoard-style toolbar strip on top, where
/// the Meme Face button lives as an icon button.
///
/// Layout is driven by `KeyboardLayout` (data) and rendered as nested stack
/// views, with each key's width set as a fraction of the row so the whole
/// thing adapts to device size and rotation without hardcoded metrics.
final class KeyboardViewController: UIInputViewController {

    private var plane: Plane = .letters
    private var shift: ShiftState = .on   // sentences start capitalised
    private var keyViews: [KeyView] = []

    /// Remembered across sessions in the shared defaults, so the choice sticks.
    private var letters: LetterLayout = LetterLayout(
        rawValue: AppGroup.defaults?.string(forKey: "keyboard.letterLayout") ?? ""
    ) ?? .qwerty

    private let rowsStack = UIStackView()
    private let statusLabel = UILabel()
    private let thumbnailView = UIImageView()
    private let layoutButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint?

    // Backspace auto-repeat while held.
    private var backspaceTimer: Timer?

    private static let log = Logger(subsystem: "com.leventemurgas.MemeMatcher.Keyboard",
                                    category: "keyboard")

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        buildUI()
        rebuildKeys()
        refreshStatus()
        // Report our own setup state so the app's tutorial can show live
        // progress — the app has no way to query either of these itself.
        // (App Group writes work even without Full Access.)
        AppGroup.writeKeyboardStatus(hasFullAccess: hasFullAccess)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The app writes the selection while the keyboard is off-screen.
        refreshStatus()
        syncShiftWithContext()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncShiftWithContext()
    }

    // MARK: - Layout

    private func buildUI() {
        // --- Toolbar: Meme Face on the left, status on the right ---
        let memeFaceButton = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "face.smiling")
        config.title = " Memes"
        config.baseForegroundColor = .systemBlue
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        memeFaceButton.configuration = config
        memeFaceButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)
        memeFaceButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8

        // The last copied meme, shown as a thumbnail rather than a filename.
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.layer.cornerRadius = 5
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailView.widthAnchor.constraint(equalToConstant: 28),
            thumbnailView.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Letter layout toggle (QWERTY / QWERTZ / …).
        var layoutConfig = UIButton.Configuration.plain()
        layoutConfig.baseForegroundColor = .secondaryLabel
        layoutConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        layoutButton.configuration = layoutConfig
        layoutButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        layoutButton.addTarget(self, action: #selector(cycleLetterLayout), for: .touchUpInside)
        layoutButton.setContentHuggingPriority(.required, for: .horizontal)
        updateLayoutButtonTitle()

        let toolbar = UIStackView(arrangedSubviews: [memeFaceButton, statusLabel, thumbnailView, layoutButton])
        toolbar.axis = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .center

        // --- Key rows ---
        rowsStack.axis = .vertical
        rowsStack.spacing = Self.rowSpacing
        rowsStack.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [toolbar, rowsStack])
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
        ])
    }

    /// Rebuild every row for the current plane. Cheap enough to redo on a
    /// plane switch, and far simpler than mutating keys in place.
    private func rebuildKeys() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        keyViews.removeAll()

        for specs in KeyboardLayout.rows(for: plane, letters: letters) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Self.keySpacing
            row.distribution = .fill

            // Width is a fraction of the row, so rotation and device size just
            // work. Every key is sized relative to the row's total units.
            let totalUnits = specs.reduce(0) { $0 + $1.widthUnits }
            var reference: KeyView?

            for spec in specs {
                let keyView = KeyView(key: spec.key)
                keyView.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(keyView)

                if let reference {
                    // Relative to the first key, preserving unit ratios.
                    let firstUnits = specs[0].widthUnits
                    keyView.widthAnchor.constraint(
                        equalTo: reference.widthAnchor,
                        multiplier: spec.widthUnits / firstUnits
                    ).isActive = true
                } else {
                    reference = keyView
                    keyView.widthAnchor.constraint(
                        equalTo: row.widthAnchor,
                        multiplier: spec.widthUnits / totalUnits,
                        constant: -Self.keySpacing * CGFloat(specs.count - 1) * spec.widthUnits / totalUnits
                    ).isActive = true
                }

                if spec.key != .spacer {
                    wire(keyView)
                    keyViews.append(keyView)
                }
            }
            rowsStack.addArrangedSubview(row)
        }
        updateKeyTitles()
    }

    private func wire(_ keyView: KeyView) {
        switch keyView.key {
        case .globe:
            // The system handles the keyboard switcher (tap = next, hold = menu).
            keyView.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        case .backspace:
            keyView.addTarget(self, action: #selector(backspaceDown), for: .touchDown)
            for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
                keyView.addTarget(self, action: #selector(backspaceUp), for: event)
            }
        default:
            keyView.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        }
    }

    private func updateKeyTitles() {
        keyViews.forEach { $0.update(plane: plane, shift: shift) }
    }

    // MARK: - Input handling

    @objc private func keyTapped(_ sender: KeyView) {
        UIDevice.current.playInputClick()

        switch sender.key {
        case .character(let value):
            let text = (plane == .letters && shift.isUppercase) ? value.uppercased() : value
            textDocumentProxy.insertText(text)
            // A one-shot shift falls back to lowercase; caps lock persists.
            if shift == .on { shift = .off; updateKeyTitles() }

        case .space:
            textDocumentProxy.insertText(" ")
            syncShiftWithContext()

        case .return:
            textDocumentProxy.insertText("\n")
            syncShiftWithContext()

        case .shift:
            shift = (shift == .off) ? .on : (shift == .on ? .capsLock : .off)
            updateKeyTitles()

        case .plane(let target):
            switch target {
            case .letters: plane = .letters
            case .numbers: plane = .numbers
            case .symbols: plane = .symbols
            }
            rebuildKeys()

        case .backspace, .globe, .spacer:
            break   // handled elsewhere
        }
    }

    @objc private func backspaceDown() {
        UIDevice.current.playInputClick()
        textDocumentProxy.deleteBackward()
        // Hold to repeat, matching the system keyboard.
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.startBackspaceRepeat()
        }
    }

    private func startBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }
    }

    @objc private func backspaceUp() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        syncShiftWithContext()
    }

    /// Auto-capitalise at the start of the document and after sentence ends —
    /// the small touch that makes a custom keyboard feel native.
    private func syncShiftWithContext() {
        guard plane == .letters, shift != .capsLock else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let shouldCapitalise = before.isEmpty
            || (before.hasSuffix(" ") && (trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")))
            || before.hasSuffix("\n")
        let newState: ShiftState = shouldCapitalise ? .on : .off
        if newState != shift {
            shift = newState
            updateKeyTitles()
        }
    }

    // MARK: - Meme Face

    /// Launch the container app.
    ///
    /// Every option here is a workaround: the responder-chain `openURL:` trick
    /// silently fails since iOS 18, and `extensionContext?.open` is Today-widget
    /// only. What works is SwiftUI's `openURL` from a fresh `EnvironmentValues`
    /// — and only with Full Access enabled.
    /// Cycle the letter arrangement and remember it. Only affects the letters
    /// plane, so switch back to it if the user is on numbers/symbols.
    @objc private func cycleLetterLayout() {
        letters = letters.next
        AppGroup.defaults?.set(letters.rawValue, forKey: "keyboard.letterLayout")
        plane = .letters
        rebuildKeys()
        updateLayoutButtonTitle()
    }

    private func updateLayoutButtonTitle() {
        layoutButton.setTitle(letters.displayName, for: .normal)
    }

    @objc private func openApp() {
        guard let url = URL(string: "memematcher://capture") else { return }
        Self.log.error("Meme Face tapped, requesting open of \(url.absoluteString)")
        EnvironmentValues().openURL(url) { accepted in
            Self.log.error("openURL accepted=\(accepted)")
        }
    }

    /// Confirm what the app last copied, so coming back lands on a clear
    /// "ready to paste" state.
    private func refreshStatus() {
        guard let data = AppGroup.readSelectionThumbnail(), let image = UIImage(data: data) else {
            statusLabel.text = "Tap Memes to match your face"
            thumbnailView.isHidden = true
            return
        }
        statusLabel.text = "Copied. Long-press to paste"
        thumbnailView.image = image
        thumbnailView.isHidden = false
    }

    // MARK: - Sizing

    private static let toolbarHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 9
    private static let keySpacing: CGFloat = 5

    /// Keyboards must declare their own height. Rows shrink in landscape,
    /// where vertical space is scarce.
    private func updateHeight() {
        let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
        let rowHeight: CGFloat = isLandscape ? 36 : 48
        let total = Self.toolbarHeight + 6 + (rowHeight * 4) + (Self.rowSpacing * 3) + 8

        if let heightConstraint {
            if heightConstraint.constant != total { heightConstraint.constant = total }
        } else {
            let constraint = view.heightAnchor.constraint(equalToConstant: total)
            constraint.priority = UILayoutPriority(999)   // avoid fighting the system
            constraint.isActive = true
            heightConstraint = constraint
        }
    }
}

/// Enables the system key-click sound (requires Full Access).
extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
