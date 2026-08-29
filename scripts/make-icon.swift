// Genera el icono de EXE & RAR y lo exporta como .iconset listo para `iconutil`.
//
// El símbolo: una caja abierta —la tapa separada del cuerpo— con un triángulo de reproducción
// recortado dentro. La tapa levantada dice «descomprimir»; el triángulo dice «ejecutar».
//
//   swift scripts/make-icon.swift Resources/AppIcon.iconset

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024

// Paleta de marca: mismo índigo y violeta que usa la interfaz.
let indigo = CGColor(red: 0.24, green: 0.22, blue: 0.86, alpha: 1)
let violet = CGColor(red: 0.58, green: 0.24, blue: 0.90, alpha: 1)
let deepEdge = CGColor(red: 0.16, green: 0.09, blue: 0.42, alpha: 0.45)

/// Rectángulo redondeado continuo, el mismo perfil que usan los iconos de macOS.
func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Triángulo con las puntas redondeadas.
func roundedTriangle(points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    for index in 0..<count {
        let current = points[index]
        let next = points[(index + 1) % count]
        let previous = points[(index + count - 1) % count]

        if index == 0 {
            let toPrevious = CGPoint(x: previous.x - current.x, y: previous.y - current.y)
            let length = max(hypot(toPrevious.x, toPrevious.y), 0.001)
            let start = CGPoint(
                x: current.x + toPrevious.x / length * radius,
                y: current.y + toPrevious.y / length * radius
            )
            path.move(to: start)
        }
        path.addArc(tangent1End: current, tangent2End: next, radius: radius)
    }
    path.closeSubpath()
    return path
}

func drawIcon(into context: CGContext) {
    context.saveGState()
    // Se trabaja con el origen arriba a la izquierda, que es como se piensa el diseño.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // ── Fondo: el "squircle" de macOS, con margen y sombra suave ──────────────
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = roundedPath(plate, radius: 185)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 34,
                      color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(platePath)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space, colors: [indigo, violet] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.minY),
            end: CGPoint(x: plate.maxX, y: plate.maxY),
            options: []
        )
    }
    // Brillo tenue en la parte alta, para que no se vea plano.
    if let sheen = CGGradient(
        colorsSpace: space,
        colors: [CGColor(gray: 1, alpha: 0.15), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: plate.midX, y: plate.minY),
            end: CGPoint(x: plate.midX, y: plate.midY + 90),
            options: []
        )
    }
    // Sombra interior en la base: le da volumen al fondo.
    if let base = CGGradient(
        colorsSpace: space,
        colors: [CGColor(gray: 0, alpha: 0), deepEdge] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            base,
            start: CGPoint(x: plate.midX, y: plate.midY + 120),
            end: CGPoint(x: plate.midX, y: plate.maxY),
            options: []
        )
    }
    context.restoreGState()

    // ── Símbolo ───────────────────────────────────────────────────────────────
    let white = CGColor(gray: 1, alpha: 1)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
                      color: CGColor(red: 0.10, green: 0.06, blue: 0.30, alpha: 0.35))

    // Tapa levantada: más ancha que el cuerpo, para que se lea como una caja abierta.
    let lid = CGRect(x: 512 - 208, y: 310, width: 416, height: 80)
    context.addPath(roundedPath(lid, radius: 34))
    context.setFillColor(white)
    context.fillPath()

    // Cuerpo de la caja, con el triángulo recortado (se ve el degradado a través).
    let body = CGRect(x: 512 - 196, y: 418, width: 392, height: 306)
    let bodyPath = CGMutablePath()
    bodyPath.addPath(roundedPath(body, radius: 46))

    let triangle = roundedTriangle(
        points: [
            CGPoint(x: 455, y: 489),
            CGPoint(x: 455, y: 653),
            CGPoint(x: 597, y: 571)
        ],
        radius: 18
    )
    bodyPath.addPath(triangle)

    context.addPath(bodyPath)
    context.setFillColor(white)
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    context.restoreGState()
}

// ── Exportación ───────────────────────────────────────────────────────────────

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)

let space = CGColorSpaceCreateDeviceRGB()
guard let master = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("No se pudo crear el lienzo\n", stderr)
    exit(1)
}

master.setAllowsAntialiasing(true)
master.interpolationQuality = .high
drawIcon(into: master)

guard let masterImage = master.makeImage() else {
    fputs("No se pudo renderizar el icono\n", stderr)
    exit(1)
}

try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

/// Cada entrada del `.iconset` que espera `iconutil`.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let side = variant.size
    guard let context = CGContext(
        data: nil, width: side, height: side,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    context.interpolationQuality = .high
    context.draw(masterImage, in: CGRect(x: 0, y: 0, width: side, height: side))

    guard let image = context.makeImage() else { continue }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: side, height: side)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}

print("Icono generado en \(outputURL.path)")
