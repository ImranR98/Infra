#!/bin/bash
# lib/net.sh — networking utilities

get_node_ip() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] || return 1
    ip -4 addr show "$iface" | grep -oP 'inet \K[\d.]+'
}
