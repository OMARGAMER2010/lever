import SwiftUI
import LeverCore

/// Lo que se abrió hace poco, para no tener que volver a buscarlo ni arrastrarlo.
///
/// Sale solo cuando no hay nada elegido en esa pestaña: es entonces cuando responde a la pregunta
/// «¿y ahora qué abro?». Con un archivo ya puesto, la pestaña va de ese archivo y la lista sería
/// ruido debajo de lo que importa.
///
/// La fila entera es el botón de abrir, que es lo que se hace el 90 % de las veces. Renombrar,
/// mover, mostrar en el Finder y quitar viven en el menú de la derecha: cuatro botones por fila
/// pesarían más que la propia lista y solo se usan de vez en cuando.
struct RecentsList: View {
    @ObservedObject var model: AppModel
    let kind: SupportedFileKind

    /// Ruta de la fila que se está renombrando. El nombre se edita en su sitio, como en el
    /// Finder, en vez de abrir una ventana para escribir una palabra.
    @State private var renamingPath: String?
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var s: Strings { model.strings }
    private var files: [RecentFile] { model.recentFiles(of: kind) }

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(s[.recentsTitle])
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(s[.recentsClear]) { model.clearRecents(of: kind) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        row(for: file)
                    }
                }
            }
        }
    }

    private func row(for file: RecentFile) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(file.isMissing ? 0.4 : 1)
                .accessibilityHidden(true)

            if renamingPath == file.path {
                renameField(for: file)
            } else {
                Button { model.reopen(file) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(file.isMissing ? Color.secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detail(for: file))
                            .font(.system(size: 11))
                            .foregroundStyle(file.isMissing ? Theme.attention : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(file.isMissing)
                .help(s[.recentsReopen])
                .accessibilityLabel("\(s[.recentsReopen]): \(file.name). \(detail(for: file))")
            }

            menu(for: file)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.Radius.inline))
    }

    private func renameField(for file: RecentFile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit { commitRename(of: file) }
                // Pinchar fuera confirma, como en el Finder: perder lo escrito por moverse de
                // sitio es la manera más fácil de enfadar a alguien.
                .onChange(of: nameFocused) { focused in
                    if !focused, renamingPath == file.path { commitRename(of: file) }
                }
                .accessibilityLabel(s[.recentsRename])
            Text(s[.recentsRenameHint])
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menu(for file: RecentFile) -> some View {
        Menu {
            Button(s[.recentsReopen]) { model.reopen(file) }
                .disabled(file.isMissing)
            Button(s[.revealInFinder]) { FileActions.reveal(file.url) }
                .disabled(file.isMissing)
            Divider()
            Button(s[.recentsRename]) { startRename(of: file) }
                .disabled(file.isMissing)
            Button(s[.recentsMove]) { model.moveRecent(file) }
                .disabled(file.isMissing)
            Divider()
            Button(s[.recentsForget]) { model.forgetRecent(file) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(file.name)
        .accessibilityLabel("\(file.name): \(s[.menuTools])")
    }

    /// Debajo del nombre va lo que sirve para distinguir dos archivos que se llaman igual: dónde
    /// está y cuánto ocupa. Y si ya no está, eso primero, que es lo único que importa.
    private func detail(for file: RecentFile) -> String {
        guard !file.isMissing else { return "\(s[.recentsMissing]) · \(file.folder)" }

        var parts: [String] = []
        if let size = file.url.formattedFileSize { parts.append(size) }
        parts.append(file.folder)
        return parts.joined(separator: " · ")
    }

    private func startRename(of file: RecentFile) {
        // Se ofrece el nombre sin extensión: es lo único que se puede cambiar desde aquí.
        draft = file.url.deletingPathExtension().lastPathComponent
        renamingPath = file.path
        nameFocused = true
    }

    private func commitRename(of file: RecentFile) {
        let name = draft
        renamingPath = nil
        draft = ""
        guard name != file.url.deletingPathExtension().lastPathComponent else { return }
        model.renameRecent(file, to: name)
    }
}
