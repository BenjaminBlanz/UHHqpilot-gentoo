# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{12..15} )

inherit desktop java-pkg-2 python-single-r1 systemd unpacker

# Debian revision: PV 5.2.0.26431_p1 is deb 5.2.0.26431-1.
MY_PV=${PV/_p/-}

DESCRIPTION="Q Pilot client for Uni Hamburg follow-me printing (FollowMe/CopyCard)"
HOMEPAGE="https://www.rrz.uni-hamburg.de/services/drucken.html"
SRC_URI="https://apt-mirror.rrz.uni-hamburg.de/uhh-qpilot/ubuntu/pool/multiverse/amd64/qpilot-${MY_PV}-amd64.deb"
S="${WORKDIR}"

LICENSE="all-rights-reserved"
SLOT="0"
KEYWORDS="-* ~amd64"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"
RESTRICT="bindist mirror strip"

RDEPEND="
	${PYTHON_DEPS}
	acct-user/qpilot
	|| ( >=sys-apps/openrc-0.45 sys-apps/systemd )
	>=virtual/jre-17:*
	net-print/cups
	net-print/ta-utax-dialog
	$(python_gen_cond_dep 'dev-python/pyqt6[dbus,gui,widgets,${PYTHON_USEDEP}]')
"
DEPEND=">=virtual/jdk-17:*"
BDEPEND="app-arch/unzip"

QP_HOME="/opt/qpilot-client"

# Queues the UHH profile defines, as <name>.ppd under here.
QP_PPD_DIR="/usr/share/qpilot-client/ppd"

pkg_setup() {
	java-pkg-2_pkg_setup
	python-single-r1_pkg_setup
}

src_compile() {
	# Shows the GUI's AWT tray icon as a StatusNotifierItem via qpilot-tray.
	mkdir classes || die
	ejavac -d classes "${FILESDIR}"/QPilotTrayBridge.java
	"$(java-config -j)" cf qpilot-tray-bridge.jar -C classes . || die
}

