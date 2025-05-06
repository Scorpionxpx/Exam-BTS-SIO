#!/bin/bash

# Mise à jour et installation
apt update && apt install -y wireguard iptables curl || {
    echo "❌ Erreur : échec de l'installation de WireGuard ou iptables."
    exit 1
}

# Vérification des commandes nécessaires
for cmd in wg curl iptables systemctl; do
    command -v $cmd >/dev/null || {
        echo "❌ Erreur : commande $cmd non trouvée."
        exit 1
    }
done

# Variables de configuration
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"
VPN_SUBNET="10.0.0.0/24"
LAN_NETWORK="192.168.2.0/24"
PORT="51820"
EXTERNAL_INTERFACE="ens192"
DNS_SERVER="192.168.1.1"
PUBLIC_IP=$(curl -s ifconfig.me)

# Configuration WireGuard du serveur
mkdir -p /etc/wireguard
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_IP/24
ListenPort = $PORT

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32, $LAN_NETWORK
EOF

# Activer le routage IP
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl --system

# Configuration du pare-feu (iptables)
iptables -A INPUT -i $EXTERNAL_INTERFACE -p udp --dport $PORT -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i wg0 -o $EXTERNAL_INTERFACE -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_INTERFACE -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT
iptables -A OUTPUT -o $EXTERNAL_INTERFACE -j ACCEPT

# Règles NAT (sortie Internet du client via VPN)
iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $EXTERNAL_INTERFACE -j MASQUERADE

# Script de configuration à l’init
cat <<EOF > /usr/local/bin/wg-setup.sh
#!/bin/bash
ip link add wg0 type wireguard
ip address add $SERVER_IP/24 dev wg0
wg set wg0 private-key <(echo "$SERVER_PRIVATE_KEY")
wg set wg0 listen-port $PORT
wg set wg0 peer $CLIENT_PUBLIC_KEY allowed-ips $CLIENT_IP/32, $LAN_NETWORK
ip link set wg0 up
EOF

chmod +x /usr/local/bin/wg-setup.sh

# Service systemd
cat <<EOF > /etc/systemd/system/wg-setup.service
[Unit]
Description=WireGuard Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-setup.service
systemctl start wg-setup.service

# Génération du fichier client WireGuard
cat <<EOF > /etc/wireguard/client.conf
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = $DNS_SERVER

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $PUBLIC_IP:$PORT
AllowedIPs = 0.0.0.0/0
EOF

# Affichage du fichier client
echo "✅ Configuration du serveur WireGuard terminée."
echo "📄 Fichier de configuration du client : /etc/wireguard/client.conf"
cat /etc/wireguard/client.conf

# Vérification finale
echo "🔎 Vérification du tunnel WireGuard..."
wg show wg0 || {
    echo "❌ Erreur : wg0 non actif."
    exit 1
}

echo "✅ Tout est prêt. Le client peut utiliser /etc/wireguard/client.conf pour se connecter."
