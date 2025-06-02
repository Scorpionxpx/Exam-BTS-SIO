#!/bin/bash

# Fonction de gestion d'erreur
error_exit() {
    echo "Erreur : $1"
    exit 1
}

# Mise à jour et installation
apt update && apt install -y wireguard iptables curl cifs-utils || error_exit "Échec de l'installation de WireGuard, iptables, curl ou cifs-utils."

# Vérification des commandes nécessaires
for cmd in wg curl iptables systemctl mount umount; do
    command -v $cmd >/dev/null || error_exit "Commande $cmd non trouvée."
done

# Variables de configuration
SERVER_PRIVATE_KEY=$(wg genkey) || error_exit "Impossible de générer la clé privée serveur."
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey) || error_exit "Impossible de générer la clé publique serveur."

SERVER_IP="10.0.0.1"
VPN_SUBNET="10.0.0.0/24"
LAN_NETWORK="192.168.2.0/24"
PORT="51820"
EXTERNAL_INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}') || error_exit "Impossible de détecter l'interface réseau externe."
DNS_SERVER="192.168.1.1"
PUBLIC_IP=$(curl -s ifconfig.me) || error_exit "Impossible de récupérer l'adresse IP publique."

# Montage du partage réseau
MOUNT_POINT="/mnt/wgconf"
mkdir -p "$MOUNT_POINT" || error_exit "Impossible de créer le dossier de montage."
mount -t cifs //192.168.1.1/wgconf "$MOUNT_POINT" -o username=wireguard,password='P@ssw0rd1234*',vers=3.0 || error_exit "Impossible de monter le partage réseau."

# Chemin du CSV des utilisateurs
CSV_USERS="personnes.csv"  # À adapter selon l'emplacement réel

# Vérification du fichier CSV
[ -f "$CSV_USERS" ] || error_exit "Fichier CSV $CSV_USERS introuvable."

# Création de la configuration serveur de base
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

EOF

# Boucle sur chaque utilisateur du CSV (en ignorant l'en-tête)
tail -n +2 "$CSV_USERS" | while IFS=',' read -r id nom prenom; do
    USERNAME="${prenom,,}.${nom,,}"  # prénom.nom en minuscules
    # Création de l'utilisateur s'il n'existe pas
    if ! id "$USERNAME" &>/dev/null; then
        useradd -m -c "$prenom $nom" "$USERNAME" || error_exit "Impossible de créer l'utilisateur $USERNAME."
        echo "Utilisateur $USERNAME créé."
    else
        echo "Utilisateur $USERNAME déjà existant."
    fi

    # Génération des clés WireGuard pour l'utilisateur
    CLIENT_PRIVATE_KEY=$(wg genkey) || error_exit "Impossible de générer la clé privée client pour $USERNAME."
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey) || error_exit "Impossible de générer la clé publique client pour $USERNAME."
    CLIENT_IP="10.0.0.$((100 + id))"  # Exemple : IP unique par id

    # Ajout du peer dans la conf serveur
    cat <<EOF >> /etc/wireguard/wg0.conf
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32, $LAN_NETWORK
EOF

    # Génération du fichier client WireGuard
    cat <<EOF > "$MOUNT_POINT/client_${USERNAME}.conf"
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

    chmod 600 "$MOUNT_POINT/client_${USERNAME}.conf" || error_exit "Impossible de sécuriser client_${USERNAME}.conf."
    echo "Fichier de configuration WireGuard généré pour $USERNAME : $MOUNT_POINT/client_${USERNAME}.conf"
done

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

# Affichage des fichiers clients générés
echo "Configuration du serveur WireGuard terminée."
echo "Fichiers de configuration des clients copiés sur le partage réseau :"
ls "$MOUNT_POINT"/client_*.conf

# Vérification finale
echo "Vérification du tunnel WireGuard..."
wg show wg0 || error_exit "wg0 non actif."

# Démontage du partage réseau
umount "$MOUNT_POINT" || error_exit "Impossible de démonter le partage réseau."

echo "Tout est prêt. Les clients peuvent utiliser leur fichier de configuration présent sur le partage réseau."