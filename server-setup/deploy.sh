#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Déploiement manuel avec rollback automatique
#
# Usage :
#   bash deploy.sh                        → déploie :latest
#   IMAGE_TAG=sha-a1b2c3d bash deploy.sh  → déploie un tag précis
#
# Ce script est conçu pour être lancé manuellement AVANT d'automatiser
# le déploiement via GitHub Actions (workflow CD complet).
#
# Prérequis :
#   - Docker installé (setup.sh exécuté)
#   - /opt/devops-cicd/.env rempli
#   - /opt/devops-cicd/docker-compose.prod.yml présent
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
APP_DIR="/opt/devops-cicd"
COMPOSE_FILE="${APP_DIR}/docker-compose.prod.yml"
SERVICE_NAME="app"
CONTAINER_NAME="devops-app"
HEALTH_URL="http://localhost:5000/health"
HEALTH_TIMEOUT=30   # secondes max pour attendre que /health réponde
IMAGE_TAG="${IMAGE_TAG:-latest}"

# ── Logging ───────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%H:%M:%S')] [INFO]     $*"; }
success() { echo "[$(date '+%H:%M:%S')] [SUCCESS]  $*"; }
warn()    { echo "[$(date '+%H:%M:%S')] [WARN]     $*"; }
error()   { echo "[$(date '+%H:%M:%S')] [ERROR]    $*" >&2; }

# ── Vérifications préalables ──────────────────────────────────────────────────
[[ ! -f "${COMPOSE_FILE}" ]] && error "Fichier introuvable : ${COMPOSE_FILE}" && exit 1
[[ ! -f "${APP_DIR}/.env" ]] && error "Fichier introuvable : ${APP_DIR}/.env" && exit 1
command -v docker &>/dev/null || { error "Docker non installé"; exit 1; }

log "=== Déploiement démarré ==="
log "Répertoire : ${APP_DIR}"
log "Tag image   : ${IMAGE_TAG}"
log "Healthcheck : ${HEALTH_URL} (timeout: ${HEALTH_TIMEOUT}s)"


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 1 — Mémoriser l'image actuellement en production
# Sert de point de rollback si le nouveau déploiement échoue.
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 1 — Identification de l'image actuelle (rollback point)"

# Récupère le digest complet de l'image en cours d'exécution
# Format : sha256:abc123... (immuable, ne change jamais pour une image donnée)
PREVIOUS_IMAGE=""
if docker ps --filter "name=${CONTAINER_NAME}" --format "{{.Image}}" | grep -q .; then
    PREVIOUS_IMAGE=$(docker inspect "${CONTAINER_NAME}" \
        --format '{{.Config.Image}}' 2>/dev/null || true)
    log "Image précédente : ${PREVIOUS_IMAGE:-aucune}"
else
    log "Aucun conteneur en cours — premier déploiement"
fi


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 2 — Pull de la nouvelle image
# On pull avant d'arrêter le service pour minimiser le downtime :
# si le pull échoue (image inexistante, réseau), l'ancienne version reste en ligne.
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 2 — Pull de l'image ${IMAGE_TAG}"

cd "${APP_DIR}"

# Export de IMAGE_TAG pour que docker-compose.prod.yml puisse l'utiliser
export IMAGE_TAG

if ! IMAGE_TAG="${IMAGE_TAG}" docker compose -f "${COMPOSE_FILE}" pull "${SERVICE_NAME}"; then
    error "Échec du pull — déploiement annulé, ancienne version toujours en ligne"
    exit 1
fi

success "Image pullée avec succès"


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 3 — Démarrage du nouveau conteneur
# --no-deps  : ne redémarre pas les services dont app dépend (db, redis…)
# --no-build : on ne build jamais en prod, on utilise l'image pullée
# -d         : mode détaché
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 3 — Redémarrage du service"

IMAGE_TAG="${IMAGE_TAG}" docker compose -f "${COMPOSE_FILE}" \
    up -d --no-deps --no-build "${SERVICE_NAME}"

log "Conteneur démarré — attente du healthcheck..."


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 4 — Vérification du healthcheck
# On interroge /health en boucle jusqu'à obtenir HTTP 200 ou timeout.
# Plus fiable que "sleep 10" : on réussit dès que l'app est prête.
# ─────────────────────────────────────────────────────────────────────────────
log "ÉTAPE 4 — Healthcheck (timeout: ${HEALTH_TIMEOUT}s)"

ELAPSED=0
HEALTHY=false

while [[ ${ELAPSED} -lt ${HEALTH_TIMEOUT} ]]; do
    # curl -sf : -s silencieux, -f échoue sur HTTP 4xx/5xx
    # On redirige stdout vers /dev/null — seul le code de retour compte
    if curl -sf "${HEALTH_URL}" -o /dev/null 2>/dev/null; then
        HEALTHY=true
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    log "En attente... (${ELAPSED}s / ${HEALTH_TIMEOUT}s)"
done


# ─────────────────────────────────────────────────────────────────────────────
# ÉTAPE 5 — Résultat : succès ou rollback
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${HEALTHY}" == "true" ]]; then
    # ── Succès ────────────────────────────────────────────────────────────────
    success "=== Déploiement réussi en ${ELAPSED}s ==="

    # Affiche le statut final du conteneur
    docker ps --filter "name=${CONTAINER_NAME}" \
        --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

    # Affiche les 5 premières lignes de logs gunicorn pour confirmation
    log "Derniers logs gunicorn :"
    docker logs "${CONTAINER_NAME}" --tail 5 2>&1 | sed 's/^/    /'

else
    # ── Échec → Rollback ──────────────────────────────────────────────────────
    error "=== Healthcheck échoué après ${HEALTH_TIMEOUT}s — ROLLBACK ==="

    # Affiche les logs du conteneur défaillant pour diagnostiquer
    warn "Logs du conteneur défaillant :"
    docker logs "${CONTAINER_NAME}" --tail 20 2>&1 | sed 's/^/    /' || true

    if [[ -n "${PREVIOUS_IMAGE}" ]]; then
        warn "Rollback vers : ${PREVIOUS_IMAGE}"

        # Force le redémarrage avec l'ancienne image
        # On écrit temporairement l'image précédente dans IMAGE_TAG
        ROLLBACK_TAG="${PREVIOUS_IMAGE##*:}"  # extrait le tag depuis "repo:tag"

        IMAGE_TAG="${ROLLBACK_TAG}" docker compose -f "${COMPOSE_FILE}" \
            up -d --no-deps --no-build "${SERVICE_NAME}" || true

        # Vérifie que le rollback a lui-même fonctionné
        sleep 5
        if curl -sf "${HEALTH_URL}" -o /dev/null 2>/dev/null; then
            success "Rollback réussi — ancienne version restaurée : ${PREVIOUS_IMAGE}"
        else
            error "Rollback échoué — intervention manuelle requise"
            error "Commande de diagnostic : docker logs ${CONTAINER_NAME}"
        fi
    else
        warn "Pas d'image précédente — impossible de rollback (premier déploiement)"
        error "Arrêt du conteneur défaillant"
        docker compose -f "${COMPOSE_FILE}" stop "${SERVICE_NAME}" || true
    fi

    # Code de sortie non-zéro pour signaler l'échec à l'appelant (CI, Makefile…)
    exit 1
fi
