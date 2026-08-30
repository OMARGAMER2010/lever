import Foundation

/// Lector del formato `.asar`, que es como Electron reparte el código de una app.
///
/// No es un ZIP y no comprime nada: es una cabecera JSON con el árbol de archivos —tamaño y
/// desplazamiento de cada uno— y detrás todo el contenido pegado. Hace falta leerlo para dos
/// cosas: sacar el `package.json` del juego y encontrar los módulos nativos `.node`, que son
/// justo lo que no viaja de Windows a Mac.
public enum AsarArchive {
    public struct Entry: Equatable, Sendable {
        /// Ruta dentro del archivo, con `/` y sin barra inicial.
        public let path: String
        public let size: Int
        public let offset: UInt64
        /// Marcado así, el archivo **no** está dentro: vive suelto en `app.asar.unpacked/` con la
        /// misma ruta. Los `.node` acaban ahí casi siempre, porque `dlopen` no sabe abrir una
        /// librería que está metida dentro de otro archivo.
        public let unpacked: Bool
    }

    /// Todas las entradas de archivo, en orden de recorrido. `nil` si no es un `.asar`.
    public static func entries(of archive: URL) -> [Entry]? {
        guard let (arbol, _) = open(archive) else { return nil }
        var salida: [Entry] = []
        recorre(arbol, prefijo: "", into: &salida)
        return salida
    }

    /// El contenido de un archivo de dentro. `nil` si no está o si está desempaquetado, porque
    /// entonces no vive aquí.
    public static func read(_ path: String, from archive: URL) -> Data? {
        guard let (arbol, inicioDatos) = open(archive) else { return nil }
        var salida: [Entry] = []
        recorre(arbol, prefijo: "", into: &salida)
        guard let entrada = salida.first(where: { $0.path == path }), !entrada.unpacked else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: inicioDatos + entrada.offset)
        return try? handle.read(upToCount: entrada.size)
    }

    // MARK: - Cabecera

    /// Cuatro enteros de 32 bits y detrás el JSON. El segundo dice dónde empiezan los datos —a 8
    /// más su valor— y el cuarto cuánto mide el JSON. Los otros dos son de la serialización de
    /// Chromium y no aportan nada aquí.
    private static func open(_ archive: URL) -> (arbol: [String: Any], inicioDatos: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }
        guard let cabecera = try? handle.read(upToCount: 16), cabecera.count == 16 else { return nil }

        let tamañoCabecera = leerUInt32(cabecera, at: 4)
        let tamañoJSON = leerUInt32(cabecera, at: 12)
        guard leerUInt32(cabecera, at: 0) == 4, tamañoJSON > 0, tamañoJSON <= tamañoCabecera else { return nil }

        guard let crudo = try? handle.read(upToCount: Int(tamañoJSON)), crudo.count == Int(tamañoJSON),
              let json = try? JSONSerialization.jsonObject(with: crudo) as? [String: Any],
              let arbol = json["files"] as? [String: Any] else { return nil }
        return (arbol, 8 + UInt64(tamañoCabecera))
    }

    private static func recorre(_ nodo: [String: Any], prefijo: String, into salida: inout [Entry]) {
        for (nombre, valor) in nodo.sorted(by: { $0.key < $1.key }) {
            guard let hijo = valor as? [String: Any] else { continue }
            let ruta = prefijo.isEmpty ? nombre : prefijo + "/" + nombre
            if let dentro = hijo["files"] as? [String: Any] {
                recorre(dentro, prefijo: ruta, into: &salida)
                continue
            }
            // El desplazamiento viene como cadena, no como número: en JavaScript un entero grande
            // pierde precisión y un asar puede pasar de los cuatro gigas.
            let desplazamiento = UInt64((hijo["offset"] as? String) ?? "") ?? 0
            salida.append(Entry(
                path: ruta,
                size: (hijo["size"] as? Int) ?? 0,
                offset: desplazamiento,
                unpacked: (hijo["unpacked"] as? Bool) ?? false
            ))
        }
    }

    private static func leerUInt32(_ datos: Data, at desplazamiento: Int) -> UInt32 {
        var valor: UInt32 = 0
        for i in (0..<4).reversed() {
            valor = valor << 8 | UInt32(datos[datos.startIndex + desplazamiento + i])
        }
        return valor
    }
}
