import Foundation
import LeverCore

/// Pruebas de la traducción de un botón físico al número que RetroArch escribe.
///
/// El número no se puede inventar ni deducir del nombre del botón: es la posición que ese botón
/// ocupa en la lista que arma el emulador. Así que lo que se comprueba aquí es que la lista se arma
/// igual, con dos tablas que no son de nadie de esta casa:
///
/// - la del **Nimbus**, que la propia fuente de RetroArch documenta en un comentario porque es el
///   caso raro que obligó a cambiar el algoritmo;
/// - la del **DualSense**, leída de un mando de verdad conectado a este Mac con IOKit.
///
/// Sin mando enchufado, porque los elementos se describen a mano: lo que se prueba es la regla.
enum GamepadTests {
    static func run() throws {
        try testNumbersTheNimbusLikeRetroArchDocumentsIt()
        try testNumbersTheDualSenseAsTheRealPadReports()
        try testTheOrderOfTheElementsDoesNotChangeTheNumbers()
        try testARepeatedUsageGoesToTheEndInsteadOfStealingItsPlace()
        try testARepeatedAxisFillsTheFirstFreeNumber()
        try testTheHatKnowsWhereItPoints()
        try testATriggerAtRestIsNotAPressedAxis()
        try testRefusesAButtonRetroArchWouldNotRead()
        try testWhatThePadReportsEndsUpInTheConfigFile()
        try testTellsTheFamilyByWhoMadeIt()
        try testEveryControlHasItsOwnPlaceOnTheDrawing()
        try testAnXboxPadIsNotDrawnLikeAPlayStationOne()
        try testEachPadIsNamedTheWayItIsPrinted()
    }

    // MARK: - Ayudas

    private static func button(_ usage: UInt32, _ cookie: UInt32, page: UInt32 = 0x09) -> HIDElementInfo {
        HIDElementInfo(page: page, usage: usage, cookie: cookie, kind: .button)
    }

    private static func misc(_ usage: UInt32, _ cookie: UInt32, page: UInt32 = 0x01) -> HIDElementInfo {
        HIDElementInfo(page: page, usage: usage, cookie: cookie, kind: .misc)
    }

    // MARK: - Las dos tablas de verdad

    /// La tabla que RetroArch lleva escrita en un comentario de `iohidmanager_hid.c`: el Nimbus
    /// numera sus botones 1–8, mete la cruceta en 144–147 y el botón de menú en 547, y aun así los
    /// trece salen seguidos del 0 al 12. Es el caso que obliga a numerar por posición y no por uso.
    private static func testNumbersTheNimbusLikeRetroArchDocumentsIt() throws {
        var elementos: [HIDElementInfo] = []
        for uso in UInt32(1)...8 { elementos.append(button(uso, 100 + uso)) }
        for (índice, uso) in [UInt32(144), 145, 146, 147].enumerated() {
            elementos.append(button(uso, 200 + UInt32(índice), page: 0x0C))
        }
        elementos.append(button(547, 300, page: 0x0C))

        let layout = RetroPadNumbering.layout(of: elementos)
        for (posición, elemento) in elementos.enumerated() {
            try expect(layout.buttons[elemento.cookie] == posición,
                       "el uso \(elemento.usage) tenía que caer en el \(posición), "
                       + "y cayó en \(layout.buttons[elemento.cookie].map(String.init) ?? "ninguno")")
        }
    }

