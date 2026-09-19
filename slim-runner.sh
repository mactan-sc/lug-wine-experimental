#!/usr/bin/env bash

set -euo pipefail

prefix="${1:-}"
if [ -z "$prefix" ] || [ ! -d "$prefix" ]; then
    echo "usage: $0 <installed-prefix>" >&2
    exit 1
fi

jobs="$(nproc 2>/dev/null || echo 1)"

strip_files() {
    local desc="$1"; shift
    local file files=()
    while IFS= read -r -d '' file; do files+=("$file"); done \
        < <(find "$prefix" -type f "$@" -print0)

    echo "==> Stripping ${#files[@]} $desc"
    if [ "${#files[@]}" -gt 0 ]; then
        printf '%s\0' "${files[@]}" | xargs -0 -r -P "$jobs" -n 1 strip --strip-unneeded
    fi
}

# modules and ELF shared objects
strip_files "PE modules and ELF shared objects" \
    \( -iname '*.dll' -o -iname '*.so' -o -iname '*.exe' -o \
       -iname '*.sys' -o -iname '*.drv' -o -iname '*.ocx' -o \
       -iname '*.cpl' -o -iname '*.acm' -o -iname '*.ax' -o \
       -iname '*.ds' \)

# Extension-less ELF executables
strip_files "ELF executables" \
    -perm -u+x ! -name '*-preloader' \
    \( -name 'wine' -o -name 'wine64' -o -name 'wineserver' \)

echo "==> Pruning development payload from $prefix"
rm -rf "$prefix/include" "$prefix/share/man"
find "$prefix/lib/wine" -type f -name 'lib*.a' -delete
rm -f "$prefix/bin/winegcc" "$prefix/bin/wineg++" "$prefix/bin/winecpp" \
      "$prefix/bin/winebuild" "$prefix/bin/widl" "$prefix/bin/wrc" \
      "$prefix/bin/wmc" "$prefix/bin/winedump" "$prefix/bin/winemaker" \
      "$prefix/bin/function_grep.pl"

# fail the build we lost something important
required=(
    bin/wine
    bin/wineserver
    lib/wine/x86_64-unix/wine64
    lib/wine/i386-windows
    lib/wine/x86_64-windows
    share/wine/wine.inf
    share/wine/nls
    share/wine/fonts
)
for path in "${required[@]}"; do
    if [ ! -e "$prefix/$path" ]; then
        echo "slim-runner: missing required path after slimming: $path" >&2
        exit 1
    fi
done

for dir in lib/wine/x86_64-unix lib/wine/i386-windows lib/wine/x86_64-windows; do
    if ! compgen -G "$prefix/$dir/*" > /dev/null; then
        echo "slim-runner: $dir is empty after slimming" >&2
        exit 1
    fi
done

echo "==> Slimmed runner: $(du -sh "$prefix" | cut -f1), $(find "$prefix" -type f | wc -l) files"
