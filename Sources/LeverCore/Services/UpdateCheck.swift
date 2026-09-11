import Foundation

/// Mira si hay una versión de Lever más nueva que la instalada.
///
/// Es lo único que Lever le pide a la red por su cuenta, y solo pide: la última etiqueta
/// publicada del repositorio. No manda nada sobre ti ni sobre tu Mac más allá de lo que cualquier
/// petición deja ver. Y si no se puede preguntar, no pasa nada: quedarse sin saber si hay versión
/// nueva no es un fallo que merezca molestar a nadie, así que falla en silencio.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/OMARGAMER2010/lever/releases/latest")!

    /// La versión de este bundle, tal como la declara su Info.plist.
    public static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Saca la etiqueta de la respuesta de GitHub. Un campo no justifica un decodificador entero.
    public static func tag(inReleaseJSON data: Data) -> String? {
        guard let objeto = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let etiqueta = objeto["tag_name"] as? String,
              !etiqueta.isEmpty else { return nil }
        return etiqueta
    }

    /// Compara versiones del estilo «v1.2.10».
    ///
    /// Número a número, no como texto: «1.0.10» es posterior a «1.0.9», y ordenadas como palabras
    /// saldría justo al revés. Lo que no se entiende no cuenta como más nuevo — es mejor no avisar
    /// que ofrecer una actualización inventada.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let nueva = numbers(in: candidate), let actual = numbers(in: installed) else { return false }
        for posición in 0..<max(nueva.count, actual.count) {
            let a = posición < nueva.count ? nueva[posición] : 0
            let b = posición < actual.count ? actual[posición] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(in version: String) -> [Int]? {
        var texto = version.trimmingCharacters(in: .whitespaces)
        if texto.first == "v" || texto.first == "V" { texto.removeFirst() }
        let trozos = texto.split(separator: ".", omittingEmptySubsequences: false)
        guard !trozos.isEmpty, trozos.count <= 4 else { return nil }
        var números: [Int] = []
        for trozo in trozos {
            guard let número = Int(trozo), número >= 0 else { return nil }
            números.append(número)
        }
        return números
    }

    /// Pregunta a GitHub por la última versión publicada. Devuelve su etiqueta solo si es más
    /// nueva que la instalada; en cualquier otro caso, nada.
    public static func newerVersion(than installed: String = installedVersion) async -> String? {
        var petición = URLRequest(url: latestReleaseURL)
        petición.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Diez segundos: si GitHub no contesta en ese rato, mejor seguir usando la app.
        petición.timeoutInterval = 10
        guard let (datos, respuesta) = try? await URLSession.shared.data(for: petición),
              (respuesta as? HTTPURLResponse)?.statusCode == 200,
              let etiqueta = tag(inReleaseJSON: datos),
              isNewer(etiqueta, than: installed) else { return nil }
        return etiqueta
    }
}
