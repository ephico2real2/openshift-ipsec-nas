#!/bin/bash
# CRC ONLY. Puts libreswan on the CRC node as a systemd system extension (sysext), because CRC
# cannot install the OpenShift "ipsec" OS extension (docs/crc-integration-guide.md, Step D.4).
# The files come from OpenShift's own extensions image; rpm-ostree is not involved, so the
# packages the CRC image already layers are left alone. Runs on the Mac, logged in as cluster-admin.
#
#   ipsec-sysext.sh fetch      copy the RPMs out of the extensions image, work out which are needed, unpack
#   ipsec-sysext.sh stage      build /var/lib/extensions/ipsec and install libreswan's /etc files (nothing active)
#   ipsec-sysext.sh activate   merge the extension into /usr and start ipsec.service (not persistent)
#   ipsec-sysext.sh persist    make it survive a reboot: merge at boot, then start ipsec.service
#   ipsec-sysext.sh status     show what is merged and whether libreswan answers
#   ipsec-sysext.sh remove     stop ipsec, unmerge, and delete everything stage and activate created
#
# Until "persist" has been run, a reboot of the node also undoes the merge.
# No sudo on the Mac: everything runs through "oc debug node".
# A production cluster never needs this: there, ipsecConfig.mode External installs libreswan.
set -euo pipefail

NODE="${NODE:-crc}"
WORK=/var/tmp/ipsec-sysext
EXT=/var/lib/extensions/ipsec

on_node() { oc debug "node/${NODE}" -q -- chroot /host bash -c "$1"; }

fetch() {
  local image
  image="$(oc get cm -n openshift-machine-config-operator machine-config-osimageurl \
    -o jsonpath='{.data.baseOSExtensionsContainerImage}')"
  [[ -n "${image}" ]] || { echo "no extensions image in machine-config-osimageurl"; exit 1; }
  echo "extensions image: ${image}"
  on_node "
set -euo pipefail
W=${WORK}
mkdir -p \"\$W/repo\"
ctr=\"\$(podman create --authfile /var/lib/kubelet/config.json '${image}' /bin/true 2>/dev/null)\"
podman cp \"\$ctr:/usr/share/rpm-ostree/extensions/.\" \"\$W/repo/\"
podman rm \"\$ctr\" >/dev/null
echo \"rpms in the extensions image: \$(ls \"\$W/repo\"/*.rpm | wc -l)\"
"
  # Which of those RPMs do libreswan and NetworkManager-libreswan need that the node lacks?
  on_node '
set -uo pipefail
cd '"${WORK}"'/repo
: > ../provides.idx
for f in *.rpm; do
  rpm -qp --provides "$f" 2>/dev/null | awk -v f="$f" "{print \$1 \"\t\" f}" >> ../provides.idx
  rpm -qpl "$f" 2>/dev/null | awk -v f="$f" "{print \$1 \"\t\" f}" >> ../provides.idx
done
todo="$(ls libreswan-[0-9]*.rpm NetworkManager-libreswan-[0-9]*.rpm | tr "\n" " ")"
done_list=""
unresolved=""
while [ -n "$todo" ]; do
  set -- $todo; cur="$1"; shift; todo="$*"
  case " $done_list " in *" $cur "*) continue;; esac
  done_list="$done_list $cur"
  while read -r cap rest; do
    case "$cap" in rpmlib\(*|config\(*) continue;; esac
    rpm -q --whatprovides "$cap" >/dev/null 2>&1 && continue
    prov="$(awk -F"\t" -v c="$cap" "\$1==c {print \$2; exit}" ../provides.idx)"
    if [ -z "$prov" ]; then unresolved="$unresolved\n$cur needs $cap $rest"; continue; fi
    case " $done_list $todo " in *" $prov "*) ;; *) todo="$todo $prov";; esac
  done < <(rpm -qpR "$cur" 2>/dev/null)
done
echo "== rpms needed that the node does not have"
printf "%s\n" $done_list | sort | tee ../closure.txt
if [ -n "$unresolved" ]; then echo "== unresolved"; printf "%b\n" "$unresolved" | sort -u; exit 1; fi
'
  on_node '
set -euo pipefail
W='"${WORK}"'
rm -rf "$W/root" && mkdir -p "$W/root" && cd "$W/root"
while read -r f; do rpm2cpio "$W/repo/$f" | cpio -idm --quiet; done < "$W/closure.txt"
echo "== outside usr/"; find . -path ./usr -prune -o \( -type f -o -type l \) -print | sort
n=0; while read -r p; do [ -e "/$p" ] && { echo "already on the node: /$p"; n=$((n+1)); }; done < <(find usr \( -type f -o -type l \) | sort)
echo "files that already exist on the node: $n"
[ "$n" -eq 0 ]
'
}

