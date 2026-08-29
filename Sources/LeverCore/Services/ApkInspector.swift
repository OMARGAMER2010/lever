import Compression
import Foundation

/// Lee un `.apk` sin ayuda de nadie: ni Android SDK, ni `aapt`, ni descomprimir a disco.
///
/// Por qué a mano y no con `aapt2`: `aapt2` viene dentro de las build-tools del SDK de Android,
/// que son varios gigas y hacen falta Java y aceptar licencias. Pedir todo eso para poder decirle
/// al usuario «este paquete no va a instalarse en tu móvil» sería cobrarle el diagnóstico más caro
/// que la propia instalación. Un `.apk` es un `.zip` con un XML binario dentro, y las dos cosas
/// están documentadas: se leen directamente, igual que la cabecera PE de un `.exe`.
///
/// Todo lo que devuelve sale del archivo. Lo que no se puede leer se queda en `nil`, nunca se
/// rellena con un valor probable.
public enum ApkInspector {
    public static func inspect(_ url: URL) -> ApkFacts {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ApkFacts(readFailed: true)
        }
        defer { try? handle.close() }

        guard let entries = try? ZipDirectory.read(from: handle), !entries.isEmpty else {
            return ApkFacts(readFailed: true)
        }

        let names = Set(entries.map(\.name))
        guard names.contains("AndroidManifest.xml") else {
            return ApkFacts(readFailed: true)
        }

        // Las carpetas `lib/<abi>/` son la única fuente de verdad sobre para qué procesadores
        // trae código el paquete.
        var abis: [String] = []
        for name in names where name.hasPrefix("lib/") {
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let abi = String(parts[1])
            if !abis.contains(abi) { abis.append(abi) }
        }
        abis.sort { lhs, rhs in
            let order = AndroidAbi.known
            let left = order.firstIndex(of: lhs) ?? order.count
            let right = order.firstIndex(of: rhs) ?? order.count
            return left == right ? lhs < rhs : left < right
        }

        let manifest = entries
            .first { $0.name == "AndroidManifest.xml" }
            .flatMap { try? ZipDirectory.contents(of: $0, from: handle) }
            .flatMap(BinaryXML.parseManifest)

        return ApkFacts(
            packageName: manifest?.packageName,
            versionName: manifest?.versionName,
            versionCode: manifest?.versionCode,
            minSdk: manifest?.minSdk,
            abis: abis,
            // Un App Bundle reparte el código en varios `.apk`; solo el principal lleva
            // `classes.dex`. Los demás no se pueden instalar sueltos.
            isSplit: !names.contains("classes.dex"),
            orientation: ScreenOrientation.fromManifest(manifest?.orientation),
            readFailed: false
        )
    }
}

// MARK: - Zip

