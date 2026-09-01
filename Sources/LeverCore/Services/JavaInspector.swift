import Foundation

/// Reconoce los juegos de Java y averigua qué hace falta para que arranquen en un Mac.
///
/// La firma es un jar con `Main-Class` en su manifiesto: pegado al final del `.exe` —lo que hace
/// Launch4j— o suelto al lado. Un `.exe` sin eso no tiene nada que lanzar, y un jar sin
/// `Main-Class` es una librería, no un juego.
public enum JavaInspector {
    public static func inspect(program: URL, fileManager: FileManager = .default) -> JavaGame? {
        let root = program.deletingLastPathComponent()

        guard let launchJar = locateLaunchJar(for: program, in: root, fileManager: fileManager),
              let manifest = manifest(inside: launchJar.container),
              let mainClass = manifest["Main-Class"], !mainClass.isEmpty else { return nil }

        guard let required = requiredJava(mainClass: mainClass, jar: launchJar.container,
                                          root: root, fileManager: fileManager) else { return nil }

        let entries = gameEntries(in: root, executable: program, fileManager: fileManager)
        return JavaGame(
            executable: program,
            root: root,
            launchJar: launchJar,
            mainClass: mainClass,
            gameEntries: entries,
            gameBytes: size(of: entries, in: root, fileManager: fileManager),
            required: required.feature,
            requiredFrom: required.origin,
            lwjgl: lwjglNatives(in: root, fileManager: fileManager),
            windowsLibraries: windowsLibraries(in: root, fileManager: fileManager),
            appleSilicon: GodotInspector.hostArch == "arm64"
        )
    }

    // MARK: - Localizar el jar que arranca

