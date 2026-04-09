#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_PREFIX="${HOME}/.local/node"
VERSION_LOCK_FILE="${REPO_ROOT}/NODE_VERSION.lock"
RELEASE_INDEX_URL="https://nodejs.org/dist/index.json"

DOWNLOAD_DIR="${REPO_ROOT}/downloads"
WORK_DIR="${REPO_ROOT}/work"
PATCH_DIR="${REPO_ROOT}/patches"
UPSTREAM_PATCH_DIR="${PATCH_DIR}/upstream"
LOCAL_PATCH_DIR="${PATCH_DIR}/local"
LOG_DIR="${REPO_ROOT}/logs"

JOBS="${JOBS:-1}"

ORACLE_PATCH_BASE_URL="https://raw.githubusercontent.com/oracle/solaris-userland/master/components/nodejs24/patches"
UPSTREAM_PATCHES=(
  "001-madvise.patch"
  "002-pthread_getattr_np.patch"
  "003-no-test-wasi-poll.patch"
)
LOCAL_PATCHES=(
  "004-solaris-openssl-defaults.patch"
)

NODE_VERSION=""
NODE_BASENAME=""
TARBALL_URL=""
TARBALL_PATH=""
SRC_DIR=""

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

write_file() {
  local path="$1"
  local value="$2"
  printf '%s\n' "${value}" > "${path}"
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

resolve_latest_release_version() {
  local metadata

  if command -v curl >/dev/null 2>&1; then
    metadata="$(curl -fsSL "${RELEASE_INDEX_URL}")"
  elif command -v wget >/dev/null 2>&1; then
    metadata="$(wget -qO- "${RELEASE_INDEX_URL}")"
  else
    die "missing downloader: need curl or wget"
  fi

  printf '%s\n' "${metadata}" | python3 -c '
import json
import sys

releases = json.load(sys.stdin)
if not releases:
    raise SystemExit("empty release metadata")

version = releases[0].get("version", "")
if not version.startswith("v"):
    raise SystemExit(f"unexpected latest release version: {version!r}")

print(version)
'
}

set_version_context() {
  local version="$1"

  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid node version: ${version}"

  NODE_VERSION="${version}"
  NODE_BASENAME="node-${NODE_VERSION}"
  TARBALL_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_BASENAME}.tar.gz"
  TARBALL_PATH="${DOWNLOAD_DIR}/${NODE_BASENAME}.tar.gz"
  SRC_DIR="${WORK_DIR}/${NODE_BASENAME}"
}

resolve_locked_version() {
  [[ -f "${VERSION_LOCK_FILE}" ]] || die "missing version lock file: ${VERSION_LOCK_FILE}"

  local locked_version
  locked_version="$(tr -d '[:space:]' < "${VERSION_LOCK_FILE}")"
  [[ -n "${locked_version}" ]] || die "empty version lock file: ${VERSION_LOCK_FILE}"
  printf '%s\n' "${locked_version}"
}

resolve_version() {
  if [[ -n "${VERSION:-}" ]]; then
    printf '%s\n' "${VERSION}"
    return
  fi

  resolve_locked_version
}

load_version_context() {
  set_version_context "$(resolve_version)"
}

_wait_with_progress() {
  local pid="$1"
  local logfile="$2"
  local elapsed=0
  while kill -0 "${pid}" 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    printf '\r[bootstrap]   ... %dm%02ds elapsed' $((elapsed / 60)) $((elapsed % 60)) >&2
  done
  (( elapsed > 0 )) && printf '\n' >&2
  wait "${pid}"
}

run_logged() {
  local logfile="$1"
  shift
  log "running: $*"
  "$@" >"${logfile}" 2>&1 &
  local pid=$!
  if ! _wait_with_progress "${pid}" "${logfile}"; then
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
    "$@" >"${logfile}" 2>&1
  ) &
  local pid=$!
  if ! _wait_with_progress "${pid}" "${logfile}"; then
    printf '[bootstrap] command failed, see %s\n' "${logfile}" >&2
    tail -n 50 "${logfile}" >&2 || true
    return 1
  fi
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

