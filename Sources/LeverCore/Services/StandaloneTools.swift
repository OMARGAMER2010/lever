import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Encontrar el emulador de una máquina y lanzarlo, sea la máquina que sea.
///
/// Esto es lo que la consola híbrida abrió y lo que la familia PlayStation aprovecha: de la PS2
/// para arriba no hay núcleo de libretro que valga, y con la familia Xbox va a pasar lo mismo. El
/// trabajo es siempre el mismo —mirar si el `.app` está donde suele, aceptar el que el usuario
/// señale, y abrirlo como app y no como proceso hijo— así que se hace en un sitio.
public enum StandaloneTools {
    /// Donde acaban las aplicaciones en un Mac.
    public static var applicationFolders: [URL] {
        ["/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
    }

    /// El emulador de esa máquina que haya instalado, con el `.app` donde está.
    ///
    /// - Parameter custom: uno señalado a mano. Vale aunque no esté en la lista: la lista sirve
    ///   para encontrarlo solo, no para decidir qué puede usar el usuario.
    public static func locate(
        machine: StandaloneMachine, preferring custom: URL? = nil, fileManager: FileManager = .default
    ) -> (emulator: StandaloneEmulator, app: URL)? {
        if let custom, fileManager.fileExists(atPath: custom.path) {
            let nombre = custom.lastPathComponent
            let cuál = machine.emulators.first {
                $0.bundleNames.contains { $0.caseInsensitiveCompare(nombre) == .orderedSame }
            }
            return (cuál ?? StandaloneEmulator(
                id: "custom", name: custom.deletingPathExtension().lastPathComponent,
                bundleNames: [nombre],
                // Si no se reconoce, se le da la carpeta de datos del emulador de referencia de esa
                // máquina: es donde va a buscar la BIOS o el firmware quien la necesite.
                dataFolder: machine.emulators.first?.dataFolder ?? machine.id
            ), custom)
        }
        for emulador in machine.emulators {
            for carpeta in applicationFolders {
                for nombre in emulador.bundleNames {
                    let app = carpeta.appendingPathComponent(nombre)
                    if fileManager.fileExists(atPath: app.path) { return (emulador, app) }
                }
            }
        }
        return nil
    }

    /// Si el firmware o la BIOS que esa máquina exige ya está puesto donde el emulador lo busca.
    ///
    /// Se comprueba **antes** de lanzar. Un emulador al que le falta su BIOS no da un error: abre
    /// una ventana negra, y el usuario se queda mirándola sin saber qué ha hecho mal.
    public static func hasFirmware(
        machine: StandaloneMachine, emulator: StandaloneEmulator, fileManager: FileManager = .default
    ) -> Bool {
        guard let firmware = machine.firmware else { return true }
        let carpeta = emulator.dataURL(fileManager: fileManager)

        // Primero, si el emulador desempaqueta el firmware en vez de guardarlo: entonces el
        // archivo original no está y lo que hay es una carpeta con lo que traía dentro. Se mira que
        // exista **y que tenga algo**, porque una carpeta vacía la crea el emulador al arrancar y
        // daría por instalado un firmware que nunca se puso.
        if let instalado = firmware.installedFolder {
            let dentro = (try? fileManager.contentsOfDirectory(
                atPath: carpeta.appendingPathComponent(instalado).path
            )) ?? []
            if !dentro.isEmpty { return true }
        }

        let dentro = (try? fileManager.contentsOfDirectory(atPath: carpeta.path)) ?? []
        // Los nombres pueden llevar comodín —una BIOS de PS2 es `SCPH-` y luego lo que sea—, así
        // que se compara por el trozo fijo y no por el nombre entero.
        return firmware.files.contains { patrón in
            let raíz = patrón.split(separator: "*").first.map(String.init) ?? patrón
            return dentro.contains { $0.lowercased().hasPrefix(raíz.lowercased()) }
                || subfolderContains(raíz, in: carpeta, fileManager: fileManager)
        }
    }

    /// Los emuladores guardan su BIOS en una subcarpeta —`bios`, `dev_flash`, `firmware`— y no
    /// suelta en la raíz. Se mira un nivel más adentro antes de decir que falta.
    private static func subfolderContains(
        _ prefix: String, in folder: URL, fileManager: FileManager
    ) -> Bool {
        for nombre in ["bios", "firmware", "dev_flash", "sys", "system"] {
            let dentro = (try? fileManager.contentsOfDirectory(
                atPath: folder.appendingPathComponent(nombre).path
            )) ?? []
            if dentro.contains(where: { $0.lowercased().hasPrefix(prefix.lowercased()) }) { return true }
        }
        return false
    }

    /// Abre el juego con el emulador.
    ///
    /// Como app y no como proceso hijo, por lo mismo que RetroArch: un programa con ventana
    /// arrancado con `Process` desde dentro de otra app se queda colgado antes de dibujar nada, sin
    /// dar ningún error. Y así además sale en el Dock y recibe el foco.
    ///
    /// A cambio no se sabe cuándo termina la partida. Es honesto: el juego no es un paso de Lever,
    /// es otro programa.
    @MainActor
    public static func open(app: URL, game: URL) throws {
        #if canImport(AppKit)
        let configuración = NSWorkspace.OpenConfiguration()
        configuración.arguments = [game.path]
        configuración.activates = true
        configuración.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuración)
        #endif
    }
}
