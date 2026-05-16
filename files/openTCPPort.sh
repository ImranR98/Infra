if ! which ufw 2>&1 >/dev/null; then
    sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport $1 -j ACCEPT
    if [ -n "$(which netfilter-persistent)" ]; then
        sudo netfilter-persistent save
    fi
else
    ufw allow "$1"
fi

# 22/TCP SSH
# 80/TCP HTTP
# 443/TCP HTTPS
# 8887/TCP PREBOOT-SSH

# DO NOT OPEN 8888/TCP (DIRECT-CORE-SSH)
