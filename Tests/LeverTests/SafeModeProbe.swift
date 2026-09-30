import AppKit
import CoreServices
import Darwin
import Foundation

/// El programa hostil de las pruebas de Safe Mode.
///
/// Es el mismo ejecutable de las pruebas, llamado con `--safe-mode-probe`: se clona dentro del
/// «motor» de una sesión aislada y desde ahí intenta todo lo que haría un malware. Hace falta así
/// porque macOS mata las copias de los binarios del sistema (`/bin/bash` copiado muere con
/// `SIGKILL`), y porque las llamadas nativas son justo lo que el código de Windows puede hacer
/// saltándose Wine.
enum SafeModeProbe {
    static let flag = "--safe-mode-probe"

    /// Si el proceso se lanzó como sonda, hace su trabajo y termina sin volver.
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == flag else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        switch arguments[2] {
        case "escape" where arguments.count >= 5:
            escape(files: arguments[3], outside: arguments[4])
        case "child-write" where arguments.count >= 4:
            if FileManager.default.createFile(atPath: arguments[3] + "/hijo.txt", contents: Data("x".utf8)) {
                print("FUGA_HIJO")
            }
        case "sleep":
            sleep(60)
        default:
            break
        }
        exit(0)
    }

    private static func escape(files: String, outside: String) {
        let fileManager = FileManager.default
        print("DLL_PATH=" + (ProcessInfo.processInfo.environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""))
        if fileManager.createFile(atPath: files + "/dentro.txt", contents: Data("ok".utf8)) { print("DENTRO_OK") }
        if fileManager.createFile(atPath: outside + "/escape.txt", contents: Data("x".utf8)) { print("FUGA_ESCRITURA") }
        if fileManager.contents(atPath: outside + "/secreto.txt") != nil { print("FUGA_LECTURA") }
        // La carpeta personal de verdad, no la del HOME aislado.
        if let account = getpwuid(getuid()),
           (try? fileManager.contentsOfDirectory(atPath: String(cString: account.pointee.pw_dir) + "/Documents")) != nil {
            print("FUGA_DOCUMENTOS")
        }
        if canConnect(ip: "1.1.1.1", port: 443) { print("FUGA_RED_IP") }
        var info: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo("apple.com", "443", nil, &info) == 0 { print("FUGA_RED_DNS"); freeaddrinfo(info) }
        if spawn("/bin/ls", ["/bin/ls", "/"], wait: true) == 0 { print("FUGA_EXEC") }
        _ = spawn(CommandLine.arguments[0], [CommandLine.arguments[0], flag, "child-write", outside], wait: true)
        if fileManager.createFile(atPath: files + "/trampa.command", contents: Data("#!/bin/sh\n".utf8)) {
            print("FUGA_LANZABLE")
        }
        if LSOpenCFURLRef(URL(fileURLWithPath: "/System/Applications/Chess.app") as CFURL, nil) == 0 {
            print("FUGA_LAUNCHSERVICES")
        }
        if NSWorkspace.shared.open(URL(string: "http://127.0.0.1:9/lever-safe-mode-probe")!) { print("FUGA_URL") }
        if NSPasteboard.general.string(forType: .string) != nil { print("FUGA_PORTAPAPELES") }
        links(files: files, outside: outside)
        paths(files: files, outside: outside)
        // Un hijo que se desliga de su padre y sigue vivo cuando la sesión «termina».
        _ = spawn(CommandLine.arguments[0], [CommandLine.arguments[0], flag, "sleep"], wait: false, detach: true)
        print("FIN")
    }

    /// Enlaces: crearlos dentro puede estar permitido —Wine los necesita para sus unidades—, pero
    /// lo que importa es que no sirvan de puente. Lo que se mira es si de verdad se lee o se escribe
    /// al otro lado, no si la llamada que los crea devuelve error.
    private static func links(files: String, outside: String) {
        let fileManager = FileManager.default
        let soft = files + "/puente"
        if symlink(outside, soft) == 0 {
            print("ENLACE_CREADO")
            if fileManager.createFile(atPath: soft + "/porelenlace.txt", contents: Data("x".utf8)) {
                print("FUGA_ENLACE_ESCRITURA")
            }
            if fileManager.contents(atPath: soft + "/secreto.txt") != nil { print("FUGA_ENLACE_LECTURA") }
            if (try? fileManager.contentsOfDirectory(atPath: soft)) != nil { print("FUGA_ENLACE_LISTADO") }
        }
        // Un enlace duro comparte el archivo de verdad: sobreviviría al borrado del espacio.
        if link(outside + "/secreto.txt", files + "/duro.txt") == 0 { print("FUGA_ENLACE_DURO") }
        // Y el mismo truco apuntando a la carpeta personal de verdad.
        if let account = getpwuid(getuid()) {
            let home = String(cString: account.pointee.pw_dir)
            let toHome = files + "/casa"
            if symlink(home, toHome) == 0, (try? fileManager.contentsOfDirectory(atPath: toHome)) != nil {
                print("FUGA_ENLACE_CASA")
            }
        }
    }

    /// Salirse por la ruta: subiendo con `..` hasta la raíz y bajando otra vez, o yendo directo a
    /// una ruta absoluta. El kernel resuelve la ruta antes de mirar el perfil, así que ninguna de
    /// las dos debería llegar a ningún sitio.
    private static func paths(files: String, outside: String) {
        let fileManager = FileManager.default
        let ups = String(repeating: "../", count: files.split(separator: "/").count)
        let relative = files + "/" + ups + outside.dropFirst()
        if fileManager.createFile(atPath: relative + "/relativa.txt", contents: Data("x".utf8)) {
            print("FUGA_RUTA_RELATIVA")
        }
        if fileManager.contents(atPath: relative + "/secreto.txt") != nil { print("FUGA_RUTA_RELATIVA_LECTURA") }
        for target in ["/private/tmp/lever-sonda-\(getpid()).txt",
                       (getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/tmp") + "/lever-sonda.txt"] {
            if fileManager.createFile(atPath: target, contents: Data("x".utf8)) {
                print("FUGA_RUTA_ABSOLUTA \(target)")
                unlink(target)
            }
        }
        // El /tmp compartido es donde viven los wineserver de las otras sesiones y del modo normal.
        if (try? fileManager.contentsOfDirectory(atPath: "/private/tmp")) != nil { print("FUGA_TMP_COMPARTIDO") }
    }

    private static func canConnect(ip: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(ip)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// Devuelve el código de salida si espera, 0 si lanzó sin esperar, o -1 si no pudo lanzar.
    private static func spawn(_ path: String, _ arguments: [String], wait: Bool, detach: Bool = false) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if detach { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) }
        // El que se desliga suelta la salida: si no, la tubería de la prueba seguiría abierta con él.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if detach {
            for descriptor: Int32 in [0, 1, 2] {
                posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
            }
        }
        var pid: pid_t = 0
        let cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        guard posix_spawn(&pid, path, &actions, &attributes, cArguments, environ) == 0 else { return -1 }
        guard wait else { return 0 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
    }
}
