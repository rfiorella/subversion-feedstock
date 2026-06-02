#!/usr/bin/env bash
set -ex

export CFLAGS="${CFLAGS} -U__USE_XOPEN2K -std=c99"

./autogen.sh
SWIG_BIN="${BUILD_PREFIX}/bin/swig"

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
  --with-swig-perl="${BUILD_PREFIX}/bin/perl" \
  "$@"


# Ensure Perl can find the modules
if [ -d "${PREFIX}/lib/" ]; then
    export PERL5LIB="${PREFIX}/lib:${PERL5LIB:-}"
fi

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
    # Test 61 (rm_missing_with_case_clashing_ondisk_item, SVN issue #4023)
    # fails when building locally via Docker Desktop on macOS because the
    # bind-mounted host filesystem is case-insensitive. Tolerate test
    # failures only in local builds; CI uses native Linux with case-sensitive
    # ext4 where all tests pass.
    if [[ -n "${CI:-}" ]]; then
        make -j ${CPU_COUNT} check CLEANUP=true TESTS=subversion/tests/cmdline/basic_tests.py
    else
        make -j ${CPU_COUNT} check CLEANUP=true TESTS=subversion/tests/cmdline/basic_tests.py || true
    fi
else
    make -j ${CPU_COUNT}
fi
make install

# Build and install Perl SWIG bindings
make swig-pl

# Regenerate native Makefile to use correct install paths
(cd subversion/bindings/swig/perl/native && "${BUILD_PREFIX}/bin/perl" Makefile.PL INSTALLDIRS=site)

make install-swig-pl

# Subversion's install-swig-pl puts perl modules under lib/site_perl/ but
# conda perl's @INC expects them under lib/perl5/. Move them to the right place.
# Note: perl -MConfig returns BUILD_PREFIX paths since perl is in the build env,
# so we substitute BUILD_PREFIX with PREFIX to get the correct target path.
SITEARCH=$("${BUILD_PREFIX}/bin/perl" -MConfig -e 'print $Config{installsitearch}')
SITEARCH="${SITEARCH/${BUILD_PREFIX}/${PREFIX}}"
SVN_PERL_DIR=$(find ${PREFIX}/lib/site_perl -name "SVN" -type d 2>/dev/null | head -1)
if [ -n "${SVN_PERL_DIR}" ]; then
    SVN_PERL_PARENT=$(dirname "${SVN_PERL_DIR}")
    mkdir -p "${SITEARCH}"
    cp -a "${SVN_PERL_PARENT}"/* "${SITEARCH}"/
    # Clean up the incorrect install location
    rm -rf "${PREFIX}/lib/site_perl"
fi

# Verify modules are findable by the host perl
if [ -x "${PREFIX}/bin/perl" ]; then
    "${PREFIX}/bin/perl" -e 'use SVN::Client; use SVN::Core; print "SVN::Client OK\n"' || {
        echo "ERROR: SVN::Client not loadable by host perl even after relocation"
        find "${PREFIX}/lib" -name "Client.pm" -path "*/SVN/*" 2>/dev/null
        exit 1
    }
else
    find "${TARGET_SITEARCH}" -name "Client.pm" -path "*/SVN/*" || {
        echo "ERROR: SVN::Client.pm not found in ${TARGET_SITEARCH}"
        exit 1
    }
fi

