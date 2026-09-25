# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{12..14} )

inherit python-single-r1 unpacker

# Debian revision: PV 9.4 is deb 9.4-0, PV 9.4_p1 is deb 9.4-1.
if [[ ${PV} == *_p* ]]; then
	MY_PV=${PV/_p/-}
else
	MY_PV=${PV}-0
fi

DESCRIPTION="TA Triumph-Adler/UTAX CUPS filters and PPDs, as packaged by Uni Hamburg"
HOMEPAGE="https://www.rrz.uni-hamburg.de/services/drucken.html"
SRC_URI="https://apt-mirror.rrz.uni-hamburg.de/uhh-qpilot/ubuntu/pool/multiverse/amd64/${PN}-${MY_PV}-amd64.deb"
S="${WORKDIR}"

LICENSE="Kyocera-EULA BSD"
SLOT="0"
KEYWORDS="-* ~amd64"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"
RESTRICT="bindist mirror strip"

RDEPEND="
	${PYTHON_DEPS}
	net-print/cups
	net-print/cups-filters
	sys-apps/dbus
	sys-libs/zlib
	$(python_gen_cond_dep '
		dev-python/packaging[${PYTHON_USEDEP}]
		dev-python/reportlab[${PYTHON_USEDEP}]
	')
"

QA_PREBUILT="usr/libexec/cups/filter/kyofilter_*"

TA_DATA="/usr/share/kyocera${PV%%_*}"
PYPDF_DIR="/usr/share/${PN}/python"

src_prepare() {
	default

	# PPDs expect filters under /usr/lib, Gentoo uses /usr/libexec.
	sed -i 's|/usr/lib/cups/filter/|/usr/libexec/cups/filter/|g' \
		"${S}${TA_DATA}"/ppd*/*.ppd || die

	# The pre-filter imports the bundled PyPDF3 and uses pkg_resources,
	# which setuptools is removing.
	sed -i \
		-e "1a import sys; sys.path.insert(0, \"${EPREFIX}${PYPDF_DIR}\")" \
		-e 's|^import pkg_resources$|from packaging.version import parse as parse_version|' \
		-e 's|pkg_resources\.parse_version|parse_version|g' \
		-e 's|/usr/share/fonts/truetype|/usr/share/fonts|' \
		usr/lib/cups/filter/kyofilter_pre_H || die
	grep -q pkg_resources usr/lib/cups/filter/kyofilter_pre_H \
		&& die "pkg_resources still used by kyofilter_pre_H"

	# Invalid escape, a SyntaxWarning on current Python.
	sed -i 's|b_("\\c")|b_("\\\\c")|' \
		"${S}${TA_DATA}"/Python/PyPDF3-*/PyPDF3/generic.py || die
}

src_install() {
	exeinto /usr/libexec/cups/filter
	doexe usr/lib/cups/filter/kyofilter_*
	python_fix_shebang "${ED}"/usr/libexec/cups/filter/kyofilter_pre_H

	insinto /usr/share/cups/model/TA_UTAX
	doins "${S}${TA_DATA}"/ppd*/*.ppd

	python_moduleinto "${PYPDF_DIR}"
	python_domodule "${S}${TA_DATA}"/Python/PyPDF3-*/PyPDF3

	# The filters read per-user settings from /usr/share/kyocera/<user>/.
	# Upstream writes them with ta_utax_dialog, which needs Qt5 and is not installed.
	keepdir /usr/share/kyocera
}

pkg_postinst() {
	elog "The PPDs are in ${EROOT}/usr/share/cups/model/TA_UTAX."
	elog "The settings GUI (ta_utax_dialog) and the aqrated tray daemon need Qt5"
	elog "and are left out; printing does not depend on them."
}
