#!/usr/bin/env bash
# =============================================================================
# verify-ssh.sh — Vérification de la configuration SSH sur la VM
#
# À lancer SUR LA VM (pas sur ton Mac) pour simuler ce que fera le runner
# GitHub Actions avant de configurer le vrai workflow.
#
# Usage : bash verify-ssh.sh
# =============================================================================

set -euo pipefail

log()     { echo "[$(date '+%H:%M:%S')] [INFO]  $*"; }
success() { echo "[$(date '+%H:%M:%S')] [OK]    $*"; }
warn()    { echo "[$(date '+%H:%M:%S')] [WARN]  $*"; }
fail()    { echo "[$(date '+%H:%M:%S')] [FAIL]  $*" >&2; FAILED=$((FAILED + 1)); }

FAILED=0

log "=== Vérification de la configuration SSH pour GitHub Actions ==="
echo ""


# ─────────────────────────────────────────────────────────────────────────────
# 1. Vérification des permissions du dossier .ssh
# ─────────────────────────────────────────────────────────────────────────────
log "1. Permissions du dossier ~/.ssh"

SSH_DIR="${HOME}/.ssh"

if [[ ! -d "${SSH_DIR}" ]]; then
    fail "~/.ssh n'existe pas — lancer : mkdir -p ~/.ssh && chmod 700 ~/.ssh"
else
    SSH_PERMS=$(stat -c "%a" "${SSH_DIR}" 2>/dev/null || stat -f "%OLp" "${SSH_DIR}")
    if [[ "${SSH_PERMS}" == "700" ]]; then
        success "~/.ssh permissions : ${SSH_PERMS} ✅"
    else
        fail "~/.ssh permissions : ${SSH_PERMS} ❌ (attendu : 700)"
        warn "Correction : chmod 700 ~/.ssh"
    fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# 2. Vérification du fichier authorized_keys
# ─────────────────────────────────────────────────────────────────────────────
log "2. Fichier authorized_keys"

AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [[ ! -f "${AUTH_KEYS}" ]]; then
    fail "authorized_keys n'existe pas"
    warn "Correction : ssh-copy-id -i ~/.ssh/gh_actions_deploy.pub devops@<IP>"
else
    AUTH_PERMS=$(stat -c "%a" "${AUTH_KEYS}" 2>/dev/null || stat -f "%OLp" "${AUTH_KEYS}")
    if [[ "${AUTH_PERMS}" == "600" ]]; then
        success "authorized_keys permissions : ${AUTH_PERMS} ✅"
    else
        fail "authorized_keys permissions : ${AUTH_PERMS} ❌ (attendu : 600)"
        warn "Correction : chmod 600 ~/.ssh/authorized_keys"
    fi

    # Compte le nombre de clés autorisées
    KEY_COUNT=$(grep -c "ssh-" "${AUTH_KEYS}" 2>/dev/null || echo "0")
    log "Clés autorisées dans authorized_keys : ${KEY_COUNT}"

    # Vérifie la présence de la clé CI/CD
    if grep -q "github-actions-deploy" "${AUTH_KEYS}" 2>/dev/null; then
        success "Clé 'github-actions-deploy' trouvée ✅"
    else
        warn "Clé 'github-actions-deploy' non trouvée dans authorized_keys"
        warn "Ajouter la clé publique avec : ssh-copy-id -i ~/.ssh/gh_actions_deploy.pub devops@<IP>"
    fi
fi


# ─────────────────────────────────────────────────────────────────────────────
# 3. Vérification que le daemon SSH est configuré pour accepter les clés
# ─────────────────────────────────────────────────────────────────────────────
log "3. Configuration du daemon SSH (sshd_config)"

SSHD_CONFIG="/etc/ssh/sshd_config"

if [[ ! -f "${SSHD_CONFIG}" ]]; then
    warn "sshd_config non trouvé — SSH non installé ?"
else
    # PubkeyAuthentication doit être "yes" (c'est la valeur par défaut, mais vérifions)
    if grep -E "^PubkeyAuthentication\s+no" "${SSHD_CONFIG}" &>/dev/null; then
        fail "PubkeyAuthentication est désactivé dans sshd_config ❌"
        warn "Correction : sudo sed -i 's/PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config && sudo systemctl reload sshd"
    else
        success "PubkeyAuthentication : activé ✅"
    fi

    # AuthorizedKeysFile pointe vers le bon fichier
    AUTH_KEYS_CONF=$(grep -E "^AuthorizedKeysFile" "${SSHD_CONFIG}" | awk '{print $2}' || echo ".ssh/authorized_keys")
    log "AuthorizedKeysFile configuré : ${AUTH_KEYS_CONF:-'.ssh/authorized_keys (défaut)'}"
fi