    /// Lo que devuelve un DualSense de verdad —conectado por Bluetooth a este Mac— leído con IOKit:
    /// catorce botones en la página de botones y las galletas de los ejes **desordenadas**, que es
    /// justo lo que hace que ordenar antes de numerar no sea un adorno. La Rx y la Ry vienen con
    /// galletas más altas que la Z y la Rz, y aun así van antes porque su uso es menor.
    private static func testNumbersTheDualSenseAsTheRealPadReports() throws {
        var elementos: [HIDElementInfo] = []
        for uso in UInt32(1)...14 { elementos.append(button(uso, 57 + uso)) }
        elementos += [
            misc(0x30, 72), misc(0x31, 73),   // palanca izquierda
            misc(0x32, 74), misc(0x35, 75),   // gatillos
            misc(0x39, 76),                   // cruceta
            misc(0x33, 77), misc(0x34, 78)    // palanca derecha
        ]

        let layout = RetroPadNumbering.layout(of: elementos)
        for uso in UInt32(1)...14 {
            try expect(layout.buttons[57 + uso] == Int(uso) - 1,
                       "el botón \(uso) del DualSense va al número \(uso - 1)")
        }
        try expect(layout.axes[72] == 0 && layout.axes[73] == 1, "la palanca izquierda es 0 y 1")
        try expect(layout.axes[77] == 2 && layout.axes[78] == 3, "la derecha es 2 y 3")
        try expect(layout.axes[74] == 4 && layout.axes[75] == 5, "y los gatillos, 4 y 5")
        try expect(layout.hat == 76, "la cruceta no es un botón ni un eje: es la suya")

        // Que un botón se declare como `button` o como `misc` no cambia dónde cae: en la página de
        // botones RetroArch acepta los dos. Comprobarlo evita que la tabla dependa de un detalle
        // que ningún mando garantiza.
        let comoMisc = elementos.map { elemento -> HIDElementInfo in
            var copia = elemento
            if copia.page == 0x09 { copia.kind = .misc }
            return copia
        }
        try expect(RetroPadNumbering.layout(of: comoMisc).buttons == layout.buttons,
                   "el tipo del elemento no puede mover los botones de sitio")
    }

    // MARK: - Las tres reglas que deciden el número

    /// IOKit no promete ningún orden. Si la numeración dependiera de él, el mismo mando daría
    /// números distintos entre dos arranques y las asignaciones guardadas dejarían de valer.
    private static func testTheOrderOfTheElementsDoesNotChangeTheNumbers() throws {
        let elementos = [button(3, 30), button(1, 10), button(2, 20), misc(0x31, 41), misc(0x30, 40)]
        let layout = RetroPadNumbering.layout(of: elementos)
        let alRevés = RetroPadNumbering.layout(of: elementos.reversed())
        try expect(layout == alRevés, "el orden de entrada no puede cambiar la numeración")
        try expect(layout.buttons[10] == 0 && layout.buttons[20] == 1 && layout.buttons[30] == 2,
                   "y se numeran por uso, no por el orden en que llegan")
        try expect(layout.axes[40] == 0 && layout.axes[41] == 1, "los ejes, igual")
    }

    /// Dos elementos con el mismo uso existen: un mando puede declarar el mismo botón en dos
    /// sitios. El segundo no pisa al primero ni se cuela en medio —eso correría todos los que
    /// vienen detrás— sino que se va al final.
    private static func testARepeatedUsageGoesToTheEndInsteadOfStealingItsPlace() throws {
        let layout = RetroPadNumbering.layout(of: [
            button(1, 10), button(2, 20), button(1, 11), button(3, 30)
        ])
        try expect(layout.buttons[10] == 0, "el primero se queda con el 0")
        try expect(layout.buttons[20] == 1 && layout.buttons[30] == 2,
                   "los siguientes no se corren de sitio")
        try expect(layout.buttons[11] == 3, "y el repetido va detrás de todos")
    }

    /// Los ejes repetidos no se pierden: rellenan los números que hayan quedado libres.
    private static func testARepeatedAxisFillsTheFirstFreeNumber() throws {
        // Dos X y ninguna Y: la segunda X ocupa el hueco de la Y.
        let layout = RetroPadNumbering.layout(of: [misc(0x30, 40), misc(0x30, 41)])
        try expect(layout.axes[40] == 0, "la primera X es el eje 0")
        try expect(layout.axes[41] == 1, "y la segunda cae en el primer hueco libre, el 1")
    }

