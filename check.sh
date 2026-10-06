#!/usr/bin/env bash
# check.sh - format guard for WinCleanup .bat scripts (run on macOS/Linux before commit).
# Verifies the 4 invariants that silently break these self-elevating bat+PowerShell files:
#   1. no UTF-8 BOM            (a BOM breaks the first `@echo off` / `set` line in cmd)
#   2. CRLF line endings only  (LF-only breaks cmd parsing on Windows)
#   3. pure ASCII before #PS-BEGIN   (the cmd part must not carry non-ASCII bytes)
#   4. launcher uses %SELF%/$env:SELF, never '%~f0' inside a PowerShell -Command string
# Does NOT modify anything. Exit code 0 = all good, 1 = at least one problem.
set -u
cd "$(dirname "$0")"
fail=0
for f in *.bat; do
  [ -e "$f" ] || continue
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
errs = []
if raw[:3] == b'\xef\xbb\xbf':
    errs.append('has UTF-8 BOM')
# CRLF: every LF must be preceded by CR; no lone CR
for i, b in enumerate(raw):
    if b == 0x0A and (i == 0 or raw[i-1] != 0x0D):
        errs.append('LF without CR (not CRLF)'); break
marker = b'\r\n#PS-BEGIN\r\n'
idx = raw.find(marker)
if idx == -1:
    errs.append('no #PS-BEGIN marker line')
else:
    head = raw[:idx]
    for i, b in enumerate(head):
        if b > 0x7F:
            errs.append('non-ASCII byte in cmd part before #PS-BEGIN (offset %d)' % i); break
    if b"'%~f0'" in head:
        errs.append("launcher passes '%~f0' into PowerShell (use $env:SELF)")
    if b'set "SELF=%~f0"' not in head:
        errs.append('launcher missing: set "SELF=%~f0"')
if errs:
    print('FAIL ' + p)
    for e in errs:
        print('   - ' + e)
    sys.exit(1)
print('OK   ' + p)
PY
  [ $? -ne 0 ] && fail=1
done
exit $fail
