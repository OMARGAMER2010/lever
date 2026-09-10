#!/usr/bin/env python3
"""Resume una ventana explícita del CSV de laboratorio, sin confundir menú con gameplay."""
import argparse
import csv
import json
import math
from pathlib import Path


def summarize(path, start, end):
    if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end):
        raise ValueError("El intervalo debe cumplir 0 <= inicio < fin")
    with Path(path).open() as file:
        header = file.readline().strip()
        if not header.startswith("# started_utc="):
            raise ValueError("Falta la fecha de inicio del registro")
        reader = csv.DictReader(file)
        samples = []
        previous = -1.0
        for row in reader:
            elapsed, milliseconds = float(row["elapsed_s"]), float(row["frame_ms"])
            if not all(map(math.isfinite, (elapsed, milliseconds))) or milliseconds <= 0 or elapsed < previous:
                raise ValueError("Registro de fotogramas inválido")
            previous = elapsed
            # El intervalo completo debe caer dentro de la escena indicada.
            if elapsed - milliseconds / 1000 >= start and elapsed <= end:
                samples.append(milliseconds)
    if len(samples) < 2:
        raise ValueError("La ventana seleccionada no contiene suficientes fotogramas")
    ordered = sorted(samples)

    def percentile(percent):
        index = (len(ordered) - 1) * percent / 100
        lower, upper = math.floor(index), math.ceil(index)
        return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower), 3)

    return {
        "file": str(path), "started_utc": header.removeprefix("# started_utc="),
        "window_s": [start, end], "frames": len(samples),
        "sampled_duration_s": round(sum(samples) / 1000, 3),
        "average_fps": round(1000 * len(samples) / sum(samples), 3),
        "frame_ms": {"p50": percentile(50), "p95": percentile(95), "p99": percentile(99),
                     "p99_9": percentile(99.9), "maximum": round(max(samples), 3)},
        "frames_over_ms": {str(limit): sum(ms > limit for ms in samples) for limit in (25, 33.334, 50, 100)},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("--scene", required=True, help="Escena y actividad observadas durante toda la ventana")
    args = parser.parse_args()
    try:
        result = summarize(args.csv, args.start, args.end)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"No se puede resumir: {error}\n")
    result["scene"] = args.scene
    result["measurement"] = "Intervalos de llamadas; no son tiempos ópticos de la pantalla ni garantía para otras zonas."
    print(json.dumps(result, ensure_ascii=False, indent=2))
