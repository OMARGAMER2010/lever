import Foundation

/// Escribe la configuración con la que se lanza RetroArch.
///
/// Es un archivo aparte, no el del usuario. RetroArch acepta `-c` y usa **solo** ese, así que lo
/// que Lever decida sobre controles, ventana o dónde van las partidas guardadas no le pisa a nadie
/// su RetroArch de siempre. Es la misma idea que el «disco C:» propio de Wine.
public enum RetroConfig {
    /// Convierte un perfil de controles en las líneas que RetroArch entiende.
    ///
    /// El formato es `clave = "valor"`, una por línea. Cada control genera hasta tres claves —la
    /// del teclado, la del botón y la del eje— y las que no se asignan **se escriben vacías** en
    /// vez de omitirse: si se omiten, RetroArch deja la suya de fábrica y el usuario ve un botón
    /// que hace algo que él no pidió.
    public static func inputLines(for profile: ControlProfile, player: Int = 1) -> [String] {
        var líneas: [String] = []
        for control in RetroPadInput.allCases {
            let clave = "input_player\(player)_\(control.retroArchName)"
            líneas.append(línea(clave, valor: teclaDe(profile.keyboard[control])))

            let mando = profile.gamepad[control]
            líneas.append(línea("\(clave)_btn", valor: botónDe(mando)))
            líneas.append(línea("\(clave)_axis", valor: ejeDe(mando)))
        }
        return líneas
    }

    private static func línea(_ clave: String, valor: String) -> String {
        "\(clave) = \"\(valor)\""
    }

    private static func teclaDe(_ binding: ControlBinding?) -> String {
        if case .key(let tecla) = binding { return tecla }
        return "nul"
    }

    private static func botónDe(_ binding: ControlBinding?) -> String {
        switch binding {
        case .button(let número): return String(número)
        case .hat(let número, let dirección): return "h\(número)\(dirección)"
        default: return "nul"
        }
    }

    private static func ejeDe(_ binding: ControlBinding?) -> String {
        if case .axis(let eje) = binding { return eje }
        return "nul"
    }

