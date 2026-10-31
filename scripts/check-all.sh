#!/bin/sh
# Build, self-test and unit tests; result summary in /tmp/cdcheck.done.
cd "$(dirname "$0")/.." || exit 1
{
./build.sh > /tmp/cdbuild.log 2>&1 && echo "build ok" || { echo "build FAILED"; grep -m8 error: /tmp/cdbuild.log; }
build/Cooldown.app/Contents/MacOS/Cooldown --selftest > /tmp/cdself.log 2>&1; echo "selftest exit $?"; tail -3 /tmp/cdself.log
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test > /tmp/cdtest.log 2>&1; echo "tests exit $?"; grep -E "Executed|error:|failed" /tmp/cdtest.log | tail -5
} > /tmp/cdcheck.out 2>&1
mv /tmp/cdcheck.out /tmp/cdcheck.done
