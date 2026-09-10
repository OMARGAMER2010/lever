import Foundation

/// Obtiene los bytes del GUID de la SDL del emulador. No se deducen del fabricante ni del
/// transporte: SDL normaliza el bus y añade datos propios. Swift consulta una función que devuelve
/// texto para evitar un retorno de estructura incompatible con @convention(c).
///
/// El texto de SDL aún no es el identificador de Ryujinx. En 1.3.3 se convierte como System.Guid
/// y se normaliza el CRC; la prueba integrada confirmó esa diferencia. Un identificador antiguo
/// guardado por Lever puede contener el formato equivocado, así que se prefiere enumerar de nuevo.
public enum SDLGamepads {
    /// Un mando visto por SDL.
    public struct Device: Equatable, Sendable, Identifiable {
        /// Identificador de Ryujinx, con índice y GUID convertido al formato de System.Guid.
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
            guard let id = ryujinx133ID(forSDLGuid: guid) else { return nil }
            return Device(id: id, name: nombre)
        }
    }

    // MARK: - El GUID

    /// SDL devuelve bytes; Ryujinx 1.3.3 los recibe como System.Guid, que cambia el orden de los
    /// tres primeros grupos al imprimirlos, añade guiones y normaliza el CRC. Es una conversión
    /// del identificador enumerado, no un GUID inventado. La prueba integrada abrió el mando con
    /// este formato; ni el hexadecimal de SDL ni cambiar solo su prefijo lo abrían.
    public static func ryujinx133ID(forSDLGuid guid: String) -> String? {
        guard self.guid(inMapping: guid + ",") != nil else { return nil }
        let letras = Array(guid)
        let bytes = stride(from: 0, to: 32, by: 2).map { String(letras[$0...($0 + 1)]) }
        let orden = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
        var texto = ""
        for (posición, índice) in orden.enumerated() {
            if [4, 6, 8, 10].contains(posición) { texto += "-" }
            texto += bytes[índice]
        }
        return "0-0000" + texto.dropFirst(4)
    }

    public static func supportsMouseBridge(inside app: URL) -> Bool {
        // El número corto del bundle instalado dice 1.2 aunque el programa es 1.3.3. La cadena
        // larga lleva la versión y el commit reales; no usamos la etiqueta corta para adivinar.
        let versión = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleLongVersionString") as? String
        return versión?.hasPrefix("1.3.3-") == true || versión == "1.3.3"
    }

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
