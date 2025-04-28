#!/bin/bash

# Mettre à jour et installer WireGuard
if ! apt update && apt install -y wireguard; then
    echo "Erreur : échec de l'installation de WireGuard."
    exit 1
fi

# Vérifier que les commandes nécessaires sont disponibles
for cmd in wg curl apt systemctl iptables; do
    if ! command -v $cmd &> /dev/null; then
        echo "Erreur : $cmd n'est pas installé."
        exit 1
    fi
done

# Variables
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo $SERVER_PRIVATE_KEY | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)
SERVER_IP="192.168.1.10"
CLIENT_IP="192.168.2.10"
PORT="51820"
EXTERNAL_INTERFACE="ens192"
# Remplacer par le nom de votre interface réseau externe

# Configurer le serveur WireGuard
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_IP/24
ListenPort = $PORT

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32
EOF

# Activer le routage IP
if ! echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf || ! sysctl -p; then
    echo "Erreur : échec de l'activation du routage IP."
    exit 1
fi

# Configurer les règles de pare-feu
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -o $EXTERNAL_INTERFACE -j MASQUERADE

# Créer le script de configuration WireGuard
cat <<EOF > /usr/local/bin/wg-setup.sh
#!/bin/bash

ip link add wg0 type wireguard
ip address add $SERVER_IP/24 dev wg0
wg set wg0 private-key <(echo $SERVER_PRIVATE_KEY)
wg set wg0 listen-port $PORT
wg set wg0 peer $CLIENT_PUBLIC_KEY allowed-ips $CLIENT_IP/32
ip link set wg0 up
EOF

chmod +x /usr/local/bin/wg-setup.sh

# Activer le service WireGuard au démarrage
cat <<EOF > /etc/systemd/system/wg-setup.service
[Unit]
Description=WireGuard Setup

[Service]
ExecStart=/usr/local/bin/wg-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-setup.service
systemctl start wg-setup.service

# Afficher la configuration du client
cat <<EOF > /etc/wireguard/client.conf
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $(curl -s ifconfig.me):$PORT
AllowedIPs = 0.0.0.0/0
EOF

echo "Configuration du serveur et du client WireGuard terminée."
echo "Le fichier de configuration du client est situé à /etc/wireguard/client.conf"

# Afficher la configuration du client
echo "Voici la configuration du client WireGuard :"
cat /etc/wireguard/client.conf

# Tests
echo "Vérification de la configuration du serveur WireGuard..."
if ! wg show wg0; then
    echo "Erreur : la configuration du serveur WireGuard n'est pas correcte."
    exit 1
fi

echo "Vérification de la configuration du client WireGuard..."
if ! [ -f /etc/wireguard/client.conf ]; then
    echo "Erreur : le fichier de configuration du client n'a pas été créé."
    exit 1
fi

echo "Tous les tests ont réussi."
