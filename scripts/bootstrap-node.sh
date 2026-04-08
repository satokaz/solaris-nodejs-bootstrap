#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE_VERSION="v25.9.0"
NODE_BASENAME="node-${NODE_VERSION}"
TARBALL_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_BASENAME}.tar.gz"
INSTALL_PREFIX="${HOME}/.local/node"

DOWNLOAD_DIR="${REPO_ROOT}/downloads"
WORK_DIR="${REPO_ROOT}/work"
PATCH_DIR="${REPO_ROOT}/patches"
UPSTREAM_PATCH_DIR="${PATCH_DIR}/upstream"
LOCAL_PATCH_DIR="${PATCH_DIR}/local"
LOG_DIR="${REPO_ROOT}/logs"

TARBALL_PATH="${DOWNLOAD_DIR}/${NODE_BASENAME}.tar.gz"
SRC_DIR="${WORK_DIR}/${NODE_BASENAME}"

JOBS="${JOBS:-16}"

ORACLE_PATCH_BASE_URL="https://raw.githubusercontent.com/oracle/solaris-userland/master/components/nodejs24/patches"
UPSTREAM_PATCHES=(
  "001-madvise.patch"
  "002-pthread_getattr_np.patch"
  "003-no-test-wasi-poll.patch"
)
LOCAL_PATCHES=(
  "004-solaris-openssl-defaults.patch"
)

log() {
  printf '[bootstrap] %s\n' "$*"
}

die() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p "${DOWNLOAD_DIR}" "${WORK_DIR}" "${LOG_DIR}" "${UPSTREAM_PATCH_DIR}" "${LOCAL_PATCH_DIR}"
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

require_file() {
  local path="$1"
  [[ -e "${path}" ]] || die "missing required file: ${path}"
}

fetch_url() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${dest}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${dest}" "${url}"
  else
    die "missing downloader: need curl or wget"
  fi
}

run_logged() {
  local logfile="$1"
  shift
  log "running: $*"
  if ! "$@" >"${logfile}" 2>&1; then
    printf '[bootstrap] command failed, see %s\n' "${logfile}" >&2
    tail -n 50 "${logfile}" >&2 || true
    return 1
  fi
}

run_logged_in() {
  local logfile="$1"
  local dir="$2"
  shift 2
  log "running in ${dir}: $*"
  (
    cd "${dir}"
    if ! "$@" >"${logfile}" 2>&1; then
      printf '[bootstrap] command failed, see %s\n' "${logfile}" >&2
      tail -n 50 "${logfile}" >&2 || true
      exit 1
    fi
  )
}

check_prereqs() {
  local cmd
  for cmd in gtar gmake gcc g++ python3 patch strings; do
    require_cmd "${cmd}"
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "missing downloader: need curl or wget"
  fi

  require_file /usr/include/ares.h
  require_file /usr/lib/64/libcares.so
}

refresh_patches() {
  ensure_dirs
  local patch_name
  for patch_name in "${UPSTREAM_PATCHES[@]}"; do
    log "fetching ${patch_name}"
    fetch_url "${ORACLE_PATCH_BASE_URL}/${patch_name}" "${UPSTREAM_PATCH_DIR}/${patch_name}"
  done
}

ensure_upstream_patches() {
  local patch_name
  for patch_name in "${UPSTREAM_PATCHES[@]}"; do
    if [[ ! -f "${UPSTREAM_PATCH_DIR}/${patch_name}" ]]; then
      log "vendored patch missing, fetching ${patch_name}"
      fetch_url "${ORACLE_PATCH_BASE_URL}/${patch_name}" "${UPSTREAM_PATCH_DIR}/${patch_name}"
    fi
  done
}

download_tarball() {
  ensure_dirs
  if [[ -f "${TARBALL_PATH}" ]]; then
    log "using cached tarball ${TARBALL_PATH}"
    return
  fi
  log "downloading ${TARBALL_URL}"
  fetch_url "${TARBALL_URL}" "${TARBALL_PATH}"
}

extract_source() {
  ensure_dirs
  download_tarball
  rm -rf "${SRC_DIR}"
  log "extracting ${TARBALL_PATH}"
  gtar -xzf "${TARBALL_PATH}" -C "${WORK_DIR}"
  [[ -d "${SRC_DIR}" ]] || die "expected extracted source at ${SRC_DIR}"
}

apply_patch_file() {
  local patch_file="$1"
  require_file "${patch_file}"
  log "applying $(basename "${patch_file}")"
  (
    cd "${SRC_DIR}"
    patch -p1 --forward --batch < "${patch_file}"
  )
}

