#!/usr/bin/env python3
"""Add the Surface Pro 12 packages to an omarchy-iso checkout's build-iso.sh.

Every edit is anchored on exact upstream text and asserted to match once, so a
changed upstream fails here instead of producing an ISO without the fixes.
    apply-sp12.py <omarchy-iso checkout>
"""
import sys
from pathlib import Path

path = Path(sys.argv[1]) / "builder" / "build-iso.sh"
s = path.read_text()

if "sp12-build-packages.sh" in s:
    sys.exit(f"{path}: already patched")


def insert(anchor: str, text: str, before: bool = False) -> None:
    global s
    n = s.count(anchor)
    if n != 1:
        sys.exit(f"{path}: anchor found {n} times, expected 1:\n{anchor}")
    s = s.replace(anchor, text + anchor if before else anchor + text)


# 1. Our packages' dependencies must be in the offline mirror.
insert(
    "mkdir -p /tmp/offlinedb\n",
    """# sp12: dependencies of the Surface Pro 12 packages built below.
all_packages+=(dkms git patch python bluez bluez-utils)

""",
    before=True,
)

# 2. The installer installs everything in the shipped base list on the target.
insert(
    'cp "${base_pkg_lists[1]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-other.packages"\n',
    """
# sp12: install the Surface Pro 12 packages on the target.
printf '%s\\n' sp12-modules-dkms sp12-flex-tools \\
  >> "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
if [[ -f /builder/sp12/private/IshS_SI.bin ]]; then
  echo sp12-ish-firmware >> "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
fi
""",
)

# 3. arch-mact2 renamed apple-bcm-firmware to apple-bcm-firmware-fetcher, which
#    breaks every build whose runtime still lists the old name. Map it the same
#    way upstream maps broadcom-wl.
old = "sed 's/^broadcom-wl$/broadcom-wl-dkms/'"
if s.count(old) != 1:
    sys.exit(f"{path}: broadcom-wl mapping not found")
s = s.replace(old, "sed -e 's/^broadcom-wl$/broadcom-wl-dkms/' -e 's/^apple-bcm-firmware$/apple-bcm-firmware-fetcher/'")

# 4. Build our packages into the pruned mirror before it is indexed.
insert(
    'rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*\n',
    """# sp12: patched limine + Surface Pro 12 packages into the mirror.
bash /builder/sp12/sp12-build-packages.sh "$offline_mirror_dir"

""",
    before=True,
)

path.write_text(s)
print(f"{path}: patched")
