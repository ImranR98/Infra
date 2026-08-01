# Replaces the InternalIP address in a kubectl get node JSON status blob
# Reads node JSON from stdin, writes status patch to stdout.
# Usage: kubectl get node <name> -o json | python3 _patch_node_ip.py <new-ip> > patch.json
import sys, json

node = json.load(sys.stdin)
addrs = node.get('status', {}).get('addresses', [])
for a in addrs:
    if a.get('type') == 'InternalIP':
        a['address'] = sys.argv[1]
json.dump({'status': {'addresses': addrs}}, sys.stdout)