    /// La configuración entera.
    ///
    /// Lleva solo lo que Lever decide. Todo lo demás lo rellena RetroArch con sus valores de
    /// fábrica al arrancar, que es lo que se quiere: cuanto menos se fije aquí, menos hay que
    /// mantener cuando RetroArch cambie.
    public static func makeConfig(
        profile: ControlProfile,
        platform: RetroPlatform?,
        saves: URL,
        states: URL,
        systemFiles: URL,
        data: URL,
        windowed: Bool = true,
        resumeSessions: Bool = true
    ) -> String {
        // **Una consola táctil va en ventana, aunque se pida pantalla completa.** RetroArch esconde
        // el cursor siempre que va a pantalla completa —`cocoa_show_mouse(data, !fullscreen)` en su
        // contexto de macOS, sin ajuste que lo evite—, y sin ver el puntero no hay forma de apuntar
        // a la pantalla de abajo: el clic llega, pero a ciegas. En ventana el cursor se ve.
        let enVentana = windowed || platform?.hasTouch == true
        var líneas: [String] = [
            "# Configuración escrita por Lever. No la edites a mano: se sobrescribe al lanzar.",
            línea("video_fullscreen", valor: enVentana ? "false" : "true"),
            // **Pantalla completa sin cambiar el modo del monitor.** La otra forma —cambiar la
            // resolución de verdad— deja el escritorio y las demás ventanas reordenadas al salir,
            // y si el emulador se cierra mal el Mac se queda en la resolución del juego. Una
            // ventana sin bordes del tamaño de la pantalla se ve igual y no toca nada.
            línea("video_windowed_fullscreen", valor: enVentana ? "false" : "true"),
            línea("savefile_directory", valor: saves.path),
            línea("savestate_directory", valor: states.path),
            // Donde el núcleo busca las BIOS que no se pueden descargar.
            línea("system_directory", valor: systemFiles.path),
            // **Nada dentro de `~/Documents`.** RetroArch guarda ahí sus listas y su historial, y
            // esa carpeta la protege macOS: lanzado desde otra app, el permiso no se puede pedir y
            // la lectura **se queda esperando para siempre**. El síntoma es una ventana que no
            // llega a abrirse y un registro que se corta en «Loading history file», sin error.
            // Con sus carpetas aquí, ni las toca.
            línea("playlist_directory", valor: data.appendingPathComponent("listas").path),
            línea("content_history_path", valor: data.appendingPathComponent("listas/historial.lpl").path),
            línea("content_favorites_path", valor: data.appendingPathComponent("listas/favoritos.lpl").path),
            línea("screenshot_directory", valor: data.appendingPathComponent("capturas").path),
            línea("cache_directory", valor: data.appendingPathComponent("cache").path),
            línea("content_database_path", valor: ""),
            // **Que RetroArch no escriba en este archivo.** Guarda su configuración entera al
            // salir, y la de Lever —sesenta líneas— vuelve convertida en tres mil trescientas con
            // todo lo que él tenía puesto. El siguiente lanzamiento ya no es el que Lever pidió:
            // en la prueba, dejaba de abrir ventana. Con esto, cada partida arranca igual.
            línea("config_save_on_exit", valor: "false"),
            // **`rgui` y no `ozone`.** Los menús bonitos de RetroArch necesitan un paquete de
            // recursos gráficos que su versión de Homebrew no trae, y sin él la ventana sale
            // **en negro**: no da ningún error, ni en pantalla ni en su registro, que se corta
            // justo después de «Found display driver». `rgui` va dibujado en el propio programa.
            línea("menu_driver", valor: "rgui"),
            // **El número de un botón solo significa algo dentro de su driver.** Lever los cuenta
            // como los cuenta `hid` sobre `iohidmanager` (ver `RetroPadNumbering`); con otro driver
            // el mismo número sería otro botón, y no habría ningún error que lo dijera. Es el que
            // RetroArch elige solo en un Mac, así que fijarlo no cambia nada hoy: lo que hace es
            // que no cambie mañana. Y si algún día no existiera, RetroArch coge el primero que
            // arranque en vez de quedarse sin mando.
            línea("input_joypad_driver", valor: "hid"),
            // Un emulador lanzado desde otra app no se queda con el foco, y RetroArch pausa el
            // juego cuando pierde la ventana: se abriría siempre parado, con el icono de pausa
            // y sin que nada explique por qué.
            línea("pause_nonactive", valor: "false"),
            // A tamaño 1 la ventana sale del tamaño de una consola de los ochenta, que en una
            // pantalla de hoy es un sello.
            línea("video_scale", valor: "3.000000"),
            // **La partida no se pierde al cerrar.** RetroArch solo vuelca la memoria de la pila
            // —la de los juegos que guardaban solos— al cerrar el contenido, así que un cierre a
            // lo bruto o un apagón se lleva todo lo hecho. Volcándola cada diez segundos, lo que
            // se pierde como mucho son diez segundos.
            línea("autosave_interval", valor: "10")
        ]

        // **Los atajos hay que escribirlos.** Una configuración pasada con `-c` que no los nombre
        // deja a RetroArch **sin ninguno**: no hereda los suyos de fábrica. Comprobado con la
        // tecla F —el atajo de pantalla completa de toda la vida— que no hacía nada hasta escribir
        // esta línea. Es la causa de que no se pudiera poner un juego a pantalla completa.
        //
        // Solo estos tres, y los tres con la tecla que RetroArch les da: son teclas que ninguna
        // disposición de juego usa, así que no le quitan nada al mando ni al teclado. Los demás
        // atajos se quedan fuera a propósito, y eso también resuelve un problema: varios caen en
        // letras que sí usa la disposición de fábrica —la `h` reinicia la partida, la `r` rebobina—
        // y sin declararlos no hay forma de dispararlos sin querer.
        líneas.append(línea("input_toggle_fullscreen", valor: "f"))
        líneas.append(línea("input_menu_toggle", valor: "f1"))
        // Salir por Escape no es una comodidad: es la forma de que el cierre sea **limpio**, y un
        // cierre limpio es el que guarda la partida. Matar la ventana a lo bruto no guarda nada.
        líneas.append(línea("input_exit_emulator", valor: "escape"))

        // Y el momento exacto: al cerrar se guarda un estado automático y al abrir se retoma ahí.
        // Es lo único que salva a las consolas **sin pila**, que son casi todas las de ocho bits:
        // ahí no hay nada que volcar, y sin esto cada sesión empieza desde el principio.
        líneas.append(línea("savestate_auto_save", valor: resumeSessions ? "true" : "false"))
        líneas.append(línea("savestate_auto_load", valor: resumeSessions ? "true" : "false"))

        // Una consola de dos pantallas se maneja con el dedo, y en un Mac el dedo es el puntero.
        //
        // Lo que decide si el dedo funciona **no está en este archivo**: es una opción del núcleo, y
        // RetroArch las guarda aparte. Mientras exista un archivo por núcleo —y existe en cuanto se
        // abre el menú una vez— manda ese y `core_options_path` se ignora, así que hay que apagar
        // las opciones por núcleo para que Lever pueda fijar la suya.
        //
        // Antes aquí se escribía `input_libretro_device_p1 = 1` creyendo que eso encendía el táctil.
        // No hace nada: melonDS declara un solo tipo de mando —«Nintendo DS», que es JOYPAD, o sea
        // el 1— y su `retro_set_controller_port_device` solo escribe una línea en el registro.
        if platform?.hasTouch == true {
            líneas.append(línea("input_player1_mouse_index", valor: "0"))
            líneas.append(línea("global_core_options", valor: "true"))
            líneas.append(línea("core_options_path", valor: coreOptionsURL(data: data).path))
        }

        líneas += inputLines(for: profile)
        líneas += mouseLines(for: platform)
        return líneas.joined(separator: "\n") + "\n"
    }