/// Lo justo del formato ZIP para encontrar una entrada y sacarla: el directorio central al final
/// del archivo, y la cabecera local de la entrada que interese. Nunca se carga el `.apk` entero
/// en memoria: pueden pesar más de un giga.
enum ZipDirectory {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: UInt64
    }

    enum Failure: Error { case malformed }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralEntrySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    /// Tamaño máximo del bloque final del zip: 22 bytes de cabecera + hasta 65 535 de comentario.
    private static let maximumTrailerLength = 22 + 0xFFFF

    static func read(from handle: FileHandle) throws -> [Entry] {
        let fileLength = Int(try handle.seekToEnd())
        guard fileLength > 22 else { throw Failure.malformed }

        let trailerLength = min(fileLength, maximumTrailerLength)
        try handle.seek(toOffset: UInt64(fileLength - trailerLength))
        guard let trailer = try handle.read(upToCount: trailerLength), trailer.count == trailerLength else {
            throw Failure.malformed
        }

        let bytes = [UInt8](trailer)
        guard let end = lastIndex(of: endOfCentralDirectorySignature, in: bytes) else {
            throw Failure.malformed
        }

        var entryCount = Int(readUInt16(bytes, end + 10))
        var directoryOffset = UInt64(readUInt32(bytes, end + 16))

        // Con más de 65 535 entradas o por encima de 4 GB, los campos se desbordan y los valores
        // reales viven en el bloque ZIP64 que va justo antes.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            (entryCount, directoryOffset) = try readZip64(bytes: bytes, endOfCentral: end, handle: handle)
        }

        guard directoryOffset < UInt64(fileLength) else { throw Failure.malformed }
        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.read(upToCount: fileLength - Int(directoryOffset)) else {
            throw Failure.malformed
        }

        return parseCentralDirectory([UInt8](directory), expectedCount: entryCount)
    }

    /// Devuelve el contenido de una entrada, descomprimiéndola si hace falta.
    static func contents(of entry: Entry, from handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30 else { throw Failure.malformed }

        let headerBytes = [UInt8](header)
        guard readUInt32(headerBytes, 0) == localHeaderSignature else { throw Failure.malformed }

        // La cabecera local repite el nombre y los extras, y su longitud puede no coincidir con
        // la del directorio central: hay que leerla de aquí para saber dónde empiezan los datos.
        let nameLength = Int(readUInt16(headerBytes, 26))
        let extraLength = Int(readUInt16(headerBytes, 28))

        try handle.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength))
        guard let payload = try handle.read(upToCount: entry.compressedSize),
              payload.count == entry.compressedSize else { throw Failure.malformed }

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = inflate(payload, expecting: entry.uncompressedSize) else {
                throw Failure.malformed
            }
            return inflated
        default:
            // Un `AndroidManifest.xml` solo aparece almacenado o en deflate. Cualquier otra cosa
            // no se adivina.
            throw Failure.malformed
        }
    }

    private static func readZip64(
        bytes: [UInt8],
        endOfCentral: Int,
        handle: FileHandle
    ) throws -> (count: Int, offset: UInt64) {
        let locator = endOfCentral - 20
        guard locator >= 0, readUInt32(bytes, locator) == zip64LocatorSignature else {
            throw Failure.malformed
        }

        let recordOffset = readUInt64(bytes, locator + 8)
        try handle.seek(toOffset: recordOffset)
        guard let record = try handle.read(upToCount: 56), record.count == 56 else { throw Failure.malformed }

        let recordBytes = [UInt8](record)
        guard readUInt32(recordBytes, 0) == zip64EndSignature else { throw Failure.malformed }

        return (Int(readUInt64(recordBytes, 32)), readUInt64(recordBytes, 48))
    }

    private static func parseCentralDirectory(_ bytes: [UInt8], expectedCount: Int) -> [Entry] {
        var entries: [Entry] = []
        var cursor = 0

        while cursor + 46 <= bytes.count, entries.count < max(expectedCount, 1) || expectedCount == 0 {
            guard readUInt32(bytes, cursor) == centralEntrySignature else { break }

            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = readUInt32(bytes, cursor + 42)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)

            entries.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: UInt64(localOffset)
                )
            )

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static func inflate(_ data: Data, expecting size: Int) -> Data? {
        // El tamaño viene del propio zip; si llegara a cero o disparatado, se pone un techo
        // razonable en vez de reservar lo que diga el archivo.
        let capacity = size > 0 ? size : 1 << 20
        guard capacity < 64 << 20 else { return nil }

        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // `COMPRESSION_ZLIB` es DEFLATE en crudo, que es justo lo que guarda un zip.
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    private static func lastIndex(of signature: UInt32, in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = bytes.count - 4
        while index >= 0 {
            if readUInt32(bytes, index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

// MARK: - Lectura de enteros

@inline(__always)
func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@inline(__always)
func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    var value: UInt32 = 0
    for index in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[offset + index]) }
    return value
}

@inline(__always)
func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
    var value: UInt64 = 0
    for index in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + index]) }
    return value
}

// MARK: - AndroidManifest.xml binario

/// El `AndroidManifest.xml` de un `.apk` no es texto: es el formato binario de recursos de
/// Android (AXML). Se lee lo justo: el depósito de cadenas, el mapa de recursos, el elemento
/// `manifest`, el `uses-sdk` y las actividades —para saber en qué orientación arranca la app.
enum BinaryXML {
    struct Manifest {
        var packageName: String?
        var versionName: String?
        var versionCode: Int?
        var minSdk: Int?
        /// Valor crudo de `android:screenOrientation` de la actividad de inicio.
        var orientation: Int?
    }

