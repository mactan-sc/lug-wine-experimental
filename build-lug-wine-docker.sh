#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

######### error codes ################################################
invalid_args=-1

######## environment #################################################
preset="default"
wine_version=""
lug_rev="1"
output_dir="$SCRIPT_DIR/output"

# LUG patches applied to every build, in order (mirrors build-lug-wine.sh)
patches=("10.2+_eac_fix"
         "eac_locale"
         "dummy_dlls"
         "enables_dxvk-nvapi"
         "nvngx_dlls"
         "cache-committed-size"
         "silence-sc-unsupported-os"
         "hidewineexports"
         "reg_hide_wine"
         "eac_60101_timeout"
         "unopenable-device-is-bad"
         "append_cmd"
         "sc_gpumem"
         "0001-wineopenxr_add"
         "0002-wineopenxr_enable"
         "disable_syscall_dispatch"
         "systray-title"
         "winewayland-prefer-relative-pointer"
         "winewayland-guess-primary-output"
         "winewayland-fullscreen-idle-inhibit"
         "winewayland-systray"
)

adhoc=()

preset_name=""
preset_staging=false
preset_wayland=false

parse_adhoc() {
  local -a extra
  IFS=',' read -r -a extra <<< "$1"
  adhoc+=("${extra[@]}")
}

preset_conf() {
  case "$1" in
    default)
      preset_name="default"; preset_staging=false; preset_wayland=false ;;
    staging|staging-default)
      preset_name="staging"; preset_staging=true; preset_wayland=false ;;
    wayland)
      preset_name="wayland"; preset_staging=false; preset_wayland=true ;;
    staging-wayland)
      preset_name="staging-wayland"; preset_staging=true; preset_wayland=true ;;
    *)
      return 1 ;;
  esac
}

runner_name() {
  local name="lug-wine"
  if [ "$preset_name" != "default" ]; then name="${name}-${preset_name}"; fi
  if [ -n "$wine_version" ]; then
    name="${name}-${wine_version}"
  else
    name="${name}-git"
  fi
  printf '%s-%s' "$name" "$lug_rev"
}

build_preset() {
  if ! preset_conf "$1"; then
    printf "%s: Unknown preset '%s'\n\n" "$0" "$1" >&2
    usage >&2
    exit $invalid_args
  fi

  local name
  name="$(runner_name)"

  # Adhoc patches
  local -a all_patches=("${patches[@]}" "${adhoc[@]}")

  local -a args=(
    --build-arg "PRESET=$preset_name"
    --build-arg "LUG_REV=$lug_rev"
    --build-arg "ENABLE_STAGING=$preset_staging"
    --build-arg "WAYLAND_DEFAULT=$preset_wayland"
    --build-arg "PATCH_LIST=${all_patches[*]}"
    --build-arg "VKD3D_PROTON_DIR=./vkd3d-proton/build/vkd3d-proton-master/"
  )
  if [ -n "$wine_version" ]; then
    args+=(--build-arg "WINE_VERSION=wine-$wine_version")
    args+=(--build-arg "STAGING_VERSION=v$wine_version")
  fi

  printf '==> Building preset %-16s -> %s.tar.gz\n' "$1" "$name"
  docker build "${args[@]}" --target export -o "$output_dir" "$SCRIPT_DIR"
  printf '    wrote %s/%s.tar.gz\n' "$output_dir" "$name"
}

usage() {
  printf "Linux Users Group Wine Docker Build Script\n
Usage: ./build-lug-wine-docker.sh <options>
./build-lug-wine-docker.sh -p default -v 10.23 -r 1 -a default-to-wayland
  -h, --help                    Display this help message and exit
  -v, --version                 Wine version to build e.g. \"10.23\" (default: latest git)
  -a, --adhoc                   Comma-separated list of adhoc patches to apply
  -p, --preset                  Select a preset (default|staging-default|staging-wayland|wayland)
                                One preset per invocation (default: default)
  -o, --output                  Output directory for the build artifact (default: ./output)
  -r, --revision                Revision number for the build (default: 1)
  -d, --vkd3d-proton-dir        Directory holding the prebuilt x64/ + x86/ vkd3d-proton
                                modules to bundle. Optional: when it is missing (or outside
                                the build context) the build proceeds and the runner keeps
                                Wine's own vkd3d modules.
                                default: ./vkd3d-proton/build/vkd3d-proton-master
"
}

# MARK: Cmdline arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help | -h )
      usage
      exit 0
      ;;
    --preset | -p )
        preset="$2"
          shift
          ;;
    --version | -v )
         wine_version="$2"
                shift
                ;;
    --revision | -r )
      lug_rev="${2:-1}"
      shift
      ;;
    --adhoc | -a )
      parse_adhoc "$2"
      shift
      ;;
    --output | -o )
      output_dir="$2"
      shift
      ;;
    --vkd3d-proton-dir | -d )
      vkd3d_build_dir="$2"
      shift
      ;;
    * )
      printf "%s: Invalid argument '%s'\n" "$0" "$1" >&2
      usage >&2
      exit $invalid_args
      ;;
  esac
  shift
done

mkdir -p "$output_dir"

build_preset "$preset"
