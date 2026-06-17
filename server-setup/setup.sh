#!/usr/bin/env bash
# =============================================================================
# setup.sh — Provisioning initial d'une VM Ubuntu 22.04
#
# Usage : sudo bash setup.sh
# À lancer UNE SEULE FOIS sur un serveur vierge.
# Idempotent : peut être relancé sans casser l'existant.
# =============================================================================

# ── Sécurité bash ────────────────────────────────────────────────────────────
# -e          : arrêt immédiat si une commande échoue
# -o pipefail : un pipe échoue si n'importe quelle commande du pipe échoue
#               (sans ça, "cmd_fail | tee log" retourne 0 car tee réussit)
# -u          : erreur si une variable non définie est utilisée
set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────────────
# Chaque étape est horodatée et préfixée pour faciliter le débogage
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"
}
error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    exit 1
}

# ── Vérifications préalables ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Ce script doit être lancé en root : sudo bash setup.sh"
[[ $(lsb_release -rs) != "22.04" ]] && log "ATTENTION : testé sur Ubuntu 22.04 uniquement"

log "=== Début du provisioning ==="
log "Serveur : $(hostname) | OS : $(lsb_release -ds)"


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 1 — Mise à jour du système
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 1 — Mise à jour des paquets système"

apt-get update -qq
# DEBIAN_FRONTEND=noninteractive : évite les prompts interactifs en CI/scripts
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

log "Paquets prérequis installés"
apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 2 — Installation de Docker Engine
# Source officielle Docker (pas le paquet Ubuntu qui est souvent outdated)
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 2 — Installation de Docker Engine"

# Idempotence : on n'ajoute la clé GPG que si elle n'existe pas déjà
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    log "Ajout de la clé GPG Docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Ajout du dépôt officiel Docker si absent
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    log "Ajout du dépôt Docker"
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
fi

# docker-compose-plugin = "docker compose" (v2, intégré au CLI Docker)
# Remplace l'ancien binaire docker-compose (v1, déprécié)
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

log "Docker version : $(docker --version)"
log "Docker Compose version : $(docker compose version)"

# Activation et démarrage du daemon Docker
systemctl enable docker
systemctl start docker
log "Docker daemon démarré et activé au boot"


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 3 — Création du user 'deploy'
# Utilisateur dédié aux déploiements : pas de sudo, accès docker uniquement
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 3 — Création du user 'deploy'"

# Idempotence : useradd -D échoue si l'user existe, on vérifie d'abord
if ! id "deploy" &>/dev/null; then
    # --system       : user système (pas de home avec shell de login)
    # --shell        : shell minimal pour les scripts de déploiement
    # --create-home  : dossier home pour stocker la config docker si nécessaire
    useradd \
        --create-home \
        --shell /bin/bash \
        --comment "Deployment user" \
        deploy
    log "User 'deploy' créé"
else
    log "User 'deploy' existe déjà — ignoré"
fi

# Ajout au groupe 'docker' : permet de lancer 'docker' sans sudo
# ATTENTION : appartenir au groupe docker ≈ droits root sur la machine.
# C'est acceptable pour un user de déploiement dédié, jamais pour un user humain.
usermod -aG docker deploy
log "User 'deploy' ajouté au groupe docker"


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 4 — Création du dossier de l'application
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 4 — Création de /opt/devops-cicd"

APP_DIR="/opt/devops-cicd"

# mkdir -p : idempotent, ne plante pas si le dossier existe
mkdir -p "${APP_DIR}"

# Le user 'deploy' doit pouvoir écrire les fichiers compose et .env
chown deploy:deploy "${APP_DIR}"
chmod 750 "${APP_DIR}"  # rwxr-x--- : deploy RW, groupe R, autres rien

log "Dossier ${APP_DIR} créé (propriétaire: deploy, permissions: 750)"

# Création du fichier .env vide si absent — à remplir manuellement après
ENV_FILE="${APP_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    touch "${ENV_FILE}"
    chown deploy:deploy "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"  # rw------- : lecture/écriture deploy uniquement
    log "Fichier .env créé (vide) — à remplir avec les vraies valeurs"
fi

# Copie du fichier compose de production s'il est présent dans le répertoire courant
if [[ -f "docker-compose.prod.yml" ]]; then
    cp docker-compose.prod.yml "${APP_DIR}/docker-compose.prod.yml"
    chown deploy:deploy "${APP_DIR}/docker-compose.prod.yml"
    log "docker-compose.prod.yml copié dans ${APP_DIR}"
fi


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 5 — Configuration du pare-feu (UFW)
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 5 — Configuration UFW"

# On n'active UFW que s'il est installé (certaines VMs cloud l'ont déjà)
if command -v ufw &>/dev/null; then
    ufw --force reset          # reset sans prompt interactif
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp           # SSH — NE JAMAIS BLOQUER avant activation
    ufw allow 5000/tcp         # Flask / Gunicorn
    ufw --force enable
    log "UFW configuré : SSH (22) + app (5000) ouverts"
else
    log "UFW non disponible — pare-feu à configurer manuellement"
fi


# ─────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ
# ─────────────────────────────────────────────────────────────────────────────
log "=== Provisioning terminé ==="
log ""
log "Prochaines étapes manuelles :"
log "  1. Copier docker-compose.prod.yml dans ${APP_DIR}/"
log "  2. Remplir ${APP_DIR}/.env avec les variables de production"
log "  3. Se connecter en tant que deploy : su - deploy"
log "  4. Lancer : cd ${APP_DIR} && docker compose -f docker-compose.prod.yml up -d"
log ""
log "Pour copier les fichiers depuis votre machine locale :"
log "  scp docker-compose.prod.yml deploy@<IP_SERVEUR>:${APP_DIR}/"
log "  scp .env.prod deploy@<IP_SERVEUR>:${APP_DIR}/.env"
