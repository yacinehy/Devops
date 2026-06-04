# flask-cicd

Projet Flask minimal conçu comme exercice DevOps CI/CD.
Il expose trois routes REST et intègre une pipeline GitHub Actions
avec lint (ruff), tests (pytest + coverage) et matrix multi-versions Python.

[![CI](https://github.com/yacinehy/devops-cicd/actions/workflows/ci.yml/badge.svg)](https://github.com/yacinehy/devops-cicd/actions/workflows/ci.yml)

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

### Routes disponibles

| Méthode | Route | Réponse |
|---------|-------|---------|
| GET | `/` | `{"message": "Hello DevOps", "status": "ok"}` |
| GET | `/health` | `{"status": "healthy"}` |
| GET | `/api/hello?name=Yacine` | `{"message": "Hello Yacine"}` |

---

## Pipeline CI

Le workflow `.github/workflows/ci.yml` se déclenche à chaque push ou pull request vers `main`.
Il teste en parallèle sur **Python 3.11 et 3.12** grâce à une strategy matrix :
chaque run installe les dépendances (avec cache pip), vérifie le style avec **ruff**,
puis exécute les **7 tests pytest** avec rapport de couverture.

---

## Structure du projet

```
flask-cicd/
├── .github/
│   └── workflows/
│       └── ci.yml          # Pipeline GitHub Actions
├── app.py                  # Application Flask (3 routes)
├── test_app.py             # Tests pytest (7 tests)
├── ruff.toml               # Configuration du linter
├── requirements.txt        # Dépendances Python
└── .gitignore
```
