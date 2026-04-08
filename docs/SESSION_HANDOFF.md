# Node.js Solaris Bootstrap Handoff

This repository bootstraps Node.js `v25.9.0` from source on Solaris 11.4 and installs it into `~/.local/node`.

## Goal

Automate:

- downloading `https://nodejs.org/dist/v25.9.0/node-v25.9.0.tar.gz`
- extracting into `work/node-v25.9.0`
- applying Oracle Solaris patches `001`, `002`, `003`
- applying a local Solaris bundled OpenSSL patch to use `/etc/openssl/3`
- building with `gcc/g++` and `gmake`
- installing into `/export/home/kazus/.local/node`

## Entrypoints

- `make bootstrap`
- `make refresh-patches`
- `make verify`

All target logic delegates to `scripts/bootstrap-node.sh`.

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
~/.local/node/bin/node -v
~/.local/node/bin/npm -v
strings ~/.local/node/bin/node | grep /etc/openssl/3
~/.local/node/bin/node --use-openssl-ca -e 'const tls=require("tls"); console.log(tls.getCACertificates("system").length)'
~/.local/node/bin/node --use-openssl-ca -e 'require("https").get("https://example.com", r => { console.log(r.statusCode); r.resume(); }).on("error", e => { console.error(e); process.exit(1); })'
```

Expected:

- `node -v` prints `v25.9.0`
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

## Logs

Build logs are written to:

- `logs/configure.log`
- `logs/build.log`
- `logs/install.log`

If a command fails, inspect the corresponding log first.

