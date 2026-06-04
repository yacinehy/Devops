# Guide de contribution

Ce document décrit le workflow Git à suivre pour contribuer au projet.
Toute contribution doit passer par une **Pull Request** avec la CI verte avant merge.

---

## Workflow Git pas à pas

### 1. Partir de main à jour

```bash
git checkout main
git pull origin main
```

Ne travaillez jamais directement sur `main` — cette branche est protégée.

### 2. Créer une branche dédiée

La branche doit décrire ce qu'elle fait. Utilisez l'un de ces préfixes :

| Préfixe | Quand l'utiliser |
|---------|-----------------|
| `feature/` | Nouvelle fonctionnalité |
| `fix/` | Correction de bug |
| `chore/` | Maintenance, mise à jour de dépendances |
| `docs/` | Documentation uniquement |

```bash
# Exemples
git checkout -b feature/add-status-route
git checkout -b fix/hello-default-name
git checkout -b docs/update-readme
```

### 3. Développer, committer souvent

```bash
# Vérifier le style avant chaque commit
ruff check .

# Vérifier que les tests passent
pytest --cov=app --cov-report=term-missing

# Committer avec un message clair
git add app.py test_app.py
git commit -m "feat: add /api/status route with version and uptime"
```

Convention de message : `type: description courte` (50 caractères max).
Types courants : `feat`, `fix`, `test`, `docs`, `chore`.

### 4. Pousser la branche et ouvrir une PR

```bash
git push origin feature/add-status-route
```

Puis sur GitHub :
1. Cliquer sur **"Compare & pull request"** (bandeau jaune)
2. Remplir le titre (= résumé de la feature)
3. Décrire les changements dans le corps : pourquoi, quoi, comment tester
4. Cliquer **"Create pull request"**

### 5. Attendre que la CI soit verte ✅

La pipeline GitHub Actions se déclenche automatiquement sur chaque PR.
Elle exécute en parallèle sur Python 3.11 et 3.12 :

```
CI  •  PR #7 — feature/add-status-route
├── test (3.11)  ✅
└── test (3.12)  ✅
```

**Règle absolue : la CI doit être entièrement verte avant tout merge.**
Si un job est rouge ❌, corriger le problème sur la même branche et repousser —
la CI se relance automatiquement.

### 6. Relecture et merge

- Au moins une revue de code approuvée (👍) est requise
- Utiliser **"Squash and merge"** pour garder un historique `main` lisible
- Supprimer la branche après merge (bouton "Delete branch")

---

## Ce qui fait échouer la CI

| Erreur | Step en rouge | Correction |
|--------|--------------|------------|
| Mauvais style (espaces, imports) | `Lint — ruff check` | `ruff check . --fix` |
| Test qui échoue | `Tests — pytest` | Corriger le code ou le test |
| Import manquant dans requirements.txt | `Installation des dépendances` | Ajouter le package |

---

## Commandes de vérification locale (avant push)

```bash
# Tout vérifier en une ligne
ruff check . && pytest --cov=app --cov-report=term-missing
```

Si cette commande passe en vert localement, la CI passera en vert sur GitHub.
