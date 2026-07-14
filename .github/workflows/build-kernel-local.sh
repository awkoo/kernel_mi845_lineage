#!/bin/bash
set -euo pipefail

AOSP_TOOLCHAIN_BRANCH="android16"
AOSP_CLANG_VERSION="r547379"
KERNEL_DIR="kernel"
OUTPUT_DIR="out"
CLANG_DIR="clang"

DEVICES=(
  "perseus"
)

declare -A device_matrix
device_matrix=(
  [beryllium]="Xiaomi Poco F1"
  [dipper]="Xiaomi Mi 8"
  [equuleus]="Xiaomi Mi 8 Pro"
  [perseus]="Xiaomi Mi MIX 3"
  [polaris]="Xiaomi Mi MIX 2S"
  [ursa]="Xiaomi Mi 8 Explorer Edition"
)


log_info() {
  echo -e "\033[0;32m[INFO]\033[0m $1"
}

log_warn() {
  echo -e "\033[1;33m[WARN]\033[0m $1"
}

log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1"
}

check_dependencies() {
  log_info "Checking dependencies..."

  local missing=()

  for cmd in make git wget curl tar zip ccache gcc; do
    if ! command -v "$cmd" &> /dev/null; then
      missing+=("$cmd")
    fi
  done

  # Check binutils
  if ! command -v aarch64-linux-gnu-as &> /dev/null; then
    missing+=("binutils-aarch64-linux-gnu")
  fi

  if ! command -v arm-linux-gnueabi-as &> /dev/null; then
    missing+=("binutils-arm-linux-gnueabi")
  fi

  # Check development headers and libraries via dpkg
  local dpkg_packages=(
    "libc6-dev"
    "linux-libc-dev"
    "libncurses-dev"
    "libncurses6"
  )

  for pkg in "${dpkg_packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("$pkg")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing dependencies: ${missing[*]}"
    echo
    echo "Install them with:"
    echo "  sudo apt-get update -q && sudo apt-get install -y ${missing[*]}"
    echo
    exit 2
  fi

  log_info "All dependencies installed"
}


setup_clang() {
    log_info "Setting up Clang..."

    local clang_url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${AOSP_TOOLCHAIN_BRANCH}-release/clang-${AOSP_CLANG_VERSION}.tar.gz"

    if [ ! -f "${CLANG_DIR}/bin/clang" ]; then
        log_info "Downloading Clang ${AOSP_CLANG_VERSION}..."
        echo

        mkdir -p "${CLANG_DIR}"
        wget -c -t 10 -O clang.tar.gz "${clang_url}"
        tar -xzf clang.tar.gz -C "${CLANG_DIR}"
        rm clang.tar.gz
    else
        log_info "Clang already installed in ${CLANG_DIR}/"
    fi

    export PATH="$PWD/${CLANG_DIR}/bin:$PATH"
}

setup_ccache() {
    export CCACHE_DIR="$PWD/.ccache"

    mkdir -p "$CCACHE_DIR"

    export CCACHE_MAXSIZE=5G
    export CCACHE_NOHASHDIR=true
    export CCACHE_COMPILERCHECK=content

    ccache -M "$CCACHE_MAXSIZE"
}


build_kernel() {
  local device=$1

  log_info "Building kernel for ${device} (${device_matrix[$device]})..."; echo

  cd "${KERNEL_DIR}"

  # Clean previous build
  rm -rf "${OUTPUT_DIR}"

  # export CCACHE_LOGFILE=/tmp/ccache.log

  ccache -d "${CCACHE_DIR}" -z 1>/dev/null

  # export KBUILD_BUILD_USER=""
  # export KBUILD_BUILD_HOST=""
  export KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$(git log -1 --format=%at 2>/dev/null || echo $(date +%s))" +"%a %b %d %H:%M:%S %Z %Y" 2>/dev/null || date -u)

  time make -j$(nproc --all) \
       O="${OUTPUT_DIR}" \
       LLVM=1 \
       LLVM_IAS=1 \
       CC="ccache clang" \
       LD=ld.lld \
       ARCH=arm64 \
       CROSS_COMPILE=aarch64-linux-gnu- \
       CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
       vendor/xiaomi/mi845_defconfig \
       vendor/xiaomi/${device}.config \
       all \
       2>&1 | tee "../build.log"

  echo >> "../build.log"
  echo
  echo ccache dir: "$CCACHE_DIR"
  echo
  du -sh "$CCACHE_DIR"
  echo
  ccache -d "${CCACHE_DIR}" -s | tee -a "../build.log"

  if [ ! -f "${OUTPUT_DIR}/arch/arm64/boot/Image.gz-dtb" ]; then
    log_error "Image.gz-dtb not found for ${device}"
    ls -la "${OUTPUT_DIR}/arch/arm64/boot/" || true
    cd ..
    return 1
  fi

  echo
  log_info "Kernel for ${device} built successfully"
  cd ..
}

create_anykernel3() {
  local device=$1
  local device_name="${device_matrix[$device]}"

  log_info "Creating AnyKernel3 for ${device} (${device_name})..."

  local ak3_dir="ak3-${device}"

  if [ ! -d "${ak3_dir}" ]; then
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "${ak3_dir}"
  else
    cd "${ak3_dir}"
    git fetch -f origin master >/dev/null
    git reset --hard FETCH_HEAD >/dev/null
    git clean -fdx >/dev/null 2>&1
    cd ..
  fi

  cp "${KERNEL_DIR}/${OUTPUT_DIR}/arch/arm64/boot/Image.gz-dtb" "${ak3_dir}/"

  cd "${ak3_dir}"

  sed -i \
    -e "s/kernel.string=.*/kernel.string=Kernel for ${device_name}/" \
    -e "s/device.name1=.*/device.name1=${device}/" \
    -e "s/device.name2=.*/device.name2=/" \
    -e "s/device.name3=.*/device.name3=/" \
    -e "s/device.name4=.*/device.name4=/" \
    -e "s|BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot|BLOCK=auto|" \
    anykernel.sh

  zip -qr9 "Anykernel3-${device}.zip" . -x "./.git/*" "./.github/*" "./README.md"
  cd ..

  log_info "AnyKernel3 for ${device} created: ${ak3_dir}/Anykernel3-${device}.zip"
}


main() {
  echo
  check_dependencies
  setup_clang
  setup_ccache
  echo

  # Build for each device
  local success_count=0
  local fail_count=0

  for device in "${DEVICES[@]}"; do
    if build_kernel "${device}"; then
      create_anykernel3 "${device}"
      success_count=$((success_count + 1))
    else
      log_error "Build for ${device} failed"
      fail_count=$((fail_count + 1))
    fi
    echo
  done

  log_info "Build completed"
  log_info "Successful: ${success_count}"
  if [ ${fail_count} -gt 0 ]; then
    log_warn "Failed: ${fail_count}"
  fi

  echo ""
  log_info "Created files:"
  for device in "${DEVICES[@]}"; do
    if [ -f "ak3-${device}/Anykernel3-${device}.zip" ]; then
      local size=$(du -h "ak3-${device}/Anykernel3-${device}.zip" | cut -f1)
      echo "  • ${device} (${device_matrix[$device]}): ${size}"
    fi
  done
}

# Run
main "$@"