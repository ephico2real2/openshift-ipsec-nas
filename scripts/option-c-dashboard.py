#!/usr/bin/env python3
"""Derives Option C's Grafana dashboard from Option B's, so the two stay one dashboard.

    python3 scripts/option-c-dashboard.py < charts/ipsec-nas/files/ipsec-nas.json \
      > charts/ipsec-nas-option-c-metrics/files/ipsec-nas-option-c.json

The panels and queries are Option B's, unchanged: both charts run the same collector (shared/collector/).
Only what names Option B changes: the uid and title (both can sit in one central Grafana), and the reporting
pod, ipsec-nas-metrics instead of ipsec-cert-sync. scripts/perses-dashboard.sh runs this; the chart test
checks the committed file is current.
"""
import json
import sys

B_POD, C_POD = "ipsec-cert-sync", "ipsec-nas-metrics"

d = json.load(sys.stdin)
if d.get("uid") != "ipsec-nas":
    sys.exit(f"option-c-dashboard: expected Option B's dashboard (uid ipsec-nas), got uid {d.get('uid')!r}")
d["uid"] = "ipsec-nas-option-c"
d["title"] = "IPsec to the NAS (Option C)"

text = json.dumps(d, indent=2)
if B_POD not in text:
    sys.exit(f"option-c-dashboard: no {B_POD!r} left to rename; update this script with the dashboard")
text = text.replace(B_POD, C_POD)
sys.stdout.write(text + "\n")
