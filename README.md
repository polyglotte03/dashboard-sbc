# Dashboard SBC — installation

Ce dossier contient tout ce qu'il faut pour publier le dashboard **et** le
maintenir à jour automatiquement chaque jour, sans serveur à gérer.

## Structure

```
docs/index.html              -> la page du dashboard (statique)
docs/data/signals.json       -> les données (regénérées chaque jour)
scripts/export_dashboard.R   -> extraction DHIS2 + export JSON
.github/workflows/refresh.yml -> planification quotidienne (GitHub Actions)
```

## Mise en place (une seule fois)

1. **Créer un dépôt GitHub** (public ou privé — les deux fonctionnent avec
   GitHub Pages, un dépôt privé nécessite un compte payant pour Pages sur
   certains plans).

2. **Copier tout ce dossier** dans le dépôt (avec `git add`, `git commit`,
   `git push`), en conservant l'arborescence ci-dessus.

3. **Ajouter les identifiants DHIS2 en secrets** (jamais en clair dans le
   code) : dans le dépôt GitHub → *Settings* → *Secrets and variables* →
   *Actions* → *New repository secret* :
   - `DHIS_USER` = `DLMEP-SDLEP`
   - `DHIS_PASS` = le mot de passe DHIS2

   Retirez ensuite le nom d'utilisateur/mot de passe en dur du script si
   vous en avez une copie ailleurs.

4. **Activer GitHub Pages** : *Settings* → *Pages* → *Source* : `Deploy from
   a branch` → branche `main`, dossier `/docs`. GitHub vous donne alors une
   URL du type `https://<votre-compte>.github.io/<votre-depot>/`.

5. **Lancer le premier rafraîchissement manuellement** : onglet *Actions* →
   *Actualisation quotidienne du dashboard SBC* → *Run workflow*. Une fois
   terminé, `docs/data/signals.json` est mis à jour et poussé automatiquement.

Ensuite, tout est automatique : chaque jour à 6h (heure du Cameroun), le
robot se connecte à DHIS2, régénère `signals.json`, et le dashboard reflète
les nouvelles données à la prochaine ouverture de la page (pas besoin de
republier — la page va chercher le fichier à chaque chargement).

## Changer la fréquence

Dans `.github/workflows/refresh.yml`, la ligne `cron: '0 5 * * *'` définit
l'horaire (en UTC). Exemples :
- Toutes les 6 heures : `0 */6 * * *`
- Deux fois par jour (6h et 18h heure Cameroun) : `0 5,17 * * *`

## Sécurité

Les identifiants DHIS2 ne sont jamais exposés dans `docs/index.html` (qui
tourne dans le navigateur de n'importe quel visiteur) — ils restent
uniquement dans les secrets GitHub, utilisés côté serveur par le script R.
