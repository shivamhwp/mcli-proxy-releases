#!/bin/sh

set -eu

repository="shivamhwp/mcli-proxy-releases"
release_version="${MCLI_VERSION:-latest}"
install_directory="${MCLI_INSTALL_DIR:-${HOME}/.local/bin}"
app_directory="${MCLI_APP_DIR:-${install_directory}/.mcli-app}"
github_token="${MCLI_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
custom_release_url="${MCLI_RELEASE_URL:-}"
local_archive="${MCLI_ARCHIVE_PATH:-}"

step() {
  printf '\n[%s/9] %s\n' "$1" "$2"
}

download() {
  source_url="$1"
  destination="$2"
  if [ -n "${github_token}" ]; then
    curl --fail --show-error --location --retry 3 --retry-all-errors --retry-delay 1 \
      --connect-timeout 10 --max-time 300 --progress-bar \
      --header "Authorization: Bearer ${github_token}" \
      --output "${destination}" "${source_url}"
  else
    curl --fail --show-error --location --retry 3 --retry-all-errors --retry-delay 1 \
      --connect-timeout 10 --max-time 300 --progress-bar \
      --output "${destination}" "${source_url}"
  fi
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    printf 'mcli needs sha256sum or shasum to verify the download\n' >&2
    exit 1
  fi
}

find_bun() {
  if [ -n "${MCLI_BUN:-}" ] && [ -x "${MCLI_BUN}" ]; then
    printf '%s\n' "${MCLI_BUN}"
  elif command -v bun >/dev/null 2>&1; then
    command -v bun
  elif [ -x "${HOME}/.bun/bin/bun" ]; then
    printf '%s\n' "${HOME}/.bun/bin/bun"
  fi
  return 0
}

bun_supported() {
  version=$("$1" --version 2>/dev/null || printf '0.0.0')
  major=${version%%.*}
  remainder=${version#*.}
  minor=${remainder%%.*}
  [ "${major}" -gt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -ge 3 ]; }
}

step 1 "detecting platform"
case "$(uname -s)" in
  Darwin) operating_system="darwin" ;;
  Linux) operating_system="linux" ;;
  *) printf 'mcli does not support %s\n' "$(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) architecture="arm64" ;;
  x86_64 | amd64) architecture="x64" ;;
  *) printf 'mcli does not support %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
asset="mcli-${operating_system}-${architecture}.tar.gz"
printf 'target: %s\n' "${asset}"

step 2 "checking Bun runtime for OpenTUI React"
bun_bin=$(find_bun)
if [ -z "${bun_bin}" ] || ! bun_supported "${bun_bin}"; then
  printf 'Bun 1.3 or newer is missing. Installing Bun 1.4.0, about 64 MB.\n'
  if ! command -v bash >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    printf 'installing Bun requires bash and unzip\n' >&2
    exit 1
  fi
  bun_install="${MCLI_BUN_INSTALL:-${HOME}/.bun}"
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors --retry-delay 1 \
    --connect-timeout 10 --max-time 60 https://bun.com/install |
    BUN_INSTALL="${bun_install}" bash -s "bun-v1.4.0"
  bun_bin="${bun_install}/bin/bun"
fi
if [ ! -x "${bun_bin}" ] || ! bun_supported "${bun_bin}"; then
  printf 'Bun 1.3 or newer could not be installed\n' >&2
  exit 1
fi
printf 'runtime: Bun %s at %s\n' "$("${bun_bin}" --version)" "${bun_bin}"

step 3 "resolving mcli release"
if [ -n "${custom_release_url}" ]; then
  release_url="${custom_release_url%/}"
elif [ "${release_version}" = "latest" ]; then
  release_url="https://github.com/${repository}/releases/latest/download"
else
  case "${release_version}" in
    v*) tag="${release_version}" ;;
    *) tag="v${release_version}" ;;
  esac
  release_url="https://github.com/${repository}/releases/download/${tag}"
fi
printf 'release: %s\n' "${release_version}"

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/mcli-install.XXXXXX")
staged_app="${app_directory}.$$.install"
backup_app="${app_directory}.$$.backup"
staged_launcher="${install_directory}/.mcli.$$.install"
cleanup() {
  case "${temporary_directory}" in
    "${TMPDIR:-/tmp}"/mcli-install.*) rm -rf "${temporary_directory}" ;;
  esac
  case "${staged_app}" in
    */.mcli-app.*.install) rm -rf "${staged_app}" ;;
  esac
  if [ -e "${backup_app}" ] && [ ! -e "${app_directory}" ]; then
    mv "${backup_app}" "${app_directory}"
  elif [ -e "${backup_app}" ] && [ -e "${app_directory}" ]; then
    case "${backup_app}" in
      */.mcli-app.*.backup) rm -rf "${backup_app}" ;;
    esac
  fi
  case "${staged_launcher}" in
    */.mcli.*.install) rm -f "${staged_launcher}" ;;
  esac
}
trap cleanup EXIT INT TERM

