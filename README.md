# Vellum

A package management system and repository tailored specifically for reMarkable tablets.

Vellum provides an opinionated wrapper and static build of Alpine Package Keeper (apk), adapted for the constraints of the reMarkable platform.

[Vellum Package Index](https://vellum.delivery)

## Installation and Usage

Please refer to the [vellum-cli](https://github.com/vellum-dev/vellum-cli) documentation for instructions on installation and usage.

##  Why "Vellum"?

The reMarkable tablet’s operating system is called Codex, meaning "bound book" in Latin.

Historically, vellum was the fine parchment used for illuminated manuscripts; today, it refers to the smooth, durable paper favored by artists and designers.

A fitting name for a package manager on a paper tablet.

## How It Works

Vellum stores everything in `/home/root/.vellum/` to work around the space-constrained and read-only root filesystem:

```
/home/root/.vellum/
├── bin/
│   ├── vellum              # wrapper binary
│   └── apk.vellum          # static apk binary
├── etc/apk/
│   ├── repositories        # package sources
│   └── keys/               # signing keys (packages.rsa.pub, local.rsa*)
├── lib/apk/db/             # package database
├── share/bash-completion/  # shell completions
├── local-repo/             # local package repository
├── cache/                  # download cache
└── state/                  # runtime state
```

## Virtual Packages

Vellum automatically detects the device model and creates an appropriate virtual package:

- **rm1** - reMarkable 1
- **rm2** - reMarkable 2
- **rmpp** - reMarkable Paper Pro
- **rmppm** - reMarkable Paper Pro Move

The `remarkable-os` virtual package is generated dynamically to match the installed OS version, enabling version-specific package dependencies.

These packages are auto-installed on every `vellum` command and allows extensions to declare device compatibility.

## Contributing

### Adding a new package

1. Create a directory under `packages/` with the package name
2. Add an `APKBUILD` file following Alpine's format
3. Test it
3. Submit a PR

### APKBUILD template for QMD extensions

```sh
maintainer="Your Name <your@email.com>"
pkgname=myextension
pkgver=1.0.0
pkgrel=0
_upstream_author="your-github-username"
_category="ui"
Description of your extension
url="https://github.com/you/your-repo"
arch="noarch"
license="SPDX License Identifier for your license"
depends="qt-resource-rebuilder remarkable-os>=3.24 remarkable-os<3.25"
source="
myextension.qmd::https://raw.githubusercontent.com/you/repo/main/myextension.qmd
LICENSE::https://raw.githubusercontent.com/you/repo/main/LICENSE
"
options="!check !fhs"

package() {
	install -Dm644 "$srcdir/betterToc.qmd" \
		"$pkgdir/home/root/xovi/exthome/qt-resource-rebuilder/myextension.qmd"

	install -Dm644 "$srcdir/LICENSE" \
		"$pkgdir/home/root/.vellum/licenses/$pkgname/LICENSE"
	echo "https://raw.githubusercontent.com/you/repo" > \
		"$pkgdir/home/root/.vellum/licenses/$pkgname/SOURCES"
}
sha512sums="
<checksum>  myextension.qmd
<checksum>  LICENSE
"
```

### Conflicts

Use `!package-name` in `depends=` to declare that your package cannot be installed alongside another:

```sh
depends="xovi !other-extension"           # conflicts with other-extension
depends="xovi !other-extension>1.0"       # conflicts with other-extension versions >1.0
```

### Versioning

Use semantic versioning (`MAJOR.MINOR.PATCH`) for `pkgver`:
- **MAJOR**: breaking changes or incompatible updates
- **MINOR**: new features, backward compatible
- **PATCH**: bug fixes (including updating a QMD for compatibility with a new reMarkable software release)

Use `pkgrel` for packaging changes that don't affect the upstream version (e.g., fixing the APKBUILD, changing dependencies). Reset `pkgrel` to `0` when bumping `pkgver`.

```sh
pkgver=1.2.0
pkgrel=0    # initial release of 1.2.0
pkgrel=1    # fixed a dependency, same upstream version
```

APK supports pre-release suffixes (underscore-prefixed):

| Suffix | Meaning | Sorts |
|--------|---------|-------|
| `_alpha` | Alpha release | before base |
| `_beta` | Beta release | before base |
| `_pre` | Pre-release | before base |
| `_rc` | Release candidate | before base |

```sh
pkgver=1.2.0_rc1   # sorts before 1.2.0
pkgver=1.2.0       # final release
```

OS compatibility is declared in `depends=`. apk automatically picks the highest compatible version:

```
mypackage-1.0.0  depends="remarkable-os>=3.22 remarkable-os<3.24"
mypackage-1.0.1  depends="remarkable-os>=3.24"              # ported to 3.24
mypackage-2.0.0  depends="remarkable-os>=3.24"              # breaking change
```

Device compatibility is also declared in `depends=`. apk ANDs these, so these should be exclusions:
```
mypackage-1.0.0  depends="!rm1 !rm2"     # Compatible with Paper Pro and Move only
```

### Package Scripts

Packages can include lifecycle scripts. Add them to your package directory and reference in APKBUILD:

```sh
install="$pkgname.post-install $pkgname.post-upgrade $pkgname.pre-deinstall"
```

| Script | When it runs |
|--------|--------------|
| `post-install` | After fresh install |
| `post-upgrade` | After upgrading to a new version |
| `pre-deinstall` | Before package removal |
| `post-os-upgrade` | After reMarkable OS update (via `vellum reenable`) |

The `post-os-upgrade` hook is installed to `/home/root/.vellum/hooks/post-os-upgrade/` and runs when users execute `vellum reenable` after an OS update. Use this for packages that need to restore system files wiped by OS updates.

### Packages with System Files

If your package installs files outside `/home/root/` (e.g., systemd units to `/etc/systemd/system/`), you'll likely need lifecycle scripts to handle installation, upgrades, OS updates, and removal.

> [!IMPORTANT]
> **System files require careful handling:**
> - Paper Pro family root filesystems are read-only; `/etc` uses an overlay that resets on reboot
> - Files created by scripts aren't tracked by apk, clean them up in `pre-deinstall`
> - `vellum reenable` wraps `post-os-upgrade` with `mount-rw`/`mount-restore` automatically, but other hooks must call these themselves

Use `mount-utils` (a dependency) to handle the read-only filesystem:

```sh
mount-rw       # Remount root read-write and unmount /etc overlay
mount-restore  # Restore /etc overlay and remount root read-only
```
It automatically detects if mount changes are required by the device.

Example for a package with a systemd service:

```sh
# mypackage.post-install
#!/bin/sh
mount-rw
cp /home/root/.vellum/share/mypackage/mypackage.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mypackage
mount-restore

# mypackage.post-upgrade
#!/bin/sh
/home/root/.vellum/share/mypackage/mypackage.post-install

# mypackage.post-os-upgrade (mount-rw/mount-restore handled by vellum reenable)
#!/bin/sh
cp /home/root/.vellum/share/mypackage/mypackage.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mypackage

# mypackage.pre-deinstall
#!/bin/sh
mount-rw
systemctl disable --now mypackage 2>/dev/null || true
rm -f /etc/systemd/system/mypackage.service
systemctl daemon-reload
mount-restore
```

### Handling Purge

When users run `vellum purge` (vs `vellum del`), they expect all data to be removed. Vellum sets `VELLUM_PURGE=1` in the environment so your scripts can detect this:

```sh
# mypackage.pre-deinstall
#!/bin/sh

# Only remove user data on purge
if [ "$VELLUM_PURGE" = "1" ]; then
    rm -rf /home/root/.config/mypackage
    rm -rf /home/root/.local/share/mypackage
fi
```

| Command | Behavior |
|---------|----------|
| `vellum del mypackage` | Removes package, keeps user config/data |
| `vellum purge mypackage` | Removes package and all associated data |

### Local Development

Requires Docker or Podman.

#### Linting

```sh
# Lint all packages
./scripts/lint-packages.sh

# Lint specific packages
./scripts/lint-packages.sh mypackage

# Lint only packages changed since main
./scripts/lint-packages.sh --changed

# Include Alpine's apkbuild-lint (slower)
./scripts/lint-packages.sh --apkbuild-lint
```

#### Updating Checksums

When you modify source URLs or update package versions:

```sh
./scripts/update-checksums.sh mypackage
```

#### Building Packages

```sh
# Build a single package
./scripts/build-package.sh mypackage aarch64

# Build a noarch package (auto-detected from APKBUILD)
./scripts/build-package.sh mypackage
```

Built packages are output to `dist/<arch>/`.

### Testing Repository

Vellum maintains a separate testing repository for packages that need validation before release. This is useful for testing package changes on real devices before merging to main.

#### For Package Developers

1. PR package changes to the `testing` branch
2. CI builds all packages and publishes to the testing repo
3. Enable testing repo on your device: `vellum testing enable`
4. Update and install: `vellum update && vellum add <package>@testing`
5. Validate the package works correctly
6. Open a PR to main when ready
7. Disable testing repo: `vellum testing disable`

#### Testing Repo Commands

```sh
vellum testing status   # Check if testing repo is enabled
vellum testing enable   # Enable testing repository
vellum testing disable  # Disable testing repository
```

## License

Individual packages retain their own licenses. Vellum infrastructure is MIT.