    /// Lo que se sabe de la actividad que se está leyendo, entre su etiqueta de apertura y la de
    /// cierre. Las categorías `LAUNCHER` van dentro de un `intent-filter` anidado, así que hay
    /// que recordar en qué actividad estamos mientras se recorre el documento.
    private struct ActivityScan {
        var name: String?
        var targetActivity: String?
        var orientation: Int?
        var isLauncher = false
    }

    // Identificadores de recurso de los atributos que interesan. Hacen falta porque un `.apk`
    // ofuscado puede dejar el nombre del atributo vacío en el depósito de cadenas y referirse a
    // él solo por este número. El nombre sigue siendo la vía principal; esto es el respaldo.
    private static let versionCodeID: UInt32 = 0x0101_021B
    private static let versionNameID: UInt32 = 0x0101_021C
    private static let minSdkID: UInt32 = 0x0101_020C
    private static let nameID: UInt32 = 0x0101_0003
    private static let screenOrientationID: UInt32 = 0x0101_001E

    private static let stringPoolChunk: UInt16 = 0x0001
    private static let resourceMapChunk: UInt16 = 0x0180
    private static let startElementChunk: UInt16 = 0x0102
    private static let endElementChunk: UInt16 = 0x0103

    private static let typeString: UInt8 = 0x03
    private static let launcherCategory = "android.intent.category.LAUNCHER"

    static func parseManifest(_ data: Data) -> Manifest? {
        let bytes = [UInt8](data)
        // Cabecera del documento: tipo 0x0003 y su tamaño.
        guard bytes.count > 8, readUInt16(bytes, 0) == 0x0003 else { return nil }

        var strings: [String] = []
        var resourceIDs: [UInt32] = []
        var manifest = Manifest()

        var current: ActivityScan?
        var launcher: ActivityScan?
        var orientationsByActivity: [String: Int] = [:]

        var cursor = Int(readUInt16(bytes, 2))
        while cursor + 8 <= bytes.count {
            let type = readUInt16(bytes, cursor)
            let headerSize = Int(readUInt16(bytes, cursor + 2))
            let size = Int(readUInt32(bytes, cursor + 4))
            guard size >= 8, cursor + size <= bytes.count else { break }

            switch type {
            case stringPoolChunk:
                strings = readStringPool(bytes, at: cursor)

            case resourceMapChunk:
                resourceIDs = (0..<((size - headerSize) / 4)).map {
                    readUInt32(bytes, cursor + headerSize + $0 * 4)
                }

            case startElementChunk:
                let element = elementName(bytes, at: cursor, headerSize: headerSize, strings: strings)
                switch element {
                case "manifest", "uses-sdk":
                    readManifestAttributes(
                        bytes, at: cursor, headerSize: headerSize, element: element ?? "",
                        strings: strings, resourceIDs: resourceIDs, into: &manifest
                    )
                case "activity", "activity-alias":
                    current = readActivity(
                        bytes, at: cursor, headerSize: headerSize,
                        strings: strings, resourceIDs: resourceIDs
                    )
                case "category":
                    if isLauncherCategory(
                        bytes, at: cursor, headerSize: headerSize,
                        strings: strings, resourceIDs: resourceIDs
                    ) {
                        current?.isLauncher = true
                    }
                default:
                    break
                }

            case endElementChunk:
                let element = elementName(bytes, at: cursor, headerSize: headerSize, strings: strings)
                if element == "activity" || element == "activity-alias", let finished = current {
                    if let key = finished.name.map(shortName), let value = finished.orientation {
                        orientationsByActivity[key] = value
                    }
                    if finished.isLauncher, launcher == nil { launcher = finished }
                    current = nil
                }

            default:
                break
            }

            cursor += size
        }

        // Un `activity-alias` puede llevar el filtro de inicio y apuntar a otra actividad. Se
        // resuelve al final y no sobre la marcha porque el destino puede estar declarado después.
        if let launcher {
            manifest.orientation = launcher.orientation
                ?? launcher.targetActivity.map(shortName).flatMap { orientationsByActivity[$0] }
        }

        return manifest.packageName == nil && manifest.versionName == nil ? nil : manifest
    }

