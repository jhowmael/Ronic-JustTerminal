#!/usr/bin/env bash
# Atualiza o xterm.js embutido em shared-web/vendor (o app roda offline, sem CDN).
#   ./scripts/vendor-xterm.sh
# Requer: npm. Versões fixas abaixo; troque e rode de novo para atualizar.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/shared-web/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PKGS=(
  "@xterm/xterm@6.0.0"
  "@xterm/addon-webgl@0.19.0"
  "@xterm/addon-fit@0.11.0"
  "@xterm/addon-web-links@0.12.0"
  "@xterm/addon-unicode11@0.9.0"
)

cd "$TMP"
for p in "${PKGS[@]}"; do npm pack --silent "$p" >/dev/null; done
rm -rf "$VENDOR"; mkdir -p "$VENDOR"
for tgz in *.tgz; do
  d="${tgz%.tgz}"; mkdir "$d"; tar -xzf "$tgz" -C "$d"
done
cp xterm-xterm-*/package/lib/xterm.js                       "$VENDOR/xterm.js"
cp xterm-xterm-*/package/css/xterm.css                      "$VENDOR/xterm.css"
cp xterm-addon-webgl-*/package/lib/addon-webgl.js           "$VENDOR/addon-webgl.js"
cp xterm-addon-fit-*/package/lib/addon-fit.js               "$VENDOR/addon-fit.js"
cp xterm-addon-web-links-*/package/lib/addon-web-links.js   "$VENDOR/addon-web-links.js"
cp xterm-addon-unicode11-*/package/lib/addon-unicode11.js   "$VENDOR/addon-unicode11.js"
cp xterm-xterm-*/package/LICENSE                            "$VENDOR/LICENSE-xterm.txt"
printf '%s\n' "${PKGS[@]}" > "$VENDOR/VERSIONS.txt"
echo "OK: $VENDOR"
