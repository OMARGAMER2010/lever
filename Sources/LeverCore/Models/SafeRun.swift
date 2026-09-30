import Foundation

/// Un espacio de Safe Mode visto como una entrada de historial: de dónde salió y qué se puede
/// ejecutar dentro.
///
/// No guarda nada nuevo en disco. El historial **son** los espacios que existen, así que la lista
/// se reconstruye leyendo la carpeta de Safe Mode. Lo que se borra deja de aparecer, y lo que
/// aparece se puede ejecutar siempre, porque sus archivos siguen ahí.
public struct SafeRun: Identifiable, Equatable, Sendable {
    public let workspace: SafeWorkspace
    public let origin: SafeWorkspaceOrigin
    /// Los programas que encontró el escáner al extraer. Vacío si el espacio no tiene informe.
    public let executables: [SafeExecutable]
    /// Lo que ocupa, tal y como lo contó el escáner. `nil` si no hay informe.
    public let sizeBytes: Int64?

    public init(
        workspace: SafeWorkspace,
        origin: SafeWorkspaceOrigin,
        executables: [SafeExecutable],
        sizeBytes: Int64?
    ) {
        self.workspace = workspace
        self.origin = origin
        self.executables = executables
        self.sizeBytes = sizeBytes
    }

    public var id: String { workspace.id }

    /// El archivo del que salió, sin la ruta. Es lo único que la persona reconoce de un vistazo:
    /// el identificador del espacio es un UUID y no dice nada.
    public var displayName: String { (origin.path as NSString).lastPathComponent }

    /// Dónde vive uno de sus programas.
    ///
    /// La ruta cae dentro de `<espacio>/files` a propósito: es lo que `SafeWorkspace.containing`
    /// reconoce, y por tanto lo que hace que al abrirlo salga en Safe Mode y no en modo normal.
    public func url(of executable: SafeExecutable) -> URL {
        workspace.files.appendingPathComponent(executable.relativePath)
    }

    /// Los espacios que hay, del más reciente al más antiguo.
    ///
    /// El orden y el filtrado los pone `SafeWorkspace.all`, que es quien sabe qué carpeta es un
    /// espacio de verdad. Aquí solo se le añade a cada uno lo que hace falta para enseñarlo.
    ///
    /// El tamaño se saca del informe en vez de medirlo: recorrer el árbol de cada espacio para
    /// pintar una lista congelaría la ventana, porque uno solo puede pesar decenas de gigas.
    public static func all(
        base: URL = SafeWorkspace.defaultBase,
        fileManager: FileManager = .default
    ) -> [SafeRun] {
        SafeWorkspace.all(base: base, fileManager: fileManager).compactMap { workspace in
            // Sin carpeta de archivos no hay nada que ejecutar, así que tampoco hay fila.
            guard let origin = workspace.origin(),
                  fileManager.fileExists(atPath: workspace.files.path) else { return nil }
            let report = workspace.loadReport()
            return SafeRun(workspace: workspace,
                           origin: origin,
                           executables: report?.executables ?? [],
                           sizeBytes: report?.totalBytes)
        }
    }
}
