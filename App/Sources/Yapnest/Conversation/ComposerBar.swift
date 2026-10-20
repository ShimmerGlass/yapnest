import SwiftUI
import YapnestKit

/// The composer, which is UIKit (its key handling, suggestions and attach
/// menu are), sized for SwiftUI: it asks the bar how tall it wants to be, and
/// asks SwiftUI to ask again when typing makes the bar taller.
struct ComposerBar: UIViewRepresentable {
    let model: ConversationModel
    let picker: AttachmentPicker
    /// The bar's height as SwiftUI lays it out. It changes in one step: an
    /// animated height would resize the message list on every frame, and the
    /// lazy stack re-guesses its unmeasured rows each time, so the messages
    /// jumped for a frame. The bar animates its own contents.
    @Binding var height: CGFloat?

    func makeUIView(context: Context) -> ComposerHost {
        let host = ComposerHost()
        let bar = host.bar
        bar.onSend = { [weak model] text in model?.send(text) }
        bar.onTextChanged = { [weak model] text in model?.textChanged(text) }
        bar.onCancelReply = { [weak model] in model?.cancelReplyOrEdit() }
        bar.onAttach = { [weak picker] source in picker?.attach(from: source) }
        bar.onGif = { [weak model] in model?.openGifPicker() }
        bar.onAttachments = { [weak model] providers in model?.offerAttachments(providers) }
        bar.onRemovePending = { [weak model] id in model?.removePendingAttachment(id) }
        bar.onDropTargeted = { [weak model] targeted in model?.composerDropTargeted = targeted }
        bar.onVoicePress = { [weak model] locked in model?.voicePress(locked: locked) }
        model.composer.bar = bar
        model.composerAttached()
        return host
    }

    func updateUIView(_ host: ComposerHost, context: Context) {
        host.onHeight = { height in
            self.height = height
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView host: ComposerHost, context: Context) -> CGSize? {
        let width = proposal.width ?? host.bounds.width
        return CGSize(width: width, height: height ?? host.fittingHeight(width: width))
    }
}

/// Holds the bar so that it can grow past the height SwiftUI last gave it,
/// for the moment before SwiftUI notices, without UIKit breaking constraints,
/// and tells SwiftUI whenever the bar's height changes either way.
final class ComposerHost: UIView {
    let bar = ConversationInputBar()
    private var reportedHeight: CGFloat = 0
    private var reportPending = false
    var onHeight: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        // No bottom constraint: it would stretch the bar to the height SwiftUI
        // last gave us, so the bar's own fitting height could never get
        // smaller again.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // The bar grows and shrinks from inside (a reply, a line of text),
        // which doesn't lay out the host.
        bar.onLayout = { [weak self] in self?.reportHeightIfChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The bar's height at `width`, worked out by a throwaway constraint
    /// engine over the whole bar. That engine covers the glass, the buttons
    /// and the text view, and costs some 18ms each time, so it's only for
    /// the first measurement, before the bar has been laid out at all.
    func fittingHeight(width: CGFloat) -> CGFloat {
        if reportedHeight > 0, abs(width - bar.bounds.width) < 0.5 { return reportedHeight }
        return bar.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        ).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportHeightIfChanged()
    }

    private func reportHeightIfChanged() {
        // The bar's constraints are what decide its height, and with no bottom
        // constraint from here, the frame the layout just gave it is their
        // solution. Reading it costs nothing, where fitting the bar again
        // ran that throwaway engine a few times for every change, which was
        // most of the hitch when a reply was set.
        guard bar.bounds.width > 0 else { return }
        let height = bar.bounds.height
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        // The bar reports from inside its own animations. SwiftUI would lay
        // the list out within them, and Core Animation would then animate the
        // list's frame and offset on its own, apart from what SwiftUI decides
        // to draw for its final size, leaving rows missing or misplaced.
        // So the list takes the new height on the next turn, with no animation.
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reportPending = false
            UIView.performWithoutAnimation { self.invalidateIntrinsicContentSize() }
            self.onHeight?(self.reportedHeight)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight(width: bounds.width))
    }
}
