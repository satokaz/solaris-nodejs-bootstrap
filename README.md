# nodejs-bootstrap

Build Node.js from source on Solaris 11.4, apply the required Solaris-specific patches, and install it into `~/.local/node`.

This repository is designed for a practical workflow:

- keep the selected Node.js version in a tracked lock file
- refresh to the latest official release without editing source files by hand
- validate patch applicability before adopting a newer release
- verify the installed binary, OpenSSL path defaults, and system CA behavior

The currently selected build version is stored in [`NODE_VERSION.lock`](./NODE_VERSION.lock).

## What This Repo Does

The bootstrap flow automates:

- downloading the Node.js source tarball from `nodejs.org/dist`
- extracting into `work/node-<version>`
- applying Oracle Solaris Userland patches
- applying a local OpenSSL defaults patch for `/etc/openssl/3`
- building with `gcc`, `g++`, and `gmake`
- installing into `~/.local/node`
- verifying the installed `node` binary

This repo is intentionally opinionated for Solaris:

- compiler: `gcc` / `g++`
- build tool: `gmake`
- tar: `gtar`
- python: `python3`
- c-ares: shared system library from `/usr/include/ares.h` and `/usr/lib/64/libcares.so`

## Required IPS Packages

On this Solaris 11.4 host, the bootstrap prerequisites are provided by these IPS packages:

- archiver/gnu-tar
- developer/build/gnu-make
- developer/gcc/gcc-c-15
- developer/gcc/gcc-c++-15
- runtime/python-311
- text/gnu-patch
- library/libcares
- web/curl

`/usr/bin/strings` is provided by `system/core-os`, which is part of the base OS on a normal Solaris installation and usually does not need separate action.

Recommended install command:

```bash
pkg install \
  shell/bash \
  archiver/gnu-tar \
  developer/build/gnu-make \
  developer/gcc/gcc-c-15 \
  developer/gcc/gcc-c++-15 \
  runtime/python-311 \
  text/gnu-patch \
  library/libcares \
  web/curl
```

Notes:

- `web/wget` can be used instead of `web/curl`
- on this host, `/usr/lib/64` is a symlink to `/usr/lib/amd64`, so `library/libcares` satisfies the bootstrap check for `/usr/lib/64/libcares.so`

## Quick Start

Build the locked version:

```bash
make bootstrap
```

Verify the installed binary:

```bash
make verify
```

Check the currently locked version:

```bash
cat NODE_VERSION.lock
```

## What This Changes In Installed Node

Compared with a plain upstream source build, this bootstrap applies these changes before installing Node into `~/.local/node`:

- `001-madvise.patch`
  - removes the Solaris-specific `madvise()` declaration conflict in V8 so the build succeeds on Solaris 11.4
- `002-pthread_getattr_np.patch`
  - changes Solaris stack discovery in V8 to use `pthread_getattr_np`
- `003-no-test-wasi-poll.patch`
  - changes the Node test suite to skip `test-wasi-poll` on Solaris
  - this affects test execution only, not the installed runtime behavior
- `004-solaris-openssl-defaults.patch`
  - changes bundled OpenSSL defaults from `/etc/ssl` to `/etc/openssl/3`
  - makes `node --use-openssl-ca` read certificates from `/etc/openssl/3/certs`
  - avoids the `Cannot open directory /etc/ssl/certs` failure on this Solaris host

This bootstrap also builds Node with these non-default choices:

- `--shared-cares`
  - Node links against the system `libcares` package instead of using bundled c-ares
- `--prefix="$HOME/.local/node"`
  - the install target is a user-local tree, not a system-wide location

What does not change:

- `npm` and `npx` come from the Node release being built
- the `003` WASI patch does not modify the installed `node` binary itself
- this repo does not patch unrelated Node subsystems beyond the Solaris fixes above

## Version Management

This repository does not require editing shell scripts when a new Node.js release appears.

Normal version resolution order:

1. `VERSION=vX.Y.Z ...` environment override for one-off runs
2. `NODE_VERSION.lock` for standard builds

Refresh the lock file to the newest official release:

```bash
make refresh-version
```

What `make refresh-version` does:

- fetches the official release metadata
- selects the newest release entry
- downloads the candidate source tarball into a temporary directory
- checks that all bundled patches apply with `patch --dry-run`
- updates `NODE_VERSION.lock` only if validation succeeds

If patch validation fails, the lock file is left unchanged.

For one-off testing without changing tracked files:

```bash
VERSION=v25.8.2 make bootstrap
```

## Common Commands

```bash
make refresh-version   # update NODE_VERSION.lock to the latest validated release
make refresh-patches   # re-fetch Oracle Solaris Userland patches
make bootstrap         # extract, patch, build, install, verify
make verify            # verify installed Node.js and bundled OpenSSL version
make clean             # remove extracted source tree and build logs
make distclean         # clean + remove cached source tarballs
```

## Verification

`make verify` checks the installed binary under `~/.local/node/bin/node` and reports:

- the installed Node.js version
- the bundled OpenSSL version
- whether `/etc/openssl/3/certs` is embedded in the binary
- whether system CA certificates can be loaded
- whether HTTPS access works with `--use-openssl-ca`

Typical output:

```text
[bootstrap] verifying installed node
  Node.js version: v25.9.0
  Bundled OpenSSL version: 3.5.5
```

## Why The OpenSSL Patch Exists

On this Solaris host, OpenSSL configuration and CA material live under `/etc/openssl/3`, not `/etc/ssl`.

The local patch in [`patches/local/004-solaris-openssl-defaults.patch`](./patches/local/004-solaris-openssl-defaults.patch) changes the bundled OpenSSL defaults so that:

- `node --use-openssl-ca` looks under `/etc/openssl/3`
- the binary embeds `/etc/openssl/3/certs`
- system CA loading works on this Solaris environment

## Repository Layout

```text
Makefile                     # public entrypoints
NODE_VERSION.lock            # selected Node.js version
scripts/bootstrap-node.sh    # bootstrap implementation
patches/upstream/            # Oracle Solaris Userland patches
patches/local/               # local Solaris-specific adjustments
docs/SESSION_HANDOFF.md      # deeper operational notes
downloads/                   # cached source tarballs
work/                        # extracted source trees
logs/                        # configure/build/install logs
```

## Notes For Solaris

- use `gmake`, not Solaris `make`
- use `gtar` for tarball extraction
- `test-wasi-poll` is intentionally skipped by the Solaris patch set
- `make bootstrap` does not auto-upgrade versions
- `make refresh-version` is the only command that updates `NODE_VERSION.lock`

## More Detail

See [`docs/SESSION_HANDOFF.md`](./docs/SESSION_HANDOFF.md) for the fuller Solaris handoff and operational notes.
