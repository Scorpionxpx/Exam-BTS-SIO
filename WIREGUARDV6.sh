#!/bin/bash

# Fonction de gestion d'erreur
error_exit() {
    echo "Erreur : $1"
    exit 1
}

# Mise à jour et installation
apt update && ap install -y wireguard iptables curl || error_exit "Échec de l'installation de WireGuard ou iptables."

# Vérification des commandes nécessaires
for cmd in wg curl iptables systemctl; do
    command -v $cmd >/dev/null || error_exit "Commande $cmd non trouvée."
done

# Variables de configuration
SERVER_PRIVATE_KEY=$(wg genkey) || error_exit "Impossible de générer la clé privée serveur."
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey) || error_exit "Impossible de générer la clé publique serveur."
CLIENT_PRIVATE_KEY=$(wg genkey) || error_exit "Impossible de générer la clé privée client."
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey) || error_exit "Impossible de générer la clé publique client."

SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"
VPN_SUBNET="10.0.0.0/24"
LAN_NETWORK="192.168.2.0/24"
PORT="51820"
EXTERNAL_INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}') || error_exit "Impossible de détecter l'interface réseau externe."
DNS_SERVER="192.168.1.1"
PUBLIC_IP=$(curl -s ifconfig.me) || error_exit "Impossible de récupérer l'adresse IP publique."

# Configuration WireGuard du serveur
mkdir -p /etc/wireguard || error_exit "Impossible de créer /etc/wireguard."
cat <<EOF > /etc/wireguard/wg0.conf || error_exit "Impossible d'écrire wg0.conf."
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_IP/24
ListenPort = $PORT
SaveConfig = true

PostUp = iptables -A FORWARD -i %i -j ACCEPT; \
         iptables -A FORWARD -o %i -j ACCEPT; \
         iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o $EXTERNAL_INTERFACE -j MASQUERADE; \
         iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -d 192.168.2.0/24 -o ens192 -j MASQUERADE; \
         iptables -A INPUT -i %i -j ACCEPT

PostDown = iptables -D FORWARD -i %i -j ACCEPT; \
           iptables -D FORWARD -o %i -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $VPN_SUBNET -o $EXTERNAL_INTERFACE -j MASQUERADE; \
           iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -d 192.168.2.0/24 -o ens192 -j MASQUERADE; \
           iptables -D INPUT -i %i -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32, $LAN_NETWORK
EOF

chmod 600 /etc/wireguard/wg0.conf || error_exit "Impossible de sécuriser wg0.conf."

# Activer le routage IP
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf || error_exit "Impossible d'écrire la configuration sysctl."
sysctl --system || error_exit "Impossible d'appliquer la configuration sysctl."

# Pare-feu : autoriser le port WireGuard
iptables -A INPUT -i $EXTERNAL_INTERFACE -p udp --dport $PORT -j ACCEPT || error_exit "Impossible d'ajouter la règle iptables (INPUT)."
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || error_exit "Impossible d'ajouter la règle iptables (conntrack)."
iptables -A OUTPUT -o $EXTERNAL_INTERFACE -j ACCEPT || error_exit "Impossible d'ajouter la règle iptables (OUTPUT)."

# Activer wg-quick@wg0
systemctl enable wg-quick@wg0 || error_exit "Impossible d'activer wg-quick@wg0."
systemctl start wg-quick@wg0 || error_exit "Impossible de démarrer wg-quick@wg0."

# Génération du fichier client WireGuard
cat <<EOF > /etc/wireguard/client.conf || error_exit "Impossible d'écrire client.conf."
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

chmod 600 /etc/wireguard/client.conf || error_exit "Impossible de sécuriser client.conf."

# Affichage du fichier client
echo "Configuration du serveur WireGuard terminée."
echo "Fichier de configuration du client : /etc/wireguard/client.conf"
cat /etc/wireguard/client.conf || error_exit "Impossible d'afficher client.conf."

# Vérification finale
echo "Vérification du tunnel WireGuard..."
wg show wg0 || error_exit "wg0 non actif."

echo "Tout est prêt. Le client peut utiliser /etc/wireguard/client.conf pour se connecter."
