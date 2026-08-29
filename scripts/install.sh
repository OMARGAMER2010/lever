#!/usr/bin/env bash
# Revisa las dependencias, instala las que se pueden instalar solas, compila la app y la deja en
# el Escritorio lista para abrirla con doble clic.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

# Primero las dependencias: si falta algo, es mejor saberlo antes de esperar a la compilación.
# No corta la instalación si algo falla —la app arranca igual y dice qué le falta—, así que su
# código de salida se ignora a propósito.
bash scripts/dependencies.sh || true

bash scripts/build-app.sh

destination="$HOME/Desktop/Lever.app"

echo "▸ Instalando en el Escritorio…"
rm -rf "$destination"
cp -R "$project_root/dist/Lever.app" "$destination"
xattr -cr "$destination" 2>/dev/null || true

# Refresca la caché de iconos del Finder para que se vea el nuevo de inmediato.
touch "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$destination" > /dev/null 2>&1 || true

echo "✓ Instalada: $destination"

# Un último repaso: si algo del grupo automático sigue faltando, que sea lo último que se lea.
bash scripts/dependencies.sh --check > /dev/null 2>&1 \
    || echo "  Ojo: algo quedó sin instalar. Repásalo con: bash scripts/dependencies.sh"
