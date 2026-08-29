import Foundation

/// Detecta y repara el motivo más común de que Wine "no haga nada" al ejecutarse.
///
/// Homebrew marca los `.cask` que descarga con el atributo `com.apple.quarantine`. Wine viene
/// firmado solo de forma ad-hoc, así que macOS mata el proceso nada más arrancar: se ve como un
/// fallo silencioso con código 137 y ni una línea de error. Quitar esa marca de la app de Wine
/// —que el propio usuario instaló a propósito— es lo que la desbloquea.
public enum QuarantineGuard {
    /// Sube desde el binario de Wine hasta el bundle `.app` que lo contiene, si lo hay.
    public static func containingAppBundle(of executable: URL) -> URL? {
        var current = executable.deletingLastPathComponent()
        while current.path != "/" {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// `true` si la ruta lleva la marca de cuarentena de macOS.
    public static func isQuarantined(_ url: URL) -> Bool {
        var size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        if size >= 0 { return true }
        // Si el binario suelto no la lleva, puede llevarla el bundle que lo contiene.
        guard let bundle = containingAppBundle(of: url) else { return false }
        size = getxattr(bundle.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        return size >= 0
    }

    /// Qué ruta hay que desbloquear: el bundle completo si existe, o el binario suelto.
    public static func repairTarget(for executable: URL) -> URL {
        containingAppBundle(of: executable) ?? executable
    }

    /// Orden que quita la marca. Se ejecuta con `xattr`, presente en cualquier macOS.
    public static func repairCommand(for executable: URL) -> ProcessCommand {
        ProcessCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", repairTarget(for: executable).path],
            currentDirectoryURL: nil
        )
    }
}
