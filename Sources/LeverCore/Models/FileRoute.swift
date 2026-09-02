import Foundation

/// A qué parte de Lever le toca un archivo que llega de fuera.
///
/// Existe porque la decisión se tomaba en dos sitios que no se hablaban: el modelo decidía a quién
/// entregarle el archivo y la ventana decidía qué pestaña enseñar, cada uno con su lista de
/// comprobaciones. Mientras las dos listas dijeron lo mismo no se notó; en cuanto una supo de un
/// formato que la otra no —un `.xci`, sin ir más lejos— el archivo entraba bien y la ventana
/// enseñaba la pestaña equivocada, que por fuera es indistinguible de que no hubiera entrado.
///
/// Con una sola lista eso no puede volver a pasar.
public enum FileRoute: String, Equatable, Sendable, CaseIterable {
    /// Un programa de Windows, que se traslada.
    case program
    /// Un comprimido, que se extrae.
    case archive
    /// Una aplicación de Android, que se instala.
    case android
    /// Un juego de consola, que se interpreta con un emulador.
    case rom
}

/// Quién se queda con un archivo, mirando lo que tiene dentro y no cómo se llama.
public enum FileRouter {
    /// A quién le toca este archivo, o `nil` si no es de nadie.
    ///
    /// El orden importa y no es alfabético. Las extensiones se pisan entre sí —un `.iso` lo
    /// reclaman los comprimidos y también media docena de consolas, un `.bin` igual— así que
    /// primero van los formatos que se reconocen por dentro y los comprimidos quedan al final,
    /// de red de seguridad. Es la razón de que un `.xci` renombrado a `.zip` siga sin colarse por
    /// el sitio que no es.
    public static func route(for url: URL) -> FileRoute? {
        if SupportedFileKind.exe.accepts(url) { return .program }
        if SupportedFileKind.apk.accepts(url) { return .android }
        // Un juego de PS3 o de PS4 volcado de su disco es una carpeta con un ejecutable dentro, no
        // un archivo. Va antes que las dos ramas de abajo porque ninguna de ellas mira dentro de
        // una carpeta.
        if url.hasDirectoryPath, PlayStationInspector.inspect(url).isRecognised { return .rom }
        if SupportedFileKind.rom.accepts(url), isRecognisedGame(url) { return .rom }
        if SupportedFileKind.rar.accepts(url) { return .archive }
        return nil
    }

    /// Si algo con extensión de juego lo es de verdad.
    ///
    /// Tres inspectores porque son tres familias que no se parecen: una ROM se reconoce por una
    /// cabecera corta, un paquete de la consola híbrida por su tabla de particiones, y un disco de
    /// PlayStation por lo que lleva en el arranque. Ninguno sabe de los formatos del otro y por eso
    /// se preguntan los tres.
    static func isRecognisedGame(_ url: URL) -> Bool {
        RomInspector.inspect(url).isRecognised
            || SwitchInspector.inspect(url).isRecognised
            || PlayStationInspector.inspect(url).isRecognised
    }

    /// Un archivo que **dice** ser de la consola híbrida y por dentro no lo es.
    ///
    /// Merece decirse aparte. Estos paquetes pesan gigas y casi siempre llegan por una descarga
    /// larga: cuando uno no se reconoce, lo que ha pasado casi seguro es que está a medias, y
    /// decir «no se reconoce el archivo» manda a buscar el fallo donde no está. Que la extensión
    /// prometa un formato concreto es justo lo que permite ser más preciso.
    ///
    /// La comprobación es superficial a propósito: se mira la tabla de particiones, que va en
    /// claro, y nada más. No se descifra ni se extrae nada.
    public static func looksLikeBrokenSwitchPackage(_ url: URL) -> Bool {
        guard SwitchContainer.named(url) != nil else { return false }
        return !SwitchInspector.inspect(url).isRecognised
    }
}

public extension SwitchContainer {
    /// El envoltorio que promete el nombre del archivo, sin mirar dentro.
    ///
    /// **Solo vale como pista.** Lo que decide es `SwitchInspector`, que entra y mira: un `.nsp`
    /// renombrado a `.xci` se descubre allí y no aquí. Esto sirve para lo contrario —saber qué
    /// esperaba el usuario— y para eso el nombre sí es la fuente correcta.
    ///
    /// Sin distinguir mayúsculas de minúsculas: un `.XCI` de un volcado viejo es un `.xci`.
    static func named(_ url: URL) -> SwitchContainer? {
        SwitchContainer(rawValue: url.pathExtension.lowercased())
    }
}
