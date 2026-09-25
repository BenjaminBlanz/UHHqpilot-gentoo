> **This repository has moved to the RRZ GitLab:**
> https://gitlab-ce.rrz.uni-hamburg.de/baj2533/uhh-qpilot-gentoo
>
> It is archived here and no longer updated. Switch your overlay with
>
> ```sh
> eselect repository remove -f uhh-qpilot
> eselect repository add uhh-qpilot git https://gitlab-ce.rrz.uni-hamburg.de/baj2533/uhh-qpilot-gentoo.git
> emerge --sync uhh-qpilot
> ```

# UHH Q Pilot for Gentoo

A Portage overlay for printing at Universität Hamburg with the **Q Pilot client**
(follow-me printing: print from your computer, release the job at any TA 5007ci/4007ci
with your CopyCard). The RRZ only supports Ubuntu; this overlay repackages the Ubuntu
packages from the RRZ APT repository for Gentoo, and follows new RRZ releases
automatically.

| Package | What it is |
|---|---|
| `net-print/qpilot-client` | Q Pilot client service and tray GUI; sets up the `UHHPrinter_SW`, `UHHPrinter_Farbe`, `DirectPrinter_SW` and `DirectPrinter_Farbe` queues |
| `net-print/ta-utax-dialog` | TA Triumph-Adler/UTAX CUPS filters and PPDs the queues use |
| `acct-user/qpilot`, `acct-group/qpilot` | User the client service runs as |

Nothing from the vendor is stored in this repository; the ebuilds download the `.deb`s
from `apt-mirror.rrz.uni-hamburg.de`.

## Install

1. Add the overlay, `/etc/portage/repos.conf/uhh-qpilot.conf`:

   ```ini
   [uhh-qpilot]
   location = /var/db/repos/uhh-qpilot
   sync-type = git
   sync-uri = https://github.com/BenjaminBlanz/UHHqpilot-gentoo.git
   ```

   then `emerge --sync uhh-qpilot`.

2. Accept keywords and licenses (the vendor software is proprietary):

   ```sh
   echo '*/*::uhh-qpilot ~amd64' > /etc/portage/package.accept_keywords/uhh-qpilot
   printf '%s\n' 'net-print/qpilot-client all-rights-reserved' \
       'net-print/ta-utax-dialog Kyocera-EULA' > /etc/portage/package.license/uhh-qpilot
   ```

3. Install, with cupsd running (the queues are created at install time):

   ```sh
   emerge -a net-print/qpilot-client
   ```

   If cupsd was not running, start it and run `emerge --config net-print/qpilot-client`.

4. Start the service:

   ```sh
   rc-update add qpilot-client default && rc-service qpilot-client start   # OpenRC
   systemctl enable --now qpilot-client                                   # systemd
   ```

5. Start **Q Pilot-Client** from the menu (it also autostarts at login). It runs as a tray
   icon: left click opens the print job list, right click shows the menu (user, server,
   *Anmeldedaten ändern*, *Druckjobliste*). It asks for your UHH ID (`bxx1234`) and password
   when you first print.

6. If your CopyCard is not registered yet: put it on the terminal on the right side of a
   5007ci/4007ci and log in there with your UHH ID. RRZ guide: *CopyCard registrieren*
   on the [RRZ printing page](https://www.rrz.uni-hamburg.de/services/drucken.html).

## Printing

Print to `UHHPrinter_SW` (black and white) or `UHHPrinter_Farbe` (colour), then release
the job at any follow-me printer with your CopyCard. *Q Pilot job list* in the menu shows
waiting jobs. The `DirectPrinter_*` queues (TA P-C3562i MFP driver) are for direct
printing; per the RRZ guide they can be deleted with `lpadmin -x` if you do not use them.

The client needs to reach the Q Pilot servers (`ps-s-qp01.ad.uni-hamburg.de`), so outside
the university network connect to the UHH VPN first. The same holds for `emerge`: the
packages are downloaded from the RRZ mirror, which only answers inside the UHH network.

## Updates

The RRZ mirror only answers inside the UHH network (or VPN), so version bumps run on a
machine there rather than on GitHub. [`scripts/bump-and-push`](scripts/bump-and-push) runs
daily: it reads the mirror's package index with [`scripts/bump.py`](scripts/bump.py), adds
the ebuild and Manifest entry for any new version (checking the download against the
index's SHA256), and pushes. It works in its own clone
(`~/.local/share/uhh-qpilot-bump`), exits silently when the mirror is unreachable, and
logs failures to `~/.local/state/uhh-qpilot-bump.log`. Set up as root, for the user whose
SSH key can push:

```sh
printf '#!/bin/sh\nexec runuser -u benjamin -- /home/benjamin/software/UHH/qpilot/scripts/bump-and-push\n' \
    > /etc/cron.daily/uhh-qpilot-bump
chmod 755 /etc/cron.daily/uhh-qpilot-bump
```

New RRZ releases then arrive with the normal

```sh
emerge --sync && emerge -uDN @world
```

If a release changes the package layout, the build fails rather than installing something
half-working; the ebuild then needs fixing by hand.

## How it differs from the Ubuntu install

- **Java:** the client runs on the system Java (`>=virtual/jre-17`), not the Java 17.0.3
  bundled by the vendor (from 2022, unpatched).
- **State:** the service keeps its config (with its client ID), spooled jobs and logs in
  `/var/lib/qpilot-client`. The GUI keeps its config in `~/.local/state/qpilot-client`.
  `/opt/qpilot-client` stays read-only.
- **Filters:** in `/usr/libexec/cups/filter` (Gentoo's CUPS path); the PPDs are adjusted
  to match. The Python watermark pre-filter uses Gentoo's reportlab and the bundled
  PyPDF3.
- **Tray icon:** the vendor GUI uses a Java AWT (XEmbed) tray icon, whose menu does not
  open on Plasma under Wayland. The GUI runs inside a small launcher (`QPilotTrayBridge`)
  that shows the same icon and menu as a native StatusNotifierItem through a PyQt6 helper,
  and passes clicks back to the GUI. Without a StatusNotifierItem host it keeps the AWT
  icon. The GUI's tray balloon messages are not shown.
- **Left out:** `ta_utax_dialog` (printer settings GUI) and `aqrated` (tray daemon) need
  Qt5, which Gentoo no longer has. Printing does not need them; set the print options in
  the print dialog instead.
- **Service user:** the service runs as user `qpilot` rather than root. The Q Pilot server
  tells it to take LPD jobs on port 515, so it gets `CAP_NET_BIND_SERVICE` and nothing else
  (OpenRC ≥ 0.45 `capabilities`, or systemd `AmbientCapabilities`).

## Notes on the RRZ Ubuntu guide

The APT line in *Q Pilot-Client silent installieren* (RRZ, 27.07.2026) has three errors.
The repository is at `…/uhh-qpilot/ubuntu/`, its component is `multiverse`, not `main`,
and the keyring path in the `signed-by` option has a stray space. A working line is:

```
deb [signed-by=/usr/share/keyrings/uhh-qpilot-repo-keyring.asc] https://apt-mirror.rrz.uni-hamburg.de/uhh-qpilot/ubuntu noble multiverse
```

## License

The ebuilds and scripts are GPL-2, as in ::gentoo. The software they install belongs to
Schomäcker GmbH (Q Pilot) and KYOCERA Document Solutions (TA/UTAX driver), under their
licenses.
