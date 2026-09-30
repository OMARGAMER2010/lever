import SwiftUI
import LeverCore

/// «Normal · Safe Mode», con una línea que dice qué va a pasar. Sin modal y sin sustos: la
/// recomendación aparece solo cuando hay una señal que la justifica, y dice cuál.
struct OpenModePicker: View {
    @ObservedObject var model: AppModel
    @Binding var mode: OpenMode
    let recommendation: SafeRecommendation
    let normalExplanation: TextKey
    let safeExplanation: TextKey

    private var s: Strings { model.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Spacing.tight) {
                Picker(s[.openModeLabel], selection: $mode) {
                    Text(s[.openModeNormal]).tag(OpenMode.normal)
                    Label(s[.safeModeName], systemImage: "shield.lefthalf.filled").tag(OpenMode.safe)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isBusy)
                .accessibilityLabel(s[.openModeLabel])

                if recommendation.isRecommended {
                    Text(s[.safeRecommended])
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Theme.attention)
                        .overlay(Capsule().strokeBorder(Theme.attention.opacity(0.6)))
                }
                Spacer(minLength: 0)
            }

            Text(s[mode == .safe ? safeExplanation : normalExplanation])
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = recommendation.reasons.first {
                Text(s(.safeRecommendedBecause, s[reason.kind.textKey]))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if mode == .safe, model.sandboxAvailability == .unavailable {
                NoticeBanner(kind: .failure, title: s[.safeModeName], message: s[.safeUnavailable])
            }
        }
        .onAppear { model.checkSandboxAvailability() }
    }
}

/// Lo que Safe Mode sabe del espacio que se está enseñando: cuatro líneas y, aparte, los detalles.
struct SafeModeSummary: View {
    @ObservedObject var model: AppModel
    @State private var showsDetails = false
    @State private var confirmsDelete = false
    @State private var sizeText = ""

    private var s: Strings { model.strings }

    var body: some View {
        if let report = model.safeReport, let workspace = model.safeWorkspace {
            Panel(padding: Theme.Spacing.normal) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(s[.safeActive], systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .semibold))
                    status(report.networkAllowed ? "network" : "network.slash",
                           s[report.networkAllowed ? .safeNetworkAllowed : .safeNetworkBlocked],
                           tint: report.networkAllowed ? Theme.attention : Theme.ready)
                    status("lock.shield", s[.safePersonalProtected], tint: Theme.ready)
                    status("square.dashed", s[.safeIsolated], tint: Theme.ready)
                    verdict(report.verdict)

                    if !report.executables.isEmpty { programs(report.executables) }

                    HStack(spacing: Theme.Spacing.tight) {
                        Button(s[showsDetails ? .safeHideDetails : .safeDetails]) { showsDetails.toggle() }
                            .buttonStyle(.link)
                        Spacer()
                        Button(s[.safeDesktopLink], action: model.createDesktopShortcutForSafeWorkspace)
                        Button(s[.safeShowFiles], action: model.revealSafeWorkspace)
                        Button(s[.safeDeleteWorkspace], role: .destructive) {
                            Task {
                                sizeText = await model.safeWorkspaceSize(all: false)
                                confirmsDelete = true
                            }
                        }
                        .disabled(model.isBusy)
                    }
                    .controlSize(.small)

                    if showsDetails { details(report, workspace: workspace) }
                }
            }
            .confirmationDialog(s[.safeDeleteConfirmTitle], isPresented: $confirmsDelete) {
                Button(s[.safeDeleteConfirm], role: .destructive, action: model.deleteSafeWorkspace)
                Button(s[.cancel], role: .cancel) {}
            } message: {
                Text(s(.safeDeleteConfirmBody, sizeText))
            }
        }
    }

    private func status(_ symbol: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16).accessibilityHidden(true)
            Text(text).font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func verdict(_ verdict: SafeVerdict) -> some View {
        switch verdict {
        case .knownThreats(let count):
            status("xmark.octagon", s(.safeVerdictKnownThreats, String(count)), tint: Theme.failure)
        case .suspicious(let count):
            status("exclamationmark.triangle", s(.safeVerdictSuspicious, String(count)), tint: Theme.attention)
        case .unverified:
            status("questionmark.circle", s[.safeVerdictUnverified], tint: Theme.attention)
        case .nothingSuspicious:
            status("checkmark.circle", s[.safeVerdictNothingSuspicious], tint: .secondary)
        case .noKnownThreats:
            status("checkmark.circle", s[.safeVerdictNoKnownThreats], tint: .secondary)
        }
    }

    private func programs(_ executables: [SafeExecutable]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s[.safeProgramsFound]).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(executables.prefix(6)) { executable in
                HStack(spacing: Theme.Spacing.tight) {
                    Text(executable.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text([executable.architecture, executable.isInstaller ? s[.safeInstallerTag] : nil,
                          s[executable.hasSignature ? .safeSigned : .safeUnsigned]].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.tight)
                    Button(s[.runSafe]) { model.runSafeExecutable(executable) }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    private func details(_ report: SafeReport, workspace: SafeWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(scannerText(report.signatureScan)).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(s[.safeDrivesNote]).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(s[.safeStaysInsideNote]).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(s[.safeFindingsTitle]).font(.system(size: 11, weight: .medium)).padding(.top, 2)
            let ordered = report.findings.sorted { $0.severity > $1.severity }
            if ordered.isEmpty {
                Text(s[.safeNoFindings]).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(ordered.prefix(60)) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: finding.severity >= .warning ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(finding.severity >= .warning ? Theme.attention : .secondary)
                    Text(line(for: finding)).font(.system(size: 11)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(report.executables.filter { $0.sha256 != nil }.prefix(6)) { executable in
                Text("\(executable.name) · \(s[.safeFingerprint]): \(executable.sha256 ?? "")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Text("\(s[.safeWorkspaceFolder]): \(workspace.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    private func line(for finding: SafeFinding) -> String {
        var text = s[finding.kind.textKey]
        switch finding.kind {
        case .windowsProgram, .nestedArchive, .webShortcut:
            if let count = finding.detail { text += " (\(count))" }
        default:
            text += " · \(finding.subject)"
            if let detail = finding.detail, !detail.isEmpty { text += " → \(detail)" }
        }
        return text
    }

    private func scannerText(_ scan: SafeSignatureScan) -> String {
        switch scan {
        case .notAvailable: return s[.safeScannerNotAvailable]
        case .nothingToScan: return s[.safeScannerNothing]
        case .clean(let engine): return s(.safeScannerClean, engine)
        case .detected(let engine, let count): return s(.safeScannerDetected, engine, String(count))
        case .failed(let engine): return s(.safeScannerFailed, engine)
        }
    }
}
