import UIKit

/// A single keyboard key.
///
/// A `UIControl` subclass rather than a `UIButton` so the press highlight,
/// fonts and metrics are fully ours — `UIButton`'s modern configuration API
/// fights this kind of dense, custom layout.
final class KeyView: UIControl {

    let key: Key
    private let label = UILabel()
    private let iconView = UIImageView()

    /// Function keys (shift, backspace, 123…) sit on a darker base, like iOS.
    private var restingColor: UIColor {
        key.isFunctionKey ? .systemFill : .secondarySystemGroupedBackground
    }

    init(key: Key) {
        self.key = key
        super.init(frame: .zero)

        // Spacers only reserve room; they must never look or act like keys.
        guard key != .spacer else {
            isUserInteractionEnabled = false
            return
        }

        backgroundColor = restingColor
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isUserInteractionEnabled = false

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        iconView.isUserInteractionEnabled = false

        for subview in [label, iconView] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
            NSLayoutConstraint.activate([
                subview.centerXAnchor.constraint(equalTo: centerXAnchor),
                subview.centerYAnchor.constraint(equalTo: centerYAnchor),
                subview.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Refresh what the key shows — called when the plane or shift changes.
    func update(plane: Plane, shift: ShiftState) {
        guard key != .spacer else { return }

        if let symbolName = KeyboardLayout.symbolName(for: key, shift: shift) {
            iconView.image = UIImage(systemName: symbolName)
            iconView.isHidden = false
            label.isHidden = true
        } else {
            label.text = KeyboardLayout.title(for: key, plane: plane, shift: shift)
            // Word keys ("space", "return", "ABC") read better smaller than
            // single characters.
            let isWordKey = key.isFunctionKey || key == .space
            label.font = .systemFont(ofSize: isWordKey ? 16 : 24,
                                     weight: isWordKey ? .regular : .regular)
            label.isHidden = false
            iconView.isHidden = true
        }

        // Caps lock and an active shift read as "engaged".
        let engaged = key == .shift && shift == .capsLock
        backgroundColor = engaged ? .systemBlue.withAlphaComponent(0.25) : restingColor
    }

    // MARK: - Press feedback

    override var isHighlighted: Bool {
        didSet {
            guard key != .spacer else { return }
            // Letter keys go darker on press; function keys go lighter, which
            // is the inverse behaviour iOS uses.
            backgroundColor = isHighlighted
                ? (key.isFunctionKey ? .secondarySystemGroupedBackground : .systemFill)
                : restingColor
        }
    }

    /// Generous vertical touch target without changing the drawn size —
    /// keyboards are tap-dense and the gaps between rows should still work.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -5).contains(point)
    }
}
