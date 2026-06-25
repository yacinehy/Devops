# Configuration des secrets GitHub Actions pour le déploiement SSH

Ce document explique comment créer une paire de clés SSH dédiée au CI/CD,
l'installer sur la VM, et configurer les secrets GitHub Actions correspondants.

> **Principe :** Le runner GitHub Actions se connecte à ta VM en SSH avec une clé
> privée stockée dans les secrets GitHub. La VM autorise uniquement cette clé,
> avec des droits limités au seul user `deploy`.

---

## ⚠️ Ce qu'il ne faut JAMAIS faire

```
❌ git add ~/.ssh/gh_actions_deploy          → committer une clé privée
❌ cat ~/.ssh/gh_actions_deploy              → afficher la clé privée dans un terminal partagé
❌ Mettre la clé privée dans un fichier .env → elle finirait dans les logs ou l'image Docker
❌ Réutiliser une clé SSH personnelle        → si elle fuite, tout ton accès SSH est compromis
❌ Créer la clé avec une passphrase en CI    → le runner ne peut pas taper de mot de passe
❌ chmod 777 sur .ssh ou authorized_keys     → SSH refusera la connexion (trop permissif)
❌ Partager les secrets GitHub entre projets → une clé = un projet = une VM
```

**Règle d'or :** une clé SSH CI/CD est à usage unique. Si elle fuite → révoquer immédiatement
(supprimer de `authorized_keys`), générer une nouvelle paire, mettre à jour les secrets GitHub.

---

## Étape 1 — Générer la paire de clés SSH sur ton Mac

```bash
# ed25519 : algorithme moderne, clé courte, très sécurisé
# -C      : commentaire pour identifier la clé dans authorized_keys
# -N ""   : pas de passphrase (le runner GitHub Actions ne peut pas en saisir une)
# -f      : chemin de la clé (nom explicite pour ne pas confondre avec tes clés perso)
ssh-keygen -t ed25519 \
            -C "github-actions-deploy" \
            -N "" \
            -f ~/.ssh/gh_actions_deploy
```

Deux fichiers sont créés :

```
~/.ssh/gh_actions_deploy      ← CLÉ PRIVÉE  — reste sur ton Mac + dans GitHub Secrets
~/.ssh/gh_actions_deploy.pub  ← CLÉ PUBLIQUE — va sur la VM dans authorized_keys
```

Vérifie les permissions (SSH refuse les clés trop accessibles) :

```bash
ls -la ~/.ssh/gh_actions_deploy*
# Attendu :
# -rw------- 1 yacine staff  411 ...  gh_actions_deploy      (600)
# -rw-r--r-- 1 yacine staff   97 ...  gh_actions_deploy.pub  (644)
```

---

## Étape 2 — Copier la clé publique sur la VM

```bash
# ssh-copy-id installe la clé publique dans ~/.ssh/authorized_keys sur la VM
# -i  : chemin vers la clé publique (le .pub — jamais la clé privée)
# -p  : port SSH (22 par défaut)
ssh-copy-id -i ~/.ssh/gh_actions_deploy.pub devops@192.168.252.2
```

Si `ssh-copy-id` n'est pas disponible, équivalent manuel :

```bash
# 1. Afficher la clé publique
cat ~/.ssh/gh_actions_deploy.pub

# 2. Se connecter à la VM avec TA clé personnelle (pas la nouvelle)
ssh devops@192.168.252.2

# 3. Sur la VM, coller la clé publique
mkdir -p ~/.ssh
echo "CONTENU_DE_LA_CLÉ_PUBLIQUE" >> ~/.ssh/authorized_keys
```

Tester que la connexion fonctionne avec la nouvelle clé :

```bash
ssh -i ~/.ssh/gh_actions_deploy devops@192.168.252.2 "echo '✅ Connexion SSH OK'"
```

---

## Étape 3 — Vérifier les permissions SSH sur la VM

SSH est strict sur les permissions : une erreur rend la clé inutilisable silencieusement.

