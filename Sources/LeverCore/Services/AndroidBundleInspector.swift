import Foundation

/// Abre los formatos que envuelven varios `.apk` y dice qué hay dentro.
///
/// Por qué a mano y no con `bundletool` para todos: un `.xapk` es un ZIP con los trozos ya
/// repartidos y una ficha JSON al lado —no hace falta nada para leerlo—, mientras que un `.apks`
/// guarda en un `toc.pb` en protobuf la tabla de qué variante le toca a cada aparato, y esa
/// tabla la escribe `bundletool` y la entiende `bundletool`. Aquí se lee lo que se puede leer sin
/// inventar, y lo demás se le pasa a su dueño.
///
/// Igual que en `ApkInspector`, todo lo que sale de aquí está en el archivo: el `manifest.json`
/// de un `.xapk` lo escribe quien lo empaquetó y a veces miente, así que sirve para la lista de
/// trozos y de expansiones —eso solo está ahí— pero los datos de la app se sacan abriendo el
/// `.apk` que hace de base.
public enum AndroidBundleInspector {
    public static func inspect(_ url: URL) -> AndroidPackage {
        guard let kind = AndroidPackageKind.fromExtension(url.pathExtension) else {
            return AndroidPackage(kind: .apk, readFailed: true)
        }

        guard kind.isBundle else {
            return AndroidPackage(
                kind: .apk,
                facts: ApkInspector.inspect(url),
                signature: ApkInspector.signature(of: url)
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: url),
              let archive = try? ZipDirectory.read(from: handle), !archive.entries.isEmpty else {
            return AndroidPackage(kind: kind, readFailed: true)
        }
        defer { try? handle.close() }

        return kind == .aab
            ? inspectBundle(archive.entries, kind: kind)
            : inspectSplitSet(archive.entries, handle: handle, kind: kind)
    }

    // MARK: - Envoltorios con `.apk` dentro

    private static func inspectSplitSet(
        _ entries: [ZipDirectory.Entry], handle: FileHandle, kind: AndroidPackageKind
    ) -> AndroidPackage {
        let apkEntries = entries.filter {
            $0.name.lowercased().hasSuffix(".apk") && !$0.name.hasSuffix("/")
        }
        guard !apkEntries.isEmpty else { return AndroidPackage(kind: kind, readFailed: true) }

        let ficha = entries
            .first { $0.name == "manifest.json" || $0.name == "info.json" }
            .flatMap { try? ZipDirectory.contents(of: $0, from: handle) }
            .flatMap(XapkManifest.parse)

        let baseEntry = chooseBase(among: apkEntries, declared: ficha?.baseFileName)
        let parts = apkEntries.map { entry -> AndroidPart in
            let declarado = ficha?.splitIds[entry.name]
                ?? ficha?.splitIds[URL(fileURLWithPath: entry.name).lastPathComponent]
            let splitId = entry.name == baseEntry?.name
                ? nil
                : (declarado ?? splitId(forEntryNamed: entry.name))
            return AndroidPart(
                entryName: entry.name,
                splitId: splitId,
                role: AndroidSplitChooser.role(forSplitId: splitId),
                size: entry.uncompressedSize
            )
        }

        // La base se saca a un archivo y se lee con el mismo lector que un `.apk` suelto: es la
        // única forma de saber el paquete, los ABI y en qué postura arranca sin fiarse de la
        // ficha. Se borra en cuanto se ha leído.
        var facts = baseEntry.flatMap { readFacts(of: $0, from: handle) } ?? ApkFacts()
        if facts.readFailed || facts.packageName == nil, let ficha {
            facts = ficha.facts(mixedWith: facts)
        }

        return AndroidPackage(
            kind: kind,
            facts: facts,
            parts: parts.sorted { $0.entryName < $1.entryName },
            expansions: expansions(in: entries, packageName: facts.packageName),
            // Los trozos vienen firmados por quien los generó; el envoltorio no se firma.
            signature: .unknown
        )
    }

    /// Cuál de los `.apk` es la app y cuáles son sus trozos.
    ///
    /// Por capas, de lo más fiable a lo menos: lo que declare la ficha; el que se llame
    /// `base.apk`; el que `bundletool` llama `…-master.apk`; y si nada de eso, el único que no
    /// parece un trozo de configuración —hay `.xapk` viejos donde la base se llama con el nombre
    /// del paquete, `com.ejemplo.juego.apk`—.
    private static func chooseBase(
        among entries: [ZipDirectory.Entry], declared: String?
    ) -> ZipDirectory.Entry? {
        func nombre(_ entry: ZipDirectory.Entry) -> String {
            URL(fileURLWithPath: entry.name).lastPathComponent
        }

        if let declared,
           let match = entries.first(where: { $0.name == declared || nombre($0) == declared }) {
            return match
        }
        if let match = entries.first(where: { nombre($0).caseInsensitiveCompare("base.apk") == .orderedSame }) {
            return match
        }
        // Entre los `…-master.apk` manda el que no lleva sufijo de variante. `bundletool` repite
        // cada trozo una vez por variante —la misma app compilada para distintos Android— y les
        // pone `_2`, `_3` para que no choquen los nombres. La primera es la del Android más
        // antiguo, así que es de la que hay que leer el mínimo: leerlo de la `_3` diría que la
        // app pide Android 12 cuando en realidad se instala desde el 7.
        let maestros = entries.filter { nombre($0).hasSuffix("-master.apk") }
        if let match = maestros.first(where: { variantSuffix(in: nombre($0)) == nil })
            ?? maestros.sorted(by: { nombre($0) < nombre($1) }).first {
            return match
        }
        let sueltos = entries.filter { splitId(forEntryNamed: $0.name) == nil }
        if let match = sueltos.max(by: { $0.uncompressedSize < $1.uncompressedSize }) { return match }
        return entries.max(by: { $0.uncompressedSize < $1.uncompressedSize })
    }

    private static func readFacts(of entry: ZipDirectory.Entry, from handle: FileHandle) -> ApkFacts? {
        let carpeta = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lever-apk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: carpeta) }

