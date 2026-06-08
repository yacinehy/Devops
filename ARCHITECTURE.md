# Architecture du pipeline CI/CD

Ce document décrit le pipeline complet du projet `devops-cicd` :
de l'écriture du code jusqu'à la publication d'une image Docker sécurisée.

---

## Vue d'ensemble

```
  Poste du développeur
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   Éditer app.py / test_app.py                        │
  │         │                                            │
  │         │  ruff check . && pytest    ← vérif locale  │
  │         │                                            │
  │   git push origin main  ─────────────────────────────┼──────────────────────┐
  │                                                      │                      │
  └──────────────────────────────────────────────────────┘                      │
                                                                                │
  GitHub Actions                                                                │
  ┌──────────────────────────────────────────────────────────────────────────── ▼ ──┐
  │                                                                                 │
  │  Workflow : ci.yml (PR + push main)                                             │
  │  ┌──────────────────────────────────────────────────────────────────────────┐   │
  │  │                                                                          │   │
  │  │   ┌─────────────────────┐   ┌─────────────────────┐                     │   │
  │  │   │  test / 3.11  ✅   │   │  test / 3.12  ✅   │  ← matrix parallèle  │   │
  │  │   │  ruff check .       │   │  ruff check .       │                     │   │
  │  │   │  pytest --cov       │   │  pytest --cov       │                     │   │
  │  │   └─────────────────────┘   └─────────────────────┘                     │   │
  │  │                                                                          │   │
  │  └──────────────────────────────────────────────────────────────────────────┘   │
  │                                                                                 │
  │  Workflow : docker.yml (push main uniquement)                                   │
  │  ┌──────────────────────────────────────────────────────────────────────────┐   │
  │  │                                                                          │   │
  │  │  ┌───────────────┐     ┌───────────────────────┐     ┌───────────────┐  │   │
  │  │  │  JOB 1        │     │  JOB 2                │     │  JOB 3        │  │   │
  │  │  │  test         │────▶│  build-and-push        │────▶│  scan         │  │   │
  │  │  │               │     │                       │     │               │  │   │
  │  │  │  (idem ci.yml)│     │  Docker Buildx        │     │  Trivy        │  │   │
  │  │  │               │     │  multi-stage build    │     │  CRITICAL +   │  │   │
  │  │  │  3.11 ✅      │     │  cache GHA            │     │  HIGH bloqués │  │   │
  │  │  │  3.12 ✅      │     │  push Docker Hub      │     │               │  │   │
  │  │  └───────────────┘     └───────────────────────┘     └───────┬───────┘  │   │
  │  │                                                               │          │   │
  │  └───────────────────────────────────────────────────────────────┼──────────┘   │
  │                                                                  │              │
  └──────────────────────────────────────────────────────────────────┼──────────────┘
                                                                     │
  Docker Hub                                                         │
  ┌───────────────────────────────────────────────────── ▼ ──────────┘
  │                                                      │
  │   [USERNAME]/devops-cicd                             │
  │   ├── :latest          ← pointe toujours le          │
  │   │                      dernier build propre        │
  │   └── :sha-a1b2c3d     ← immuable, lié au commit    │
  │                          utilisé pour les rollbacks  │
  │                                                      │
  └──────────────────────────────────────────────────────┘
```

---

## Détail du Dockerfile — multi-stage build

```
  python:3.12-slim (builder)
  ┌───────────────────────────────┐
  │  COPY requirements-prod.txt   │
  │  python -m venv /opt/venv     │  ← venv isolé
  │  pip install flask gunicorn   │
  └──────────────┬────────────────┘
                 │  COPY --from=builder /opt/venv
                 ▼
  python:3.12-slim (runtime)               Éléments ABSENTS de l'image finale :
  ┌───────────────────────────────┐        ✗  pip, setuptools, wheel
  │  useradd appuser              │        ✗  pytest, ruff, pytest-cov
  │  COPY /opt/venv               │        ✗  compilateurs (gcc, make)
  │  COPY app.py                  │        ✗  headers C
  │  USER appuser          ← non-root
  │  HEALTHCHECK /health          │        Résultat :
  │  CMD gunicorn -w 2            │        → image finale : ~47 MB réels
  └───────────────────────────────┘        → surface d'attaque minimale
```

---

## Flux de données en production

```
  Client HTTP
      │
      │  GET /health
      ▼
  ┌──────────────────────────────────────────┐
  │  Conteneur flask-app                     │
  │  ┌──────────────────────────────────┐    │
  │  │  Gunicorn (2 workers)            │    │
  │  │  └── Flask app                  │    │
  │  │       ├── GET /                 │    │
  │  │       ├── GET /health    ◀──────┼────┤── HEALTHCHECK Docker (30s)
  │  │       ├── GET /api/hello        │    │
  │  │       └── GET /api/status       │    │
  │  └──────────────────────────────┘    │
  │  Réseau : backend (bridge)            │
  └───────────────┬──────────────────────┘
                  │  DB_HOST=db / DB_PORT=5432
                  ▼
  ┌──────────────────────────────────────────┐
  │  Conteneur flask-db                      │
  │  postgres:16-alpine                      │
  │  Volume : postgres_data (named)          │
  │  Port 5432 : interne uniquement          │
  └──────────────────────────────────────────┘
```

---

## Fichiers clés et leur rôle

```
flask-cicd/
│
├── .github/workflows/
│   ├── ci.yml              → lint + tests sur PR et push main
│   └── docker.yml          → tests + build + push + scan sur push main
│
├── Dockerfile              → multi-stage : builder (venv) + runtime (slim)
├── docker-compose.yml      → stack locale Flask + PostgreSQL
├── .dockerignore           → exclut tests, .env, __pycache__ de l'image
│
├── app.py                  → application Flask (4 routes)
├── test_app.py             → 10 tests pytest
├── requirements.txt        → dépendances dev (flask + gunicorn + pytest + ruff)
├── requirements-prod.txt   → dépendances prod uniquement (flask + gunicorn)
├── ruff.toml               → linter : line-length 88, py312, règles E/W/F/I
│
├── .env.example            → template des variables d'environnement
└── CONTRIBUTING.md         → workflow Git : branche → PR → CI verte → merge
```

---

## Règles de sécurité du pipeline

| Règle | Où | Pourquoi |
|---|---|---|
| Tests obligatoires avant build | `needs: test` dans docker.yml | On ne livre jamais du code non testé |
| Branche main uniquement pour push | `if: github.ref == 'refs/heads/main'` | Les branches feature ne publient pas d'images |
| Utilisateur non-root | `USER appuser` dans Dockerfile | Limite l'impact d'une compromission |
| Scan CVE CRITICAL/HIGH | job `scan` avec Trivy | Détecte les vulnérabilités connues avant déploiement |
| CVE sans correctif ignorées | `ignore-unfixed: true` | Évite de bloquer sur des failles sans solution |
| Secrets jamais en clair | `secrets.DOCKER_*` dans GitHub | Les credentials ne transitent pas dans les logs |
| `.env` dans `.gitignore` | `.gitignore` | Les mots de passe ne sont jamais commités |
