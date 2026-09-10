# Odyssey — verificación en el M4 Pro

## Equipo y alcance

El usuario cambió de computadora. Verificado en la tarea: Mac16,7, Apple M4 Pro, 24 GiB y macOS 26.5.1 (25F80). Las mediciones del informe del M2 de 8 GiB son históricas y no describen este equipo.

Se conservaron el juego, sus datos, el motor original y el motor separado de laboratorio. Las firmas de ambas instalaciones de Ryujinx y de Lever pasaron la comprobación. El juego se identifica como Odyssey v1.0.0, aunque el nombre del archivo indique otra versión. La partida disponible continúa al principio del Reino Sombrero.

## Cambios entregados

- El selector previo al juego ofrece 50 %, 75 %, 100 %, 150 % y 200 %. Los dos valores superiores no necesitan el parche de reducción. Resolución y filtro siguen bloqueados mientras Ryujinx está abierto.
- Se verificó en la aplicación del Escritorio que 150 % escribe `res_scale=-1`, `res_scale_custom=1.5`, y que 200 % aparece como escala 2 ×. Se conserva la selección independiente de Portátil/Dock y de Teclado y ratón/Mando.
- Un mando que aparezca después del aviso de arranque de 45 segundos actualiza el estado a listo. La regresión reprodujo el fallo antes de la corrección y pasó después; tampoco se repiten avisos en cada sondeo.
- Las 26 suites Swift pasaron con el XCI real; las pruebas nativas de entrada también pasaron en este Mac. La compilación release y la firma pasaron.

## Mediciones

Los CSV registran intervalos entre llamadas de presentación Vulkan, no tiempos ópticos de pantalla. Se excluyen menús y cargas. No se ha medido una ruta por una zona pesada ni una comparación controlada de caché fría/caliente.

| Configuración | Ventana del CSV | Fotogramas | FPS medios | P99 | Máximo | >25 ms |
|---|---|---:|---:|---:|---:|---:|
| Portátil, 100 %, Bilinear | `m4-native-handheld.present.csv`, 240–300 s | 3600 | 59,9998 | 17,348 ms | 19,706 ms | 0 |
| Dock, 200 %, Bilinear, pantalla completa | `m4-docked-200-lever.present.csv`, 150–270 s | 7197 | 59,9752 | 17,297 ms | 110,693 ms | 1 |
| Dock, 200 %, repetición sin cambios | `m4-docked-200-lever.present.csv`, 270–390 s | 7200 | 60,0000 | 17,288 ms | 20,935 ms | 0 |

Escena inicial, Mario quieto. Muestra portátil de 60 segundos y muestra Dock de 120 segundos. El sistema registró cero memoria de intercambio durante las comprobaciones. El arranque sí registró advertencias de espera de GPU durante la carga; una muestra estable posterior no demuestra que todas las pausas estén eliminadas. Al 200 % hubo un intervalo de 110,693 ms a los 179,618 segundos del CSV; no se elimina del resultado ni se atribuye sin evidencia a la resolución.

La prueba `m4-native-docked` quedó en el menú por dificultades de la automatización para activar la ventana. Se excluye del resultado jugable. El proceso ya no estaba abierto al retomar la tarea y las entradas físicas estaban restauradas, sin diario pendiente.

La prueba Dock al 200 % se realizó desde el botón Jugar de la aplicación instalada. Se confirmó `Docked (2x)` en Ryujinx, la creación del CSV y la entrada a la partida inicial; activar pantalla completa permitió que E reanudara el juego durante la automatización. La repetición inmediata de 120 segundos no tuvo intervalos superiores a 25 ms; esto no invalida la pausa de la primera muestra. Lever puede transmitir `LEVER_FRAME_LOG` al motor únicamente cuando se inicia explícitamente con esa variable y una ruta absoluta. Un arranque normal no activa la grabación ni hereda otras variables del proceso.

## Pendiente

Cierre verificado: emulación detenida normalmente, proceso Ryujinx ausente, diario de recuperación eliminado y entradas restauradas a DualSense en Handheld/Player1 y teclado en Player2. Lever quedó reabierto sin `LEVER_FRAME_LOG`, con Dock al 200 % y Bilinear guardados. Las 26 suites volvieron a pasar con el XCI real después del cambio de diagnóstico; firma estricta válida y ejecutable/puente del Escritorio idénticos a `dist/Lever.app`.

Recorrer una zona exigente en movimiento. El 200 % queda como punto de partida de máxima calidad probado en la escena inicial, no como garantía para otros reinos. No se declara alcanzado el objetivo de 60 FPS constantes sin tirones en todas las zonas.
