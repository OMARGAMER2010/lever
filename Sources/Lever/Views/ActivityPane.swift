import SwiftUI
import LeverCore

/// Cajón inferior con el registro de lo que va pasando.
struct ActivityPane: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: Strings { model.strings }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if isExpanded {
                Divider().opacity(0.5)
                content
                    .frame(height: 168)
            }
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button {
                if reduceMotion { isExpanded.toggle() }
                else { withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(s[.activity])
                        .font(.system(size: 12, weight: .semibold))
                    if !model.log.isEmpty {
                        Text("\(model.log.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.09), in: Capsule())
                    }
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer()

            if model.isBusy {
                ProgressView().controlSize(.small)
            }

            Text(model.activityMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !model.log.isEmpty {
                Button(action: model.copyLog) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(s[.copyActivity])
                .accessibilityLabel(s[.copyActivity])

                Button(action: model.clearLog) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(s[.clearActivity])
                .accessibilityLabel(s[.clearActivity])
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 9)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if model.log.isEmpty {
                        Text(s[.activityEmpty])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    ForEach(model.log) { entry in
                        row(for: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.log.count) { _ in
                guard let last = model.log.last else { return }
                if reduceMotion { proxy.scrollTo(last.id, anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            if let symbol = entry.level.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(entry.level.tint)
                    .padding(.top, 2)
            } else {
                Color.clear.frame(width: 9, height: 1)
            }

            Text(entry.text)
                .font(.system(size: 11, design: entry.level == .output ? .monospaced : .default))
                .foregroundStyle(entry.level == .output ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
