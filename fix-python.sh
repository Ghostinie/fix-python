#!/usr/bin/env bash
#
# fix-python.sh
#
# Arregla (o previene) el error de macOS/Homebrew:
#   ImportError: dlopen(... pyexpat ...): Symbol not found:
#   _XML_SetAllocTrackerActivationThreshold
#   Expected in: /usr/lib/libexpat.1.dylib
#
# Causa: el pyexpat del python de Homebrew queda compilado contra una libexpat
# distinta de la que carga en runtime (típico tras un `brew upgrade` parcial).
# Se resuelve resincronizando expat + python y recreando el virtualenv afectado.
#
# Caso 2 (macOS antiguo): si el libexpat del SISTEMA (/usr/lib) no trae el
# símbolo que exige el bottle de python (p.ej. python 3.14.6 en macOS < 26),
# reinstalar no basta. El script entonces reapunta pyexpat a la expat de
# Homebrew (que sí lo trae) con install_name_tool + codesign. Fix permanente:
# actualizar macOS a 26 "Tahoe" o superior.
#
# Requisitos / supuestos:
#   - macOS con Homebrew (Apple Silicon /opt/homebrew o Intel /usr/local)
#   - El Python del venv viene de Homebrew (autodetectado desde el pyvenv.cfg)
#   - venv objetivo por defecto: ./.venv (o pásalo como argumento / VENV=...)
#
# Uso:
#   ./fix-python.sh --install        # crea el comando global 'fix-python' (symlink en el bin de brew)
#   ./fix-python.sh --uninstall      # quita el comando global
#   fix-python /ruta/al/.venv        # autodetecta python@X.Y del venv y repara todo
#   fix-python                       # usa ./.venv (el del directorio actual)
#   VENV=/ruta/al/.venv fix-python   # o pásalo por variable de entorno
#   PYTHON_FORMULA=python@3.13 fix-python   # forzar fórmula
#   DRY_RUN=1 fix-python             # solo diagnostica, no cambia nada

set -euo pipefail

