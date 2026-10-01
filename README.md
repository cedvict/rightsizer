# ResourceQuotaClaim Rightsizer v3

Règle : `used + 5%` est appliqué uniquement si cette valeur est strictement
inférieure à la valeur actuelle du ResourceQuotaClaim. Le script ne fait donc
jamais d'augmentation automatique.

CPU et mémoire sont évalués indépendamment.

Formats CPU supportés : `10`, `1`, `0.5`, `1000m`, `500m`.
Le CPU est normalisé en millicores avant comparaison.

Formats mémoire supportés : `Ki`, `Mi`, `Gi`, `Ti`.
La mémoire est normalisée en Mi avant comparaison (`1Gi = 1024Mi`).

Le script :
1. lit la liste des namespaces ;
2. sauvegarde chaque `kubectl get resourcequota -o json` dans un fichier temporaire ;
3. valide le JSON avec `jq empty` ;
4. ignore un namespace dont `.items` est vide ;
5. lit le claim `managed-quota` par défaut ;
6. ne mélange pas stderr de kubectl avec le JSON envoyé à jq ;
7. calcule et valide toutes les cibles ;
8. bloque toute application si une vraie erreur d'évaluation existe ;
9. applique seulement les claims réellement réductibles.

Les anciens contrôles incorrects `jq ... | grep true` ont été supprimés.

Le script évite les redirections de fichiers `>`, `>>`, `<` et `<<<`.
Il utilise des pipes et `tee`.

Simulation recommandée :

    DRY_RUN=true ./resourcequota-rightsizer.sh namespaces.txt

Le dry run produit `rightsizer-changes.tsv` dans le répertoire courant.
Ce fichier TSV contient uniquement les claims réductibles : namespace, nom du
claim, consommation, valeurs actuelles, valeurs cibles et indicateurs de réduction
CPU/mémoire. Il peut être ouvert dans un tableur. Sans changement applicable, il
contient seulement l'en-tête. Une erreur d'évaluation empêche sa génération.
Un rapport existant au même chemin est remplacé après une évaluation réussie.

Choisir le chemin du rapport :

    DRY_RUN=true DRY_RUN_FILE=/tmp/changements.tsv ./resourcequota-rightsizer.sh namespaces.txt

Application :

    ./resourcequota-rightsizer.sh namespaces.txt

Changer la marge :

    MARGIN_PERCENT=10 ./resourcequota-rightsizer.sh namespaces.txt

Changer le claim :

    CLAIM_NAME=mon-claim ./resourcequota-rightsizer.sh namespaces.txt
