#!/usr/bin/env bash
#
# Installs the exact Godot editor and web export templates this project builds
# with, so a human can reproduce the CI export locally.
#
#   ./scripts/dev-setup.sh
#
# Installs to:
#   ~/godot-bin/godot
#   ~/.local/share/godot/export_templates/4.7.1.stable/
#
# Both locations match the paths the GitHub Actions workflow caches, so what you
# run locally is what CI runs.

set -euo pipefail

GODOT_VERSION="4.7.1-stable"
# Directory name is the literal contents of the archive's version.txt: dots, and
# no "-stable" suffix.
TEMPLATE_DIR="4.7.1.stable"
BASE_URL="https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}"

BIN_DIR="${HOME}/godot-bin"
TEMPLATES_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/godot/export_templates/${TEMPLATE_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is required" >&2; exit 1; }
done

# --------------------------------------------------------------- editor ------
if [[ -x "${BIN_DIR}/godot" ]] && "${BIN_DIR}/godot" --version 2>/dev/null | grep -q "^4\.7\.1\.stable"; then
  info "Godot ${GODOT_VERSION} already installed at ${BIN_DIR}/godot"
else
  info "Downloading Godot ${GODOT_VERSION} editor (~76 MB)"
  mkdir -p "${BIN_DIR}"
  curl -fsSL -o "${TMP_DIR}/godot.zip" \
    "${BASE_URL}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
  # The archive holds a single bare file with no wrapping directory.
  unzip -q -j "${TMP_DIR}/godot.zip" -d "${BIN_DIR}"
  mv "${BIN_DIR}/Godot_v${GODOT_VERSION}_linux.x86_64" "${BIN_DIR}/godot"
  chmod +x "${BIN_DIR}/godot"
  info "Installed $("${BIN_DIR}/godot" --version)"
fi

# ------------------------------------------------------------ templates ------
if [[ -f "${TEMPLATES_DIR}/web_nothreads_release.zip" ]]; then
  info "Web export templates already present at ${TEMPLATES_DIR}"
else
  # The full .tpz is ~1.28 GB. We export single-threaded to Web only, so pull
  # just those two templates out of it rather than unpacking all 35 files.
  # Both debug and release are needed: --export-release validates both paths.
  info "Downloading export templates (~1.28 GB download, ~46 MB extracted)"
  mkdir -p "${TEMPLATES_DIR}"
  curl -fSL --progress-bar -o "${TMP_DIR}/templates.tpz" \
    "${BASE_URL}/Godot_v${GODOT_VERSION}_export_templates.tpz"
  info "Extracting the single-threaded web templates"
  unzip -q -j "${TMP_DIR}/templates.tpz" \
    'templates/web_nothreads_release.zip' \
    'templates/web_nothreads_debug.zip' \
    'templates/version.txt' \
    -d "${TEMPLATES_DIR}"
  info "Installed templates for $(cat "${TEMPLATES_DIR}/version.txt")"
fi

cat <<EOF

Done.

  Godot binary : ${BIN_DIR}/godot
  Templates    : ${TEMPLATES_DIR}

Add Godot to your PATH:

  export PATH="\$HOME/godot-bin:\$PATH"

Then, from the repo root:

  cd web
  npm install
  npm run export:game   # headless Godot export into web/public/game/
  npm run dev           # http://localhost:5173/godot-ai-test/

EOF
