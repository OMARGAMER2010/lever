import CoreGraphics
import Foundation
import LeverCore

/// La pantalla completa de Android, sin emulador: el archivo de descubrimiento, los mensajes que
/// se mandan, las cuentas de girar y recortar y la lectura de lo que dicen `adb` y el sistema de
/// ventanas. Los datos de ejemplo son los medidos en este Mac el 2026-09-21, con el emulador 37.1.11
/// y un Pixel 6 de 1080×2400.
@MainActor
enum AndroidFullscreenTests {
    static func run() throws {
        try testReadsTheDiscoveryFile()
        try testIgnoresDiscoveryWithoutKey()
        try testListsOnlyLiveEmulators()
        try testWritesProtobufFields()
        try testReadsProtobufFields()
        try testBuildsInputMessages()
        try testReadsAScreenImage()
        try testWritesAndReadsFrames()
        try testBuildsRequestHeaders()
        try testReadsRealTrailers()
        try testJoinsSplitGrpcMessages()
        try testRotatesPointsAndRects()
        try testShowsTheGameUpright()
        try testMapsClicksBackToThePanel()
        try testReadsAndroidScreenState()
        try testCropsToTheAppWithoutBars()
        try testFindsTheEmulatorWindows()
        try testPlacesTheButtonUnderTheMenu()
        try testAsksAndroidInOneCommand()
        try testModelNeedsARunningEmulator()
    }

    // MARK: - Descubrimiento

    private static func testReadsTheDiscoveryFile() throws {
        let texto = """
        emulator.build=15917651
        avd.id=Lever
        port.serial=5554
        port.adb=5555
        avd.name=Lever
        emulator.version=37.1.11.0
        cmdline="/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64" "-avd" "Lever"
        grpc.token=llave-de-prueba
        grpc.port=8554
        """
        let punto = EmulatorDiscovery.endpoint(fromDiscovery: texto, pid: 76325)
        try expect(punto?.grpcPort == 8554, "el puerto sale de grpc.port")
        try expect(punto?.token == "llave-de-prueba", "la llave sale de grpc.token")
        try expect(punto?.adbSerial == "emulator-5554", "la serie de adb se forma con el puerto de consola")
        try expect(punto?.avdName == "Lever", "el nombre del aparato se conserva")
        try expect(EmulatorDiscovery.pid(fromFileName: "pid_76325.ini") == 76325, "el PID va en el nombre")
        try expect(EmulatorDiscovery.pid(fromFileName: "76325") == nil,
                   "la carpeta con el número al lado no es un archivo de descubrimiento")
    }

    private static func testIgnoresDiscoveryWithoutKey() throws {
        try expect(EmulatorDiscovery.endpoint(fromDiscovery: "grpc.port=8554\n", pid: 1) == nil, "sin llave no hay canal")
        try expect(EmulatorDiscovery.endpoint(fromDiscovery: "grpc.token=abc\n", pid: 1) == nil, "sin puerto tampoco")
        try expect(EmulatorDiscovery.endpoint(fromDiscovery: "grpc.port=cero\ngrpc.token=abc\n", pid: 1) == nil,
                   "un puerto que no es un número no vale")
    }

