# Node.js Solaris Bootstrap Handoff

This repository bootstraps a locked Node.js release from source on Solaris 11.4 and installs it into `~/.local/node`.

The tracked release is stored in `NODE_VERSION.lock`. At the moment it is `v25.9.0`.

## Goal

Automate:

- resolving the build version from `VERSION` or `NODE_VERSION.lock`
- refreshing `NODE_VERSION.lock` from the official Node.js release feed when requested
- downloading `https://nodejs.org/dist/<version>/node-<version>.tar.gz`
- extracting into `work/node-<version>`
- applying Oracle Solaris patches `001`, `002`, `003`
- applying a local Solaris bundled OpenSSL patch to use `/etc/openssl/3`
- building with `gcc/g++` and `gmake`
- installing into `/export/home/kazus/.local/node`

## Entrypoints

- `make bootstrap`
- `make refresh-version`
- `make refresh-patches`
- `make verify`

All target logic delegates to `scripts/bootstrap-node.sh`.

## Version workflow

Default resolution order:

- `VERSION=vX.Y.Z ...` environment override for one-off runs
- `NODE_VERSION.lock` for normal builds

Supported commands:

- `make refresh-version`
  - fetches `https://nodejs.org/dist/index.json`
  - selects the newest official Node.js release
  - downloads the source tarball into a temporary directory
  - validates that all Solaris patches apply with `patch --dry-run`
  - updates `NODE_VERSION.lock` only if validation succeeds
- `VERSION=vX.Y.Z make bootstrap`
  - builds a specific version once without editing tracked files

Important behavior:

- `make bootstrap` does not auto-upgrade the version
- a newly released Node version is not adopted unless the current patch set still applies cleanly
- `make refresh-version` is the only command that updates `NODE_VERSION.lock`

## Fixed build assumptions

- install prefix: `~/.local/node`
- compiler: `gcc` / `g++`
- build tool: `gmake`
- tar extraction: `gtar`
- python: `python3`
- c-ares: shared system library via:
  - `/usr/include/ares.h`
  - `/usr/lib/64/libcares.so`

Configure flags:

```bash
CC=gcc CXX=g++ ./configure \
  --prefix="$HOME/.local/node" \
  --shared-cares \
  --shared-cares-includes=/usr/include \
  --shared-cares-libpath=/usr/lib/64 \
  --shared-cares-libname=cares
```

## Patch set

Vendored upstream patches live in `patches/upstream/` and are refreshed from Oracle with `make refresh-patches`.

The current upstream patch source is Oracle Solaris Userland `components/nodejs24/patches`. Those patches are reused here against the locked Node version and must pass `patch --dry-run` before a newer release is accepted.

- `001-madvise.patch`
  - avoids Solaris `madvise()` declaration conflict in V8
- `002-pthread_getattr_np.patch`
  - switches Solaris stack discovery to `pthread_getattr_np`
- `003-no-test-wasi-poll.patch`
  - skips `test-wasi-poll` on Solaris because it fails on Solaris 11.4

Local patch:

- `patches/local/004-solaris-openssl-defaults.patch`
  - changes bundled OpenSSL Solaris `OPENSSLDIR` from `/etc/ssl` to `/etc/openssl/3`
  - ensures the binary embeds `/etc/openssl/3/certs` instead of `/etc/ssl/certs`

## Why the local OpenSSL patch exists

Solaris on this host keeps OpenSSL material under `/etc/openssl/3` and certificate symlinks under `/etc/openssl/3/certs`, while the stock bundled Node/OpenSSL defaults point at `/etc/ssl`.

Without the patch, `node --use-openssl-ca` tries to open `/etc/ssl/certs` and loads zero system certificates.

## Verification commands

```bash
cat NODE_VERSION.lock
~/.local/node/bin/node -v
~/.local/node/bin/npm -v
strings ~/.local/node/bin/node | grep /etc/openssl/3
~/.local/node/bin/node --use-openssl-ca -e 'const tls=require("tls"); console.log(tls.getCACertificates("system").length)'
~/.local/node/bin/node --use-openssl-ca -e 'require("https").get("https://example.com", r => { console.log(r.statusCode); r.resume(); }).on("error", e => { console.error(e); process.exit(1); })'
```

Expected:

- `NODE_VERSION.lock` contains the version selected for builds
- `node -v` prints the same version as `NODE_VERSION.lock`
- embedded strings include `/etc/openssl/3` and `/etc/openssl/3/certs`
- system cert count is greater than `0`
- HTTPS test prints `200`
- no `Cannot open directory /etc/ssl/certs` message

## Solaris caveats

- Use `gmake`, not Solaris `make`
- Use `gtar` for GNU tarball workflows
- `node-gyp`-driven addon tests may also need `MAKE=gmake`
- `test-wasi-poll` is intentionally skipped by patch `003`
- The install target is updated in place at `~/.local/node`
- `clean` removes extracted `work/node-v*` trees
- `distclean` also removes cached `downloads/node-v*.tar.gz` tarballs

## Logs

Build logs are written to:

- `logs/configure.log`
- `logs/build.log`
- `logs/install.log`

If `refresh-version` fails before the build starts, inspect the terminal output first. If a build step fails, inspect the corresponding log.
