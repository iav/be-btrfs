# Packaging

## Prerequisites

**Debian/Ubuntu** (for .deb): `dpkg` (pre-installed).

**Alpine** (for .apk):
```
apk add alpine-sdk
```

## Install from source

```
sudo make install
```

To uninstall:
```
sudo make uninstall
```

## Build .deb package

```
make deb
```

Output: `build/be-btrfs_<version>_all.deb`

Install:
```
sudo dpkg -i build/be-btrfs_*_all.deb
```

## Build Alpine .apk package

Must be run on Alpine Linux (or in an Alpine container):

```
make apk
```

Output: `~/packages/*/be-btrfs-<version>-r0.apk`

## GitHub Releases

Packages are built automatically by GitHub Actions when a version tag is pushed:

```
git tag v0.4.0
git push origin v0.4.0
```

You can also trigger a build manually from the Actions tab (without creating a release).

Both `.deb` and `.apk` packages will be attached to the release.
