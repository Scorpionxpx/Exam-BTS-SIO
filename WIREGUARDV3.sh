#!/bin/bash

# Mettre à jour et installer WireGuard, iptables et iptables-persistent
if ! apt update && apt install -y wireguard iptables iptables-persistent; then
    echo "Erreur : échec de l'installation de WireGuard, iptables ou iptables-persistent."
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
SERVER_WG_IP="10.0.0.1"
CLIENT_WG_IP="10.0.0.2"
PORT="51820"
EXTERNAL_INTERFACE="ens192"
LAN_NETWORK="192.168.2.0/24"

# Générer les clés WireGuard
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Sauvegarder les clés sur disque avec permissions sécurisées
echo "$SERVER_PRIVATE_KEY" > /etc/wireguard/server_private.key
chmod 600 /etc/wireguard/server_private.key

echo "$CLIENT_PRIVATE_KEY" > /etc/wireguard/client_private.key
chmod 600 /etc/wireguard/client_private.key

# Configurer le serveur WireGuard
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
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# Configurer les règles de pare-feu
iptables -A INPUT -i $EXTERNAL_INTERFACE -p udp --dport $PORT -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i wg0 -o $EXTERNAL_INTERFACE -j ACCEPT
iptables -A FORWARD -i $EXTERNAL_INTERFACE -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT
iptables -A OUTPUT -o $EXTERNAL_INTERFACE -j ACCEPT
iptables -t nat -A POSTROUTING -s $CLIENT_WG_IP -o $EXTERNAL_INTERFACE -j MASQUERADE
iptables -t nat -A POSTROUTING -s $LAN_NETWORK -o $EXTERNAL_INTERFACE -j MASQUERADE

# Sauvegarder les règles iptables
netfilter-persistent save

# Supprimer l'interface wg0 si elle existe
ip link show wg0 &> /dev/null && ip link delete wg0

# Créer le script de configuration WireGuard
cat <<EOF > /usr/local/bin/wg-setup.sh
#!/bin/bash
ip link add wg0 type wireguard
ip address add $SERVER_WG_IP/24 dev wg0
wg set wg0 private-key /etc/wireguard/server_private.key
wg set wg0 listen-port $PORT
wg set wg0 peer $CLIENT_PUBLIC_KEY allowed-ips $CLIENT_WG_IP/32, $LAN_NETWORK
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

# Récupérer l'adresse IP publique
PUBLIC_IP=$(curl -s ifconfig.me)
if [ -z "$PUBLIC_IP" ]; then
    echo "Erreur : impossible de récupérer l'adresse IP publique."
    exit 1
fi

# Créer la configuration client
cat <<EOF > /etc/wireguard/client.conf
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_WG_IP/24

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $PUBLIC_IP:$PORT
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
