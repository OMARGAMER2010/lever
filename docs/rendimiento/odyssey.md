# Odyssey — rendimiento observado

Estado: comparación exploratoria terminada, 7 de septiembre de 2026. No se han demostrado 60 FPS constantes en las zonas más exigentes.

Equipo: MacBook Pro con M2 y 8 GB, macOS 15.7.5. Odyssey se identifica como v1.0.0, `0100000000010000`. Motor de laboratorio compilado desde Ryujinx 1.3.3, commit `e2143d43bcb6762340d8a01f20e7b5fdf104f02f`, con el parche de geometría mipmap e instrumentación opcional del repositorio. La instalación de `/Applications/Ryujinx.app` sigue intacta.

## Método y límites

Cada muestra selecciona 30 segundos dentro de la partida, en el inicio del Reino Sombrero. Las primeras muestras a 100 % y 75 % se tomaron después de un salto, con Mario quieto. En la muestra a 50 % se comprobó un salto y la cámara cambió de orientación durante el intervalo: se conserva como observación independiente, no como comparación idéntica. La repetición a 100 % mantuvo la vista hacia la torre y la luna. No es un recorrido por una zona pesada ni una prueba de todos los shaders o movimientos. Las cachés están activas. Chrome estaba cerrado durante las muestras y no se ejecutaron compilaciones en los intervalos seleccionados.

Se miden los intervalos entre llamadas de presentación Vulkan. Son una aproximación al ritmo de entrega de fotogramas; no son tiempos ópticos de la pantalla. El contador del juego por sí solo puede contar fotogramas reemplazados. El script conserva percentiles y pausas, además de la media.

| Configuración | FPS medios | P99 (ms) | Máximo (ms) | Pausas >25 ms | Intervalo del CSV |
| --- | ---: | ---: | ---: | ---: | --- |
| 100 % · Bilinear | 59,467 | 19,285 | 234,934 | 9 | `native-compare.present.csv`, 183–213 s |
| 75 % · Bilinear | 60,000 | 17,274 | 18,841 | 0 | `scale75-compare.present.csv`, 169–199 s |
| 50 % · FSR, cámara distinta | 60,000 | 17,355 | 21,759 | 0 | `scale50-compare2.present.csv`, 59–89 s |
| 100 % · Bilinear, repetición | 59,999 | 17,250 | 19,911 | 0 | `native-repeat.present.csv`, 62–92 s |

La primera muestra nativa tuvo una pausa de 51,390 ms a los 189,508 s y otra de 234,934 ms a los 201,258 s. La repetición nativa no tuvo pausas mayores de 25 ms, por lo que no se puede atribuir la mejora únicamente a bajar resolución. Las diferencias de duración de calentamiento y cámara tampoco permiten establecer causalidad.

Se conserva **100 % · Bilinear · Portátil** como ajuste inicial, para mantener la mayor calidad que fue estable en esta escena. El 75 % y el 50 % quedan disponibles para reducir carga cuando se necesite. No se demuestra que el 50 % aporte más fluidez que el 75 % en esta zona. No se borraron cachés, así que tampoco se afirma una comparación controlada entre caché fría y caliente.

Los CSV están en `.build/lever-sprint8/benchmarks/`. Se reproducen las estadísticas con `scripts/summarize-frame-times.py CSV --start INICIO --end FIN --scene DESCRIPCIÓN`. Los registros anteriores de menú y diagnóstico quedan excluidos.

## Compatibilidad

El 75 % y el 50 % cargaron la partida y permitieron saltar sin el aborto de niveles mipmap que afectaba al motor original. Volver al 100 % también cargó la partida. Esto valida el caso inicial probado, no toda la geometría de todos los juegos.

La captura y los giros con ratón ya tienen aceptación manual del usuario. Durante esta comparación, la acción de arrastre de la herramienta de UI devolvió `noWindowsAvailable`; no se presenta como un recorrido automático de cámara completado.

## Ajustes y entrega local

La app actualizada está en `~/Desktop/Lever.app`, con firma ad hoc comprobada mediante `codesign --verify --deep --strict`. La versión anterior se conserva en `.build/lever-sprint8/Lever-desktop-before-quality-20260907.app`.