    // MARK: - Elementos

    /// Vale para la etiqueta de apertura y la de cierre: en las dos, el índice del nombre está en
    /// el mismo sitio, justo detrás del espacio de nombres.
    private static func elementName(
        _ bytes: [UInt8], at chunkStart: Int, headerSize: Int, strings: [String]
    ) -> String? {
        string(at: Int(Int32(bitPattern: readUInt32(bytes, chunkStart + headerSize + 4))), in: strings)
    }

    private static func readManifestAttributes(
        _ bytes: [UInt8], at chunkStart: Int, headerSize: Int, element: String,
        strings: [String], resourceIDs: [UInt32], into manifest: inout Manifest
    ) {
        forEachAttribute(bytes, at: chunkStart, headerSize: headerSize,
                         strings: strings, resourceIDs: resourceIDs) { name, resourceID, text, number in
            switch element {
            case "manifest":
                // `package` no lleva espacio de nombres, así que solo puede venir por su nombre.
                if name == "package" { manifest.packageName = text() }
                if name == "versionName" || resourceID == versionNameID { manifest.versionName = text() }
                if name == "versionCode" || resourceID == versionCodeID { manifest.versionCode = number() }
            case "uses-sdk":
                if name == "minSdkVersion" || resourceID == minSdkID { manifest.minSdk = number() }
            default:
                break
            }
        }
    }

    private static func readActivity(
        _ bytes: [UInt8], at chunkStart: Int, headerSize: Int,
        strings: [String], resourceIDs: [UInt32]
    ) -> ActivityScan {
        var activity = ActivityScan()
        forEachAttribute(bytes, at: chunkStart, headerSize: headerSize,
                         strings: strings, resourceIDs: resourceIDs) { name, resourceID, text, number in
            if name == "name" || resourceID == nameID { activity.name = text() }
            if name == "targetActivity" { activity.targetActivity = text() }
            if name == "screenOrientation" || resourceID == screenOrientationID {
                activity.orientation = number()
            }
        }
        return activity
    }

    private static func isLauncherCategory(
        _ bytes: [UInt8], at chunkStart: Int, headerSize: Int,
        strings: [String], resourceIDs: [UInt32]
    ) -> Bool {
        var found = false
        forEachAttribute(bytes, at: chunkStart, headerSize: headerSize,
                         strings: strings, resourceIDs: resourceIDs) { name, resourceID, text, _ in
            guard name == "name" || resourceID == nameID else { return }
            if text() == launcherCategory { found = true }
        }
        return found
    }

    /// `.MainActivity` y `com.ejemplo.MainActivity` nombran lo mismo: en el manifiesto el nombre
    /// puede ser relativo al paquete o absoluto. Se comparan por el último tramo.
    private static func shortName(_ name: String) -> String {
        String(name.split(separator: ".").last ?? Substring(name))
    }

    // MARK: - Atributos

