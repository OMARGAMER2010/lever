# Motor de laboratorio para reducción de resolución

Fuente: [Ryubing 1.3.3](https://git.ryujinx.app/projects/Ryubing/src/tag/1.3.3), commit `e2143d43bcb6762340d8a01f20e7b5fdf104f02f`. `ryujinx-1.3.3-scale.patch` se aplica exclusivamente a ese commit. Lever no descarga, compila ni incluye este motor.

El parche conserva a resolución nativa las texturas cuya reducción haría imposible mantener sus niveles mipmap. No elimina niveles ni cambia las vistas del juego. Incluye registro opcional de intervalos de presentación Vulkan y del contador de juego, habilitado solo con `LEVER_FRAME_LOG=/ruta/absoluta/prefijo`.

## Reproducción

Desde la raíz de Lever, con un checkout limpio del commit indicado:

```sh
scripts/build-ryujinx-scale-lab.sh /ruta/al/checkout /ruta/a/salida
```

Verificado en Apple M2, macOS 15.7.5, SDK .NET 10.0.301, runtime empaquetado .NET 9.0.17 y C# 13. El script ejecuta la prueba de geometría de `scale-check`, restaura dependencias, publica ARM64 y crea/firma el bundle. Los ajustes del SDK y los feeds de NuGet forman parte del parche. La fuente conserva sus licencias originales.

La propiedad numérica `LeverTextureScaleGeometryVersion=1` permite a Lever reconocer esta corrección y habilitar 75 % y 50 %. No es una certificación de compatibilidad ni de 60 FPS para otros juegos o zonas.

Para obtener percentiles de un intervalo explícito:

```sh
python3 scripts/summarize-frame-times.py /ruta/prefijo.present.csv \
  --start 62 --end 92 --scene 'Descripción de la escena realmente observada'
```

Se excluyen menús, carga y pausas prolongadas del usuario. Los intervalos son entre llamadas Vulkan; no son tiempos ópticos de pantalla. Los resultados y limitaciones están en [el informe de rendimiento](../docs/rendimiento/odyssey.md).

La copia instalada para esta sesión está en `~/Applications/Lever Lab/Ryujinx.app`. Una firma local nueva puede requerir que macOS vuelva a solicitar acceso a la carpeta que contiene el juego. No se debe modificar TCC ni desactivar protecciones para evitar ese diálogo.

## Medir desde el botón Jugar de Lever

Con Lever y Ryujinx cerrados, se puede iniciar Lever con una variable explícita de diagnóstico:

```sh
open -a "$HOME/Desktop/Lever.app" --env "LEVER_FRAME_LOG=$PWD/.build/lever-sprint8/benchmarks/mi-prueba"
```

La carpeta de salida debe existir. Después se elige calidad y se pulsa Jugar normalmente. Solo el motor de laboratorio interpreta esa variable; Lever transmite únicamente una ruta absoluta, además de las dos variables de su módulo de entrada. Cerrar Lever y abrirlo normalmente desactiva la medición para las partidas siguientes. No se modifica el entorno global del Mac.

Las pruebas del nuevo equipo están en [el informe del M4 Pro](../docs/rendimiento/m4-pro.md).
