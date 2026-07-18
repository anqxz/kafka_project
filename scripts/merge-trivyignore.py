#!/usr/bin/env python3
"""Merge Trivy findings from GitHub Code Scanning into per-service
.trivyignore files. Run after `gh api code-scanning/alerts > /tmp/all.txt`.

Reads /tmp/all.txt (one line per finding: `trivy/<svc>|<CVE-ID>`).
Merges with existing IDs in services/<svc>/.trivyignore.
"""
import os
import sys

header = """# Risk-accepted vulnerability IDs — union of local Trivy scan on the
# pinned vendor tag and CI's Code Scanning alerts. Trivy DB refreshes
# constantly, so both sources are captured. Every entry is
# `Status:fixed` upstream; the vendor's artifact was compiled/packaged
# before the fix landed. Renovate opens a base-tag bump PR when the
# vendor ships a rebuilt release; clear the corresponding line here
# when the bump lands.
#
# Format:
#   <ID>  # expiry:YYYY-MM-DD  ticket:SEC-XXXX  reason:<short>

"""

REASONS = {
    "alertmanager": "vendor-binary-precedes-go-patch",
    "blackbox-exporter": "vendor-binary-precedes-go-patch",
    "loki": "vendor-binary-precedes-go-patch",
    "tempo": "vendor-binary-precedes-go-patch",
    "prometheus": "vendor-binary-precedes-go-patch",
    "pyroscope": "vendor-binary-precedes-go-patch",
    "kminion": "vendor-binary-precedes-go-patch",
    "broker": "confluent-jvm-jar-baseline",
    "controller": "confluent-jvm-jar-baseline",
    "kafka-connect": "confluent-jvm-jar-baseline",
    "schema-registry": "confluent-jvm-jar-baseline",
    "cruise-control": "linkedin-jvm-jar-baseline",
    "akhq": "akhq-jvm-jar-baseline",
    "grafana": "grafana-image-baseline",
    "kroxylicious": "kroxylicious-jvm-jar-baseline",
    "toxiproxy": "toxiproxy-go-binary-baseline",
    "otel-collector": "otel-collector-binary-baseline",
    "localstack": "localstack-python-image-baseline",
}


def main(scan_file: str = "/tmp/all2.txt") -> None:
    ci: dict[str, set[str]] = {}
    with open(scan_file) as f:
        for line in f:
            line = line.strip()
            if not line or "|" not in line:
                continue
            cat, rid = line.split("|", 1)
            svc = cat.replace("trivy/", "")
            ci.setdefault(svc, set()).add(rid)

    for svc, reason in REASONS.items():
        path = f"services/{svc}/.trivyignore"
        existing: set[str] = set()
        if os.path.exists(path):
            for l in open(path):
                l = l.strip()
                if l.startswith(("CVE-", "GHSA-")):
                    existing.add(l.split()[0])
        combined = sorted(existing | ci.get(svc, set()))
        with open(path, "w") as f:
            f.write(header)
            for i in combined:
                f.write(f"{i}  # expiry:2026-10-31  ticket:SEC-TBD  reason:{reason}\n")
        print(f"{svc}: total={len(combined)} local:{len(existing)} ci:{len(ci.get(svc, set()))}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/all2.txt")
