import SwiftUI
import LeverCore

/// Lo que ya está extraído en Safe Mode, para volver a ejecutarlo sin ir a buscarlo.
///
/// La lista no es un registro aparte: **son** los espacios que hay en disco, leídos cada vez que
/// se entra. Por eso todo lo que se ve se puede ejecutar —sus archivos siguen ahí— y lo que se
/// borra desaparece solo, sin dejar filas muertas.
///
/// Elegir un programa no ejecuta nada ni fuerza ningún modo: solo lo carga, y quien decide si
/// sale Safe Mode o normal es `SafeWorkspace.containing(_:)`, la misma puerta de siempre. Como la
/// ruta cae dentro del espacio, sale Safe Mode. Forzarlo aquí escondería el día que esa puerta
/// dejara de reconocerla, que es justo el día en que habría que enterarse.
struct SafeRunsPane: View {
    @ObservedObject var model: AppModel

    @State private var runs: [SafeRun] = []
    @State private var expanded: Set<String> = []

    private var s: Strings { model.strings }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
            if runs.isEmpty {
                empty
            } else {
                Panel(padding: Theme.Spacing.normal) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(runs) { run in
                            space(run)
                        }
                    }
                }
            }

            if model.selectedProgram != nil {
                Divider()
                OpenModePicker(
                    model: model,
                    mode: $model.programOpenMode,
                    recommendation: model.programRecommendation,
                    normalExplanation: .normalProgramExplain,
                    safeExplanation: .safeProgramExplain
                )
                if model.programOpenMode == .safe { SafeModeSummary(model: model) }
            }
        }
        .onAppear { runs = SafeRun.all() }
    }

    private var empty: some View {
        Panel(padding: Theme.Spacing.normal) {
            VStack(alignment: .leading, spacing: 4) {
                Label(s[.safeRunsEmpty], systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                Text(s[.safeRunsEmptyBody])
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func space(_ run: SafeRun) -> some View {
        let isOpen = expanded.contains(run.id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if isOpen { expanded.remove(run.id) } else { expanded.insert(run.id) }
            } label: {
                HStack(spacing: Theme.Spacing.tight) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(run.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.tight)
                    if let bytes = run.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Text(Self.relative.localizedString(for: run.origin.createdAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                if run.executables.isEmpty {
                    Text(s[.safeRunsNoPrograms])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                } else {
                    ForEach(run.executables) { executable in
                        program(run, executable)
                    }
                }
            }
        }
    }

    private func program(_ run: SafeRun, _ executable: SafeExecutable) -> some View {
        let url = run.url(of: executable)
        let isChosen = model.selectedProgram?.standardizedFileURL.path == url.standardizedFileURL.path
        return Button {
            model.acceptProgram(url)
        } label: {
            HStack(spacing: Theme.Spacing.tight) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isChosen ? Theme.ready : Color.secondary)
                Text(executable.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text([executable.architecture,
                      executable.isInstaller ? s[.safeInstallerTag] : nil,
                      s[executable.hasSignature ? .safeSigned : .safeUnsigned]]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
    }
}