src_install() {
	local qp="${S}/tmp/qp52"
	local run=( "${qp}"/QPilot-Client-*-Setup-*.run )
	[[ -f ${run[0]} ]] || die "vendor installer not found in ${qp}"
	chmod +x "${run[0]}" || die

	# The vendor installer needs root, runs systemctl, moves the GUI desktop
	# file to /etc/xdg/autostart and adds the queues with lpadmin (from its
	# own PATH). Stub systemctl, point lpadmin at a dead CUPS socket and
	# deny the autostart move; the queues are set up in pkg_config.
	mkdir -p "${T}"/stub || die
	printf '#!/bin/sh\nexit 0\n' > "${T}"/stub/systemctl || die
	chmod +x "${T}"/stub/systemctl || die
	addpredict /etc/xdg/autostart
	pushd "${qp}" >/dev/null || die
	CUPS_SERVER="${T}/no-cups.sock" PATH="${T}/stub:${PATH}" TMPDIR="${T}" HOME="${T}" \
		"${run[0]}" --mode unattended --installer-language de \
		--prefix "${ED}${QP_HOME}" \
		|| ewarn "vendor installer reported errors (expected: autostart and lpadmin)"
	popd >/dev/null || die

	local d="${ED}${QP_HOME}"
	[[ -f ${d}/Service/libs/qpilot-client-service-exe.jar && -f ${d}/GUI/libs/qpilot-client-gui-exe.jar ]] \
		|| die "vendor installer did not produce the expected tree"
	grep -q '^qpilot.host=' "${d}"/Service/service-config.txt \
		|| die "UHH server profile was not applied"
	[[ -f ${d}/GUI/qpilot-client-gui.desktop ]] \
		|| die "installer moved its desktop file out of the image; delete /etc/xdg/autostart/qpilot-client-gui.desktop"

	# Bundled 2022 JRE, uninstaller and launchers with the image path baked in.
	rm -r "${d}"/Java "${d}"/uninstall "${d}"/uninstall.dat \
		"${d}"/GUI/*.desktop "${d}"/GUI/gui-launcher.sh "${d}"/GUI/qpilot_client_joblist \
		"${d}"/GUI/QPilot-Client-GUI.ini \
		"${d}"/Service/qpilot-client.service "${d}"/Service/qpilot-client-service.sh || die
	find "${d}" -type d -exec chmod 0755 {} + || die
	find "${d}" -type f -exec chmod 0644 {} + || die

	local f
	for f in qpilot-client-service qpilot-client-gui; do
		sed -e "s|@QP_HOME@|${EPREFIX}${QP_HOME}|" -e "s|@JAVA@|${EPREFIX}/usr/bin/java|" \
			-e "s|@BRIDGE_JAR@|${EPREFIX}/usr/share/${PN}/lib/qpilot-tray-bridge.jar|" \
			"${FILESDIR}/${f}" > "${T}/${f}" || die
	done
	exeinto /usr/libexec/qpilot-client
	doexe "${T}"/qpilot-client-service "${FILESDIR}"/qpilot-tray
	python_fix_shebang "${ED}"/usr/libexec/qpilot-client/qpilot-tray
	dobin "${T}"/qpilot-client-gui
	java-pkg_dojar qpilot-tray-bridge.jar

	newinitd "${FILESDIR}"/qpilot-client.initd qpilot-client
	systemd_dounit "${FILESDIR}"/qpilot-client.service

	newicon "${d}"/GUI/qpilot-logo.png qpilot-client.png
	domenu "${FILESDIR}"/qpilot-client-gui.desktop "${FILESDIR}"/qpilot-client-joblist.desktop
	# The GUI asks for the UHH login when a job is printed, so it autostarts.
	insinto /etc/xdg/autostart
	doins "${FILESDIR}"/qpilot-client-gui.desktop

	# Queue definitions from the UHH profile: driver.install lists the zips,
	# each names its queue and PPD.
	local profile=( "${qp}"/*.qpilot-profile )
	local drv zip queue ppd
	for drv in $(sed -n 's/^driver\.install=//p' "${profile[0]}" | tr -d '\r'); do
		zip=$(sed -n "s/^driver\.${drv}=//p" "${profile[0]}" | tr -d '\r')
		mkdir "${T}/${drv}" || die
		unzip -q -d "${T}/${drv}" "${qp}/${zip}" || die
		queue=$(sed -n 's/^queueName=//p' "${T}/${drv}"/driver.qpilot-profile | tr -d '\r[:space:]')
		ppd=$(sed -n 's/^driverSource=//p' "${T}/${drv}"/driver.qpilot-profile | tr -d '\r')
		[[ -n ${queue} && -f ${T}/${drv}/${ppd} ]] || die "bad driver profile in ${zip}"
		sed 's|/usr/lib/cups/filter/|/usr/libexec/cups/filter/|g' \
			"${T}/${drv}/${ppd}" > "${T}/${queue}.ppd" || die
		insinto "${QP_PPD_DIR}"
		doins "${T}/${queue}.ppd"
	done
}

# Adds or updates the UHH queues. Jobs go by LPD to the local service,
# which passes them to the Q Pilot server for release at the printer.
qpilot_setup_queues() {
	local ppd queue
	for ppd in "${EROOT}${QP_PPD_DIR}"/*.ppd; do
		queue=${ppd##*/}
		queue=${queue%.ppd}
		einfo "Setting up print queue ${queue}"
		lpadmin -p "${queue}" -o printer-is-shared=false -o job-sheets-default=none,none \
			-P "${ppd}" -v "lpd://127.0.0.1/${queue}" -E \
			|| { eerror "lpadmin failed for ${queue}; is cupsd running?"; return 1; }
	done
}

pkg_config() {
	qpilot_setup_queues
}

pkg_postinst() {
	qpilot_setup_queues || ewarn "Queues not set up; start cupsd and run: emerge --config ${CATEGORY}/${PN}"

	if [[ -z ${REPLACING_VERSIONS} ]]; then
		elog "Start the service:"
		elog "  OpenRC:  rc-update add qpilot-client default && rc-service qpilot-client start"
		elog "  systemd: systemctl enable --now qpilot-client"
		elog "Then start 'Q Pilot-Client' (autostarts at login) and log in with your UHH ID."
		elog "Print to UHHPrinter_SW or UHHPrinter_Farbe and release the job at a"
		elog "printer with your registered CopyCard."
	fi
}

pkg_prerm() {
	[[ -n ${REPLACED_BY_VERSION} ]] && return
	local ppd queue
	for ppd in "${EROOT}${QP_PPD_DIR}"/*.ppd; do
		queue=${ppd##*/}
		lpadmin -x "${queue%.ppd}" 2>/dev/null && einfo "Removed print queue ${queue%.ppd}"
	done
}