DEFAULT_VENV="${VENV:-${PWD}/.venv}"
VENV_PATH="${1:-$DEFAULT_VENV}"
DRY_RUN="${DRY_RUN:-0}"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
info()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
ok()    { printf "\033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m!\033[0m %s\n" "$*"; }
die()   { printf "\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
run()   { if [[ "$DRY_RUN" == "1" ]]; then printf "\033[90m[dry-run] %s\033[0m\n" "$*"; else "$@"; fi; }

command -v brew >/dev/null 2>&1 || die "Homebrew no está en el PATH."

# ---------------------------------------------------------------------------
# --install / --uninstall: registrar (o quitar) el comando global `fix-python`
# ---------------------------------------------------------------------------
# Resolver la ruta REAL de este script, aunque se invoque vía symlink.
SELF="${BASH_SOURCE[0]}"
while [[ -L "$SELF" ]]; do
  link="$(readlink "$SELF")"
  [[ "$link" = /* ]] && SELF="$link" || SELF="$(cd "$(dirname "$SELF")" && pwd)/$link"
done
SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"

case "${1:-}" in
  --install)
    if [[ "$(uname -m)" == "arm64" ]]; then BINDIR="/opt/homebrew/bin"; else BINDIR="/usr/local/bin"; fi
    [[ -d "$BINDIR" && -w "$BINDIR" ]] || BINDIR="$(brew --prefix)/bin"
    ln -sf "$SELF" "${BINDIR}/fix-python"
    ok "Instalado: ${BINDIR}/fix-python -> ${SELF}"
    info "Ya puedes ejecutar 'fix-python' desde cualquier carpeta."
    command -v fix-python >/dev/null 2>&1 || warn "Ojo: ${BINDIR} no parece estar en tu PATH."
    exit 0
    ;;
  --uninstall)
    removed=0
    for d in /opt/homebrew/bin /usr/local/bin "$(brew --prefix 2>/dev/null)/bin"; do
      if [[ -L "${d}/fix-python" ]]; then rm -f "${d}/fix-python"; ok "Eliminado ${d}/fix-python"; removed=1; fi
    done
    [[ "$removed" == "1" ]] || warn "No encontré ningún symlink 'fix-python' que quitar."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 0. Detectar qué fórmula de Python usa este venv
# ---------------------------------------------------------------------------
detect_formula() {
  # 1) Preferir lo que ya dice el pyvenv.cfg del venv (home = .../python@X.Y/bin)
  if [[ -f "${VENV_PATH}/pyvenv.cfg" ]]; then
    local home_line
    home_line="$(grep -E '^home' "${VENV_PATH}/pyvenv.cfg" 2>/dev/null | sed 's/.*= *//')"
    if [[ "$home_line" =~ python@([0-9]+\.[0-9]+) ]]; then
      echo "python@${BASH_REMATCH[1]}"; return 0
    fi
    # pyvenv.cfg con 'version = 3.14.3' -> python@3.14
    local ver
    ver="$(grep -E '^version' "${VENV_PATH}/pyvenv.cfg" 2>/dev/null | sed -E 's/.*= *([0-9]+\.[0-9]+).*/\1/')"
    [[ -n "$ver" ]] && { echo "python@${ver}"; return 0; }
  fi
  # 2) Fallback: la python@ más nueva instalada por brew.
  #    Orden numérico por major.minor (portable a BSD sort; no depende de `sort -V`).
  local newest
  newest="$(brew list --formula 2>/dev/null | grep -E '^python@[0-9]+\.[0-9]+$' \
              | sed 's/^python@//' | sort -t. -k1,1n -k2,2n | tail -1)"
  [[ -n "$newest" ]] && { echo "python@${newest}"; return 0; }
  return 1
}

PYTHON_FORMULA="${PYTHON_FORMULA:-$(detect_formula || true)}"
[[ -n "${PYTHON_FORMULA:-}" ]] || die "No pude detectar la fórmula de Python. Pásala con PYTHON_FORMULA=python@3.14"

# ---------------------------------------------------------------------------
# 0b. Clasificar el origen del Python base del venv
#     Este script solo sabe arreglar Python de Homebrew. Si el venv apunta a
#     pyenv / python.org / conda / sistema, `brew reinstall` NO lo repara.
# ---------------------------------------------------------------------------
venv_base_origin() {
  # Si el venv no existe aún, lo crearemos con el python de Homebrew -> homebrew.
  [[ -d "$VENV_PATH" ]] || { echo "homebrew"; return 0; }

  # Resolver la ruta real del Python base: primero pyvenv.cfg, luego el symlink.
  local base_path=""
  if [[ -f "${VENV_PATH}/pyvenv.cfg" ]]; then
    base_path="$(grep -E '^(executable|home)' "${VENV_PATH}/pyvenv.cfg" 2>/dev/null | head -1 | sed 's/.*= *//')"
  fi
  if [[ -z "$base_path" && -e "${VENV_PATH}/bin/python" ]]; then
    # Seguir la cadena de symlinks hasta el binario real.
    base_path="$(cd "${VENV_PATH}/bin" 2>/dev/null && python_bin="$(readlink python 2>/dev/null || echo python)"; \
                 while [[ -L "$python_bin" ]]; do python_bin="$(readlink "$python_bin")"; done; \
                 [[ "$python_bin" = /* ]] && echo "$python_bin" || echo "$(pwd)/$python_bin")"
  fi

  local brew_prefix; brew_prefix="$(brew --prefix 2>/dev/null)"
  case "$base_path" in
    *"/Cellar/"*|*"/opt/homebrew/opt/"*|*"/usr/local/opt/"*)   echo "homebrew" ;;
    "${brew_prefix}"/*Caskroom*|*miniforge*|*miniconda*|*anaconda*|*conda*) echo "conda" ;;
    *"/.pyenv/"*)                                              echo "pyenv" ;;
    *"/Library/Frameworks/Python.framework"*)                 echo "python.org" ;;
    "/usr/bin/"*|"/System/"*)                                 echo "system" ;;
    "${brew_prefix}"/*)                                        echo "homebrew" ;;
    *)                                                         echo "unknown" ;;
  esac
}

VENV_ORIGIN="$(venv_base_origin)"

bold "Diagnóstico inicial"
info "Homebrew:          $(brew --prefix)  ($(uname -m))"
info "Fórmula Python:    ${PYTHON_FORMULA}  (autodetectada del venv)"
info "Virtualenv:        ${VENV_PATH}"
info "Origen del Python: ${VENV_ORIGIN}"
[[ "$DRY_RUN" == "1" ]] && warn "DRY_RUN activo: no se ejecutará ningún cambio."
echo

# ---------------------------------------------------------------------------
# 1. ¿Ya está todo bien? (early-exit preventivo)
# ---------------------------------------------------------------------------
PY_VERSION="${PYTHON_FORMULA#python@}"
BASE_PYTHON="$(brew --prefix "${PYTHON_FORMULA}" 2>/dev/null)/bin/python${PY_VERSION}"
[[ -x "$BASE_PYTHON" ]] || BASE_PYTHON="$(brew --prefix)/bin/python3"

healthy_base=0
if "$BASE_PYTHON" -c "import pyexpat" >/dev/null 2>&1; then healthy_base=1; fi

healthy_venv=0
if [[ -x "${VENV_PATH}/bin/python" ]] && "${VENV_PATH}/bin/python" -c "import pyexpat" >/dev/null 2>&1; then
  healthy_venv=1
fi

if [[ "$healthy_base" == "1" && "$healthy_venv" == "1" ]]; then
  ok "pyexpat carga bien en el Python base y en el venv. Nada que reparar."
  "$BASE_PYTHON"        -c "import pyexpat; print('  base:', pyexpat.EXPAT_VERSION)"
  "${VENV_PATH}/bin/python" -c "import pyexpat; print('  venv:', pyexpat.EXPAT_VERSION)"
  bold "Estado: SANO ✅  (corre con --repair para forzar reparación de todos modos)"
  [[ "${1:-}" == "--repair" || "${FORCE:-0}" == "1" ]] || exit 0
fi

# ---------------------------------------------------------------------------
# 1b. Guardia: solo reparamos venvs basados en Homebrew
# ---------------------------------------------------------------------------
if [[ "$VENV_ORIGIN" != "homebrew" ]]; then
  warn "El Python base de este venv NO viene de Homebrew (origen: ${VENV_ORIGIN})."
  warn "Este script repara pyexpat de Homebrew; aquí NO aplica. Arréglalo así:"
  case "$VENV_ORIGIN" in
    pyenv)
      echo "  • pyenv: recompila la versión afectada contra una expat correcta:"
      echo "      pyenv uninstall <version> && pyenv install <version>"
      echo "      (o: PYTHON_CONFIGURE_OPTS=... pyenv install <version>)"
      echo "  • Luego recrea el venv con ese python."
      ;;
    conda)
      echo "  • conda/mamba: actualiza expat dentro del entorno:"
      echo "      conda update -n <env> expat libexpat   (o: conda install expat=<ver>)"
      ;;
    python.org)
      echo "  • python.org: reinstala el paquete oficial desde python.org/downloads"
      echo "    (trae su propia libexpat; el instalador la resincroniza)."
      ;;
    system)
      echo "  • Estás usando el Python del sistema (/usr/bin). No lo modifiques:"
      echo "    crea el venv con un Python de Homebrew y reejecuta este script."
      ;;
    *)
      echo "  • No pude identificar el origen. Revisa '${VENV_PATH}/pyvenv.cfg'"
      echo "    y repara el Python al que apunte, o recrea el venv con Homebrew."
      ;;
  esac
  echo
  [[ "${FORCE:-0}" == "1" ]] || die "Abortado sin cambios (usa FORCE=1 para forzar de todos modos)."
  warn "FORCE=1: continuando pese al origen no-Homebrew…"
fi

# ---------------------------------------------------------------------------
# Fallback: reapuntar pyexpat (y demás libs) a la expat de Homebrew.
#   Se usa cuando el libexpat del SISTEMA (/usr/lib/libexpat.1.dylib) no trae
#   el símbolo que el pyexpat de Homebrew necesita. Pasa cuando el Mac corre un
#   macOS más antiguo que el bottle de python recién actualizado (p.ej. python
#   3.14.6 en macOS < 26 "Tahoe"). La expat de Homebrew SÍ trae el símbolo, así
#   que reapuntamos las librerías a ella y las re-firmamos.
# ---------------------------------------------------------------------------
repoint_to_brew_expat() {
  command -v install_name_tool >/dev/null 2>&1 || die "Falta 'install_name_tool' (instala Xcode CLT: xcode-select --install)."
  command -v codesign          >/dev/null 2>&1 || die "Falta 'codesign' (instala Xcode CLT: xcode-select --install)."

  info "Instalando/actualizando expat de Homebrew"
  run brew install expat 2>/dev/null || run brew reinstall expat
  local brew_expat; brew_expat="$(brew --prefix expat 2>/dev/null)/lib/libexpat.1.dylib"
  [[ -f "$brew_expat" ]] || die "No encontré la libexpat de Homebrew en ${brew_expat}."

  # Confirmar que la expat de Homebrew SÍ trae el símbolo que falta.
  if command -v nm >/dev/null 2>&1 && ! nm -gU "$brew_expat" 2>/dev/null | grep -q "SetAllocTrackerActivationThreshold"; then
    warn "La expat de Homebrew no parece traer el símbolo; el reapuntado podría no bastar."
  fi

  local pyprefix; pyprefix="$(brew --prefix "${PYTHON_FORMULA}" 2>/dev/null)"
  [[ -d "$pyprefix" ]] || pyprefix="$(dirname "$(dirname "$BASE_PYTHON")")"

  info "Buscando librerías enlazadas a /usr/lib/libexpat.1.dylib en ${pyprefix}"
  local files
  files="$(find -L "$pyprefix" \( -name '*.so' -o -name '*.dylib' \) -type f 2>/dev/null \
             -exec sh -c 'otool -L "$1" 2>/dev/null | grep -q "/usr/lib/libexpat.1.dylib" && echo "$1"' _ {} \; \
           | while read -r f; do echo "$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"; done | sort -u)"

  if [[ -z "$files" ]]; then
    warn "No encontré librerías que reapuntar (¿ya estaban apuntadas a la expat de Homebrew?)."
    return 0
  fi

  local count=0 so
  while IFS= read -r so; do
    [[ -n "$so" ]] || continue
    info "Reapuntando: ${so##*/}"
    run install_name_tool -change /usr/lib/libexpat.1.dylib "$brew_expat" "$so"
    run codesign -f -s - "$so"
    count=$((count+1))
  done <<< "$files"

  ok "Reapuntadas ${count} librería(s) a ${brew_expat}."
  warn "Nota: un futuro 'brew upgrade/reinstall python' revertirá esto; vuelve a correr el script si reaparece."
}

