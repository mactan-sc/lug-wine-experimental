# syntax=docker/dockerfile:1

ARG WINE_REPO=https://github.com/wine-mirror/wine.git
ARG STAGING_REPO=https://github.com/wine-staging/wine-staging.git
ARG WINE_VERSION=master
ARG ENABLE_STAGING=false
ARG STAGING_VERSION=
ARG WAYLAND_DEFAULT=false
ARG JOBS=auto
ARG PREFIX=/opt
# Preset name used in the runner/prefix/tarball name, e.g. "default" or "staging-wayland".
# "default" is excluded from the runner name
ARG PRESET=default
# LUG build revision used in the runner name
ARG LUG_REV=1
# Space separated list of LUG patches
ARG PATCH_LIST=
# Optional prebuilt vkd3d-proton
ARG VKD3D_PROTON_DIR=.vkd3d-proton

FROM ubuntu:24.04 AS builder

ARG WINE_REPO
ARG WINE_VERSION
ARG ENABLE_STAGING
ARG STAGING_REPO
ARG STAGING_VERSION
ARG WAYLAND_DEFAULT
ARG JOBS
ARG PREFIX
ARG PRESET
ARG LUG_REV
ARG PATCH_LIST
ARG VKD3D_PROTON_DIR

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential gcc g++ make pkg-config \
      git ca-certificates curl xz-utils bzip2 cpio patch \
      autoconf automake libtool gettext autopoint bison flex gawk perl python3 \
      gcc-mingw-w64-i686 g++-mingw-w64-i686 gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
      libfreetype6-dev libfontconfig1-dev \
      libx11-dev libxext-dev libxi-dev libxrender-dev libxrandr-dev libxcomposite-dev \
      libxfixes-dev libxinerama-dev libxcursor-dev libxdamage-dev libxmu-dev \
      libxpresent-dev libxxf86vm-dev libgl1-mesa-dev libglu1-mesa-dev libosmesa6-dev \
      libegl1-mesa-dev libvulkan-dev \
      libwayland-dev libxkbcommon-dev libxkbregistry-dev libopenxr-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      libpulse-dev libasound2-dev libopenal-dev libfaudio-dev libsdl2-dev \
      libmpg123-dev libv4l-dev \
      libgnutls28-dev libgcrypt20-dev libssl-dev libkrb5-dev libldap2-dev \
      libcups2-dev libsane-dev libusb-1.0-0-dev libpcap-dev libudev-dev libunwind-dev \
      libdbus-1-dev ocl-icd-opencl-dev \
      libxml2-dev libxslt1-dev liblcms2-dev libpng-dev libjpeg-dev libtiff-dev libgif-dev \
      libgtk-3-dev zlib1g-dev libattr1-dev libcap-dev \
    && rm -rf /var/lib/apt/lists/*

# ntsync header (needed by Wine's ntsync support; not in ubuntu 24.04 yet)
RUN mkdir -p /usr/local/include/linux && \
    curl -o /usr/local/include/linux/ntsync.h -fs --retry 5 \
      https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/include/uapi/linux/ntsync.h && \
    echo "Latest ntsync.h downloaded!"

# Compiler flags
ENV CFLAGS="-O2 -ftree-vectorize -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types" \
    CXXFLAGS="-O2 -ftree-vectorize -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types" \
    LDFLAGS="-Wl,-O1,--sort-common,--as-needed" \
    CROSSCFLAGS="-O2 -ftree-vectorize -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types" \
    CROSSLDFLAGS="-Wl,-O1,--sort-common,--as-needed"

WORKDIR /src

# Set up the runner name
RUN VERSION="$(echo "${WINE_VERSION#wine-}" | sed 's/^v//' | tr '/' '_')"; \
    RUNNER_NAME="lug-wine"; \
    if [ -n "$PRESET" ] && [ "$PRESET" != "default" ]; then RUNNER_NAME="${RUNNER_NAME}-${PRESET}"; fi; \
    if [ -n "$VERSION" ] && [ "$VERSION" != "master" ]; then \
        RUNNER_NAME="${RUNNER_NAME}-${VERSION}"; \
    else \
        RUNNER_NAME="${RUNNER_NAME}-git"; \
    fi; \
    RUNNER_NAME="${RUNNER_NAME}-${LUG_REV}"; \
    echo "$RUNNER_NAME" > /src/runner-name && \
    echo "==> Runner name: $RUNNER_NAME"

# Fetch Wine and wine-staging
RUN if [ "$ENABLE_STAGING" = "true" ]; then \
        git clone --no-checkout "$WINE_REPO" /src/wine && \
        git clone "$STAGING_REPO" /src/wine-staging && \
        if [ -n "$STAGING_VERSION" ]; then git -C /src/wine-staging checkout "$STAGING_VERSION"; fi; \
    else \
        git clone --depth 1 --branch "$WINE_VERSION" "$WINE_REPO" /src/wine || \
        (git clone "$WINE_REPO" /src/wine && git -C /src/wine checkout "$WINE_VERSION"); \
    fi

COPY patches/wine/ /src/patches/wine/

# Check out the correct base commit and apply wine-staging if needed
RUN cd /src/wine && \
    if [ "$ENABLE_STAGING" = "true" ]; then \
        if [ -f /src/wine-staging/patches/patchinstall.sh ]; then \
            UPSTREAM=$(/src/wine-staging/patches/patchinstall.sh --upstream-commit); \
            PATCHER=/src/wine-staging/patches/patchinstall.sh; \
        else \
            UPSTREAM=$(cat /src/wine-staging/staging/upstream-commit); \
            PATCHER=/src/wine-staging/staging/patchinstall.py; \
        fi && \
        echo "==> wine-staging upstream commit: $UPSTREAM" && \
        git -c advice.detachedHead=false checkout "$UPSTREAM" && \
        STAGING_ARGS="-W ntdll-Hide_Wine_Exports" && \
        if [ -d /src/wine-staging/patches/ntdll-NtAlertThreadByThreadId ]; then \
            STAGING_ARGS="$STAGING_ARGS -W ntdll-NtAlertThreadByThreadId"; \
        fi && \
        # dcomp-DCompositionCreateDevice2 breaks the build
        STAGING_ARGS="$STAGING_ARGS -W dcomp-DCompositionCreateDevice2" && \
        "$PATCHER" DESTDIR=/src/wine --all $STAGING_ARGS; \
    else \
        git -c advice.detachedHead=false checkout "$WINE_VERSION"; \
    fi

# Apply LUG patches
RUN cd /src/wine && \
    if [ "$WAYLAND_DEFAULT" = "true" ]; then PATCH_LIST="$PATCH_LIST default-to-wayland"; fi && \
    for p in $PATCH_LIST; do \
        echo "==> Applying $p.patch"; \
        patch -Np1 < "/src/patches/wine/$p.patch" || exit 1; \
    done

# Regenerate build system after patching
RUN cd /src/wine && \
    git add -A && \
    tools/make_makefiles && \
    dlls/winevulkan/make_vulkan && \
    tools/make_requests && \
    if [ -x tools/make_specfiles ]; then tools/make_specfiles; fi && \
    autoreconf -fiv

# Report the runner name as the Wine version
RUN cd /src/wine && \
    RUN_NAME="$(cat /src/runner-name)" && \
    sed -i "s/GIT_DIR=\${wine_srcdir}.git git describe HEAD 2>\\/dev\\/null || echo \\\\\"wine-\\\\\$(PACKAGE_VERSION)\\\\\"/echo \\\\\"$RUN_NAME\\\\\"/g" \
        configure.ac configure && \
    if ! grep -qF "$RUN_NAME" configure; then \
        echo "ERROR: failed to set the Wine version name to '$RUN_NAME' (Wine's version rule changed?)" >&2; \
        exit 1; \
    fi && \
    echo "==> Wine reports its version as: $RUN_NAME"

# Configure and build
RUN JOBS_N=$([ "$JOBS" = "auto" ] && nproc || echo "$JOBS") && \
    mkdir -p /src/wine64-build && cd /src/wine64-build && \
    /src/wine/configure \
      --prefix="$PREFIX/$(cat /src/runner-name)" \
      --enable-archs=i386,x86_64 \
      --with-x --with-gstreamer --with-xattr \
      --disable-tests --with-faudio --without-vkd3d \
      --with-wayland --with-vulkan && \
    make -j"$JOBS_N" && \
    make install

# Bundle prebuilt vkd3d-proton modules if available
COPY ${VKD3D_PROTON_DIR}/ /src/vkd3d-proton/
RUN PREFIX_FULL="$PREFIX/$(cat /src/runner-name)"; \
    if [ -d /src/vkd3d-proton/x64 ] && [ -d /src/vkd3d-proton/x86 ]; then \
        for f in /src/vkd3d-proton/x64/*; do \
            "$PREFIX_FULL/bin/winebuild" "$f" --builtin; \
        done; \
        cp /src/vkd3d-proton/x64/* "$PREFIX_FULL/lib/wine/x86_64-windows/"; \
        for f in /src/vkd3d-proton/x86/*; do \
            "$PREFIX_FULL/bin/winebuild" "$f" --builtin; \
        done; \
        cp /src/vkd3d-proton/x86/* "$PREFIX_FULL/lib/wine/i386-windows/"; \
        echo "==> Bundled the prebuilt vkd3d-proton modules"; \
    else \
        echo "==> No vkd3d-proton build found, keeping Wine's own vkd3d modules"; \
    fi

# Slim the installed runner before it is archived
COPY slim-runner.sh /src/slim-runner.sh
RUN bash /src/slim-runner.sh "$PREFIX/$(cat /src/runner-name)"

# Archive the wine runner
RUN TAR_BASE="$(cat /src/runner-name)" && \
    PREFIX_FULL="$PREFIX/$TAR_BASE" && \
    mkdir -p /out && \
    tar -czf "/out/${TAR_BASE}.tar.gz" -C "$(dirname "$PREFIX_FULL")" "$(basename "$PREFIX_FULL")" && \
    echo "Created /out/${TAR_BASE}.tar.gz"

# Stage archived runner to the host
FROM scratch AS export
COPY --from=builder /out/*.tar.gz /

FROM builder AS runner
