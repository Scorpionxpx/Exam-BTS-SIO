# WireGuard – Scripts de configuration pour l'examen BTS SIO

Ce dépôt contient des scripts Bash permettant d'installer et de configurer un serveur VPN WireGuard sur un système Linux. Il a été réalisé dans le cadre d'un examen du BTS SIO.

## 📁 Contenu du dépôt

- `WIREGUARDV5.sh` : Script principal pour l'installation et la configuration automatique de WireGuard.
- `WIREGUARDV2.sh`, `WIREGUARDV3.sh`, `WIREGUARDV4.sh` : Versions alternatives ou expérimentales du script principal.
- `Wireguard.sh` : Ancienne version du script, actuellement non fonctionnelle.
- `.vscode/` : Dossier contenant les configurations spécifiques à Visual Studio Code :
  - `extensions.json` : Liste des extensions recommandées.
  - `launch.json` : Configuration pour le débogage.
  - `settings.json` : Paramètres spécifiques à l'espace de travail.
  - `tasks.json` : Définition des tâches automatisées.
- `LICENSE` : Fichier de licence du projet (MIT).

## ⚙️ Prérequis

Avant d'exécuter le script, assurez-vous que votre système dispose des éléments suivants :

- Un système d'exploitation Linux (Ubuntu, Debian, CentOS, etc.).
- Les droits administrateur (sudo).
- Une connexion Internet active.

## 🚀 Installation

Pour installer et configurer WireGuard à l'aide du script principal :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Scorpionxpx/Exam-BTS-SIO/main/WIREGUARDV5.sh)"
