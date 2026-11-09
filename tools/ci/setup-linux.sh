#!/usr/bin/env bash
set -euo pipefail

# The base images supply R-devel. Compile all package dependencies below with
# the same toolchain: mixing GCC's libstdc++ and Clang's libc++ can hide errors.
case "$CI_COMPILER" in
  gcc|clang) ;;
  *) echo "Unsupported compiler: $CI_COMPILER" >&2; exit 1 ;;
esac

if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y gcc g++ gfortran cmake ninja-build pkg-config \
    libcurl4-openssl-dev libssl-dev libxml2-dev libgit2-dev zlib1g-dev \
    libbz2-dev liblzma-dev libzstd-dev libicu-dev libuv1-dev
  # The Debian R-hub image already supplies LLVM and libc++ 23.
  clang_cc=clang-23
  clang_cxx=clang++-23
elif command -v dnf >/dev/null; then
  dnf install -y gcc gcc-c++ gcc-gfortran clang libcxx-devel libcxxabi-devel \
    cmake ninja-build pkgconf-pkg-config libcurl-devel openssl-devel \
    libxml2-devel libgit2-devel zlib-devel bzip2-devel xz-devel \
    libzstd-devel libicu-devel libuv-devel
  clang_cc=clang
  clang_cxx=clang++
else
  echo 'Expected a Debian or Fedora container.' >&2
  exit 1
fi

if [ "$CI_COMPILER" = clang ]; then
  compiler_cc=$clang_cc
  compiler_cxx="$clang_cxx -stdlib=libc++"
else
  compiler_cc=gcc
  compiler_cxx=g++
fi

mkdir -p "$R_LIBS_USER"
{
  echo "CC = $compiler_cc"
  echo "CFLAGS = -O3 -Wall -pedantic"
  for standard in '' 11 14 17 20 23; do
    echo "CXX$standard = $compiler_cxx"
    echo "CXX${standard}FLAGS = -O3 -Wall -pedantic"
  done
  echo 'FC = gfortran'
  echo 'FFLAGS = -O2'
} > "$R_MAKEVARS_USER"

"$compiler_cc" --version
$compiler_cxx --version
