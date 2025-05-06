#!/bin/bash

# Stopper à la moindre erreur
set -e

# Mettre à jour et installer WireGuard et iptables
apt update && apt install -y wireguard iptables curl

# Vérifier les commandes nécessaires
for cmd in wg curl apt systemctl iptables; do
    if ! command -v $cmd &> /dev/null; then
        echo "Erreur : $cmd n'est pas installé."
        exit 1
    fi
done

# Variables réseau
SERVER_WG_IP="10.0.0.1"
CLIENT_WG_IP="10.0.0.2"
PORT="51820"
EXTERNAL_INTERFACE="ens192"
LAN_NETWORK="192.168.2.0/24"

# Génération des clés
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Sauvegarde des clés (utiles pour systemd)
echo "$SERVER_PRIVATE_KEY" > /etc/wireguard/server_private.key
chmod 600 /etc/wireguard/server_private.key
echo "$CLIENT_PUBLIC_KEY" > /etc/wireguard/client_public.key
chmod 600 /etc/wireguard/client_public.key

# Création du fichier de configuration du serveur WireGuard
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_WG_IP/24
ListenPort = $PORT

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_WG_IP/32, $LAN_NETWORK
EOF

# Activer le routage IP
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl --system

# Configuration du pare-feu
iptables -A INPUT -i $EXTERNAL_INTERFACE -p udp --dport $PORT -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i wg0 -o $EXTERNAL_INTERFACE -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_INTERFACE -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT
iptables -A OUTPUT -o $EXTERNAL_INTERFACE -j ACCEPT
iptables -t nat -A POSTROUTING -s $CLIENT_WG_IP -o $EXTERNAL_INTERFACE -j MASQUERADE
iptables -t nat -A POSTROUTING -s $LAN_NETWORK -o $EXTERNAL_INTERFACE -j MASQUERADE

# Création du script d'activation wg-setup
cat <<EOF > /usr/local/bin/wg-setup.sh
#!/bin/bash
ip link add wg0 type wireguard
ip address add $SERVER_WG_IP/24 dev wg0
wg set wg0 private-key /etc/wireguard/server_private.key
wg set wg0 listen-port $PORT
wg set wg0 peer $(cat /etc/wireguard/client_public.key) allowed-ips $CLIENT_WG_IP/32,$LAN_NETWORK
ip link set wg0 up
EOF

chmod +x /usr/local/bin/wg-setup.sh

# Création du service systemd
cat <<EOF > /etc/systemd/system/wg-setup.service
[Unit]
Description=WireGuard Setup Script
After=network.target

[Service]
ExecStart=/usr/local/bin/wg-setup.sh
RemainAfterExit=yes
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF

# Activation du service
systemctl daemon-reload
systemctl enable wg-setup.service
systemctl start wg-setup.service

# Création du fichier client
cat <<EOF > /etc/wireguard/client.conf
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_WG_IP/24

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $(curl -s ifconfig.me):$PORT
AllowedIPs = 0.0.0.0/0
EOF

# Affichage final
echo "✅ Configuration complète effectuée."
echo "📄 Fichier client : /etc/wireguard/client.conf"
cat /etc/wireguard/client.conf

# Vérification de l'état
echo "🔍 État de l'interface WireGuard :"
wg show wg0 || { echo "❌ Erreur : wg0 ne fonctionne pas."; exit 1; }

echo "✅ Tous les tests ont réussi."
echo "🔄 Redémarrage du service WireGuard..."