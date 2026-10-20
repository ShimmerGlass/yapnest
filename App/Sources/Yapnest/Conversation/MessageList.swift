import SwiftUI
import YapnestKit

/// The messages, scrolled to the newest. The scroll view anchors its bottom
/// edge, so a bubble that grows (a preview or a photo arriving, a reaction, an
/// edit) or a message that arrives pushes the older ones up rather than
/// growing past the bottom for a frame and jumping back.
struct MessageList: View {
    @Bindable var model: ConversationModel
    /// The height of the bars over the top of the list.
    let topInset: CGFloat
    /// The height of the composer over the bottom of the list.
    let bottomInset: CGFloat

    /// The safe area the list is given. Flipped, the scroll view would put the
    /// bars' at its own top, the bottom of the screen, so it ignores that and
    /// it's given back at the edge it belongs to.
    @State private var inheritedSafeArea = EdgeInsets()

    var body: some View {
        // Redraws when the model moves the list.
        let _ = model.scrollRevision
        let flipped = model.isFlipped
        ScrollView {
            LazyVStack(spacing: 0) {
                // The list is upside down and each row turned back, so the
                // newest message is first, at the scroll view's resting point,
                // and the older ones and their row follow it. Whatever
                // measures the rows' growth in the stack's own space has it the
                // right way up; what is inside a row is as if nothing were
                // flipped.
                if !flipped { OlderMessagesRow(model: model) }
                ForEach(flipped ? Array(model.rows.reversed()) : model.rows) { row in
                    MessageRowView(row: row, model: model).equatable()
                        // Only a message that just arrived slides in, and a
                        // leaving row fades rather than sliding down.
                        .transition(.asymmetric(
                            insertion: model.arrivingIDs.contains(row.id) ? .opacity.combined(with: .move(edge: .bottom)) : .identity,
                            removal: .opacity,
                        ))
                        // A little above the composer. On the row rather than
                        // the stack, so that scrolling to the newest row by
                        // its id reaches the very end. Unflipped, the room
                        // under the composer is here too: as an inset or a
                        // margin it would leave the scroll view past its end.
                        .padding(.bottom, row.id == model.rows.last?.id ? 8 + (flipped ? 0 : bottomInset) : 0)
                        // The scroll view only reports a row once half of it is
                        // in view, which one taller than two screens never is, so
                        // this reports whether the row fills the part of the view
                        // the user sees: below the bars and above the composer.
                        // It's worked out in the row's own coordinates, which is
                        // the space `bounds(of:)` gives the scroll view's bounds in.
                        .onGeometryChange(for: Bool.self) { proxy in
                            guard let viewport = proxy.bounds(of: .scrollView) else { return false }
                            let visibleTop = viewport.minY + topInset
                            let visibleBottom = viewport.maxY - bottomInset
                            let seen = visibleBottom - visibleTop
                            let overlap = min(proxy.size.height, visibleBottom) - max(0, visibleTop)
                            return seen > 0 && overlap >= seen * 0.5
                        } action: { [id = row.id] fills in
                            model.rowFillsViewChanged(id, fills)
                        }
                        // A row the lazy stack releases never reports again, and
                        // a fill left behind would claim a row that isn't drawn.
                        // Which rows are built is also what the model has when
                        // neither report says a row at the end is in view.
                        .onAppear { [id = row.id] in model.rowBuiltChanged(id, true) }
                        .onDisappear { [id = row.id] in
                            model.rowBuiltChanged(id, false)
                            model.rowFillsViewChanged(id, false)
                        }
                        #if DEBUG
                        .recordingFrame(of: row.id, model)
                        #endif
                        .upsideDown(flipped)
                }
                if flipped { OlderMessagesRow(model: model).upsideDown(true) }
            }
            .scrollTargetLayout()
        }
        .coordinateSpace(.named("messageList"))
        .scrollPosition(Binding(get: { model.scroll }, set: { model.scrollViewMoved($0) }))
        // Flipped, the newest message is where the scroll view rests, and
        // an estimate of the heights of the rows past the other end can
        // change without moving what's on screen.
        .defaultScrollAnchor(flipped ? nil : .bottom)
        .defaultScrollAnchor(flipped ? nil : .bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // Room for the bars over the top, so a message scrolled to, such as
        // a search match, lands below them rather than under them.
        .contentMargins(flipped ? .bottom : .top, topInset + 8 + model.layoutNudge, for: .scrollContent)
        .contentMargins(flipped ? .bottom : .top, topInset, for: .scrollIndicators)
        .coveredAtTop(flipped, by: flipped ? inheritedSafeArea.top : 0)
        .contentMargins(.bottom, flipped ? 0 : bottomInset, for: .scrollIndicators)
        .safeAreaPadding(.top, flipped ? bottomInset : 0)
        // Flipped, the scroll view's bottom is the screen's top: it runs under
        // the bars, which `coveredAtTop` makes room for. The home indicator,
        // at its top, it makes room for itself, and the composer's height
        // over it is added.
        .ignoresSafeArea(.container, edges: flipped ? .bottom : [])
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            model.geometryChanged(geometry)
        }
        .onScrollGeometryChange(for: Bool.self) { ConversationModel.isAway($0, flipped: flipped) } action: { _, away in
            model.awayFromBottomChanged(away)
        }
        .onScrollGeometryChange(for: Bool.self) { ConversationModel.isNearTop($0, flipped: flipped) } action: { _, near in
            model.nearTopChanged(near)
        }
        .onScrollGeometryChange(for: Bool.self) { ConversationModel.isNearEnd($0, flipped: flipped) } action: { _, near in
            model.nearEndChanged(near)
        }
        .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.5) { ids in
            model.visibleChanged(ids)
        }
        // Any part of a row: tells a blank list from one of tall rows that
        // are each less than half in view.
        .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.01) { ids in
            model.anyVisibleChanged(count: ids.count)
        }
        .onScrollPhaseChange { old, phase in
            FrameLog.event("scrollPhase \(old) -> \(phase)")
            model.scrollPhase = phase
            switch phase {
            case .interacting: model.userStartedScrolling()
            case .idle: model.scrollSettled()
            default: break
            }
        }
        // Tapping the messages puts the keyboard away. Links and buttons in
        // the bubbles still get their taps. Not on the Mac, where there's no
        // keyboard to put away and a click in the list would take the
        // composer's focus (and the caret) for nothing; `.subviews` leaves
        // this gesture out there.
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }, including: Platform.isMac ? .subviews : .all)
        .upsideDown(flipped)
        // Outside the flip, where the safe area is as the screen has it.
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { inheritedSafeArea = $0 }
        #if DEBUG
        .scrollRecording(model)
        #endif
    }
}