# ─────────────────────────────────────────────────────────────────────────────
# 4. Simulation de ce que fait le runner GitHub Actions
# Le runner crée un fichier de clé temporaire, configure les options SSH,
# puis exécute les commandes sur le serveur distant.
# Ce test simule la connexion depuis la même VM (boucle locale).
# ─────────────────────────────────────────────────────────────────────────────
log "4. Simulation de connexion SSH (boucle locale)"

# Crée un fichier de clé temporaire comme le ferait le runner
TEMP_KEY=$(mktemp /tmp/test_ssh_key_XXXXXX)
chmod 600 "${TEMP_KEY}"

log "En attente d'une clé privée de test..."
log "(Dans un vrai test : coller le contenu de SSH_PRIVATE_KEY et appuyer sur Ctrl+D)"
log "Pour ce test, on utilise la clé déjà dans authorized_keys si disponible"

# En mode non-interactif : teste simplement que le service SSH répond
SSH_PORT="${SSH_PORT:-22}"
if nc -z -w3 localhost "${SSH_PORT}" 2>/dev/null; then
    success "Daemon SSH répond sur le port ${SSH_PORT} ✅"
else
    fail "Daemon SSH ne répond pas sur le port ${SSH_PORT} ❌"
    warn "Vérifier : sudo systemctl status ssh"
fi

rm -f "${TEMP_KEY}"


# ─────────────────────────────────────────────────────────────────────────────
# 5. Vérification de l'application et de deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
log "5. Vérification de l'environnement de déploiement"

APP_DIR="/opt/devops-cicd"
DEPLOY_SCRIPT="${APP_DIR}/deploy.sh"

if [[ -d "${APP_DIR}" ]]; then
    success "Dossier ${APP_DIR} existe ✅"
    APP_OWNER=$(stat -c "%U" "${APP_DIR}" 2>/dev/null || stat -f "%Su" "${APP_DIR}")
    log "Propriétaire : ${APP_OWNER}"
    [[ "${APP_OWNER}" == "deploy" ]] && success "Propriétaire correct (deploy) ✅" \
        || warn "Propriétaire inattendu : ${APP_OWNER} (attendu : deploy)"
else
    fail "${APP_DIR} n'existe pas ❌ — lancer setup.sh d'abord"
fi

if [[ -f "${DEPLOY_SCRIPT}" ]]; then
    success "deploy.sh présent ✅"
    [[ -x "${DEPLOY_SCRIPT}" ]] && success "deploy.sh est exécutable ✅" \
        || fail "deploy.sh n'est pas exécutable ❌ — correction : chmod +x ${DEPLOY_SCRIPT}"
else
    warn "deploy.sh absent de ${APP_DIR} — copier depuis server-setup/"
fi

if [[ -f "${APP_DIR}/.env" ]]; then
    success ".env présent ✅"
    ENV_PERMS=$(stat -c "%a" "${APP_DIR}/.env" 2>/dev/null || stat -f "%OLp" "${APP_DIR}/.env")
    [[ "${ENV_PERMS}" == "600" ]] && success ".env permissions : ${ENV_PERMS} ✅" \
        || warn ".env permissions : ${ENV_PERMS} ❌ (attendu : 600) — correction : chmod 600 ${APP_DIR}/.env"
else
    warn ".env absent — créer à partir de .env.example et remplir les valeurs"
fi

if command -v docker &>/dev/null; then
    success "Docker installé : $(docker --version) ✅"
    if docker compose version &>/dev/null; then
        success "Docker Compose plugin : $(docker compose version) ✅"
    else
        fail "docker compose plugin non installé ❌"
    fi
    # Vérifie que l'user courant peut lancer docker sans sudo
    if docker ps &>/dev/null; then
        success "docker ps fonctionne sans sudo ✅"
    else
        fail "Impossible de lancer docker sans sudo ❌"
        warn "Correction : sudo usermod -aG docker \$(whoami) && newgrp docker"
    fi
else
    fail "Docker non installé ❌ — lancer setup.sh d'abord"
fi


# ─────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
if [[ ${FAILED} -eq 0 ]]; then
    success "Toutes les vérifications sont passées — prêt pour GitHub Actions ✅"
    echo ""
    echo "  Prochaine étape : configurer les secrets GitHub"
    echo "  → Settings → Secrets → Actions → New repository secret"
    echo ""
    echo "  SSH_PRIVATE_KEY  = contenu de ~/.ssh/gh_actions_deploy (sur ton Mac)"
    echo "  SSH_HOST         = $(hostname -I | awk '{print $1}')"
    echo "  SSH_USER         = $(whoami)"
    echo "  SSH_PORT         = ${SSH_PORT:-22}"
else
    fail "${FAILED} vérification(s) échouée(s) — corriger avant de configurer GitHub Actions"
fi
echo "════════════════════════════════════════════════════════════"

exit ${FAILED}
