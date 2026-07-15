# fix-python

Arregla el error de macOS/Homebrew que rompe `pyexpat` en un virtualenv de Python
de Homebrew. La línea clave es:

```
ImportError: dlopen(.../pyexpat.cpython-3XX-darwin.so, 0x0002): Symbol not found: _XML_SetAllocTrackerActivationThreshold
  Referenced from: .../pyexpat.cpython-3XX-darwin.so
  Expected in:     /usr/lib/libexpat.1.dylib
```

Normalmente aparece al crear un venv o instalar/actualizar dependencias (por ejemplo
un `pip install`), y el `ensurepip` termina con un `subprocess.CalledProcessError`.

<details>
<summary><b>Ver traceback completo</b></summary>

```
Traceback (most recent call last):
  File "<string>", line 6, in <module>
  File "<frozen runpy>", line 226, in run_module
  File "<frozen runpy>", line 98, in _run_module_code
  File "<frozen runpy>", line 88, in _run_code
  File "/var/folders/6b/.../T/tmpXXXX/pip-26.1.2-py3-none-any.whl/pip/__main__.py", line 24, in <module>
  File "/var/folders/6b/.../T/tmpXXXX/pip-26.1.2-py3-none-any.whl/pip/_internal/cli/main.py", line 83, in main
  File "/var/folders/6b/.../T/tmpXXXX/pip-26.1.2-py3-none-any.whl/pip/_internal/commands/__init__.py", line 121, in create_command
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/importlib/__init__.py", line 90, in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
  File "<frozen importlib._bootstrap>", line 1387, in _gcd_import
  ...
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/xmlrpc/client.py", line 138, in <module>
    from xml.parsers import expat
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/xml/parsers/expat.py", line 4, in <module>
    from pyexpat import *
ImportError: dlopen(/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/lib-dynload/pyexpat.cpython-312-darwin.so, 0x0002): Symbol not found: _XML_SetAllocTrackerActivationThreshold
  Referenced from: <3B0932E6-9EE3-3EF0-B087-638BACF98DEF> /opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/lib-dynload/pyexpat.cpython-312-darwin.so
  Expected in:     <4D62FA9D-D86A-3DD0-98F2-C6D0718849E8> /usr/lib/libexpat.1.dylib

Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/ensurepip/__main__.py", line 5, in <module>
    sys.exit(ensurepip._main())
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/ensurepip/__init__.py", line 284, in _main
    return _bootstrap(
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/ensurepip/__init__.py", line 200, in _bootstrap
    return _run_pip([*args, *_PACKAGE_NAMES], additional_paths)
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/ensurepip/__init__.py", line 101, in _run_pip
    return subprocess.run(cmd, check=True).returncode
  File "/opt/homebrew/Cellar/python@3.12/3.12.13_4/Frameworks/Python.framework/Versions/3.12/lib/python3.12/subprocess.py", line 571, in run
    raise CalledProcessError(retcode, process.args,
subprocess.CalledProcessError: Command '['/Users/<usuario>/path/to/.venv/bin/python3', '-W', 'ignore::DeprecationWarning', '-c', '...install --upgrade pip...']' returned non-zero exit status 1.
```

</details>

**Causa:** tras un `brew upgrade` parcial, el `pyexpat` del Python de Homebrew
queda compilado contra una `libexpat` distinta de la que carga en runtime. El
script resincroniza `expat` + `python` de Homebrew y recrea el virtualenv afectado.

**Caso 2 (macOS antiguo):** si el `libexpat` **del sistema** (`/usr/lib`) no trae
el símbolo que exige el bottle de Python (por ejemplo `python@3.14` 3.14.6 en un
macOS anterior al 26 "Tahoe"), reinstalar no basta. En ese caso el script reapunta
`pyexpat` a la `expat` de Homebrew (que sí lo trae) con `install_name_tool` +
`codesign`. El arreglo **permanente** es actualizar macOS a **26 "Tahoe"** o
superior, cuyo `libexpat` del sistema ya incluye el símbolo.

> El reapuntado se revierte si luego corres `brew upgrade`/`reinstall python`.
> Si el error reaparece, vuelve a correr `./fix-python.sh`.

---

## Requisitos

- macOS con **Homebrew** instalado.
- El Python del venv debe venir de **Homebrew** (si es pyenv/conda/python.org/sistema,
  el script no lo repara pero te dice cómo arreglarlo).
- **No necesita** permisos de administrador (`sudo`).

## Uso (una sola vez, cuando aparece el error)

```bash
# 1. Clonar este repo (solo la primera vez)
git clone https://github.com/Ghostinie/fix-python.git
cd fix-python

# 2. Correr el arreglo
./fix-python.sh
```

Por defecto repara el venv `./.venv` del directorio actual. Si tu venv está en otro
lugar, pásalo como argumento (`./fix-python.sh /ruta/al/.venv`) o vía `VENV=...`.
Autodetecta tu Python de Homebrew, repara `expat` y recrea el venv afectado.
Al terminar debería decir **"Listo. Todo resincronizado."**.

Si en el futuro vuelve a pasar (otro `brew upgrade`), corre `./fix-python.sh` de nuevo.

> Si ya tienes el repo clonado de antes, primero se actualiza con `git pull` y se vuelve
> a correr `./fix-python.sh`.

## Opciones útiles

```bash
DRY_RUN=1 ./fix-python.sh          # solo diagnostica, no cambia nada
./fix-python.sh /ruta/a/otro/.venv # reparar un venv específico (por defecto usa ./.venv)
./fix-python.sh --repair           # forzar reparación aunque diga "sano"
PYTHON_FORMULA=python@3.13 ./fix-python.sh   # forzar una fórmula de Python
```
> El `--install` deja un symlink apuntando al archivo del repo, así que **no borres
> ni muevas la carpeta del repo** mientras uses el comando global.

## Después de actualizar macOS

Actualizar a **macOS 26 "Tahoe"** (o superior) es el **arreglo permanente**: su
`libexpat` del sistema ya incluye el símbolo, así que `pyexpat` funciona sin parches.

Tras una actualización mayor de macOS conviene un mantenimiento de Homebrew (esto es
normal, no es por este bug). Corre:

```bash
brew update
brew reinstall python@3.14     # restaura el enlace limpio al libexpat del sistema
cd fix-python && git pull
./fix-python.sh                # recrea el venv; debería reportar "SANO ✅"
```

> ¿Por qué el `brew reinstall python@3.14`? Si antes se aplicó el parche del reapuntado
> (Caso 2), Python quedaba dependiendo de la `expat` de Homebrew. Reinstalar Python tras
> actualizar lo devuelve al estado limpio (usando el `libexpat` del sistema, que en Tahoe
> ya sirve) y elimina esa dependencia frágil.