write_lock_file() {
  local version="$1"
  write_file "${VERSION_LOCK_FILE}" "${version}"
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

validate_patch_set_for_version() {
  local version="$1"
  local temp_root
  local temp_tarball
  local temp_work_dir
  local temp_src_dir
  local patch_name

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/node-bootstrap-refresh.XXXXXX")" || die "failed to create temporary directory"

  temp_tarball="${temp_root}/node-${version}.tar.gz"
  temp_work_dir="${temp_root}/work"
  temp_src_dir="${temp_work_dir}/node-${version}"

  if ! {
    mkdir -p "${temp_work_dir}"

    log "validating latest release candidate ${version}"
    fetch_url "https://nodejs.org/dist/${version}/node-${version}.tar.gz" "${temp_tarball}"
    gtar -xzf "${temp_tarball}" -C "${temp_work_dir}"
    [[ -d "${temp_src_dir}" ]]

    ensure_upstream_patches

    for patch_name in "${UPSTREAM_PATCHES[@]}"; do
      require_file "${UPSTREAM_PATCH_DIR}/${patch_name}"
      log "dry-run patch ${patch_name} against ${version}"
      (
        cd "${temp_src_dir}"
        patch -p1 --forward --batch --dry-run < "${UPSTREAM_PATCH_DIR}/${patch_name}"
      ) >/dev/null
    done

    for patch_name in "${LOCAL_PATCHES[@]}"; do
      require_file "${LOCAL_PATCH_DIR}/${patch_name}"
      log "dry-run patch ${patch_name} against ${version}"
      (
        cd "${temp_src_dir}"
        patch -p1 --forward --batch --dry-run < "${LOCAL_PATCH_DIR}/${patch_name}"
      ) >/dev/null
    done
  }; then
    rm -rf "${temp_root}"
    die "patch validation failed for ${version}"
  fi

  rm -rf "${temp_root}"
}

refresh_version() {
  local latest_version

  ensure_dirs
  latest_version="$(resolve_latest_release_version)"
  set_version_context "${latest_version}"
  validate_patch_set_for_version "${latest_version}"
  write_lock_file "${latest_version}"
  log "locked node version ${latest_version} in ${VERSION_LOCK_FILE}"
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
  load_version_context
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
  load_version_context
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
  load_version_context
  [[ -d "${SRC_DIR}" ]] || die "source tree missing: ${SRC_DIR}"
  run_logged "${LOG_DIR}/build.log" \
    env CC=gcc CXX=g++ \
    gmake -C "${SRC_DIR}" -j"${JOBS}"
}

install_source() {
  load_version_context
  [[ -d "${SRC_DIR}" ]] || die "source tree missing: ${SRC_DIR}"
  run_logged "${LOG_DIR}/install.log" \
    env CC=gcc CXX=g++ \
    gmake -C "${SRC_DIR}" install
}

verify_install() {
  local node_bin="${INSTALL_PREFIX}/bin/node"
  require_file "${node_bin}"

  log "verifying installed node"
  local node_version
  local openssl_version

  node_version="$("${node_bin}" -v)"
  openssl_version="$("${node_bin}" -p "process.versions.openssl")"

  printf '  Node.js version: %s\n' "${node_version}"
  printf '  Bundled OpenSSL version: %s\n' "${openssl_version}"

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
  load_version_context
  extract_source
  apply_patches
  configure_source
  build_source
  install_source
  verify_install
}

clean_work() {
  rm -rf "${WORK_DIR}"/node-v*
  rm -f "${LOG_DIR}/configure.log" "${LOG_DIR}/build.log" "${LOG_DIR}/install.log"
}

distclean_work() {
  clean_work
  rm -f "${DOWNLOAD_DIR}"/node-v*.tar.gz
}

usage() {
  cat <<'EOF'
Usage: bootstrap-node.sh <subcommand>

Subcommands:
  refresh-version  Resolve the latest Node release, validate patches, and update NODE_VERSION.lock
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
    refresh-version)
      check_prereqs
      refresh_version
      ;;
    download)
      check_prereqs
      load_version_context
      download_tarball
      ;;
    extract)
      check_prereqs
      load_version_context
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
