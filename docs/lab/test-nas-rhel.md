# Test NAS on RHEL 10 — Basic Guide

**Team:** KCS OpenShift  **Audience:** junior/new platform engineers  **Purpose:** a NAS to test against, not a production NAS

The setup docs ([`docs/README.md`](../README.md)) need a NAS that speaks IPsec with certificates. This guide builds a small one on a RHEL 10 host: an **NFSv4 server that only accepts NFS arriving through IPsec** (libreswan, IKEv2, transport mode, certificate authentication). It sits **outside** the OpenShift cluster, like a real NAS.

| | |
|---|---|
| Tested on | CentOS Stream 10 (libreswan 5.4), the public upstream of RHEL 10, as Lima VMs on 2026-10-02 |
| Not tested on | RHEL itself, a host with firewalld running, or a real OpenShift cluster as the client |
| On RHEL 9 | The same steps were run once on CentOS Stream 9. See [On RHEL 9: what to watch out for](#on-rhel-9-what-to-watch-out-for). |
| Same steps as a script | [`lab/rhel/setup-nas.sh`](../../lab/rhel/setup-nas.sh) |
| Same NAS as a container | [`lab/container/`](../../lab/container/), see [Run it as a container instead](#run-it-as-a-container-instead) |
| A lab to try it on a Mac | [`lima-lab.md`](lima-lab.md) |
| A client behind NAT (CRC) | [One client behind NAT](#one-client-behind-nat) |

> [!NOTE]
> **Why certificates and not a pre-shared key?** Many NFS-over-IPsec examples use `authby=secret` with a pre-shared key. That cannot pair with this project: the NNCP in the setup docs authenticates with a certificate (`leftcert: left_server`, `leftid: '%fromcert'`). The test NAS must do the same, or the tunnel will not come up.

---

## What you need

- [ ] A RHEL 10 host (CentOS Stream 10, AlmaLinux 10 and Rocky 10 use the same packages), and `root` on it.
- [ ] A network where the workers reach this host **directly**, without NAT, on **UDP 500**, **UDP 4500** and **ESP (IP protocol 50)**.
- [ ] Two certificate files in one directory on the host:
  - `ca.pem`: the root CA that signed the workers' certificates.
  - `nas.p12`: this NAS's certificate and private key, **empty password**, friendly name `nas`.
- [ ] firewalld is **not** running. The cloud images used for testing do not install it, and this guide loads its own nftables rules. A host with firewalld active has not been tested.

In real use the enterprise CA issues `nas.p12`. For a lab, [`lab/pki/make-test-pki.sh`](../../lab/pki/make-test-pki.sh) creates a throwaway CA, the NAS certificate and the worker certificates in one go:

```bash
# <out-dir> <nas-fqdn> <worker-fqdn> [<worker-fqdn> ...]
./make-test-pki.sh /tmp/pki nas01.example.com worker-0.ocp.example.com worker-1.ocp.example.com
install -D -m 0644 -t /root/ipsec-pki /tmp/pki/ca.pem /tmp/pki/nas.p12
```

> [!CAUTION]
> The test PKI keeps the CA private key next to the certificates. Never use it outside a lab.

---

## Set up the NAS

Run every block as `root`, in **one** shell, in order. Become root first with `sudo -i`. The blocks share the variables from Step 0, so do not open a new terminal halfway.

After each step, compare what you see with the **Expected** line. If it does not match, stop and fix that step before going on. The libreswan log is the first place to look: `journalctl -u ipsec --no-pager -n 40`.

New to the terms (IPsec, IKEv2, ESP, NSS database, `.p12`)? They are explained in [Words you will see](lima-lab.md#words-you-will-see) in the lab guide.

### Step 0 – Variables

```bash
# ---- CHANGE THIS: the subnet the workers connect from ----
export WORKER_SUBNET="192.168.104.0/24"
# ----------------------------------------------------------
export PKI_DIR="/root/ipsec-pki"      # holds ca.pem and nas.p12
# Only if this host has more than one network interface: the NAS address the workers connect to.
# The default uses the interface that holds the default route.
export NAS_LEFT="%defaultroute"
export EXPORT_DIR="/export"           # the directory to share
```

### Step 1 – Packages

```bash
dnf -y install libreswan nfs-utils nss-tools nftables
```

### Step 2 – Certificates into the libreswan NSS database

These are the same three commands the workers run in the setup docs, with the nickname `nas` instead of `left_server`.

```bash
ipsec checknss
certutil -A -n CA -t 'CT,C,C' -d /var/lib/ipsec/nss -i "${PKI_DIR}/ca.pem"
pk12util -W '' -i "${PKI_DIR}/nas.p12" -d /var/lib/ipsec/nss
certutil -M -n nas -t 'u,u,u' -d /var/lib/ipsec/nss
certutil -L -d /var/lib/ipsec/nss
```

✅ **Expected:** `CA` with trust `CT,C,C` and `nas` with trust `u,u,u`.

### Step 3 – libreswan connection for the workers

The NAS is the `left` side here, and it answers **any** peer that holds a certificate from the same CA. This is the mirror image of the NNCP in the setup docs.

```bash
cat > /etc/ipsec.d/nas-workers.conf <<CONF
# The NAS answers any peer that holds a certificate from our CA.
# Which peers may connect at all is limited by the firewall (worker subnet), not here.
conn workers
    left=${NAS_LEFT}
    leftid=%fromcert
    leftcert=nas
    leftrsasigkey=%cert
    right=%any
    rightid=%fromcert
    rightrsasigkey=%cert
    rightca=%same
    ikev2=insist
    type=transport
    auto=add
CONF

systemctl enable ipsec
systemctl restart ipsec
# pluto loads connections a moment after the service reports ready
for _ in $(seq 1 20); do
  ipsec status | grep -q '"workers":.*%any' && break
  sleep 1
done
ipsec status | grep -E '"workers":.*%any|uniqueids='
```

✅ **Expected:** a line starting `"workers":` that ends in `...%any[%fromcert]`, and `uniqueids=yes`.

> [!IMPORTANT]
> **Option A (one shared certificate) needs one more setting.** Every worker then presents the same identity, and with the default `uniqueids=yes` the NAS keeps only one of their tunnels. Allow duplicate IDs and restart:
>
> ```
> sed -i '/^config setup/a\\tuniqueids=no' /etc/ipsec.conf
> systemctl restart ipsec
> ```
>
> The lab reproduces both the problem and the fix: see [the lab guide](lima-lab.md#8-what-the-lab-showed).

### Step 4 – Firewall: IKE and ESP from the workers, NFS only through IPsec

The last rule is what makes this NAS useful as a test: NFS that arrives **without** IPsec is dropped, so a mount can only succeed through the tunnel.

```bash
cat > /etc/nftables/nas-ipsec-only.nft <<CONF
# NFS (tcp/2049) is accepted only when the packet arrived through IPsec.
table inet nas_ipsec_only
delete table inet nas_ipsec_only
table inet nas_ipsec_only {
    chain input {
        type filter hook input priority filter; policy accept;
        ip saddr ${WORKER_SUBNET} udp dport { 500, 4500 } counter accept comment "ike"
        ip saddr ${WORKER_SUBNET} meta l4proto esp counter accept comment "esp-in"
        ip saddr ${WORKER_SUBNET} tcp dport 2049 meta ipsec exists counter accept comment "nfs-over-ipsec"
        tcp dport 2049 counter drop comment "nfs-cleartext-dropped"
    }
}
CONF
grep -q 'nas-ipsec-only.nft' /etc/sysconfig/nftables.conf \
  || echo 'include "/etc/nftables/nas-ipsec-only.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables
systemctl reload nftables
nft list table inet nas_ipsec_only
```

✅ **Expected:** the table with four rules, all counters at 0.

### Step 5 – NFSv4 server

```bash
mkdir -p "${EXPORT_DIR}"
chmod 0777 "${EXPORT_DIR}"
echo "${EXPORT_DIR} ${WORKER_SUBNET}(rw,sync,no_subtree_check)" > /etc/exports.d/ipsec-nas.exports
# NFSv4 only: one TCP port (2049), no rpcbind and no NFSv3 side protocols
nfsconf --set nfsd vers3 n
systemctl enable --now nfs-server
exportfs -ra
exportfs -v
cat /proc/fs/nfsd/versions
```

✅ **Expected:** `exportfs -v` lists `${EXPORT_DIR}` for the worker subnet, and the versions line reads `-3 +4 +4.1 +4.2`.

> [!NOTE]
> `chmod 0777` and a subnet-wide read-write export are acceptable for a throwaway test share only.

---

## Check it from a client

What to put in the setup docs' variables ([Part 0.3](../00-prepare-the-cluster.md#03-open-a-shell-and-set-variables)) for this NAS:

| Main guide variable | Value |
|---|---|
| `NAS_FQDN` | this host's name, exactly as in the `nas.p12` certificate SAN, resolvable from the workers |
| `NAS_IP` | this host's address on the worker-facing network |

On the NAS, after a worker has connected and mounted the share:

```bash
ipsec trafficstatus                                  # one line per connected worker, with byte counters
nft list table inet nas_ipsec_only | grep counter    # nfs-over-ipsec grows; nfs-cleartext-dropped counts refused packets
```

No cluster yet? [`lab/rhel/setup-worker.sh`](../../lab/rhel/setup-worker.sh) turns a second RHEL host into a stand-in worker that uses the same libreswan keys as the NNCP, and [`lab/rhel/verify-worker.sh`](../../lab/rhel/verify-worker.sh) proves the data went through the tunnel. The [lab guide](lima-lab.md) runs both.

---

## One client behind NAT

If a client reaches the NAS **through NAT**, the transport-mode connection in Step 3 does not work for it: the IKE login succeeds, and then the NAS refuses the tunnel with `TS_UNACCEPTABLE`, because the client proposes its own address while the NAS only sees the NAT's address. This was measured; [`40-lab-crc-and-nas.md`](../40-lab-crc-and-nas.md) has the logs. A CRC cluster on the same Mac as the NAS is such a client.

Tunnel mode works through the same NAT. The script builds it when you name the client's own address:

```
WORKER_SUBNET=192.168.64.0/24 NAS_LEFT=192.168.64.8 NAT_CLIENT=192.168.127.2 ./lab/rhel/setup-nas.sh
```

| Variable | Meaning in this case |
|---|---|
| `WORKER_SUBNET` | Where the IKE packets come **from**, as the NAS sees them: the NAT's network |
| `NAS_LEFT` | The NAS's own IP on that network. Required here. |
| `NAT_CLIENT` | The client's **own** address behind the NAT. NFS then arrives from this address, and only it is allowed. |

Compared with Step 3, the connection gains three lines and the firewall rule and the export name the client's own address:

```text
    leftsubnet=<NAS_LEFT>/32
    rightsubnet=<NAT_CLIENT>/32
    type=tunnel
```

This mode serves one client behind NAT. Several clients behind the same NAT address were not tested.

---

## On RHEL 9: what to watch out for

This guide targets RHEL 10. The same steps were run once on CentOS Stream 9 (libreswan 4.15) on 2026-10-02, before the lab was narrowed to Stream 10. These are the differences that were seen. OpenShift 4.19 nodes are RHEL 9 based, so the client-side rows also describe what a node does.

| | RHEL 10 family (libreswan 5.4), this guide | RHEL 9 family (libreswan 4.15) |
|---|---|---|
| NSS check command (Step 2) | `ipsec checknss` | `ipsec checknss` works here too. That release's `ipsec.service` uses the older spelling `ipsec --checknss`, which RHEL 10 also still accepts. |
| `ikev2=insist` (Step 3) | accepted, logged as replaced by `keyexchange=ikev2` | accepted |
| Host names in `left=` / `right=` on a **client** | did not resolve (`unbound error: initialization failure`) until `dnssec-enable=no` was added under `config setup` | resolved without that setting |
| Two peers with the same certificate identity, `uniqueids=yes` | the two peers keep replacing each other, many times a second | the second peer silently replaces the first, and the first one's NFS hangs |
| `ipsec trafficstatus` output | lines start with `#2: "workers"...` | lines start with `006 #2: "workers"...` |
| Container NAS | pluto loads the kernel IPsec stack itself | start `/usr/libexec/ipsec/_stackmanager start` before pluto, and install `procps-ng` (it calls `pidof`) |

Steps 3, 4 and 5 ran unchanged on both.

---

## Run it as a container instead

[`lab/container/`](../../lab/container/) packages the same five steps as an image. It still needs a Linux host: the container uses the host's kernel for IPsec and for the NFS server.

```bash
# on a Linux host with podman (or CONTAINER_ENGINE=docker), as root, with ca.pem and nas.p12 in /root/ipsec-pki
WORKER_SUBNET=192.168.104.0/24 PKI_DIR=/root/ipsec-pki ./lab/container/run-nas.sh
```

| Setting | Why |
|---|---|
| `--network host` | IKE, ESP and NFS use the host's own address. ESP is an IP protocol, not a port, so it cannot be published like one. |
| `--privileged` | libreswan programs the kernel's IPsec state and the kernel NFS server is started from inside the container. |
| `-v <dir>:/export` | The share must be a real filesystem. The container's own root is overlayfs, which the kernel NFS server refuses. |
| `ALLOW_DUPLICATE_IDS=yes` | Option A only, same meaning as `uniqueids=no` above. |

Because it shares the host's network and kernel, the container changes the **host's** nftables and NFS server state. Use a host you can dedicate to it.

---

## Remove it

```bash
systemctl disable --now nfs-server ipsec
rm -f /etc/exports.d/ipsec-nas.exports /etc/ipsec.d/nas-workers.conf
nft delete table inet nas_ipsec_only
sed -i '/nas-ipsec-only.nft/d' /etc/sysconfig/nftables.conf
rm -f /etc/nftables/nas-ipsec-only.nft
```

The certificates stay in `/var/lib/ipsec/nss`; remove them with `certutil -F -n nas -d /var/lib/ipsec/nss` and `certutil -D -n CA -d /var/lib/ipsec/nss`.
