# Grok Bot Linux Port

Port de [Grok Bot](https://downloads.cursor.com/grokbot/stable/win32-x64/) (la app oficial de escritorio de Grok) para Linux, sin Wine. Se construye fusionando el instalador de Windows (NSIS) con el binario oficial de Electron 42.1.0 para Linux y recompilando los módulos nativos.

Existe porque no hay build oficial para Linux.

## Instalar

**Arch (AUR):**

```bash
yay -S grokbot-linux-port-bin   # binario precompilado, recomendado
yay -S grokbot-linux-port       # desde fuente (compila 6 módulos nativos)
```

**Fedora (COPR): WIP!!**

```bash
sudo dnf copr enable nichokas/grokbot-linux-port
sudo dnf install grokbot-linux-port
```

**Tarball (cualquier distro):** descarga `Grok_Bot_<ver>_linux_x64.tar.gz` de [Releases](https://github.com/Nichokas/grokbot-linux-port/releases) y:

```bash
tar -xzf Grok_Bot_*_linux_x64.tar.gz && cd Grok_Bot_*_linux_x64
sudo chown root:root chrome-sandbox && sudo chmod 4755 chrome-sandbox
./grok-bot          # o ./grok-bot --no-sandbox
```

## Versiones

| Componente | Versión |
|------------|---------|
| Grok Bot | [`VERSION`](./VERSION) (0.20.0) |
| Electron | 42.1.0 |

## Cómo funciona

1. **Detección** (`scripts/detect-version.sh`): upstream no expone listado ni `latest.yml`, así que se hace HEAD-probing de candidatos semver (parches, minors, major) contra `downloads.cursor.com`. El mayor que responde `200` y supera a `VERSION` dispara un build.
2. **Port** (`scripts/port.sh`): descarga el `Setup.exe`, lo extrae con `7z` (sin Wine), descarga Electron 42.1.0 Linux, fusiona `app.asar`, recompila los 6 módulos nativos (`better-sqlite3`, `tree-sitter`, etc.) con `@electron/rebuild`, fija `chrome-sandbox` a `4755` y emite el tarball a `dist/`.
3. **CI** (`.github/workflows/auto-update.yml`): diario a las `37 6 * * *` UTC. Si hay versión nueva: build → GitHub Release `v<ver>` → bump de `VERSION` y de los PKGBUILD del AUR → push a `aur.archlinux.org`. Lanzar el workflow a mano con la versión actual (`-f version=$(cat VERSION)`) fuerza un *rebuild*: re-sube los artefactos a la release existente y resincroniza el `sha256sums` del paquete `-bin` con bump de `pkgrel`, sin tocar `VERSION`.

Build manual de una versión concreta:

```bash
gh workflow run auto-update.yml -f version=0.20.0   # en GitHub
scripts/port.sh 0.20.0                               # en local (requiere p7zip, curl, unzip, node 22, python3)
```

## Mantenimiento AUR

El CI actualiza `aur/*/PKGBUILD` + `.SRCINFO` en cada release y los publica en `aur.archlinux.org` automáticamente (job `aur-publish`, con la clave del secreto `AUR_SSH_PRIVATE_KEY`). El checksum del tarball `-bin` se calcula sobre los bytes exactos que sube el job `release` (`--bin-sum`), no re-descargando la URL publicada: el CDN de GitHub puede seguir sirviendo el asset anterior durante la propagación, que es como se publicaron checksums obsoletos en 0.20.0.

Push manual (solo si el job `aur-publish` falla):

```bash
for pkg in grokbot-linux-port grokbot-linux-port-bin; do
  rm -rf /tmp/aur-$pkg
  git clone ssh://aur@aur.archlinux.org/$pkg.git /tmp/aur-$pkg
  cp -a aur/$pkg/{PKGBUILD,.SRCINFO} /tmp/aur-$pkg/
  git -C /tmp/aur-$pkg add PKGBUILD .SRCINFO
  git -C /tmp/aur-$pkg commit -m "upgpkg: X.Y.Z-1" || true
  git -C /tmp/aur-$pkg push
done
```

## Troubleshooting

- `7z: command not found` → instala `p7zip-full`.
- `chrome-sandbox` permission denied → el `chown`/`chmod` de arriba, o lanza con `--no-sandbox`.
- `@electron/rebuild` falla → el tarball igualmente se genera; reintenta con `npx @electron/rebuild --version 42.1.0`.

## Licencia

Este repo no contiene binarios de Grok Bot; los artefactos se derivan en build time de la distribución oficial de Windows. Grok Bot y Electron pertenecen a sus respectivos propietarios.
