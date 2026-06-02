#!/usr/bin/env bash
set -ex

export CFLAGS="${CFLAGS} -U__USE_XOPEN2K -std=c99"

./autogen.sh
SWIG_BIN="${BUILD_PREFIX}/bin/swig"

# Cross-compile from x86 build_prefix to arm64 target: build_prefix perl's
# %Config{ccflags,cccdlflags,...} carries x86-only flags (-march=core2,
# -mtune=haswell, -mssse3). SVN's swig-pl rule and Makefile.PL inject those
# flags into the arm64 compile line; clang rejects them. Install a Perl shim
# that filters %Config at FETCH time, and activate it via PERL5OPT before
# configure so the generated Makefile and any later Makefile.PL inherit the
# filtered values.
if [[ "${target_platform}" == "osx-arm64" && "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
    mkdir -p "${SRC_DIR}/perl-shim"
    cat > "${SRC_DIR}/perl-shim/ConfigFilter.pm" <<'EOF'
package ConfigFilter;
require Config;
my $orig = \&Config::FETCH;
{
    no warnings 'redefine';
    *Config::FETCH = sub {
        my $v = $orig->(@_);
        if (defined $v) {
            $v =~ s/\s*-march=\S+//g;
            $v =~ s/\s*-mtune=\S+//g;
            $v =~ s/\s*-mssse3\b//g;
        }
        $v;
    };
}
1;
EOF
    export PERL5LIB="${SRC_DIR}/perl-shim${PERL5LIB:+:${PERL5LIB}}"
    export PERL5OPT="-MConfigFilter${PERL5OPT:+ ${PERL5OPT}}"
fi

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

echo "=== DEBUG perl-bindings layout ==="
echo "target_platform=${target_platform:-unset}"
echo "CONDA_BUILD_CROSS_COMPILATION=${CONDA_BUILD_CROSS_COMPILATION:-unset}"
echo "BUILD_PREFIX=${BUILD_PREFIX}"
echo "PREFIX=${PREFIX}"
echo "BUILD_PREFIX perl -V archname/installsitearch/installsitelib:"
"${BUILD_PREFIX}/bin/perl" -MConfig -e 'for (qw(archname installsitearch installsitelib installarchlib privlib sitelib)) { print "  $_ = $Config{$_}\n" }'
if [ -x "${PREFIX}/bin/perl" ]; then
    echo "PREFIX perl -V archname/installsitearch (may fail on cross):"
    "${PREFIX}/bin/perl" -MConfig -e 'for (qw(archname installsitearch installsitelib)) { print "  $_ = $Config{$_}\n" }' 2>&1 || echo "  (PREFIX perl exec failed)"
fi
echo "Derived SITEARCH=${SITEARCH}"
echo "PREFIX/lib/site_perl tree:"
find "${PREFIX}/lib/site_perl" -maxdepth 6 2>/dev/null | head -40 || echo "  (no site_perl tree)"
echo "All SVN/*.pm anywhere under PREFIX:"
find "${PREFIX}" -path "*/SVN/*.pm" 2>/dev/null | head -40
echo "All *.bundle / *.so for SVN:"
find "${PREFIX}" \( -name "_Client*" -o -name "_Core*" -o -name "_Repos*" \) 2>/dev/null | head -40
echo "=== END DEBUG ==="

# SVN's install-swig-pl writes to ${PREFIX}/lib/site_perl/<ver>/<archname>/
# which is NOT in conda perl's @INC. Move contents into SITEARCH.
# Use the .pm-containing SVN dir (not auto/SVN) to find the arch root, so we
# copy BOTH SVN/*.pm and auto/SVN/_*/_*.so (the prior single-find approach
# picked auto/SVN alphabetically and dropped the .pm files).
SVN_PM=$(find "${PREFIX}/lib/site_perl" -path '*/SVN/Client.pm' 2>/dev/null | head -1)
if [ -n "${SVN_PM}" ]; then
    SRC_ARCH_DIR=$(dirname "$(dirname "${SVN_PM}")")
    mkdir -p "${SITEARCH}"
    cp -a "${SRC_ARCH_DIR}"/* "${SITEARCH}"/
    rm -rf "${PREFIX}/lib/site_perl"
fi

# Verify modules are findable. Skip runtime load when cross-compiling because
# PREFIX perl binary is built for the target arch and cannot exec on the
# build host. The recipe's tests: block re-runs the load on the target.
if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" && -z "${CROSSCOMPILING_EMULATOR:-}" ]]; then
    find "${SITEARCH}" -name "Client.pm" -path "*/SVN/*" || {
        echo "ERROR: SVN::Client.pm not found in ${SITEARCH}"
        exit 1
    }
elif [ -x "${PREFIX}/bin/perl" ]; then
    "${PREFIX}/bin/perl" -e 'use SVN::Client; use SVN::Core; print "SVN::Client OK\n"' || {
        echo "ERROR: SVN::Client not loadable by host perl even after relocation"
        find "${PREFIX}/lib" -name "Client.pm" -path "*/SVN/*" 2>/dev/null
        exit 1
    }
else
    find "${SITEARCH}" -name "Client.pm" -path "*/SVN/*" || {
        echo "ERROR: SVN::Client.pm not found in ${SITEARCH}"
        exit 1
    }
fi

