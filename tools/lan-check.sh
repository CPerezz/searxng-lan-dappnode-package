#!/usr/bin/env bash
# Run from a device on the home network: the search page and the OpenSearch description answer on both addresses,
# and the OpenSearch search URL uses the address the device used.
# usage: tools/lan-check.sh <dappnode-ip> <port>
set -euo pipefail
ip="${1:?usage: $0 <dappnode-ip> <port>}"
port="${2:?usage: $0 <dappnode-ip> <port>}"
fails=0
for host in "dappnode.local:$port" "$ip:$port"; do
  page=$(curl -s -m 15 -w '\n%{http_code}' "http://$host/" || true)
  code=${page##*$'\n'}
  if [ "$code" = 200 ] && grep -q 'id="search"' <<<"$page"; then echo "PASS search page at http://$host/"
  else echo "FAIL http://$host/ gave $code"; fails=$((fails + 1)); fi
  if curl -s -m 15 "http://$host/opensearch.xml" | grep -qF "template=\"http://$host/search?q={searchTerms}\""; then
    echo "PASS OpenSearch at http://$host/ searches http://$host/"
  else echo "FAIL OpenSearch at http://$host/ doesn't point back to $host"; fails=$((fails + 1)); fi
done
echo "fails: $fails"
exit $((fails > 0))
