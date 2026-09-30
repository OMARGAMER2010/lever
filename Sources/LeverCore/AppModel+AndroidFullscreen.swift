import Foundation

extension AppModel {
    /// La barra de la pestaña Android ofrece la pantalla completa cuando el aparato elegido es un
    /// emulador listo. Con un móvil no hay nada que agrandar: su pantalla es la del móvil.
    public var canOpenAndroidFullscreen: Bool {
        guard let device = selectedDevice else { return false }
        return device.isEmulator && device.availability == .ready && !isAndroidFullscreen
    }

    /// Abre la pantalla completa. Con PID —el botón pegado al menú lateral sabe de qué emulador
    /// viene— se usa ese; sin él, el emulador elegido en la pestaña Android.
    public func openAndroidFullscreen(emulatorPID: Int32?) -> AndroidFullscreenSession? {
        let enMarcha = EmulatorDiscovery.running(fileManager: fileManager)
        let elegido: EmulatorEndpoint?
        if let pid = emulatorPID {
            elegido = enMarcha.first { $0.pid == pid }
        } else if let serie = selectedDevice?.serial {
            elegido = enMarcha.first { $0.adbSerial == serie }
        } else {
            elegido = enMarcha.first
        }
        guard let endpoint = elegido else {
            let sinNinguno = enMarcha.isEmpty && emulatorPID == nil
            showError(strings[sinNinguno ? .errFullscreenNoEmulator : .errFullscreenNoChannel])
            return nil
        }
        let canal: EmulatorChannel
        do {
            canal = try EmulatorChannel(port: endpoint.grpcPort, token: endpoint.token)
        } catch {
            showError(strings[.errFullscreenNoChannel])
            return nil
        }
        clearError()
        isAndroidFullscreen = true
        add(strings(.logFullscreenOpened, endpoint.avdName ?? endpoint.adbSerial ?? strings[.deviceEmulator]), level: .info)
        if runtimeStatus.adbURL == nil { add(strings[.logFullscreenNoAdb], level: .warning) }
        return AndroidFullscreenSession(endpoint: endpoint, channel: canal, runner: runner, adb: runtimeStatus.adbURL)
    }

    /// Lo que la ventana cuenta al cerrarse.
    public func androidFullscreenEnded(_ end: AndroidFullscreenSession.End, framesPerSecond: Double?) {
        isAndroidFullscreen = false
        switch end {
        case .closedByUser:
            let media = framesPerSecond.map { String(format: "%.0f", $0) } ?? "—"
            add(strings(.logFullscreenClosed, media), level: .info)
        case .connectionLost:
            showError(strings[.errFullscreenLost])
        case .refused(let status):
            showError(strings[.errFullscreenRefused] + (status.map { " (grpc-status \($0))" } ?? ""))
        }
    }
}