    // MARK: - La cruceta

    /// Los dos ajustes de RetroArch antes de leer la posición. Sin ellos, la cruceta de la mitad de
    /// los mandos apunta a otro lado: uno que declara cuatro posiciones las cuenta de dos en dos y
    /// otro que empieza en uno va corrido entero.
    private static func testTheHatKnowsWhereItPoints() throws {
        // Ocho posiciones contando desde cero: lo más común.
        try expect(RetroPadNumbering.hatDirection(value: 0, logicalMin: 0, logicalMax: 7) == "up",
                   "el cero de una cruceta de ocho es arriba")
        try expect(RetroPadNumbering.hatDirection(value: 2, logicalMin: 0, logicalMax: 7) == "right",
                   "el dos es la derecha")
        try expect(RetroPadNumbering.hatDirection(value: 4, logicalMin: 0, logicalMax: 7) == "down",
                   "el cuatro es abajo")
        try expect(RetroPadNumbering.hatDirection(value: 6, logicalMin: 0, logicalMax: 7) == "left",
                   "y el seis, la izquierda")
        try expect(RetroPadNumbering.hatDirection(value: 8, logicalMin: 0, logicalMax: 7) == nil,
                   "fuera de las ocho, está en el centro y no hay nada que asignar")
        try expect(RetroPadNumbering.hatDirection(value: 1, logicalMin: 0, logicalMax: 7) == nil,
                   "en diagonal hay dos direcciones a la vez: no se adivina cuál quería")

        // Cuatro posiciones: cada una vale por dos.
        try expect(RetroPadNumbering.hatDirection(value: 1, logicalMin: 0, logicalMax: 3) == "right",
                   "con cuatro posiciones, el uno ya es la derecha")
        try expect(RetroPadNumbering.hatDirection(value: 2, logicalMin: 0, logicalMax: 3) == "down",
                   "y el dos, abajo")

        // Y una que empieza a contar en uno.
        try expect(RetroPadNumbering.hatDirection(value: 1, logicalMin: 1, logicalMax: 8) == "up",
                   "si empieza en uno, su uno es arriba")
        try expect(RetroPadNumbering.hatDirection(value: 5, logicalMin: 1, logicalMax: 8) == "down",
                   "y su cinco, abajo")
    }

    // MARK: - Los ejes

    /// **La trampa del gatillo.** En reposo no vale cero: vale el extremo. Un umbral que mire solo
    /// el valor daría por pulsado un gatillo que nadie ha tocado, y el primer control que se
    /// intentara asignar se llevaría el gatillo suelto sin que el usuario tocara nada.
    private static func testATriggerAtRestIsNotAPressedAxis() throws {
        let enReposo = RetroPadNumbering.axisValue(0, physicalMin: 0, physicalMax: 255)
        try expect(enReposo < -32000, "un gatillo suelto marca el extremo, no el centro: \(enReposo)")
        let apretado = RetroPadNumbering.axisValue(255, physicalMin: 0, physicalMax: 255)
        try expect(apretado > 32000, "y apretado, el otro extremo: \(apretado)")

        // Una palanca centrada sí vale cero, que es lo que hace que se puedan distinguir.
        let centrada = RetroPadNumbering.axisValue(128, physicalMin: 0, physicalMax: 255)
        try expect(abs(centrada) < 300, "una palanca en el centro vale casi cero: \(centrada)")

        // Y un recorrido de cero no puede dividir entre cero.
        try expect(RetroPadNumbering.axisValue(5, physicalMin: 3, physicalMax: 3) == 0,
                   "un eje sin recorrido no vale nada")
    }