    private static func testListsOnlyLiveEmulators() throws {
        let fixture = try TemporaryFixture()
        let carpeta = fixture.directoryURL
        try "grpc.port=8554\ngrpc.token=a\nport.serial=5554\n"
            .write(to: carpeta.appendingPathComponent("pid_100.ini"), atomically: true, encoding: .utf8)
        try "grpc.port=8556\ngrpc.token=b\nport.serial=5556\n"
            .write(to: carpeta.appendingPathComponent("pid_200.ini"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: carpeta.appendingPathComponent("200"), withIntermediateDirectories: true)

        let vivos = EmulatorDiscovery.running(in: [carpeta], isAlive: { $0 == 200 })
        try expect(vivos.map(\.pid) == [200], "el archivo de un emulador que ya no está se ignora")
        try expect(vivos.first?.adbSerial == "emulator-5556", "y el del vivo se lee entero")
    }

    // MARK: - Protobuf y mensajes

    private static func testWritesProtobufFields() throws {
        try expect(ProtoWire.varint(0) == Data([0]), "cero ocupa un byte")
        try expect(ProtoWire.varint(300) == Data([0xAC, 0x02]), "300: el ejemplo de la documentación de protobuf")
        try expect(ProtoWire.field(1, int: 150) == Data([0x08, 0x96, 0x01]), "campo 1 con 150, también de la documentación")
        let menosUno = Data([UInt8(0x10)] + [UInt8](repeating: 0xFF, count: 9) + [UInt8(0x01)])
        try expect(ProtoWire.field(2, int: -1) == menosUno, "un negativo ocupa diez bytes")
        try expect(ProtoWire.field(3, bytes: Data("hi".utf8)) == Data([0x1A, 0x02, 0x68, 0x69]),
                   "texto con su longitud delante")
    }

    private static func testReadsProtobufFields() throws {
        let mensaje = ProtoWire.field(1, int: 7) + ProtoWire.field(4, bytes: Data([1, 2, 3])) + ProtoWire.field(1, int: 9)
        let leído = ProtoMessage(mensaje)
        try expect(leído?.varint(1) == 9, "si un campo se repite, manda el último")
        try expect(leído?.bytes(4) == Data([1, 2, 3]), "los bytes se leen tal cual")
        try expect(leído?.varint(2) == nil, "un campo que no está es nil, no cero")
        try expect(ProtoMessage(Data([0x0A, 0x05, 0x01])) == nil, "una longitud que se sale del mensaje lo invalida")
    }

    private static func testBuildsInputMessages() throws {
        // El toque que se mandó a mano al emulador de este Mac y pulsó «PLAY»: (439, 919), abajo.
        let dedo = EmulatorMessages.mouse(x: 439, y: 919, pressed: true)
        try expect(dedo == Data([0x08, 0xB7, 0x03, 0x10, 0x97, 0x07, 0x18, 0x01]), "x, y y botón, en ese orden")
        let flecha = EmulatorMessages.key(macKeyCode: 125, down: true)
        try expect(flecha == Data([0x08, 0x04, 0x10, 0x00, 0x18, 0x7D]),
                   "flecha abajo del Mac, con codeType Mac (4) y keydown (0)")
        try expect(EmulatorMessages.key(macKeyCode: 125, down: false)[3] == 0x01, "soltar es keyup (1)")
        try expect(EmulatorMessages.inputEvent(mouse: dedo).prefix(2) == Data([0x1A, 0x08]),
                   "el ratón va en el hueco 3 de InputEvent")
        try expect(EmulatorMessages.inputEvent(key: flecha).prefix(2) == Data([0x0A, 0x06]), "la tecla, en el 1")
        try expect(EmulatorMessages.screenFormat() == Data([0x08, 0x01]), "imágenes en RGBA8888, a tamaño nativo")
    }

    private static func testReadsAScreenImage() throws {
        let giro = ProtoWire.field(1, int: 3)
        let formato = ProtoWire.field(1, int: 1) + ProtoWire.field(2, bytes: giro)
            + ProtoWire.field(3, int: 2) + ProtoWire.field(4, int: 1)
        let píxeles = Data([1, 2, 3, 255, 4, 5, 6, 255])
        let imagen = ProtoWire.field(1, bytes: formato) + ProtoWire.field(4, bytes: píxeles) + ProtoWire.field(5, int: 42)

        let leída = EmulatorMessages.frame(fromImage: imagen)
        try expect(leída?.width == 2 && leída?.height == 1, "el tamaño sale del formato")
        try expect(leída?.rotation == 3, "y el giro de la piel también")
        try expect(leída?.pixels == píxeles && leída?.sequence == 42, "los píxeles y la secuencia, tal cual")
        try expect(EmulatorMessages.frame(fromImage: ProtoWire.field(5, int: 1))?.isEmpty == true,
                   "con la pantalla apagada llega una imagen de 0×0")
        let rota = ProtoWire.field(1, bytes: formato) + ProtoWire.field(4, bytes: Data([1, 2, 3]))
        try expect(EmulatorMessages.frame(fromImage: rota) == nil, "si los píxeles no cuadran con el tamaño, no vale")
    }

    // MARK: - HTTP/2

    private static func testWritesAndReadsFrames() throws {
        let trama = HTTP2Wire.frame(.data, flags: HTTP2Wire.Flag.endStream, stream: 3, payload: Data([9, 9]))
        try expect(trama == Data([0, 0, 2, 0, 1, 0, 0, 0, 3, 9, 9]), "longitud, tipo, marcas y flujo, en nueve bytes")
        try expect(HTTP2Wire.FrameHeader(trama) == HTTP2Wire.FrameHeader(length: 2, type: 0, flags: 1, stream: 3),
                   "y se leen igual")
        let ajustes = HTTP2Wire.settings(in: Data([0, 4, 0, 1, 0, 0, 0, 5, 0, 0, 0x40, 0]))
        try expect(ajustes.count == 2 && ajustes[0].id == 4 && ajustes[0].value == 65_536 && ajustes[1].value == 16_384,
                   "los ajustes van de seis en seis bytes")
        try expect(HTTP2Wire.content(of: Data([2, 0xAA, 0xBB, 0, 0]), flags: HTTP2Wire.Flag.padded, isHeaders: false)
                    == Data([0xAA, 0xBB]), "el relleno se quita")
        try expect(HTTP2Wire.content(of: Data([9, 1]), flags: HTTP2Wire.Flag.padded, isHeaders: false) == nil,
                   "un relleno más largo que la trama es un error")
    }

    private static func testBuildsRequestHeaders() throws {
        let bloque = HTTP2Wire.requestHeaders(path: EmulatorMessages.Method.getStatus, authority: "127.0.0.1:8554", token: "llave")
        try expect(bloque.prefix(2) == Data([0x83, 0x86]), ":method POST y :scheme http van por índice")
        let campos = HPACKDecoder().decode(bloque) ?? []
        func valor(_ nombre: String) -> String? { campos.first { $0.name == nombre }?.value }
        try expect(valor(":path") == "/android.emulation.control.EmulatorController/getStatus", "la ruta del método")
        try expect(valor(":method") == "POST", "el índice 3 de la tabla estática es POST")
        try expect(valor("authorization") == "Bearer llave", "la llave va como Bearer")
        try expect(valor("te") == "trailers", "gRPC exige te: trailers")
        let larga = HTTP2Wire.hpackString(String(repeating: "x", count: 200))
        try expect(larga.prefix(3) == Data([0x7F, 0x49, 0x78]), "una longitud de 127 o más sigue en bytes de más")
    }

    private static func testReadsRealTrailers() throws {
        let decoder = HPACKDecoder()
        // Los trailers de la primera llamada al emulador de este Mac: grpc-status 0, que además
        // entra en la tabla dinámica…
        try expect(decoder.decode(hexData("400b677270632d7374617475730130"))?.first?.value == "0", "grpc-status 0")
        // …y en la llamada siguiente llegó solo su número de entrada: 0xbe, la 62.
        let segunda = decoder.decode(Data([0xBE]))
        try expect(segunda?.first?.name == "grpc-status" && segunda?.first?.value == "0",
                   "la tabla dinámica se recuerda entre bloques")
        // Con una llave mala: :status 200, content-type y grpc-status 16, todo literal.
        let rechazo = hexData("00073a73746174757303323030"
            + "000c636f6e74656e742d74797065106170706c69636174696f6e2f67727063"
            + "000b677270632d737461747573023136")
        try expect(HPACKDecoder().decode(rechazo)?.first(where: { $0.name == "grpc-status" })?.value == "16",
                   "grpc-status 16: sin autenticar")
        // Un Huffman que tenía que entrar en la tabla la deja sin fiar.
        let conHuffman = HPACKDecoder()
        _ = conHuffman.decode(Data([0x40, 0x81, 0xFF, 0x01, 0x30]))
        try expect(!conHuffman.isReliable && conHuffman.decode(Data([0xBE])) == nil,
                   "tras un Huffman que entra en la tabla ya no se lee nada")
    }

    private static func testJoinsSplitGrpcMessages() throws {
        var lector = GrpcMessageReader()
        let todo = HTTP2Wire.grpcMessage(Data("uno".utf8)) + HTTP2Wire.grpcMessage(Data("dos".utf8))
        try expect(lector.append(todo.prefix(4)).isEmpty, "con medio prefijo no hay mensaje")
        try expect(lector.append(todo.dropFirst(4).prefix(6)) == [Data("uno".utf8)], "el primero sale en cuanto está entero")
        try expect(lector.append(todo.dropFirst(10)) == [Data("dos".utf8)], "y el segundo con el resto")
        var otro = GrpcMessageReader()
        try expect(otro.append(todo) == [Data("uno".utf8), Data("dos".utf8)], "dos mensajes en una trama salen los dos")
    }

    // MARK: - Geometría

    private static let pixel6 = PixelSize(width: 1080, height: 2400)
    private static let pantallaDelMac = CGSize(width: 1728, height: 1117)

    private static func testRotatesPointsAndRects() throws {
        let esquina = ScreenGeometry.rotate(x: 0, y: 0, quarterTurns: 1, in: pixel6)
        try expect(esquina.x == 0 && esquina.y == 1080, "un cuarto de vuelta antihorario lleva (0,0) abajo")
        let vuelta = ScreenGeometry.rotate(x: 12, y: 34, quarterTurns: 4, in: pixel6)
        try expect(vuelta.x == 12 && vuelta.y == 34, "cuatro cuartos dejan el punto donde estaba")
        let a = ScreenGeometry.rotate(x: 900, y: 638, quarterTurns: -1, in: pixel6.swapped)
        let b = ScreenGeometry.rotate(x: 900, y: 638, quarterTurns: 3, in: pixel6.swapped)
        try expect(a.x == b.x && a.y == b.y, "girar -1 es girar 3")
        let recorte = ScreenGeometry.rotate(PixelRect(x: 128, y: 0, width: 2272, height: 1017), quarterTurns: 3, in: pixel6.swapped)
        try expect(recorte == PixelRect(x: 63, y: 128, width: 1017, height: 2272),
                   "el recorte de Android pasado a la imagen vertical: \(recorte)")
    }

    private static func testShowsTheGameUpright() throws {
        // Lo medido: Android a 90°, piel en vertical. El juego deja libres la barra de navegación
        // (63 px abajo) y el hueco de cámara (128 px a la izquierda).
        let medido = ScreenGeometry(natural: pixel6, androidRotation: 1, imageRotation: 0,
                                    visibleArea: PixelRect(x: 128, y: 0, width: 2272, height: 1017),
                                    viewSize: pantallaDelMac)
        try expect(medido.extraRotation == 1, "la imagen llega de lado y hay que girarla un cuarto de vuelta")
        try expect(medido.cropInImage == PixelRect(x: 63, y: 128, width: 1017, height: 2272),
                   "en la imagen vertical la barra está a la izquierda y el hueco arriba")
        let r = medido.displayRect
        try expect(abs(r.width - 1728) < 0.5 && abs(r.midX - 864) < 0.5 && abs(r.midY - 558.5) < 0.5,
                   "ocupa todo el ancho de la pantalla del Mac, centrada: \(r)")

        let deAcuerdo = ScreenGeometry(natural: pixel6, androidRotation: 3, imageRotation: 3,
                                       visibleArea: nil, viewSize: pantallaDelMac)
        try expect(deAcuerdo.extraRotation == 0 && deAcuerdo.cropInImage == PixelRect(x: 0, y: 0, width: 2400, height: 1080),
                   "con la piel girada como Android, la imagen se enseña tal cual")
    }

    private static func testMapsClicksBackToThePanel() throws {
        // «PLAY» estaba en (900, 638) de la pantalla de Android y el toque que lo pulsó, en (442, 900)
        // del panel. A escala 1 y sin recorte, el camino de vuelta tiene que dar eso exacto.
        let entera = ScreenGeometry(natural: pixel6, androidRotation: 1, imageRotation: 0,
                                    visibleArea: nil, viewSize: CGSize(width: 2400, height: 1080))
        let play = entera.naturalPoint(fromView: CGPoint(x: 900, y: 638))
        try expect(play?.x == 442 && play?.y == 900, "se deshace el giro de Android: \(String(describing: play))")

        let recortada = ScreenGeometry(natural: pixel6, androidRotation: 1, imageRotation: 0,
                                       visibleArea: PixelRect(x: 128, y: 0, width: 2272, height: 1017),
                                       viewSize: pantallaDelMac)
        let centro = recortada.naturalPoint(fromView: CGPoint(x: recortada.displayRect.midX, y: recortada.displayRect.midY))
        try expect(centro.map { abs($0.x - 571) <= 1 && abs($0.y - 1264) <= 1 } == true,
                   "el centro de lo visible: \(String(describing: centro))")
        try expect(recortada.naturalPoint(fromView: CGPoint(x: 5, y: 5)) == nil, "un clic en la franja negra no toca nada")
        try expect(recortada.naturalPoint(fromView: CGPoint(x: 5, y: 5), clamped: true) != nil,
                   "un arrastre que se sale se queda en el borde")
    }

    // MARK: - Lo que dice Android

    private static func testReadsAndroidScreenState() throws {
        let salida = """
              mFocusedApp=ActivityRecord{f03b7a6 u0 com.tioeroge.BulmasBallsTheGame/com.rpgmaker.only.MainActivity t27}
              mCurrentRotation=ROTATION_90
                InsetsSource id=ccd70001 type=navigationBars frame=[0,1017][2400,1080] visible=true flags=SUPPRESS_SCRIM insetsRoundedCornerFrame=false
                InsetsSource id=ccd70004 type=systemGestures frame=[0,0][206,1080] visible=true flags= insetsRoundedCornerFrame=false
                InsetsSource id=7 type=displayCutout frame=[0,0][128,1080] visible=true flags= insetsRoundedCornerFrame=false
                InsetsSource id=3ea20000 type=statusBars frame=[0,0][2400,63] visible=false flags= insetsRoundedCornerFrame=false
                mSource=InsetsSource id=ccd70001 type=navigationBars frame=[0,1017][2400,1080] visible=true flags=SUPPRESS_SCRIM insetsRoundedCornerFrame=false
          Window #4 Window{3a8da0 u0 NavigationBar0}:
            Frames: parent=[0,0][2400,1080] display=[0,0][2400,1080] frame=[0,954][2400,1080] last=[0,954][2400,1080] insetsChanged=false
          Window #8 Window{bcbbf6e u0 com.tioeroge.BulmasBallsTheGame/com.rpgmaker.only.MainActivity}:
            Frames: parent=[128,0][2400,1017] display=[128,0][2400,1017] frame=[242,253][2286,763] last=[242,253][2286,763] insetsChanged=false
          Window #10 Window{88f4d44 u0 com.tioeroge.BulmasBallsTheGame/com.rpgmaker.only.MainActivity}:
            Frames: parent=[128,0][2400,1080] display=[128,0][2400,1080] frame=[128,0][2400,1080] last=[128,0][2400,1080] insetsChanged=false
          Window #11 Window{27227e2 u0 com.google.android.apps.nexuslauncher/com.google.android.apps.nexuslauncher.NexusLauncherActivity}:
            Frames: parent=[0,0][2400,1080] display=[0,0][2400,1080] frame=[0,0][2400,1080] last=[0,0][2400,1080] insetsChanged=false
        """
        let estado = AndroidScreenState.parse(salida)
        try expect(estado.rotation == 1, "ROTATION_90 es un cuarto de vuelta")
        try expect(estado.visibleBars == [PixelRect(x: 0, y: 1017, width: 2400, height: 63)],
                   "solo la barra de navegación está a la vista, y una vez aunque salga repetida")
        try expect(estado.appFrame == PixelRect(x: 128, y: 0, width: 2272, height: 1080),
                   "el marco del juego es el de su ventana grande, no el del diálogo")
        try expect(AndroidScreenState.parse("basura\n").rotation == nil, "sin datos no se inventa el giro")
    }

    private static func testCropsToTheAppWithoutBars() throws {
        let juego = AndroidScreenState(rotation: 1,
                                       visibleBars: [PixelRect(x: 0, y: 1017, width: 2400, height: 63)],
                                       appFrame: PixelRect(x: 128, y: 0, width: 2272, height: 1080))
        try expect(juego.visibleArea(in: pixel6.swapped) == PixelRect(x: 128, y: 0, width: 2272, height: 1017),
                   "el marco del juego sin la barra de abajo")
        let vertical = AndroidScreenState(rotation: 0,
                                          visibleBars: [PixelRect(x: 0, y: 0, width: 1080, height: 63),
                                                        PixelRect(x: 0, y: 2274, width: 1080, height: 126)],
                                          appFrame: nil)
        try expect(vertical.visibleArea(in: pixel6) == PixelRect(x: 0, y: 63, width: 1080, height: 2211),
                   "en vertical, sin la barra de estado ni la de navegación")
        let diminuto = AndroidScreenState(rotation: 1, visibleBars: [], appFrame: PixelRect(x: 1000, y: 500, width: 100, height: 100))
        try expect(diminuto.visibleArea(in: pixel6.swapped) == PixelRect(x: 0, y: 0, width: 2400, height: 1080),
                   "un marco diminuto no se amplía: se enseña todo")
    }

    // MARK: - Ventanas del emulador

    private static func testFindsTheEmulatorWindows() throws {
        // Lo medido: la ventana principal de 402×922, el menú de 54×506 pegado a su derecha y las
        // del menú de la app arriba, que no cuentan. Y una ventana estrecha de Lever, que tampoco.
        let ventanas = [
            EmulatorWindowLayout.WindowInfo(number: 1, ownerPID: 70319, ownerName: "qemu-system-aarch64", layer: 0,
                                            bounds: CGRect(x: 0, y: 0, width: 1728, height: 33)),
            EmulatorWindowLayout.WindowInfo(number: 37930, ownerPID: 70319, ownerName: "qemu-system-aarch64", layer: 0,
                                            bounds: CGRect(x: 992, y: 280, width: 54, height: 506)),
            EmulatorWindowLayout.WindowInfo(number: 37929, ownerPID: 70319, ownerName: "qemu-system-aarch64", layer: 0,
                                            bounds: CGRect(x: 590, y: 252, width: 402, height: 922)),
            EmulatorWindowLayout.WindowInfo(number: 5, ownerPID: 62893, ownerName: "Lever", layer: 0,
                                            bounds: CGRect(x: 531, y: 195, width: 54, height: 506))
        ]
        let emuladores = EmulatorWindowLayout.emulators(in: ventanas)
        try expect(emuladores.count == 1, "un emulador; la ventana estrecha de otra app no es un menú lateral")
        try expect(emuladores.first?.toolbarNumber == 37930 && emuladores.first?.main.width == 402,
                   "el menú y la ventana pegada a su izquierda")
        try expect(emuladores.first?.pid == 70319, "el PID es el mismo del archivo de descubrimiento")
        try expect(EmulatorWindowLayout.emulators(in: [ventanas[1]]).isEmpty,
                   "un menú sin su ventana no es un emulador que acompañar")
    }

    private static func testPlacesTheButtonUnderTheMenu() throws {
        let pantalla = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let debajo = EmulatorWindowLayout.buttonFrame(for: CGRect(x: 992, y: 280, width: 54, height: 506), within: pantalla)
        try expect(debajo == CGRect(x: 992, y: 792, width: 54, height: 44), "debajo del menú, con su ancho y seis puntos de aire")
        let sinSitio = EmulatorWindowLayout.buttonFrame(for: CGRect(x: 992, y: 600, width: 54, height: 506), within: pantalla)
        try expect(sinSitio == CGRect(x: 992, y: 550, width: 54, height: 44), "si abajo no cabe, encima")
    }

    private static func testAsksAndroidInOneCommand() throws {
        let orden = AndroidLauncher.screenStateCommand(adb: URL(fileURLWithPath: "/opt/homebrew/bin/adb"), serial: "emulator-5554")
        try expect(Array(orden.arguments.prefix(3)) == ["-s", "emulator-5554", "shell"], "al aparato elegido")
        let script = orden.arguments.last ?? ""
        try expect(script.contains("mCurrentRotation=") && script.contains("InsetsSource") && script.contains("Frames:"),
                   "giro, barras y marcos en una sola ida y vuelta")
    }

    // MARK: - El modelo

    private static func testModelNeedsARunningEmulator() throws {
        let model = AppModel(locator: RuntimeLocator(
            wineCandidates: [], sevenZipCandidates: [], unarCandidates: [], unrarCandidates: [],
            homebrewCandidates: [], adbCandidates: [], emulatorCandidates: []
        ))
        try expect(!model.canOpenAndroidFullscreen, "sin aparato elegido no se ofrece la pantalla completa")
        // Un PID que no es de ningún emulador: no hay canal, y se dice.
        try expect(model.openAndroidFullscreen(emulatorPID: 999_999) == nil, "sin su archivo no se abre nada")
        try expect(model.lastError != nil && !model.isAndroidFullscreen, "y el motivo queda a la vista")
    }
}
