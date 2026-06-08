# devops-cicd

Projet Flask minimal conçu comme exercice DevOps CI/CD complet.
Il expose quatre routes REST et intègre deux pipelines GitHub Actions :
lint + tests multi-versions Python, build Docker multi-stage, scan de vulnérabilités Trivy,
et push automatique sur Docker Hub à chaque merge sur `main`.

[![CI](https://github.com/[USERNAME]/devops-cicd/actions/workflows/ci.yml/badge.svg)](https://github.com/[USERNAME]/devops-cicd/actions/workflows/ci.yml)
[![Docker Build & Push](https://github.com/[USERNAME]/devops-cicd/actions/workflows/docker.yml/badge.svg)](https://github.com/[USERNAME]/devops-cicd/actions/workflows/docker.yml)

---

## Lancer localement

```bash
# 1. Créer et activer l'environnement virtuel
python3 -m venv .venv
source .venv/bin/activate        # Windows : .venv\Scripts\activate

# 2. Installer les dépendances
pip install -r requirements.txt

# 3. Démarrer l'application
python app.py                    # → http://127.0.0.1:5000

# 4. Lancer le lint
ruff check .

# 5. Lancer les tests avec couverture
pytest --cov=app --cov-report=term-missing
```

### Lancer avec Docker Compose (Flask + PostgreSQL)

```bash
cp .env.example .env             # configurer les variables
docker compose up -d --build     # démarre Flask + PostgreSQL
docker compose logs -f app       # suivre les logs en temps réel
docker compose down              # arrêter proprement
```

### Routes disponibles

| Méthode | Route | Réponse |
|---------|-------|---------|
| GET | `/` | `{"message": "Hello DevOps", "status": "ok"}` |
| GET | `/health` | `{"status": "healthy"}` |
| GET | `/api/hello?name=Yacine` | `{"message": "Hello Yacine"}` |
| GET | `/api/status` | `{"version": "1.0.0", "uptime": "ok"}` |

---

## Images Docker

L'image est publiée automatiquement sur Docker Hub à chaque push sur `main`,
après validation complète du pipeline (tests + scan Trivy).

**Docker Hub :** [hub.docker.com/r/[USERNAME]/devops-cicd](https://hub.docker.com/r/[USERNAME]/devops-cicd)

```bash
# Récupérer la dernière image stable
docker pull [USERNAME]/devops-cicd:latest

# Récupérer une version précise (SHA du commit — pour les rollbacks)
docker pull [USERNAME]/devops-cicd:sha-a1b2c3d

# Lancer l'image directement
docker run -d -p 5001:5000 [USERNAME]/devops-cicd:latest
curl http://localhost:5001/health
```

Les deux tags disponibles par build :

| Tag | Caractéristique | Usage |
|-----|----------------|-------|
| `latest` | Mutable — pointe toujours le dernier build | Déploiement automatique |
| `sha-a1b2c3d` | Immuable — lié à un commit précis | Rollback production |

---

## Pipeline CI

Le workflow `ci.yml` se déclenche sur chaque **push et pull request** vers `main`.

```
push/PR → test (3.11) ┐
                       ├── lint ruff + pytest --cov
          test (3.12) ┘
```

Tests en parallèle sur Python **3.11 et 3.12** grâce à une strategy matrix,
avec cache pip basé sur le hash de `requirements.txt`.

## Pipeline CD (Docker)

Le workflow `docker.yml` se déclenche uniquement sur **push vers `main`**.

```
push main → test (3.11 + 3.12) → build-and-push → scan Trivy
                                       │                │
                                  Docker Hub       CRITICAL/HIGH
                                  :latest          bloque le pipeline
                                  :sha-xxxxx       si CVE avec fix
```

---

## Sécurité

Chaque image Docker produite par le pipeline est automatiquement analysée par **Trivy**
avant d'être considérée comme déployable. Scanner en CI/CD permet de détecter les
vulnérabilités dès qu'elles apparaissent — une nouvelle CVE publiée aujourd'hui sera
signalée au prochain push, sans attendre un audit manuel. Le pipeline échoue sur toute
CVE de sévérité **CRITICAL** ou **HIGH** disposant d'un correctif, forçant une mise à
jour avant que l'image ne parte en production.

---

## Choix techniques

### Multi-stage build

Le Dockerfile est découpé en deux stages : un stage `builder` qui installe les
dépendances dans un venv, et un stage `runtime` qui ne copie que le venv et le code.
Les outils de build (pip, gcc, headers C) et les dépendances de développement (pytest,
ruff) **ne sont jamais présents dans l'image finale** — ce qui réduit la taille de
l'image et la surface d'attaque exposée en production.

### `python:3.12-slim`

L'image de base `slim` est une variante Debian minimale : elle ne contient pas les
packages recommandés ni les outils de dev du système. Elle est ~5x plus petite que
l'image `python:3.12` complète (~130 MB vs ~1 GB), tout en restant compatible avec les
packages Python compilés (contrairement à `alpine` qui utilise musl libc et cause des
problèmes de compatibilité avec certaines wheels). C'est le compromis taille/compatibilité
recommandé pour les applications Python en production.

### Scanner avec Trivy

Une image Docker est un assemblage de centaines de packages OS et Python, chacun pouvant
contenir des vulnérabilités découvertes après sa publication. Trivy interroge les bases
de données CVE (NVD, GitHub Advisory, RedHat…) et signale les packages vulnérables avec
leur version corrigée. Intégré dans le pipeline, le scan est **automatique et systématique** :
aucun déploiement ne peut passer à travers sans avoir été analysé, ce qui serait
impossible à garantir avec des audits manuels.

---

## Structure du projet

```
flask-cicd/
├── .github/workflows/
│   ├── ci.yml              # Lint + tests sur PR et push main
│   └── docker.yml          # Tests + build + push + scan sur push main
├── Dockerfile              # Multi-stage : builder (venv) + runtime (slim)
├── docker-compose.yml      # Stack locale Flask + PostgreSQL
├── .dockerignore
├── .env.example            # Template des variables d'environnement
├── app.py                  # Application Flask (4 routes)
├── test_app.py             # 10 tests pytest
├── requirements.txt        # Dépendances dev
├── requirements-prod.txt   # Dépendances prod uniquement
├── ruff.toml               # Configuration linter
├── ARCHITECTURE.md         # Schémas et documentation technique
└── CONTRIBUTING.md         # Workflow Git : branche → PR → CI verte → merge
```