    /// Lo que hace el ratón además de ser el lápiz.
    ///
    /// En una consola táctil el puntero ya toca la pantalla, así que el botón derecho queda libre
    /// —la mano ya está ahí— y se le da lo que más se usa con el lápiz puesto: cambiar las
    /// pantallas de sitio. Va por núcleo porque el botón que hace eso es cosa suya: en melonDS es
    /// R2, y en el de la 3DS ese mismo R2 es un gatillo de verdad.
    ///
    /// Los números son los de RetroArch: 1 el izquierdo, 2 el derecho, 3 el de la rueda.
    public static let mouseButtons: [String: [RetroPadInput: Int]] = [
        "melonds": [.r2: 2]
    ]

    static func mouseLines(for platform: RetroPlatform?, player: Int = 1) -> [String] {
        guard let platform, let botones = mouseButtons[platform.core] else { return [] }
        return botones
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { línea("input_player\(player)_\($0.key.retroArchName)_mbtn", valor: String($0.value)) }
    }

    // MARK: - Opciones de los núcleos

    /// Donde Lever guarda las opciones de los núcleos, junto al resto de lo suyo.
    public static func coreOptionsURL(data: URL) -> URL {
        data.appendingPathComponent("opciones-nucleo.cfg")
    }

    /// Lo que hace que la pantalla de abajo responda al puntero, por núcleo.
    ///
    /// Los dos núcleos de DS vienen de fábrica en modo «ratón», que lee **desplazamientos**: llevan
    /// un cursor propio y tocan donde esté ese cursor, no donde apuntas. En un Mac, donde el cursor
    /// del sistema está escondido mientras se juega, eso se ve como que hacer clic sobre la pantalla
    /// no hace nada. El modo de puntero lee la posición **absoluta**, que es lo que espera
    /// cualquiera: se toca donde se pincha.
    public static let touchOptions: [String: [String: String]] = [
        "melonds": ["melonds_touch_mode": "Touch"],
        "desmume": ["desmume_pointer_type": "touch"]
    ]

