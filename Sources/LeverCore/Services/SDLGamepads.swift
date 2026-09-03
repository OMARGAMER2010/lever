import Foundation

/// Enumera los mandos **con la misma biblioteca que usa el emulador**, para saber con qué
/// identificador los va a ver él.
///
/// **Por qué no se puede calcular.** El emulador identifica un mando como `0-<GUID de SDL>`, y ese
/// GUID no es el par fabricante/modelo: lleva empaquetados un número de bus, un CRC del nombre del
/// dispositivo, el fabricante, el modelo, la versión y qué controlador de SDL lo está atendiendo.
///
/// Y el número de bus **no es el transporte de verdad**, que es la trampa que lo cierra. Medido en
/// este Mac: un DualSense conectado por Bluetooth da `030057564c050000e60c000000016800`, y ese
/// `0300` de delante es el código de USB. Lo pone así porque SDL lo atiende por su controlador
/// HIDAPI y ese normaliza el bus. Quien dedujera el `0500` de Bluetooth —que es lo que parece
/// razonable— escribiría un identificador equivocado.
///
/// No hay forma de construirlo a mano sin reimplementar SDL, y una reimplementación que se desvíe
/// en un byte produce un identificador que el archivo acepta y el emulador nunca reconoce:
/// controles mudos y ningún mensaje de error.
///
/// Así que se le pregunta a la biblioteca del propio emulador, que es la única respuesta que no es
/// una suposición. Y aun así **es el segundo sitio donde se busca**: si el `Config.json` ya tiene un
/// identificador guardado, ese lo escribió el emulador y es correcto por definición —ver
/// `EmulatorControls.knownPad`—.
///
/// **Solo se llaman funciones que devuelven texto o enteros.** El GUID se saca de la cadena de
/// correspondencia (`SDL_GameControllerMappingForDeviceIndex`), cuyo primer campo es justo el GUID
/// en hexadecimal, en vez de la función que lo devuelve como estructura de dieciséis bytes. Da lo
/// mismo, y evita tener que acertar a mano cómo se pasa una estructura por valor entre Swift y C:
/// equivocarse ahí no daría un error, daría bytes de basura escritos en la configuración ajena.
///
/// Se pide el subsistema de mandos y nada más: ni vídeo, ni audio, ni se abre ningún mando. No se
/// le quita a nadie y no aparece ninguna ventana.
public enum SDLGamepads {
    /// Un mando visto por SDL.
    public struct Device: Equatable, Sendable, Identifiable {
        /// Tal como lo escribe el emulador: `0-` y los treinta y dos dígitos del GUID.
        public let id: String
        public let name: String

        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// Los mandos que hay, preguntados a la biblioteca que lleva dentro esa aplicación.
    ///
    /// Devuelve vacío en cuanto algo no encaja —no está la biblioteca, falta un símbolo, el GUID no
    /// tiene la forma que debe—. Vacío significa «no lo sé», y quien llama tiene que tratarlo como
    /// tal: escribir un identificador inventado sería peor que no escribir nada.
    public static func enumerate(inside app: URL) -> [Device] {
        guard let biblioteca = open(inside: app) else { return [] }
        guard let arrancar = biblioteca.symbol(
                  "SDL_Init", as: (@convention(c) (UInt32) -> Int32).self),
              let soltar = biblioteca.symbol(
                  "SDL_QuitSubSystem", as: (@convention(c) (UInt32) -> Void).self),
              let cuántos = biblioteca.symbol(
                  "SDL_NumJoysticks", as: (@convention(c) () -> Int32).self),
              let correspondencia = biblioteca.symbol(
                  "SDL_GameControllerMappingForDeviceIndex",
                  as: (@convention(c) (Int32) -> UnsafeMutablePointer<CChar>?).self)
        else { return [] }

        // Sin manejadores de señales: esta biblioteca vive dentro de Lever, no al revés, y no le
        // toca decidir qué pasa cuando alguien interrumpe el proceso.
        if let hint = biblioteca.symbol(
            "SDL_SetHint",
            as: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self
        ) {
            "SDL_NO_SIGNAL_HANDLERS".withCString { clave in
                "1".withCString { valor in _ = hint(clave, valor) }
            }
        }

        let nombrePorÍndice = biblioteca.symbol(
            "SDL_GameControllerNameForIndex",
            as: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self)
        let nombreCrudo = biblioteca.symbol(
            "SDL_JoystickNameForIndex",
            as: (@convention(c) (Int32) -> UnsafePointer<CChar>?).self)
        let liberar = biblioteca.symbol(
            "SDL_free", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

        guard arrancar(initGameController) == 0 else { return [] }
        defer { soltar(initGameController) }

        return (0..<max(0, cuántos())).compactMap { índice -> Device? in
            guard let cadena = correspondencia(índice) else { return nil }
            defer { liberar?(UnsafeMutableRawPointer(cadena)) }
            guard let guid = self.guid(inMapping: String(cString: cadena)) else { return nil }
            let nombre = nombrePorÍndice?(índice).map { String(cString: $0) }
                ?? nombreCrudo?(índice).map { String(cString: $0) }
                ?? ""
            guard !nombre.isEmpty else { return nil }
            return Device(id: "0-\(guid)", name: nombre)
        }
    }

    // MARK: - El GUID

    /// El GUID que abre una cadena de correspondencia de SDL: `<guid>,<nombre>,<botones…>`.
    ///
    /// Se comprueba la forma antes de devolverlo. Treinta y dos dígitos hexadecimales en minúsculas
    /// y no todos cero: un mando desconectado a mitad de la enumeración da ceros, y treinta y dos
    /// ceros escritos en el archivo son un mando que no existe.
    public static func guid(inMapping mapping: String) -> String? {
        guard let primero = mapping.split(separator: ",", maxSplits: 1).first else { return nil }
        let texto = String(primero)
        guard texto.count == 32,
              texto.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              texto.contains(where: { $0 != "0" })
        else { return nil }
        return texto
    }

    // MARK: - Cargar la biblioteca

    /// `SDL_INIT_GAMECONTROLLER`, que arrastra el de mandos. Hace falta el de mandos «con forma»
    /// porque de ahí sale la cadena de correspondencia de donde se lee el GUID.
    private static let initGameController: UInt32 = 0x0000_2000

    /// Los dos nombres con los que aparece. El primero es el que trae la versión viva; el segundo,
    /// el que dejaron las anteriores.
    static let libraryNames = ["libSDL2.dylib", "libSDL2-2.0.0.dylib"]

    private static func open(inside app: URL) -> Library? {
        let marcos = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        for nombre in libraryNames {
            if let biblioteca = Library(path: marcos.appendingPathComponent(nombre).path) {
                return biblioteca
            }
        }
        return nil
    }

    /// Una biblioteca abierta. **No se cierra a propósito**: SDL registra trabajo para el final del
    /// proceso, y descargarla en caliente es la clase de fallo que aparece en el usuario y no aquí.
    /// Lo que se suelta es el subsistema, que es lo que de verdad ocupa algo.
    struct Library {
        let handle: UnsafeMutableRawPointer

        init?(path: String) {
            guard FileManager.default.fileExists(atPath: path),
                  let abierta = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            else { return nil }
            handle = abierta
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let dirección = dlsym(handle, name) else { return nil }
            return unsafeBitCast(dirección, to: type)
        }
    }
}
