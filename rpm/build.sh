#!/usr/bin/env bash
# Construit le tarball source et le RPM de kelescope.
# Prérequis : elixir, erlang, rpmbuild, accès réseau (hex.pm, GitHub).
set -euo pipefail
ORIG_DIR="$(pwd)"
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'version:' mix.exs | sed -E 's/.*version: *"([^"]+)".*/\1/')
TOPDIR="$(pwd)/rpm/build"

rm -rf "$TOPDIR"
mkdir -p "$TOPDIR"/{SOURCES,RPMS,SRPMS,BUILD,BUILDROOT}

tar --transform "s,^,kelescope-${VERSION}/," \
    --exclude=.git --exclude=_build --exclude=deps --exclude=cover \
    --exclude=rpm/build --exclude=assets/node_modules \
    -czf "$TOPDIR/SOURCES/kelescope-${VERSION}.tar.gz" .

rpmbuild \
    --define "_topdir ${TOPDIR}" \
    --define "_sourcedir ${TOPDIR}/SOURCES" \
    --define "_specdir ${TOPDIR}/SPECS" \
    --define "_builddir ${TOPDIR}/BUILD" \
    --define "_buildrootdir ${TOPDIR}/BUILDROOT" \
    --define "_srcrpmdir ${TOPDIR}/SRPMS" \
    --define "_rpmdir ${TOPDIR}/RPMS" \
    -bb rpm/kelescope.spec

mv "${TOPDIR}"/RPMS/*/*.rpm "${ORIG_DIR}/"
rm -rf "$TOPDIR"

echo "RPM(s) produit(s) dans ${ORIG_DIR}"