    /// RetroArch solo lee los treinta y dos primeros botones. Guardar el treinta y dos sería
    /// guardar un botón que no hace nada y no avisa: mejor no guardarlo.
    private static func testRefusesAButtonRetroArchWouldNotRead() throws {
        try expect(RetroPadNumbering.isUsable(button: 0), "el primero vale")
        try expect(RetroPadNumbering.isUsable(button: 31), "y el último que lee, también")
        try expect(!RetroPadNumbering.isUsable(button: 32), "el treinta y dos ya no lo lee")
        try expect(!RetroPadNumbering.isUsable(button: -1), "y un número negativo, menos")
    }

    // MARK: - De punta a punta

    /// Lo que se lee del mando tiene que acabar escrito con la forma exacta que RetroArch entiende:
    /// el botón como número pelado, la cruceta como `h0` más la dirección y el eje con su signo
    /// delante. Cualquier otra cosa la ignora sin dar error.
    private static func testWhatThePadReportsEndsUpInTheConfigFile() throws {
        var perfil = ControlProfile.standard
        perfil.gamepad[.a] = .button(1)
        perfil.gamepad[.up] = .hat(0, "up")
        perfil.gamepad[.r2] = .axis("+5")

        let líneas = RetroConfig.inputLines(for: perfil)
        func valor(_ clave: String) -> String? {
            líneas.first { $0.hasPrefix(clave + " =") }?
                .split(separator: "\"").dropFirst().first.map(String.init)
        }

        try expect(valor("input_player1_a_btn") == "1", "el botón va como número pelado")
        try expect(valor("input_player1_up_btn") == "h0up",
                   "la cruceta va por la clave del botón: \(valor("input_player1_up_btn") ?? "nada")")
        try expect(valor("input_player1_r2_axis") == "+5", "y el eje con su signo delante")
        // Asignar el mando no puede llevarse la tecla por delante: RetroArch admite las dos.
        try expect(valor("input_player1_a") == "x", "la tecla sigue donde estaba")

        // Y el número solo significa algo dentro del driver con el que se contó, así que la
        // configuración tiene que decir cuál es. Sin esta línea, un cambio de driver movería todos
        // los botones de sitio sin dar ningún error.
        let completa = RetroConfig.makeConfig(
            profile: perfil, platform: nil,
            saves: URL(fileURLWithPath: "/tmp/p"), states: URL(fileURLWithPath: "/tmp/e"),
            systemFiles: URL(fileURLWithPath: "/tmp/s"), data: URL(fileURLWithPath: "/tmp/d")
        )
        try expect(completa.contains("input_joypad_driver = \"hid\""),
                   "la configuración tiene que fijar el driver con el que se contaron los botones")
    }

    /// La familia sale de quién fabrica el mando, no de cómo dice llamarse: el nombre cambia con
    /// cada revisión y el par fabricante/modelo no.
    private static func testTellsTheFamilyByWhoMadeIt() throws {
        try expect(ConnectedGamepad.Family.of(vendor: 0x054C, product: 0x0CE6) == .dualSense,
                   "el DualSense de este Mac")
        try expect(ConnectedGamepad.Family.of(vendor: 0x054C, product: 0x05C4) == .dualShock,
                   "un DualShock 4")
        try expect(ConnectedGamepad.Family.of(vendor: 0x045E, product: 0x0B13) == .xbox,
                   "cualquier mando de Microsoft")
        try expect(ConnectedGamepad.Family.of(vendor: 0x1234, product: 0x0001) == .generic,
                   "y el resto habla el mismo protocolo igual")
        // Los nombres de los cuatro botones de la derecha son lo único que cambia entre familias.
        try expect(ConnectedGamepad.Family.dualSense.faceLabels.b == "✕", "en Sony, el de abajo es ✕")
        try expect(ConnectedGamepad.Family.xbox.faceLabels.b == "A", "y en Xbox, la A")
    }

    // MARK: - El dibujo