    static func locateLaunchJar(
        for program: URL,
        in root: URL,
        fileManager: FileManager = .default
    ) -> JavaLaunchJar? {
        // Launch4j deja su lanzador nativo delante y el jar detrás, sin ningún pie que lo diga:
        // se busca igual que el `.love` de LÖVE, por el final del directorio central del ZIP.
        if let start = ZipTrailer.archiveStart(of: program), start > 0,
           manifest(inside: program)?["Main-Class"] != nil {
            return .fused(program, offset: start)
        }

        let jars = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jar" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let arrancables = jars.filter { manifest(inside: $0)?["Main-Class"] != nil }
        guard !arrancables.isEmpty else { return nil }

        // Con varios, el que se llama como el `.exe`. Es la convención de Launch4j cuando deja el
        // jar fuera, y sin ella no hay forma de saber cuál de los dos quería el desarrollador.
        let esperado = program.deletingPathExtension().lastPathComponent.lowercased()
        if let elegido = arrancables.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == esperado
        }) { return .sibling(elegido) }
        return arrancables.count == 1 ? .sibling(arrancables[0]) : nil
    }

    // MARK: - Qué versión de Java hace falta

    struct Requirement { let feature: JavaFeature; let origin: JavaRequirementOrigin }

    static func requiredJava(
        mainClass: String,
        jar: URL,
        root: URL,
        fileManager: FileManager = .default
    ) -> Requirement? {
        // El `jre/` que trae el juego vale más que el bytecode: dice con qué lo probó su autor, no
        // con qué mínimo compila.
        if let release = try? String(contentsOf: root.appendingPathComponent("jre/release"), encoding: .utf8),
           let feature = featureVersion(inRelease: release) {
            return Requirement(feature: feature, origin: .bundledRuntime)
        }

        let ruta = mainClass.replacingOccurrences(of: ".", with: "/") + ".class"
        guard let clase = read(entry: ruta, from: jar), clase.count >= 8,
              clase.prefix(4).elementsEqual([0xCA, 0xFE, 0xBA, 0xBE]) else { return nil }
        let major = Int(clase[clase.startIndex + 6]) << 8 | Int(clase[clase.startIndex + 7])
        guard let feature = JavaFeature.readingClassFile(major: major) else { return nil }
        return Requirement(feature: feature, origin: .classFile)
    }

    /// `JAVA_VERSION="17.0.2"` en las modernas y `JAVA_VERSION="1.8.0_292"` en Java 8, donde el
    /// número que importa es el segundo.
    public static func featureVersion(inRelease texto: String) -> JavaFeature? {
        guard let linea = texto.split(separator: "\n").first(where: { $0.hasPrefix("JAVA_VERSION=") })
        else { return nil }
        let valor = linea.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"\r "))
        let partes = valor.split(separator: ".")
        guard let primera = partes.first, let numero = Int(primera) else { return nil }
        if numero == 1 {
            guard partes.count > 1, let segunda = Int(partes[1]) else { return nil }
            return JavaFeature(segunda)
        }
        return JavaFeature(numero)
    }

    // MARK: - Librerías nativas

    /// Jars de nativos de LWJGL compilados para Windows.
    ///
    /// Se reconocen por `LWJGL-Platform` en su manifiesto, no por el nombre del archivo: el nombre
    /// lo pone Maven, pero nada impide que un reparto lo cambie, y el manifiesto lo escribe LWJGL.
    public static func lwjglNatives(in root: URL, fileManager: FileManager = .default) -> [LwjglNatives] {
        var encontrados: [LwjglNatives] = []
        for jar in jars(in: root, fileManager: fileManager) {
            guard let manifiesto = manifest(inside: jar),
                  let plataforma = manifiesto["LWJGL-Platform"], plataforma.hasPrefix("windows"),
                  let modulo = manifiesto["Implementation-Title"],
                  // `Implementation-Version` aquí pone «build 1»: no sirve para nombrar la descarga.
                  let version = manifiesto["Specification-Version"] else { continue }
            guard let relativa = PortPaths.relativePath(of: jar, from: root) else { continue }
            encontrados.append(LwjglNatives(module: modulo, version: version, relativePath: relativa))
        }
        return encontrados.sorted { $0.relativePath < $1.relativePath }
    }

    /// Binarios de Windows sueltos en la carpeta. Al revés que los de LWJGL, estos no tienen de
    /// dónde bajarse: son código que alguien compiló una vez y solo para Windows.
    public static func windowsLibraries(in root: URL, fileManager: FileManager = .default) -> [String] {
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: Set<String> = []
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants() }
            // El `jre/` de Windows se tira entero y se sustituye: sus DLL no son del juego.
            if url.lastPathComponent == "jre", url.hasDirectoryPath { walker.skipDescendants(); continue }
            if ["dll", "so"].contains(url.pathExtension.lowercased()) { found.insert(url.lastPathComponent) }
        }
        return found.sorted()
    }

    // MARK: - Qué viaja al `.app`

    static func gameEntries(in root: URL, executable: URL, fileManager: FileManager = .default) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != executable.lastPathComponent && $0 != "jre" && !$0.hasPrefix(".") }
            .sorted()
    }

    static func size(of entries: [String], in root: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        for entry in entries {
            let url = root.appendingPathComponent(entry)
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

    static func jars(in root: URL, fileManager: FileManager) -> [URL] {
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants() }
            if url.pathExtension.lowercased() == "jar" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Leer de dentro de un jar

    /// El manifiesto de un jar, ya desdoblado.
    ///
    /// `unzip` lee igual un jar suelto que uno pegado detrás de un ejecutable: avisa de los bytes
    /// de más y sigue. Eso ahorra tener que extraer el jar de dentro del `.exe` solo para mirarlo.
    public static func manifest(inside jar: URL) -> [String: String]? {
        guard let datos = read(entry: "META-INF/MANIFEST.MF", from: jar),
              let texto = String(data: datos, encoding: .utf8) else { return nil }
        return parseManifest(texto)
    }

    /// Un manifiesto parte las líneas a 72 bytes y sigue en la siguiente con un espacio delante.
    /// Leerlo línea a línea sin volver a juntarlas parte los classpath por la mitad.
    public static func parseManifest(_ texto: String) -> [String: String] {
        var pares: [String: String] = [:]
        var clave: String?
        var valor = ""
        func guarda() {
            if let clave, !clave.isEmpty { pares[clave] = valor }
            clave = nil
            valor = ""
        }
        for linea in texto.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                             omittingEmptySubsequences: false) {
            if linea.hasPrefix(" ") {
                valor += linea.dropFirst()
            } else {
                guarda()
                guard let corte = linea.firstIndex(of: ":") else { continue }
                clave = String(linea[linea.startIndex..<corte])
                valor = String(linea[linea.index(after: corte)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guarda()
        return pares
    }

    static func read(entry: String, from jar: URL) -> Data? {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proceso.arguments = ["-p", jar.path, entry]
        let tuberia = Pipe()
        proceso.standardOutput = tuberia
        proceso.standardError = FileHandle.nullDevice
        guard (try? proceso.run()) != nil else { return nil }
        let datos = try? tuberia.fileHandleForReading.readToEnd()
        proceso.waitUntilExit()
        // `unzip` sale con 1 —aviso, no error— cuando el ZIP lleva algo delante, que es justo el
        // caso de Launch4j: avisa de los bytes de más y extrae bien igual. Exigirle un 0 deja
        // fuera precisamente el reparto que había que reconocer. De 2 en adelante sí son fallos.
        guard proceso.terminationStatus <= 1, let datos, !datos.isEmpty else { return nil }
        return datos
    }
}
