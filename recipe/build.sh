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

# Get Perl's architecture-specific directory
PERL_ARCHLIB=$(perl -MConfig -e 'print $Config{sitearchexp}')
PERL_LIB=$(perl -MConfig -e 'print $Config{sitelibexp}')

echo "=== Perl configuration ==="
echo "PERL_ARCHLIB: ${PERL_ARCHLIB}"
echo "PERL_LIB: ${PERL_LIB}"

# Install Perl bindings with explicit paths
make install-swig-pl-lib \
  INSTALLDIRS=site \
  INSTALLSITEARCH="${PERL_ARCHLIB}" \
  INSTALLSITELIB="${PERL_LIB}"

# Debug: show where modules were installed
echo "=== Installed Perl modules ===" 
find ${PREFIX} -name "Client.pm" -o -name "*svn*.so" 2>/dev/null | head -20
echo "=== Perl @INC paths ==="
perl -e 'print join("\n", @INC), "\n"'