stage() {
  on_node '
set -euo pipefail
W='"${WORK}"'
E='"${EXT}"'
[ -d "$W/root/usr" ] || { echo "run fetch first"; exit 1; }
[ ! -e "$E" ] || { echo "$E already exists; run remove first"; exit 1; }

echo "== 1. the extension directory: only usr/ goes in"
mkdir -p "$E"
cp -a "$W/root/usr" "$E/usr"
mkdir -p "$E/usr/lib/extension-release.d"
# must match the node, so an OS update refuses RPMs built for the old release
( . /etc/os-release; printf "ID=%s\nVERSION_ID=%s\n" "$ID" "$VERSION_ID" ) > "$E/usr/lib/extension-release.d/extension-release.ipsec"
cat "$E/usr/lib/extension-release.d/extension-release.ipsec"

echo "== 2. SELinux labels, as if the directory were /"
setfiles -r "$E" /etc/selinux/targeted/contexts/files/file_contexts "$E/usr"
ls -Zd "$E/usr" "$E/usr/sbin/ipsec" "$E/usr/libexec/ipsec/pluto" "$E/usr/libexec/nm-libreswan-service" "$E/usr/lib/systemd/system/ipsec.service" "$E/usr/bin/certutil"

echo "== 3. configuration files into the real /etc (never overwriting; the list is kept for remove)"
cd "$W/root"
: > "$W/etc-installed.txt"
find etc \( -type f -o -type l \) | sort | while read -r p; do
  mkdir -p "/$(dirname "$p")"
  if [ -e "/$p" ]; then echo "kept existing /$p"; else cp -a "$p" "/$p"; echo "/$p" >> "$W/etc-installed.txt"; echo "installed /$p"; fi
done
xargs -r restorecon -F < "$W/etc-installed.txt"
xargs -r ls -Z < "$W/etc-installed.txt"

echo "== nothing is active yet"
systemd-sysext status
'
}

activate() {
  on_node '
set -euo pipefail
echo "== 1. merge the extension into /usr"
systemctl start systemd-sysext.service
systemd-sysext status
ipsec --version

echo "== 2. what the RPM scriptlets would have done"
systemd-tmpfiles --create /usr/lib/tmpfiles.d/libreswan.conf
/usr/lib/systemd/systemd-sysctl 50-libreswan.conf
systemctl daemon-reload
systemctl reload dbus-broker.service 2>/dev/null || systemctl reload dbus.service

echo "== 3. start libreswan (a reboot undoes all of this until persist is run)"
systemctl start ipsec.service
systemctl is-active ipsec.service
ipsec status | sed -n "1,5p"
certutil -L -d /var/lib/ipsec/nss
'
}

persist() {
  on_node '
set -euo pipefail
U=/etc/systemd/system/ipsec-sysext-start.service
# systemd reads its unit files before the extension is merged, so at boot it does not know
# ipsec.service yet. This unit reloads systemd after the merge and then starts libreswan.
cat > "$U" <<UNIT
[Unit]
Description=Start libreswan from the ipsec system extension (CRC only)
After=systemd-sysext.service network-online.target ipsec-import.service
Wants=network-online.target
ConditionPathExists='"${EXT}"'

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl daemon-reload
ExecStart=/usr/bin/systemd-tmpfiles --create /usr/lib/tmpfiles.d/libreswan.conf
ExecStart=/usr/lib/systemd/systemd-sysctl 50-libreswan.conf
ExecStart=/usr/bin/systemctl start --no-block ipsec.service

[Install]
WantedBy=multi-user.target
UNIT
restorecon -F "$U"
ls -Z "$U"
systemctl daemon-reload
systemctl enable systemd-sysext.service ipsec-sysext-start.service
systemctl is-enabled systemd-sysext.service ipsec-sysext-start.service
'
}

status() {
  on_node '
systemd-sysext status
echo "ipsec.service: $(systemctl is-active ipsec.service 2>&1)"
command -v ipsec >/dev/null && ipsec --version
ls -Z /usr/libexec/ipsec/pluto 2>&1
ausearch -m avc -ts recent 2>/dev/null | grep -i -E "pluto|ipsec|libreswan" | tail -5 || true
'
}

remove() {
  on_node '
set -uo pipefail
W='"${WORK}"'
E='"${EXT}"'
systemctl stop ipsec.service 2>/dev/null
systemctl disable systemd-sysext.service ipsec-sysext-start.service 2>/dev/null
rm -f /etc/systemd/system/ipsec-sysext-start.service
systemctl stop systemd-sysext.service
rm -rf "$E"
rmdir /var/lib/extensions 2>/dev/null
[ -f "$W/etc-installed.txt" ] && xargs -r rm -f < "$W/etc-installed.txt"
rmdir /etc/ipsec.d/policies /etc/ipsec.d /etc/pki/nssdb 2>/dev/null
rm -rf /var/lib/ipsec /run/pluto
systemctl daemon-reload
systemd-sysext status
command -v ipsec >/dev/null && echo "ipsec is still on the PATH" || echo "libreswan is gone from the node"
'
}

case "${1:-}" in
  fetch|stage|activate|persist|status|remove) "$1" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