        let destino = carpeta.appendingPathComponent("base.apk")
        guard (try? ZipDirectory.extract(entry, from: handle, to: destino)) != nil else { return nil }
        return ApkInspector.inspect(destino)
    }

    /// Los `.obb` que viajan dentro del envoltorio. La ruta dice a qué paquete pertenecen, y esa
    /// es la que hay que respetar en el aparato: Android solo los busca ahí.
    private static func expansions(
        in entries: [ZipDirectory.Entry], packageName: String?
    ) -> [AndroidExpansion] {
        entries.compactMap { entry in
            guard entry.name.lowercased().hasSuffix(".obb") else { return nil }
            let tramos = entry.name.split(separator: "/").map(String.init)
            guard let archivo = tramos.last else { return nil }

            // `Android/obb/<paquete>/<archivo>.obb` es la forma normal. Si el `.obb` viene suelto
            // se le atribuye al paquete que se haya leído del `.apk`, que es de quien puede ser.
            let carpeta = tramos.count >= 2 ? tramos[tramos.count - 2] : nil
            guard let dueño = (carpeta.flatMap { $0.contains(".") ? $0 : nil }) ?? packageName else {
                return nil
            }
            return AndroidExpansion(
                entryName: entry.name, packageName: dueño, fileName: archivo, size: entry.uncompressedSize
            )
        }
    }

    // MARK: - App Bundle

    /// De un `.aab` se lee poco a propósito: su manifiesto está en protobuf, no en el formato
    /// binario de Android, y adivinarlo sería inventar. Lo que sí está a la vista son los módulos
    /// y para qué procesadores trae código; el resto lo dirá `bundletool` cuando genere los
    /// `.apk`, que es cuando de verdad se sabe.
    private static func inspectBundle(_ entries: [ZipDirectory.Entry], kind: AndroidPackageKind) -> AndroidPackage {
        var abis: [String] = []
        var modules: Set<String> = []

        for entry in entries {
            let tramos = entry.name.split(separator: "/").map(String.init)
            guard tramos.count >= 2 else { continue }
            let modulo = tramos[0]
            guard modulo != "BUNDLE-METADATA", modulo != "META-INF" else { continue }
            modules.insert(modulo)

            if tramos.count >= 3, tramos[1] == "lib", !abis.contains(tramos[2]) {
                abis.append(tramos[2])
            }
        }
        guard modules.contains("base") else { return AndroidPackage(kind: kind, readFailed: true) }

        return AndroidPackage(
            kind: kind,
            facts: ApkFacts(abis: abis.sorted(by: AndroidAbi.isBefore)),
            extraModules: modules.subtracting(["base"]).sorted()
        )
    }

    // MARK: - Sacar los trozos

    /// Saca del envoltorio las entradas que se piden, cada una a un archivo dentro de `folder`.
    ///
    /// Devuelve las rutas en el mismo orden en que se pidieron, que en una instalación importa:
    /// la base va delante.
    @discardableResult
    public static func extract(
        entryNames: [String], of url: URL, into folder: URL, fileManager: FileManager = .default
    ) throws -> [URL] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ZipDirectory.Failure.malformed }
        defer { try? handle.close() }
        let archive = try ZipDirectory.read(from: handle)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        return try entryNames.map { name in
            guard let entry = archive.entries.first(where: { $0.name == name }) else {
                throw ZipDirectory.Failure.malformed
            }
            // Aplanado a propósito: dentro de un `.xapk` los trozos cuelgan de carpetas que aquí
            // no sirven para nada, y `adb install-multiple` recibe rutas sueltas.
            let destino = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            try ZipDirectory.extract(entry, from: handle, to: destino)
            return destino
        }
    }
}