El motor corregido está en `~/Applications/Lever Lab/Ryujinx.app`, separado de Lever. Está seleccionado en sus preferencias. Su marca `LeverTextureScaleGeometryVersion=1` identifica el parche de geometría, no una garantía de rendimiento. La app original de `/Applications` no se sustituyó.

En la UI del Escritorio se comprobaron 75 %, 50 %, FSR y el regreso a 100 % · Bilinear contra los valores reales de `Config.json`. Se creó `Config.json.lever-before-quality.json`; el guardado conserva los demás campos y usa escritura atómica. También se verificó la hoja con dispositivo, sensibilidad e inversión. Al pulsar Jugar, los selectores de calidad quedaron deshabilitados mientras el motor estaba abierto.

El primer arranque desde Lever de esta copia se detuvo antes de mostrar la partida: macOS solicitó de nuevo acceso al Escritorio por el cambio de firma. `dotnet-stack` mostró la espera al abrir el XCI y el registro TCC confirmó `kTCCServiceSystemPolicyDesktopFolder` pendiente. El permiso quedó resuelto fuera de la herramienta y los arranques posteriores abrieron el juego. No se modificó TCC ni se eludió la solicitud.

CUA bloqueó expresamente el acceso a `com.apple.UserNotificationCenter` por seguridad. Ese diálogo quedó reservado al usuario. Tras resolverlo se cerró la emulación desde Actions → Stop Emulation, se volvió a la biblioteca y se cerró el motor. Lever restauró exactamente la lista de entradas anterior, retiró el diario y la carpeta temporal, y conservó 100 % · Bilinear · Portátil. El SHA-256 canónico de las entradas fue `7bdc31d008b44069a47f6c8dca8dbed1fa04c4786cd75c309979b3876361b2d2`, igual antes y después.

El arranque final se hizo pulsando Jugar en la app del Escritorio. La sesión `lever-input-EB5C5029-73ED-4EDE-9B75-F66C36B7D567` indicó `state=ready` y `controllerOpened=true`. Después de enfocar el juego, E confirmó Resume y se observó a Mario en el Reino Sombrero. El registro correspondiente es `~/Library/Logs/Ryujinx/Ryujinx_1.3.3+lever-scale1_2026-09-07_15-34-03.log`. Esto comprueba el lanzamiento real con el módulo empaquetado; no sustituye la aceptación manual de cámara, movimiento y salto ya recogida en el informe del sprint.

## Esperas de GPU en la aceptación final

La sesión que quedó abierta durante una pausa larga registró diez advertencias de espera/presentación de GPU. Una sesión posterior también registró diez, entre ellas esperas de sincronización de 1000 ms. Por tanto, **no se declara resuelto el objetivo de eliminar todos los tirones**, aunque las cuatro ventanas medidas anteriores fueran mejores.

Durante un intervalo posterior de 30 segundos sin capturas de pantalla, el contador de esas advertencias permaneció en diez. El sistema registró 1812 páginas de swap de entrada y 5012 de salida, de 16 KiB cada una; Chrome estaba cerrado. La coincidencia con la automatización no demuestra que las capturas causen los bloqueos. Tampoco la ausencia de advertencias equivale a una medición de tiempos de fotograma. La causa de esas esperas y una prueba de recorrido por una zona exigente siguen pendientes; no se presentan como límites de hardware demostrados.

La configuración por juego tiene prioridad sobre la global, incluso si está corrupta. La resolución de perfiles portables o un `--root-data-dir` externo sigue fuera de esta verificación; este equipo usa la carpeta estándar de Ryujinx.

## Cambio de equipo

El usuario migró a un M4 Pro con 24 GiB y macOS 26.5.1. Las cifras anteriores pertenecen al M2. Véase la [verificación del nuevo equipo](2026-09-08-m4-pro-rendimiento.md) para los resultados y cambios posteriores.

Antes del cambio se completó otra muestra del M2: `native-nsworkspace.present.csv`, 140–260 s, 7200 fotogramas, 60,000 FPS medios, P99 17,292 ms, máximo 25,540 ms y un intervalo mayor de 25 ms; ninguno mayor de 33,334 ms. Tres capturas consecutivas posteriores no reprodujeron una pausa larga (ventana 410–435 s, máximo 20,270 ms). App Nap figuraba como No y el modo de bajo consumo estaba apagado. Estos resultados no establecen la causa de las esperas anteriores ni sustituyen una prueba de zona pesada.