    /// Recorre los atributos de un elemento. Cada uno ocupa 20 bytes con la misma forma, así que
    /// se decodifica una vez aquí en lugar de repetirlo en cada sitio que los necesita.
    private static func forEachAttribute(
        _ bytes: [UInt8], at chunkStart: Int, headerSize: Int,
        strings: [String], resourceIDs: [UInt32],
        body: (_ name: String, _ resourceID: UInt32, _ text: () -> String?, _ number: () -> Int?) -> Void
    ) {
        let extensionStart = chunkStart + headerSize
        let attributeStart = Int(readUInt16(bytes, extensionStart + 8))
        let attributeSize = Int(readUInt16(bytes, extensionStart + 10))
        let attributeCount = Int(readUInt16(bytes, extensionStart + 12))
        guard attributeSize >= 20, attributeCount > 0 else { return }

        for index in 0..<attributeCount {
            let attribute = extensionStart + attributeStart + index * attributeSize
            guard attribute + 20 <= bytes.count else { return }

            let attributeNameIndex = Int(Int32(bitPattern: readUInt32(bytes, attribute + 4)))
            let rawValueIndex = Int(Int32(bitPattern: readUInt32(bytes, attribute + 8)))
            let dataType = bytes[attribute + 15]
            let data = readUInt32(bytes, attribute + 16)

            let name = string(at: attributeNameIndex, in: strings) ?? ""
            let resourceID = attributeNameIndex >= 0 && attributeNameIndex < resourceIDs.count
                ? resourceIDs[attributeNameIndex]
                : 0

            func text() -> String? {
                if dataType == typeString { return string(at: Int(Int32(bitPattern: data)), in: strings) }
                return string(at: rawValueIndex, in: strings)
            }

            func number() -> Int? {
                if dataType == typeString || rawValueIndex >= 0 {
                    if let parsed = text().flatMap(Int.init) { return parsed }
                }
                return Int(Int32(bitPattern: data))
            }

            body(name, resourceID, text, number)
        }
    }

    private static func string(at index: Int, in strings: [String]) -> String? {
        guard index >= 0, index < strings.count else { return nil }
        let value = strings[index]
        return value.isEmpty ? nil : value
    }

    /// Depósito de cadenas. Puede venir en UTF-16 (lo normal) o en UTF-8 (algunas herramientas).
    private static func readStringPool(_ bytes: [UInt8], at chunkStart: Int) -> [String] {
        let count = Int(readUInt32(bytes, chunkStart + 8))
        let flags = readUInt32(bytes, chunkStart + 16)
        let dataStart = chunkStart + Int(readUInt32(bytes, chunkStart + 20))
        let offsetsStart = chunkStart + Int(readUInt16(bytes, chunkStart + 2))
        let isUTF8 = (flags & 0x100) != 0

        guard count > 0, count < 500_000, dataStart < bytes.count else { return [] }

        var strings: [String] = []
        strings.reserveCapacity(count)

        for index in 0..<count {
            let start = dataStart + Int(readUInt32(bytes, offsetsStart + index * 4))
            guard start < bytes.count else { strings.append(""); continue }
            strings.append(isUTF8 ? utf8String(bytes, at: start) : utf16String(bytes, at: start))
        }

        return strings
    }

    private static func utf16String(_ bytes: [UInt8], at start: Int) -> String {
        var cursor = start
        var length = Int(readUInt16(bytes, cursor))
        cursor += 2
        // Una longitud con el bit alto puesto ocupa dos enteros de 16 bits.
        if length & 0x8000 != 0 {
            length = ((length & 0x7FFF) << 16) | Int(readUInt16(bytes, cursor))
            cursor += 2
        }
        guard length > 0, cursor + length * 2 <= bytes.count else { return "" }

        var units: [UInt16] = []
        units.reserveCapacity(length)
        for index in 0..<length { units.append(readUInt16(bytes, cursor + index * 2)) }
        return String(decoding: units, as: UTF16.self)
    }

    private static func utf8String(_ bytes: [UInt8], at start: Int) -> String {
        var cursor = start
        // Dos longitudes seguidas: primero la de caracteres y luego la de bytes. Cada una ocupa
        // uno o dos bytes según el bit alto del primero.
        for _ in 0..<1 {
            guard cursor < bytes.count else { return "" }
            if bytes[cursor] & 0x80 != 0 { cursor += 2 } else { cursor += 1 }
        }
        guard cursor < bytes.count else { return "" }

        var byteLength = Int(bytes[cursor])
        if byteLength & 0x80 != 0 {
            guard cursor + 1 < bytes.count else { return "" }
            byteLength = ((byteLength & 0x7F) << 8) | Int(bytes[cursor + 1])
            cursor += 2
        } else {
            cursor += 1
        }

        guard byteLength > 0, cursor + byteLength <= bytes.count else { return "" }
        return String(decoding: bytes[cursor..<cursor + byteLength], as: UTF8.self)
    }
}