```bash
# Se connecter à la VM
ssh devops@192.168.252.2

# Vérifier et corriger les permissions
chmod 700 ~/.ssh                    # rwx------  le dossier .ssh
chmod 600 ~/.ssh/authorized_keys    # rw-------  le fichier des clés autorisées
chmod 600 ~/.ssh/known_hosts 2>/dev/null || true

# Vérification
ls -la ~/.ssh/
# Attendu :
# drwx------ 2 devops devops  ...  .ssh/              (700) ✅
# -rw------- 1 devops devops  ...  authorized_keys    (600) ✅

# Vérifier que la clé est bien présente
grep "github-actions-deploy" ~/.ssh/authorized_keys
# Doit afficher la ligne de ta clé publique
```

---

## Étape 4 — Créer les secrets dans GitHub Actions

**Chemin :** ton dépôt GitHub → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Nom du secret | Valeur | Comment l'obtenir |
|---|---|---|
| `SSH_PRIVATE_KEY` | Contenu complet de `~/.ssh/gh_actions_deploy` | `cat ~/.ssh/gh_actions_deploy` |
| `SSH_HOST` | `192.168.252.2` | L'IP de ta VM |
| `SSH_USER` | `devops` | Le user de déploiement créé par `setup.sh` |
| `SSH_PORT` | `22` | Port SSH (22 par défaut, à changer si personnalisé) |

### Comment copier la clé privée exactement

```bash
# Affiche la clé privée dans le terminal — à copier intégralement
cat ~/.ssh/gh_actions_deploy
```

Le contenu doit ressembler à :

```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAABbmlsAAAAAAAAAA...
[plusieurs lignes]
...AAAAB3NzaC1lZDI1NTE5AAAA
-----END OPENSSH PRIVATE KEY-----
```

> **Important :** copier **tout** le contenu, header (`-----BEGIN`) et footer (`-----END`) inclus.
> GitHub stocke le secret tel quel — une ligne manquante rend la clé invalide.

---

## Étape 5 — Utiliser les secrets dans le workflow GitHub Actions

Exemple de step SSH dans `.github/workflows/docker.yml` (à ajouter après le job `scan`) :

```yaml
  deploy:
    runs-on: ubuntu-latest
    needs: scan

    steps:
      - name: Déploiement SSH sur la VM
        uses: appleboy/ssh-action@v1.0.3
        with:
          host:     ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key:      ${{ secrets.SSH_PRIVATE_KEY }}
          port:     ${{ secrets.SSH_PORT }}
          script: |
            cd /opt/devops-cicd
            export IMAGE_TAG=${{ github.sha }}
            bash deploy.sh
```

---

## Étape 6 — Restreindre la clé à une seule commande (sécurité avancée)

Par défaut, la clé CI/CD peut faire n'importe quelle commande SSH.
Pour la limiter strictement à `deploy.sh` :

```bash
# Sur la VM, éditer authorized_keys
nano ~/.ssh/authorized_keys
```

Préfixer la clé avec une restriction `command=` :

```
command="/opt/devops-cicd/deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... github-actions-deploy
```

Ainsi, même si la clé privée est compromise, l'attaquant ne peut exécuter
**que** `deploy.sh` — rien d'autre sur le serveur.

---

## Résumé des fichiers et leur emplacement

```
Sur ton Mac :
  ~/.ssh/gh_actions_deploy      → clé privée (ne jamais partager)
  ~/.ssh/gh_actions_deploy.pub  → clé publique (peut être partagée)

Sur la VM (192.168.252.2) :
  /home/devops/.ssh/             → permissions 700
  /home/devops/.ssh/authorized_keys → permissions 600, contient la clé publique

Dans GitHub Secrets :
  SSH_PRIVATE_KEY  → contenu de gh_actions_deploy
  SSH_HOST         → 192.168.252.2
  SSH_USER         → devops
  SSH_PORT         → 22
```
