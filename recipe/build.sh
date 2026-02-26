#!/usr/bin/env bash
set -ex

export CFLAGS="${CFLAGS} -U__USE_XOPEN2K -std=c99"

./autogen.sh
./configure \
  --prefix="${PREFIX}" \
  --enable-svnxx \
  --enable-bdb6 \
  --with-sqlite="${PREFIX}" \
  --disable-static \
  --prefix="${PREFIX}" \
  --with-apr="${PREFIX}" \
  --with-apr-util="${PREFIX}" \
  --with-serf="${PREFIX}" \
  --with-swig \
  --with-swig-perl="${PREFIX}/bin/perl" \
  "$@"


# Ensure Perl can find the modules
if [ -d "${PREFIX}/lib/" ]; then
    export PERL5LIB="${PREFIX}/lib:${PERL5LIB:-}"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
    make -j ${CPU_COUNT} check CLEANUP=true TESTS=subversion/tests/cmdline/basic_tests.py
else
    make -j ${CPU_COUNT}
fi
make install

# Build and install Perl SWIG bindings
make swig-pl
make install-swig-pl