step 4 "downloading ${asset}"
if [ -n "${local_archive}" ]; then
  cp "${local_archive}" "${temporary_directory}/${asset}"
  printf 'using local package: %s\n' "${local_archive}"
else
  download "${release_url}/${asset}" "${temporary_directory}/${asset}"
fi

step 5 "downloading SHA256SUMS"
if [ -n "${local_archive}" ]; then
  expected_checksum=$(checksum "${temporary_directory}/${asset}")
  printf 'local package checksum recorded\n'
else
  download "${release_url}/SHA256SUMS" "${temporary_directory}/SHA256SUMS"
  expected_checksum=$(awk -v name="${asset}" '$2 == name || $2 == "*" name { print $1; exit }' "${temporary_directory}/SHA256SUMS")
  if [ -z "${expected_checksum}" ]; then
    printf 'SHA256SUMS does not contain %s\n' "${asset}" >&2
    exit 1
  fi
fi

step 6 "verifying checksum"
actual_checksum=$(checksum "${temporary_directory}/${asset}")
if [ "${actual_checksum}" != "${expected_checksum}" ]; then
  printf 'checksum mismatch for %s\n' "${asset}" >&2
  exit 1
fi
printf 'checksum: %s\n' "${actual_checksum}"

step 7 "installing OpenTUI React application"
case "${app_directory}" in
  /*/.mcli-app) ;;
  *) printf 'MCLI_APP_DIR must end with /.mcli-app\n' >&2; exit 1 ;;
esac
case "${install_directory}" in
  / | "${HOME}") printf 'refusing unsafe MCLI_INSTALL_DIR: %s\n' "${install_directory}" >&2; exit 1 ;;
esac
if ! command -v tar >/dev/null 2>&1; then
  printf 'mcli needs tar to extract the application package\n' >&2
  exit 1
fi
mkdir -p "${install_directory}" "$(dirname -- "${app_directory}")"
rm -rf "${staged_app}" "${backup_app}"
mkdir -p "${staged_app}"
tar -xzf "${temporary_directory}/${asset}" -C "${staged_app}"
if [ ! -f "${staged_app}/bin.js" ] || [ ! -f "${staged_app}/mcli" ]; then
  printf 'the mcli package is incomplete\n' >&2
  exit 1
fi
had_current=0
if [ -e "${app_directory}" ]; then
  mv "${app_directory}" "${backup_app}"
  had_current=1
fi
if mv "${staged_app}" "${app_directory}"; then
  rm -rf "${backup_app}"
else
  if [ "${had_current}" -eq 1 ] && [ -e "${backup_app}" ]; then mv "${backup_app}" "${app_directory}"; fi
  exit 1
fi
install -m 0755 "${app_directory}/mcli" "${staged_launcher}"
mv -f "${staged_launcher}" "${install_directory}/mcli"
printf 'launcher: %s/mcli\napplication: %s\n' "${install_directory}" "${app_directory}"

step 8 "configuring shell"
if [ "${MCLI_NO_SHELL_CONFIG:-0}" = "1" ]; then
  printf 'shell configuration skipped\n'
else
  case ":${PATH}:" in
    *":${install_directory}:"*) printf '%s is already in PATH\n' "${install_directory}" ;;
    *)
      shell_name="${SHELL##*/}"
      if [ "${shell_name}" = "fish" ]; then
        if command -v fish >/dev/null 2>&1 && fish -c 'fish_add_path --universal $argv[1]' -- "${install_directory}"; then
          printf 'added %s to Fish PATH\n' "${install_directory}"
        else
          printf "add to Fish PATH: fish_add_path '%s'\n" "${install_directory}"
        fi
      else
        printf 'add to PATH: export PATH="%s:$PATH"\n' "${install_directory}"
      fi
      ;;
  esac
fi

installed_version=$(MCLI_APP_DIR="${app_directory}" MCLI_BUN="${bun_bin}" "${install_directory}/mcli" --version)
step 9 "mcli ${installed_version} is ready"
printf 'run: mcli setup\nthen: mcli\n'
