#!/bin/sh
# Builds and captures the panel's tabs for both agents into screenshots/review (real window pictures).
cd "$(dirname "$0")/.." || exit 1
./build.sh > /tmp/cdbuild.log 2>&1 || { grep -m5 error: /tmp/cdbuild.log > /tmp/cdsnap.done; exit 1; }
D=../screenshots/review
for p in codex claude; do for t in limits stats tasks; do
  build/Cooldown.app/Contents/MacOS/Cooldown --snapshot "$D/real-$t-$p.png" --tab $t --provider $p >/dev/null 2>&1
done; done
echo ok > /tmp/cdsnap.done
