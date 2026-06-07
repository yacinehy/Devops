# =============================================================================
# STAGE 1 — builder
# Installe les dépendances dans un venv isolé.
# Ce stage n'est jamais embarqué dans l'image finale : il sert uniquement
# à produire le dossier /opt/venv qui sera copié dans le stage runtime.
# =============================================================================
FROM python:3.12-slim AS builder

WORKDIR /build

# Copier uniquement requirements.txt en premier.
# Raison : si le code source change mais pas requirements.txt,
# Docker réutilise le cache de ce layer (pip install) → build ~5x plus rapide.
# requirements-prod.txt : uniquement flask + gunicorn (pas pytest/ruff/coverage).
# Séparer prod et dev évite d'embarquer ~180 MB d'outils inutiles dans l'image finale.
COPY requirements-prod.txt .

# Créer un venv standard puis y installer uniquement les dépendances de production.
# Un vrai venv (vs --prefix) garantit que Python résout correctement
# les site-packages au runtime sans configuration PYTHONPATH supplémentaire.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements-prod.txt


# =============================================================================
# STAGE 2 — runtime
# Image finale minimale : contient uniquement l'appli + le venv pré-compilé.
# Aucun outil de build (pip, gcc, headers) n'est présent → surface d'attaque réduite.
# =============================================================================
FROM python:3.12-slim AS runtime

# ── Utilisateur non-root ──────────────────────────────────────────────────────
# Par défaut Docker tourne en root : si l'appli est compromise, l'attaquant a
# les droits root sur le conteneur. Un utilisateur dédié limite les dégâts.
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

# ── Dépendances depuis le stage builder ──────────────────────────────────────
COPY --from=builder /opt/venv /opt/venv

# Ajouter le venv au PATH pour que `python` et `gunicorn` soient trouvés
ENV PATH="/opt/venv/bin:$PATH"

# ── Code source ──────────────────────────────────────────────────────────────
# Copié APRÈS les dépendances : le code change souvent, requirements.txt rarement.
# Cet ordre garantit que le layer pip n'est pas invalidé à chaque modif de code.
COPY app.py .

# Transférer la propriété des fichiers à appuser avant de changer d'utilisateur
RUN chown -R appuser:appuser /app

USER appuser

# ── Port exposé ───────────────────────────────────────────────────────────────
# Documentaire uniquement (n'ouvre pas réellement le port — c'est docker run -p)
EXPOSE 5000

# ── Healthcheck ───────────────────────────────────────────────────────────────
# Docker interroge /health toutes les 30s.
# --interval  : fréquence des checks
# --timeout   : délai max pour une réponse
# --retries   : nb d'échecs consécutifs avant de passer en "unhealthy"
# --start-period : délai de grâce au démarrage (l'app a 10s pour s'initialiser)
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" \
    || exit 1

# ── Commande de démarrage ─────────────────────────────────────────────────────
# gunicorn remplace le serveur de dev Flask (jamais utiliser `flask run` en prod).
# -w 2 : 2 workers (règle empirique : 2 × CPU + 1, ajuster selon la VM)
# -b 0.0.0.0:5000 : écoute sur toutes les interfaces
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "app:app"]