# ---------------------------------------------------------------------------
# 2. Reparar expat + python de Homebrew
# ---------------------------------------------------------------------------
bold "1/3 · Resincronizando librerías de Homebrew"
run brew update
run brew reinstall expat
run brew link --overwrite expat 2>/dev/null || warn "expat no necesitó relink (o es keg-only)."
run brew reinstall "${PYTHON_FORMULA}"
ok "Homebrew resincronizado."
echo

# ---------------------------------------------------------------------------
# 3. Verificar Python base
# ---------------------------------------------------------------------------
bold "2/3 · Verificando pyexpat en el Python base"
info "Usando: ${BASE_PYTHON}"
if [[ "$DRY_RUN" == "1" ]]; then
  warn "dry-run: se omite verificación."
elif "$BASE_PYTHON" -c "import pyexpat; print('EXPAT_VERSION =', pyexpat.EXPAT_VERSION)"; then
  ok "pyexpat OK en el Python base."
else
  warn "pyexpat sigue fallando tras el reinstall."
  warn "Causa: el libexpat del SISTEMA (/usr/lib) no trae el símbolo requerido"
  warn "(este Mac corre un macOS más antiguo que el bottle de python)."
  echo
  bold "Arreglo alterno · Reapuntando pyexpat a la expat de Homebrew"
  repoint_to_brew_expat
  echo
  info "Reverificando pyexpat en el Python base"
  if "$BASE_PYTHON" -c "import pyexpat; print('EXPAT_VERSION =', pyexpat.EXPAT_VERSION)"; then
    ok "pyexpat OK tras reapuntar a la expat de Homebrew."
  else
    warn "pyexpat sigue fallando incluso tras reapuntar."
    echo "  Opción recomendada: actualizar macOS a la versión del resto del equipo"
    echo "  (macOS 26 'Tahoe' o superior), cuyo libexpat del sistema ya trae el símbolo."
    die "No se pudo reparar automáticamente. Revisa también 'brew doctor'."
  fi
