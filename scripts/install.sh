#!/usr/bin/env bash
# Compila la app y deja su icono en el Escritorio, listo para abrirla con doble clic.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

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