    /// Dos controles en el mismo sitio serían un botón que tapa a otro: uno de los dos no se podría
    /// pulsar nunca, y no habría nada en pantalla que lo dijera.
    private static func testEveryControlHasItsOwnPlaceOnTheDrawing() throws {
        for estilo in GamepadFaceplate.Style.allCases {
            var ocupados: [String: RetroPadInput] = [:]
            for control in RetroPadInput.allCases {
                let sitio = GamepadFaceplate.spot(of: control, style: estilo)
                try expect((0...1).contains(sitio.x) && (0...1).contains(sitio.y),
                           "\(estilo.rawValue): \(control.rawValue) se sale del dibujo")
                let clave = "\(sitio.x),\(sitio.y)"
                try expect(ocupados[clave] == nil,
                           "\(estilo.rawValue): \(control.rawValue) cae encima de "
                           + "\(ocupados[clave]?.rawValue ?? "")")
                ocupados[clave] = control
            }
        }
    }

    /// La diferencia que obliga a tener dos disposiciones: en un mando de Xbox la palanca izquierda
    /// está **donde un PlayStation tiene la cruceta**. Dibujarlas iguales manda a buscar un botón
    /// donde no está, que es justo lo que el dibujo tiene que evitar.
    private static func testAnXboxPadIsNotDrawnLikeAPlayStationOne() throws {
        let sonyCruceta = GamepadFaceplate.spot(of: .up, style: .sony)
        let xboxCruceta = GamepadFaceplate.spot(of: .up, style: .xbox)
        try expect(xboxCruceta.y > sonyCruceta.y, "en un Xbox la cruceta va más abajo")

        let sonyPalanca = GamepadFaceplate.spot(of: .l3, style: .sony)
        let xboxPalanca = GamepadFaceplate.spot(of: .l3, style: .xbox)
        try expect(xboxPalanca.y < sonyPalanca.y && xboxPalanca.x < sonyPalanca.x,
                   "y la palanca izquierda sube y se va a la izquierda, al hueco de la cruceta")
        // El rombo no se mueve de lado en ninguno de los dos: es la referencia de todo el dibujo.
        try expect(GamepadFaceplate.spot(of: .a, style: .sony).x > 0.5
                   && GamepadFaceplate.spot(of: .a, style: .xbox).x > 0.5,
                   "el rombo se queda a la derecha en los dos")

        // Sin mando conectado se dibuja el de PlayStation: el RetroPad tiene su forma, así que es
        // el que describe lo que se está configurando.
        try expect(GamepadFaceplate.style(for: nil) == .sony, "sin mando, el del RetroPad")
        try expect(GamepadFaceplate.style(for: .dualSense) == .sony, "un DualSense es de esa forma")
        try expect(GamepadFaceplate.style(for: .xbox) == .xbox, "y solo el de Xbox es el otro")
    }

    /// Cada fabricante llama a lo mismo de otra manera, y el dibujo tiene que usar **su** nombre:
    /// en un DualSense no pone «Select» por ninguna parte, así que buscarlo es perder el rato.
    private static func testEachPadIsNamedTheWayItIsPrinted() throws {
        try expect(ConnectedGamepad.Family.dualSense.menuLabels.select == "Create",
                   "el DualSense lo llama Create")
        try expect(ConnectedGamepad.Family.dualShock.menuLabels.select == "Share",
                   "el DualShock 4, Share")
        try expect(ConnectedGamepad.Family.xbox.menuLabels == ("Menu", "View"),
                   "y el de Xbox, Menu y View")
        try expect(ConnectedGamepad.Family.generic.menuLabels == ("Start", "Select"),
                   "sin saber cuál es, los nombres de siempre")

        try expect(ConnectedGamepad.Family.xbox.shoulderLabels.l2 == "LT",
                   "en Xbox los gatillos son triggers")
        try expect(ConnectedGamepad.Family.dualSense.shoulderLabels.l2 == "L2", "y en Sony, L2")
        try expect(ConnectedGamepad.Family.xbox.stickLabels.left == "LS",
                   "pulsar la palanca también cambia de nombre")
    }
}
