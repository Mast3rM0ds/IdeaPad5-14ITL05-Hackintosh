#!/usr/bin/env python3
"""Makes a Linux Hardware Sniffer report pass 1401's report check, then runs that check.

On Linux, Hardware Sniffer reads ACPI paths from sysfs, which also lists devices outside \\_SB (\\AOD_, \\HPET, ...).
The Windows backend never reports those, and 1401's validator only accepts \\_SB paths, so they are dropped: an
"ACPI Path" is optional for every device, and 1401 only uses \\_SB ones.

    fix_report.py <1401 checkout> <Report.json>
"""
import json
import os
import re
import sys

ACPI = re.compile(r"^[\\]?_SB(\.[A-Z0-9_]+)+$")


def clean(node, where, dropped):
    if isinstance(node, dict):
        path = node.get("ACPI Path")
        if isinstance(path, str) and not ACPI.match(path):
            del node["ACPI Path"]
            dropped.append(f"{where}: {path}")
        for k, v in node.items():
            clean(v, f"{where}.{k}" if where else k, dropped)


def main():
    src, report = sys.argv[1], sys.argv[2]
    with open(report) as fh:
        data = json.load(fh)
    dropped = []
    clean(data, "", dropped)
    if dropped:
        with open(report, "w") as fh:
            json.dump(data, fh, indent=4)
        print(f"dropped {len(dropped)} ACPI path(s) outside \\_SB (Linux-only, unused by 1401): "
              + ", ".join(d.rsplit(": ", 1)[1] for d in dropped))
    # 1401's own check, the one the build runs first
    sys.path.insert(0, os.path.join(src, "upstream", "OpCore-Simplify"))
    from Scripts.report_validator import ReportValidator  # noqa: E402
    v = ReportValidator()
    v.validate_report(report)
    if v.errors:
        print("STOP the report still fails 1401's check:\n  " + "\n  ".join(v.errors))
        sys.exit(1)
    print("OK the report passes 1401's check")
    for n, g in (data.get("GPU") or {}).items():
        print(f"GPU:   {n}: {g.get('Manufacturer')} / {g.get('Device Type')} / {g.get('Device ID')}")


if __name__ == "__main__":
    main()
