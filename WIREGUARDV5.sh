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
EXTERNAL_INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
DNS_SERVER="192.168.1.1"
PUBLIC_IP=$(curl -s ifconfig.me)

# Configuration WireGuard du serveur
mkdir -p /etc/wireguard
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_IP/24
ListenPort = $PORT
SaveConfig = true

PostUp = iptables -A FORWARD -i %i -j ACCEPT; \
         iptables -A FORWARD -o %i -j ACCEPT; \
         iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $EXTERNAL_INTERFACE -j MASQUERADE; \
         iptables -A INPUT -i %i -j ACCEPT

PostDown = iptables -D FORWARD -i %i -j ACCEPT; \
           iptables -D FORWARD -o %i -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $VPN_SUBNET -o $EXTERNAL_INTERFACE -j MASQUERADE; \
           iptables -D INPUT -i %i -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32, $LAN_NETWORK
EOF

chmod 600 /etc/wireguard/wg0.conf

# Activer le routage IP
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl --system

# Pare-feu : autoriser le port WireGuard
iptables -A INPUT -i $EXTERNAL_INTERFACE -p udp --dport $PORT -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o $EXTERNAL_INTERFACE -j ACCEPT

# Activer wg-quick@wg0
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

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
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/client.conf

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