fi
echo

# ---------------------------------------------------------------------------
# 4. Recrear el venv
# ---------------------------------------------------------------------------
bold "3/3 · Recreando virtualenv"
REQ_TMP=""
if [[ -x "${VENV_PATH}/bin/pip" ]]; then
  REQ_TMP="$(mktemp)"
  if "${VENV_PATH}/bin/pip" freeze > "$REQ_TMP" 2>/dev/null && [[ -s "$REQ_TMP" ]]; then
    ok "Dependencias congeladas en ${REQ_TMP} ($(wc -l < "$REQ_TMP" | tr -d ' ') paquetes)."
  else
    warn "No se pudieron congelar dependencias; se recreará vacío."
    rm -f "$REQ_TMP"; REQ_TMP=""
  fi
fi

if [[ -d "$VENV_PATH" ]]; then
  info "Eliminando venv viejo"
  run rm -rf "$VENV_PATH"
fi

info "Creando venv con ${BASE_PYTHON}"
run "$BASE_PYTHON" -m venv "$VENV_PATH"
run "${VENV_PATH}/bin/python" -m pip install --upgrade pip

if [[ -n "$REQ_TMP" && -s "$REQ_TMP" ]]; then
  info "Reinstalando dependencias previas"
  run "${VENV_PATH}/bin/pip" install -r "$REQ_TMP" || warn "Algunas dependencias fallaron; revísalas."
  rm -f "$REQ_TMP"
fi

if [[ "$DRY_RUN" != "1" ]]; then
  info "Verificando pyexpat en el venv"
  "${VENV_PATH}/bin/python" -c "import pyexpat; print('EXPAT_VERSION =', pyexpat.EXPAT_VERSION)"
fi

echo
bold "Listo. Todo resincronizado. 🎉"
