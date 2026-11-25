#!/usr/bin/env bash
# Empacota o Ronic JustTerminal para Windows (x64). Roda no macOS, Linux ou Windows (Git Bash):
#   dist/RonicJustTerminal-Windows/        RonicJustTerminal.exe + web\
#   dist/RonicJustTerminal-Windows.zip     pronto para o GitHub Releases
#
# Requer: .NET SDK 10+.   Variável opcional: VERSION=0.2.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
OUT="$ROOT/dist/RonicJustTerminal-Windows"
ZIP="$ROOT/dist/RonicJustTerminal-Windows.zip"

echo "==> Ronic JustTerminal $VERSION (Windows x64)"
rm -rf "$OUT" "$ZIP" "$ROOT/build/windows-publish"
mkdir -p "$OUT"

echo "==> Compilando RonicJustTerminal.exe"
dotnet publish "$ROOT/windows/RonicJustTerminal/RonicJustTerminal.csproj" -c Release \
  -p:Version="$VERSION" -o "$ROOT/build/windows-publish" --nologo -v quiet
cp "$ROOT/build/windows-publish/RonicJustTerminal.exe" "$OUT/RonicJustTerminal.exe"
# Bibliotecas nativas que o single-file não embute (WebView2Loader etc.), se houver.
find "$ROOT/build/windows-publish" -maxdepth 1 -name "*.dll" -exec cp {} "$OUT/" \;

echo "==> Copiando interface web"
cp -R "$ROOT/shared-web" "$OUT/web"

cat > "$OUT/LEIA-ME.txt" <<TXT
Ronic JustTerminal $VERSION para Windows 10 (1809+) e 11

1. Abra RonicJustTerminal.exe (deixe a pasta "web" ao lado dele).
2. Se o SmartScreen avisar, clique em "Mais informações" > "Executar assim mesmo".

Ao fechar a janela, o app continua na bandeja do sistema com as sessões abertas.
Para encerrar: botão direito no ícone da bandeja > Sair.

Atalhos: Ctrl+Shift+T nova aba, Ctrl+Shift+W fecha, Ctrl+Tab troca, Ctrl+Shift+B barra lateral,
Ctrl+Shift+C / Ctrl+V copiar/colar, Ctrl+, ajustes.

Requer o Microsoft Edge WebView2 Runtime (já vem no Windows 11 e no Windows 10 atualizado).
Mais informações: https://github.com/jhowmael/Ronic-JustTerminal
TXT

(cd "$ROOT/dist" && rm -f "$ZIP" && \
  if command -v zip >/dev/null; then zip -qr "$ZIP" "RonicJustTerminal-Windows"; \
  else powershell -NoProfile -Command "Compress-Archive -Path 'RonicJustTerminal-Windows' -DestinationPath 'RonicJustTerminal-Windows.zip'"; fi)

echo
echo "Pronto: $ZIP"