/// La ficha que acompaña a un `.xapk` (`manifest.json`) o a un `.apkm` (`info.json`).
///
/// No es una fuente de verdad: la escribe quien empaqueta. Vale para dos cosas que no están en
/// ningún otro sitio —qué trozos hay y qué expansiones— y como respaldo si el `.apk` de base no
/// se deja leer.
struct XapkManifest {
    var packageName: String?
    var versionName: String?
    var versionCode: Int?
    var minSdk: Int?
    /// Nombre de archivo del trozo → identificador que declara la ficha.
    var splitIds: [String: String] = [:]
    var baseFileName: String?

    static func parse(_ data: Data) -> XapkManifest? {
        guard let raíz = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var ficha = XapkManifest()

        ficha.packageName = raíz["package_name"] as? String ?? raíz["pname"] as? String
        ficha.versionName = texto(raíz["version_name"]) ?? texto(raíz["release_version"])
        ficha.versionCode = número(raíz["version_code"]) ?? número(raíz["versioncode"])
        ficha.minSdk = número(raíz["min_sdk_version"]) ?? número(raíz["min_api"])

        // `.xapk` los llama `split_apks`; `.apkm`, `apk_list`. La forma de dentro es la misma.
        let trozos = (raíz["split_apks"] as? [[String: Any]]) ?? (raíz["apk_list"] as? [[String: Any]]) ?? []
        for trozo in trozos {
            guard let archivo = trozo["file"] as? String else { continue }
            let identificador = trozo["id"] as? String
            if identificador == nil || identificador == "base" {
                ficha.baseFileName = archivo
            }
            if let identificador { ficha.splitIds[archivo] = identificador }
        }
        return ficha
    }

    /// Rellena solo lo que falte: lo leído del `.apk` manda siempre sobre lo que diga la ficha.
    func facts(mixedWith leído: ApkFacts) -> ApkFacts {
        ApkFacts(
            packageName: leído.packageName ?? packageName,
            versionName: leído.versionName ?? versionName,
            versionCode: leído.versionCode ?? versionCode,
            minSdk: leído.minSdk ?? minSdk,
            abis: leído.abis,
            isSplit: leído.readFailed ? false : leído.isSplit,
            orientation: leído.orientation,
            readFailed: leído.readFailed && packageName == nil
        )
    }

    /// Las fichas mezclan números y cadenas para lo mismo según quién las escriba.
    private static func número(_ valor: Any?) -> Int? {
        if let entero = valor as? Int { return entero }
        if let texto = valor as? String { return Int(texto) }
        return nil
    }

    private static func texto(_ valor: Any?) -> String? {
        if let texto = valor as? String { return texto }
        if let entero = valor as? Int { return String(entero) }
        return nil
    }
}

extension AndroidBundleInspector {
    /// El identificador de un trozo a partir del nombre de su archivo, con las dos convenciones
    /// que existen: la de Play —`config.arm64_v8a.apk`, a veces con `split_` delante— y la de
    /// `bundletool`, que nombra por módulo y cualidad separados por un guion (`base-arm64_v8a.apk`,
    /// `base-master.apk`). Devuelve `nil` cuando el archivo no parece un trozo.
    static func splitId(forEntryNamed name: String) -> String? {
        var raíz = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        for prefijo in ["split_", "split-"] where raíz.hasPrefix(prefijo) {
            raíz.removeFirst(prefijo.count)
        }
        if raíz.isEmpty || raíz == "base" { return nil }
        if raíz.hasPrefix("config.") { return raíz }

        guard let guion = raíz.firstIndex(of: "-") else { return nil }
        let modulo = String(raíz[raíz.startIndex..<guion])
        var cualidad = String(raíz[raíz.index(after: guion)...])
        // El sufijo de variante no dice nada del trozo: `base-arm64_v8a_2.apk` sigue siendo el
        // trozo de arm64, solo que el de la segunda variante. Sin quitarlo, la cualidad no
        // coincidiría con ningún procesador ni densidad y el trozo pasaría por un módulo aparte.
        if let sufijo = variantSuffix(in: cualidad) { cualidad.removeLast(sufijo.count) }

        // `…-master.apk` es el trozo principal de su módulo: del paquete entero si es `base`.
        if cualidad == "master" { return modulo == "base" ? nil : modulo }
        return modulo == "base" ? "config.\(cualidad)" : "\(modulo).config.\(cualidad)"
    }

    /// El `_2` del final de un nombre de `bundletool`, si lo lleva.
    static func variantSuffix(in name: String) -> String? {
        let raíz = name.hasSuffix(".apk") ? String(name.dropLast(4)) : name
        guard let barra = raíz.lastIndex(of: "_") else { return nil }
        let cola = String(raíz[raíz.index(after: barra)...])
        guard !cola.isEmpty, cola.allSatisfy(\.isNumber) else { return nil }
        return "_" + cola
    }
}
