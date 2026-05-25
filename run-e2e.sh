#!/usr/bin/env bash
# Repeatable e2e: hard-reclaim the sandbox ports, boot clean, bootstrap once, run e2e.
# Records all evidence to registry-client/e2e-evidence.txt.
set -uo pipefail
export PATH="$HOME/.dpm/bin:$PATH" TERM=dumb
cd "$(dirname "$0")"
EVIDENCE="registry-client/e2e-evidence.txt"

reclaim_port() {
  local port=$1
  local pids
  pids="$(lsof -ti:"$port" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    echo "  reclaiming port $port from pid(s): $pids"
    echo "$pids" | xargs kill -TERM 2>/dev/null || true
    sleep 2
    pids="$(lsof -ti:"$port" 2>/dev/null || true)"
    [ -n "$pids" ] && { echo "$pids" | xargs kill -KILL 2>/dev/null || true; sleep 1; }
  fi
}

{
echo "================================================================"
echo "E2E EVIDENCE — DEPO lifecycle vs real Canton sandbox (Daml 3.4.9 DARs)"
echo "Recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"

echo ""; echo "### [1/3] Clean sandbox (hard port reclaim) ###"
reclaim_port 6865; reclaim_port 7575; reclaim_port 6866
rm -f /tmp/canton-ports.json
DARS="--dar extracted-dars/utility-version-v0-0.0.1.dar --dar extracted-dars/utility-credential-v0-0.1.0.dar --dar extracted-dars/utility-registry-holding-v0-0.2.1.dar --dar extracted-dars/utility-registry-v0-0.6.0.dar --dar extracted-dars/utility-credential-app-v0-0.4.1.dar --dar extracted-dars/utility-registry-app-v0-0.7.0.dar --dar extracted-dars/utility-settlement-app-v1-1.2.0.dar"
nohup dpm sandbox $DARS --ledger-api-port 6865 --admin-api-port 6866 --json-api-port 7575 \
  --canton-port-file /tmp/canton-ports.json --no-tty > /tmp/sandbox.log 2>&1 &
echo $! > /tmp/sandbox.pid
for i in $(seq 1 40); do
  sleep 5
  [ "$(curl -s -m3 -o /dev/null -w '%{http_code}' http://localhost:7575/v2/packages 2>/dev/null)" = "200" ] && { echo "  sandbox READY in ~$((i*5))s (pid $(cat /tmp/sandbox.pid))"; break; }
done
PKGS=$(curl -s http://localhost:7575/v2/packages | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).packageIds.length))')
echo "  packages loaded: $PKGS"
# Wait until all 6 DARs are vetted (package count stabilizes at 53).
for i in $(seq 1 12); do
  [ "$PKGS" -ge 53 ] && break
  sleep 2
  PKGS=$(curl -s http://localhost:7575/v2/packages | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).packageIds.length))')
done
echo "  packages settled: $PKGS"

echo ""; echo "### [2/3] Bootstrap (single-party submits, no submitMulti) ###"
( cd registry-bootstrap && dpm script --dar .daml/dist/registry-bootstrap-0.1.0.dar \
    --script-name Bootstrap:bootstrap --ledger-host localhost --ledger-port 6865 2>&1 ) \
  | grep -iE "Prelude|complete|ERROR|exception|already exists" | sed 's/\[DA.Internal.Prelude:555\]: //' || true

echo ""; echo "### [3/3] E2E lifecycle via JSON-API client ###"
( cd registry-client && node src/e2e.js ); RC=$?
echo ""; echo "=== E2E EXIT CODE: $RC ==="
exit $RC
} 2>&1 | tee "$EVIDENCE"
exit "${PIPESTATUS[0]}"