extension View {
    /// Mirrors the view top to bottom, around its middle. Applied twice it is
    /// as if it weren't.
    @ViewBuilder
    func upsideDown(_ on: Bool) -> some View {
        if on { scaleEffect(x: 1, y: -1) } else { self }
    }
}

/// The row above the oldest message: a spinner while the server is asked
/// for more, a retry if that failed, and a quiet note at the very start.
/// It's always there, blank when it has nothing to say, so showing and
/// hiding it never shifts the messages.
private struct OlderMessagesRow: View {
    let model: ConversationModel

    var body: some View {
        ZStack {
            switch model.olderState {
            case .idle:
                Color.clear
            case .loading:
                ProgressView()
            case .complete:
                Text("Beginning of conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                HStack(spacing: 4) {
                    Text("Couldn't load older messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.retryOlder() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // A minimum, so larger text doesn't spill onto the first message.
        .frame(minHeight: 44)
    }
}

/// A spinner until the messages are read, and while an empty chat may
/// still be getting its history; then says it's empty.
struct MessagesPlaceholder: View {
    let model: ConversationModel
    @State private var showsSpinner = false

    var body: some View {
        let isLoading = !model.hasLoaded || (model.rows.isEmpty && model.isFetchingHistory)
        if isLoading {
            // Reading the messages is usually quick: the spinner only shows
            // up if it isn't, rather than flashing.
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading messages…").foregroundStyle(.secondary)
            }
            .opacity(showsSpinner ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
            }
        } else if model.rows.isEmpty {
            ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
        }
    }
}

/// A round button above the composer that takes the user back to the newest
/// message, with the number of messages they haven't read yet.
struct ScrollToEndControl: View {
    let model: ConversationModel

    var body: some View {
        // A bounded window's last row isn't the conversation's end, however
        // near it the list is.
        let shows = model.hasLoaded && model.isPositioned && (model.isAwayFromBottom || model.isBounded)
        // Only there while it shows. Left in at no opacity it is still an
        // element on screen as far as the accessibility tree goes, and one
        // that takes no touch, so a tap on it falls through to the row
        // beneath.
        ZStack {
            if shows { button.transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.2), value: shows)
    }

    private var button: some View {
        Button {
            model.scrollToLatest()
        } label: {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                // A plain button only takes touches where its label draws,
                // and neither the glass nor its clear circle counts, which
                // left only the arrow itself to hit.
                .contentShape(.circle)
                .background { background }
                .overlay(alignment: .topTrailing) { badge }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to latest message")
        .accessibilityValue(model.unreadCount == 0 ? "" : String(localized: "\(model.unreadCount) unread"))
    }

    @ViewBuilder
    private var background: some View {
        if #available(iOS 26, *) {
            Circle().fill(.clear).glassEffect(.regular.interactive(), in: .circle)
        } else {
            Circle().fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if model.unreadCount > 0 {
            Text(model.unreadCount > 99 ? "99+" : "\(model.unreadCount)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(Capsule().fill(Color.blue))
                .offset(x: 4, y: -4)
        }
    }
}

/// Brings up the emoji keyboard, or on the Mac the character viewer, to pick
/// a reaction beyond the quick ones. It's an invisible text field that hands
/// back the first emoji typed into it.
struct EmojiPickerHost: UIViewRepresentable {
    let model: ConversationModel

    func makeUIView(context: Context) -> EmojiField {
        let field = EmojiField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        field.isUserInteractionEnabled = false
        return field
    }

    func updateUIView(_ field: EmojiField, context: Context) {
        guard let request = model.emojiPicker else { return }
        let id = request.id
        model.emojiPicker = nil
        field.isUserInteractionEnabled = true
        field.onPick = { [weak model] emoji in model?.react(emoji, to: id) }
        field.anchor = request.anchor
        // After this update, which may still be settling what has focus.
        DispatchQueue.main.async { _ = field.becomeFirstResponder() }
    }
}

extension View {
    /// Room at the visual top of a flipped list, that is at the scroll view's
    /// bottom, `height` tall. The iOS 26 scroll edge effect doesn't draw there,
    /// and the one it draws at the other end covers the whole list, so both
    /// are off and `TopEdgeBlur` stands in for the first. An unflipped list
    /// has no use for it, its bars are the content margin.
    @ViewBuilder
    func coveredAtTop(_ flipped: Bool, by height: CGFloat) -> some View {
        if !flipped {
            self
        } else if #available(iOS 26, *) {
            safeAreaPadding(.bottom, height).scrollEdgeEffectHidden(true, for: .all)
        } else {
            safeAreaPadding(.bottom, height)
        }
    }
}

/// What the scroll edge effect does under the navigation bar, for the flipped
/// list, where the system's isn't drawn: the messages blur and fade into the
/// background going up. A material alone draws gray over the messages, where
/// the system's darkens them towards the background in dark mode.
struct TopEdgeBlur: View {
    @State private var safeTop: CGFloat = 0

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
            .overlay(alignment: .top) {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    LinearGradient(stops: [
                        .init(color: Color(.systemBackground).opacity(0.9), location: 0),
                        .init(color: Color(.systemBackground).opacity(0.6), location: 0.55),
                        .init(color: Color(.systemBackground).opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                    .frame(height: safeTop + 24)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
    }
}
