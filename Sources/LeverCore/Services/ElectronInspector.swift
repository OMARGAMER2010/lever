import Foundation

/// Reconoce los juegos hechos con Electron y averigua qué versión del motor necesitan.
///
/// La firma es `resources/app.asar` al lado del `.exe`. Es la que usa el propio Electron para
/// encontrar el código de la app, y ningún otro motor de los contemplados reparte así.
public enum ElectronInspector {
    public static func inspect(program: URL, fileManager: FileManager = .default) -> ElectronGame? {
        let root = program.deletingLastPathComponent()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let asar = resources.appendingPathComponent("app.asar")
        guard fileManager.fileExists(atPath: asar.path) else { return nil }
        guard let (version, origen) = engineVersion(in: root, executable: program, fileManager: fileManager)
        else { return nil }

        let entradas = resourceEntries(in: resources, fileManager: fileManager)
        return ElectronGame(
            executable: program,
            root: root,
            engineVersion: version,
            versionOrigin: origen,
            asar: asar,
            productName: productName(inside: asar),
            resourceEntries: entradas,
            gameBytes: size(of: entradas, in: resources, fileManager: fileManager),
            nativeModules: nativeModules(in: resources, asar: asar, fileManager: fileManager),
            appleSilicon: GodotInspector.hostArch == "arm64"
        )
    }

    // MARK: - Versión del motor

    /// Primero el archivo `version` de la raíz; si no está, la cadena que queda dentro del
    /// ejecutable.
    ///
    /// **El recurso de versión del PE no sirve, y no es una precaución teórica**: comprobado con
    /// `electron-packager`, que renombra `electron.exe` al nombre del juego y de paso le reescribe
    /// el recurso con la versión *del juego*. Un reparto de Electron 44 declara ahí «1.0.0.0».
    public static func engineVersion(
        in root: URL,
        executable: URL,
        fileManager: FileManager = .default
    ) -> (ElectronVersion, ElectronVersionOrigin)? {
        let archivo = root.appendingPathComponent("version")
        if let texto = try? String(contentsOf: archivo, encoding: .utf8),
           let version = ElectronVersion(texto.trimmingCharacters(in: CharacterSet(charactersIn: "v \n\r\t"))) {
            return (version, .versionFile)
        }
        if let version = versionInsideBinary(executable) { return (version, .embeddedString) }
        return nil
    }

    /// Busca `Electron/<X.Y.Z>` dentro del ejecutable.
    ///
    /// Se lee por trozos porque el binario pasa de los doscientos megas y la cadena cae por el
    /// último tercio. El solape entre trozos evita perderla si cae justo en la juntura.
    public static func versionInsideBinary(_ executable: URL) -> ElectronVersion? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }

        let aguja = Data("Electron/".utf8)
        let solape = aguja.count + 24
        var cola = Data()
        while let trozo = try? handle.read(upToCount: 8 << 20), !trozo.isEmpty {
            let bloque = cola + trozo
            if let version = primeraVersion(en: bloque, aguja: aguja) { return version }
            cola = bloque.suffix(solape)
        }
        return nil
    }

    /// La búsqueda se hace con `range(of:)` y no a mano: recorrer doscientos megas comparando
    /// rebanadas byte a byte tarda minutos, y esto es una función que corre al elegir un archivo.
    private static func primeraVersion(en datos: Data, aguja: Data) -> ElectronVersion? {
        var desde = datos.startIndex
        while let encontrado = datos.range(of: aguja, in: desde..<datos.endIndex) {
            let resto = datos[encontrado.upperBound...].prefix(24)
            let cifras = resto.prefix { $0 == 46 || ($0 >= 48 && $0 <= 57) }
            if let version = ElectronVersion(String(decoding: cifras, as: UTF8.self)) { return version }
            desde = encontrado.upperBound
        }
        return nil
    }

    // MARK: - Lo que dice el juego de sí mismo

    /// `productName` del `package.json` de dentro del `.asar`. Es el nombre que el autor escribió
    /// para que se viera; el `name` es el del paquete de npm y suele ser un identificador feo.
    public static func productName(inside asar: URL) -> String? {
        guard let datos = AsarArchive.read("package.json", from: asar),
              let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return nil }
        return (json["productName"] as? String) ?? nil
    }

    // MARK: - Módulos nativos

    /// Los `.node` que el juego trae compilados para Windows.
    ///
    /// Se buscan en los dos sitios donde pueden estar: sueltos en `app.asar.unpacked/` —que es lo
    /// normal, porque `dlopen` no sabe abrir una librería metida dentro de otro archivo— y dentro
    /// del propio `.asar`, por si el empaquetador no los sacó.
    public static func nativeModules(
        in resources: URL,
        asar: URL,
        fileManager: FileManager = .default
    ) -> [NodeNativeModule] {
        var rutas: [String] = []

        let desempaquetado = resources.appendingPathComponent("app.asar.unpacked", isDirectory: true)
        if let walker = fileManager.enumerator(at: desempaquetado, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "node" {
                if let relativa = PortPaths.relativePath(of: url, from: desempaquetado) { rutas.append(relativa) }
            }
        }
        for entrada in AsarArchive.entries(of: asar) ?? [] where entrada.path.hasSuffix(".node") {
            if !rutas.contains(entrada.path) { rutas.append(entrada.path) }
        }

        var vistos: Set<String> = []
        var salida: [NodeNativeModule] = []
        for ruta in rutas.sorted() {
            let nombre = moduleName(inPath: ruta) ?? (ruta as NSString).lastPathComponent
            guard vistos.insert(nombre).inserted else { continue }
            salida.append(NodeNativeModule(
                name: nombre,
                version: moduleVersion(of: nombre, inside: asar),
                relativePath: ruta
            ))
        }
        return salida
    }

    /// El nombre del paquete sale de la ruta: lo que va detrás del último `node_modules/`, y dos
    /// segmentos si es un paquete con ámbito (`@scope/nombre`).
    public static func moduleName(inPath ruta: String) -> String? {
        let partes = ruta.split(separator: "/").map(String.init)
        guard let indice = partes.lastIndex(of: "node_modules"), indice + 1 < partes.count else { return nil }
        let primero = partes[indice + 1]
        if primero.hasPrefix("@"), indice + 2 < partes.count { return primero + "/" + partes[indice + 2] }
        return primero
    }

    /// La versión sale del `package.json` del módulo, que casi siempre sigue dentro del `.asar`
    /// aunque su `.node` esté fuera: el empaquetador solo saca los binarios.
    static func moduleVersion(of nombre: String, inside asar: URL) -> String? {
        guard let datos = AsarArchive.read("node_modules/\(nombre)/package.json", from: asar),
              let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    // MARK: - Qué viaja al `.app`

    /// Todo lo de `resources/` menos el `default_app.asar`, que es la app de bienvenida del propio
    /// Electron y no pinta nada en un juego.
    static func resourceEntries(in resources: URL, fileManager: FileManager = .default) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0 != "default_app.asar" && !$0.hasPrefix(".") }
            .sorted()
    }

    static func size(of entries: [String], in folder: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        for entry in entries {
            let url = folder.appendingPathComponent(entry)
            var esCarpeta: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &esCarpeta) else { continue }
            if !esCarpeta.boolValue {
                total += (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0) ?? 0
                continue
            }
            guard let walker = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in walker {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
