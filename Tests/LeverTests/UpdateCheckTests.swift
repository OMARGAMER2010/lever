import Foundation
import LeverCore

enum UpdateCheckTests {
    static func run() throws {
        try testItComparesVersionsByNumberAndNotByLetter()
        try testItRefusesWhatItCannotUnderstand()
        try testItReadsTheTagFromWhatGitHubAnswers()
    }

    /// El fallo clásico de comparar versiones como texto: «1.0.10» sale antes que «1.0.9» en un
    /// diccionario, así que un usuario en la 1.0.9 nunca se enteraría de la 1.0.10.
    private static func testItComparesVersionsByNumberAndNotByLetter() throws {
        try expect(UpdateCheck.isNewer("v1.0.10", than: "1.0.9"), "10 es más que 9, aunque «1» sea menos que «9»")
        try expect(UpdateCheck.isNewer("1.1.0", than: "1.0.9"), "la versión media manda sobre la última")
        try expect(UpdateCheck.isNewer("2.0.0", than: "1.9.9"), "la primera manda sobre todas")
        try expect(!UpdateCheck.isNewer("1.0.0", than: "1.0.0"), "la misma versión no es una actualización")
        try expect(!UpdateCheck.isNewer("1.0.0", than: "1.0.1"), "no se ofrece volver atrás")
        try expect(!UpdateCheck.isNewer("v1.0.0", than: "1.0.0"), "la «v» de la etiqueta no cambia el número")

        // Longitudes distintas: lo que falta vale cero.
        try expect(UpdateCheck.isNewer("1.1", than: "1.0.9"), "«1.1» es «1.1.0», y eso es más que «1.0.9»")
        try expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"), "«1.0» y «1.0.0» son la misma versión")
        try expect(UpdateCheck.isNewer("1.0.1", than: "1.0"), "un parche sobre «1.0» sí es más nuevo")
    }

    /// Ante algo que no se entiende, callarse. Un aviso de actualización inventado es peor que no
    /// avisar: manda al usuario a compilar para nada.
    private static func testItRefusesWhatItCannotUnderstand() throws {
        for basura in ["", "v", "latest", "1.0.0-beta", "1..0", "uno.cero", "-1.0.0", "1.0.0.0.0"] {
            try expect(!UpdateCheck.isNewer(basura, than: "1.0.0"),
                       "«\(basura)» no es una versión que se pueda comparar")
        }
        try expect(!UpdateCheck.isNewer("2.0.0", than: "no es una versión"),
                   "si no se sabe qué hay instalado, no se ofrece nada")
    }

    private static func testItReadsTheTagFromWhatGitHubAnswers() throws {
        let respuesta = Data("""
        {"url":"https://api.github.com/repos/quien/lever/releases/1",
         "tag_name":"v1.2.0","name":"Lever 1.2.0","draft":false}
        """.utf8)
        try expect(UpdateCheck.tag(inReleaseJSON: respuesta) == "v1.2.0", "la etiqueta está en tag_name")

        try expect(UpdateCheck.tag(inReleaseJSON: Data("no es json".utf8)) == nil,
                   "una respuesta que no es JSON no trae etiqueta")
        try expect(UpdateCheck.tag(inReleaseJSON: Data("{}".utf8)) == nil, "sin tag_name no hay etiqueta")
        try expect(UpdateCheck.tag(inReleaseJSON: Data(#"{"tag_name":""}"#.utf8)) == nil,
                   "una etiqueta vacía no sirve de nada")
        try expect(UpdateCheck.tag(inReleaseJSON: Data(#"{"tag_name":123}"#.utf8)) == nil,
                   "una etiqueta que no es texto no se fuerza a texto")
    }
}