apply_patches() {
  [[ -d "${SRC_DIR}" ]] || extract_source
  ensure_upstream_patches
  local patch_name
  for patch_name in "${UPSTREAM_PATCHES[@]}"; do
    require_file "${UPSTREAM_PATCH_DIR}/${patch_name}"
    apply_patch_file "${UPSTREAM_PATCH_DIR}/${patch_name}"
  done
  for patch_name in "${LOCAL_PATCHES[@]}"; do
    require_file "${LOCAL_PATCH_DIR}/${patch_name}"
    apply_patch_file "${LOCAL_PATCH_DIR}/${patch_name}"
  done
}

configure_source() {
  [[ -d "${SRC_DIR}" ]] || die "source tree missing: ${SRC_DIR}"
  run_logged_in "${LOG_DIR}/configure.log" "${SRC_DIR}" \
    env CC=gcc CXX=g++ \
    ./configure \
    --prefix="${INSTALL_PREFIX}" \
    --shared-cares \
    --shared-cares-includes=/usr/include \
    --shared-cares-libpath=/usr/lib/64 \
    --shared-cares-libname=cares
}

build_source() {
  [[ -d "${SRC_DIR}" ]] || die "source tree missing: ${SRC_DIR}"
  run_logged "${LOG_DIR}/build.log" \
    env CC=gcc CXX=g++ \
    gmake -C "${SRC_DIR}" -j"${JOBS}"
}

install_source() {
  [[ -d "${SRC_DIR}" ]] || die "source tree missing: ${SRC_DIR}"
  run_logged "${LOG_DIR}/install.log" \
    env CC=gcc CXX=g++ \
    gmake -C "${SRC_DIR}" install
}

verify_install() {
  local node_bin="${INSTALL_PREFIX}/bin/node"
  require_file "${node_bin}"

  log "verifying installed node"
  "${node_bin}" -v
  "${node_bin}" -p "process.versions.openssl"

  local embedded_strings
  embedded_strings="$(strings "${node_bin}")"
  if ! grep -q '/etc/openssl/3/certs' <<<"${embedded_strings}"; then
    die "installed node does not embed /etc/openssl/3/certs"
  fi

  local cert_count
  cert_count="$("${node_bin}" --use-openssl-ca -e 'const tls=require("tls"); process.stdout.write(String(tls.getCACertificates("system").length))')"
  [[ "${cert_count}" =~ ^[0-9]+$ ]] || die "unexpected certificate count output: ${cert_count}"
  if (( cert_count <= 0 )); then
    die "system certificate count is not positive"
  fi

  local https_status
  https_status="$("${node_bin}" --use-openssl-ca -e 'require("https").get("https://example.com", (res) => { console.log(res.statusCode); res.resume(); }).on("error", (err) => { console.error(err); process.exit(1); })')"
  [[ "${https_status}" == "200" ]] || die "unexpected HTTPS status: ${https_status}"
}

bootstrap() {
  check_prereqs
  ensure_dirs
  extract_source
  apply_patches
  configure_source
  build_source
  install_source
  verify_install
}

clean_work() {
  rm -rf "${SRC_DIR}"
  rm -f "${LOG_DIR}/configure.log" "${LOG_DIR}/build.log" "${LOG_DIR}/install.log"
}

distclean_work() {
  clean_work
  rm -f "${TARBALL_PATH}"
}

usage() {
  cat <<'EOF'
Usage: bootstrap-node.sh <subcommand>

Subcommands:
  refresh-patches  Download Oracle Solaris patches 001, 002, 003 into patches/upstream/
  download         Download the Node.js source tarball into downloads/
  extract          Extract the source tarball into work/
  patch            Apply vendored Oracle patches and the local Solaris OpenSSL patch
  build            Configure and build the extracted source tree
  install          Install the built tree into ~/.local/node
  verify           Verify the installed Node binary and OpenSSL CA behavior
  bootstrap        Run the full flow from patch refresh through verify
  clean            Remove extracted source and logs
  distclean        Remove extracted source, logs, and cached tarball
EOF
}

main() {
  local subcommand="${1:-}"
  case "${subcommand}" in
    refresh-patches)
      check_prereqs
      refresh_patches
      ;;
    download)
      check_prereqs
      download_tarball
      ;;
    extract)
      check_prereqs
      extract_source
      ;;
    patch)
      check_prereqs
      apply_patches
      ;;
    build)
      check_prereqs
      configure_source
      build_source
      ;;
    install)
      check_prereqs
      install_source
      ;;
    verify)
      check_prereqs
      verify_install
      ;;
    bootstrap)
      bootstrap
      ;;
    clean)
      clean_work
      ;;
    distclean)
      distclean_work
      ;;
    *)
      usage
      [[ -n "${subcommand}" ]] && exit 1
      ;;
  esac
}

main "$@"