    /// Deja escritas las opciones que Lever necesita **sin pisar** las que haya elegido la persona:
    /// solo añade las claves que falten. Así se puede cambiar el modo desde el menú de RetroArch y
    /// la siguiente partida lo respeta. Devuelve si hizo falta escribir.
    @discardableResult
    public static func mergeCoreOptions(
        for platform: RetroPlatform?,
        data: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let platform, platform.hasTouch, let deseadas = touchOptions[platform.core] else { return false }
        let url = coreOptionsURL(data: data)
        var texto = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let presentes = Set(texto.split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        })
        var escribió = false
        for (clave, valor) in deseadas.sorted(by: { $0.key < $1.key }) where !presentes.contains(clave) {
            if !texto.isEmpty, !texto.hasSuffix("\n") { texto += "\n" }
            texto += línea(clave, valor: valor) + "\n"
            escribió = true
        }
        guard escribió else { return false }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}

/// Guarda y recupera los perfiles de control del usuario.
///
/// Tres niveles, del más general al más concreto: lo global, lo de una máquina y lo de un juego.
/// Al lanzar gana el más concreto que exista, que es como la gente espera que funcione: «esto lo
/// tengo así en general, menos en la Nintendo 64, menos en este juego».
public final class ControlLibrary: @unchecked Sendable {
    public static let shared = ControlLibrary()

    private let fileManager: FileManager
    private let customRoot: URL?

    public init(fileManager: FileManager = .default, root: URL? = nil) {
        self.fileManager = fileManager
        self.customRoot = root
    }

    public var folderURL: URL {
        if let customRoot { return customRoot }
        let soporte = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return soporte.appendingPathComponent("Lever/controles", isDirectory: true)
    }

    public func save(_ profile: ControlProfile, for scope: ControlScope) throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let datos = try JSONEncoder().encode(profile)
        try datos.write(to: folderURL.appendingPathComponent(scope.fileName))
    }

    public func load(_ scope: ControlScope) -> ControlProfile? {
        let archivo = folderURL.appendingPathComponent(scope.fileName)
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return try? JSONDecoder().decode(ControlProfile.self, from: datos)
    }

    public func remove(_ scope: ControlScope) {
        try? fileManager.removeItem(at: folderURL.appendingPathComponent(scope.fileName))
    }

    /// El perfil que de verdad se va a usar para un juego: el más concreto que exista, y si no hay
    /// ninguno, el estándar.
    public func resolved(platform: RetroPlatform?, gameName: String?) -> ControlProfile {
        if let gameName, let propio = load(.game(gameName)) { return propio }
        if let platform, let deLaMáquina = load(.platform(platform.id)) { return deLaMáquina }
        return load(.global) ?? .standard
    }

    /// Qué nivel está mandando ahora mismo, para poder decirlo en la interfaz en vez de dejar al
    /// usuario adivinando por qué sus cambios no se ven.
    public func effectiveScope(platform: RetroPlatform?, gameName: String?) -> ControlScope {
        if let gameName, load(.game(gameName)) != nil { return .game(gameName) }
        if let platform, load(.platform(platform.id)) != nil { return .platform(platform.id) }
        return .global
    }
}

/// Los `[RetroPadInput: ControlBinding]` no se codifican solos: un diccionario con clave que no es
/// `String` se guarda como una lista plana, y entonces el archivo no hay quien lo lea ni lo
/// arregle a mano. Con esto se guarda como un objeto de verdad.
extension RetroPadInput: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

struct StringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
