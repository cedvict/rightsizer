# ResourceQuotaClaim Rightsizer v3

Règle : `used + 5%` est appliqué uniquement si cette valeur est strictement
inférieure au plafond actuel (`spec.hard`) du ResourceQuota. Le script ne fait donc
jamais d'augmentation automatique.

CPU et mémoire sont évalués indépendamment.

Les valeurs utilisées proviennent du `status.used` du ResourceQuota :
Les clés sont sélectionnées dans `spec.hard` : `requests.cpu` et
`requests.memory` en priorité, sinon `cpu` et `memory`. Les mêmes clés
sont lues dans `status.used` pour comparer des valeurs cohérentes.
Une valeur absente bloque l'évaluation ; elle n'est pas assimilée à zéro.

Formats CPU supportés : `10`, `1`, `0.5`, `1000m`, `500m`.
Le CPU est normalisé en millicores avant comparaison.

Formats mémoire supportés : `Ki`, `Mi`, `Gi`, `Ti`, ainsi que `0` sans unité.
La mémoire est normalisée en Mi avant comparaison (`1Gi = 1024Mi`).

Le script :
1. lit la liste des namespaces ;
2. sauvegarde chaque `kubectl get resourcequota -o json` dans un fichier temporaire ;
3. valide le JSON avec `jq empty` ;
4. ignore un namespace dont `.items` est vide ;
5. lit les plafonds `spec.hard` du ResourceQuota, sans lire de ResourceQuotaClaim ;
6. ne mélange pas stderr de kubectl avec le JSON envoyé à jq ;
7. calcule et valide toutes les cibles ;
8. bloque toute application si une vraie erreur d'évaluation existe ;
9. génère tous les ResourceQuotaClaim réductibles, puis les applique à la fin.

Le nom des claims générés est `managed-quota` par défaut. Une dimension non
réductible conserve le plafond du ResourceQuota.

Les anciens contrôles incorrects `jq ... | grep true` ont été supprimés.

Le script évite les redirections de fichiers `>`, `>>`, `<` et `<<<`.
Il utilise des pipes et `tee`.

Simulation recommandée :

    DRY_RUN=true ./resourcequota-rightsizer.sh namespaces.txt

Chaque exécution réussie produit `rightsizer-changes.tsv` dans le répertoire
courant (celui depuis lequel la commande est lancée), en simulation comme en
application. Le script affiche les chemins absolus des deux fichiers générés.
Ce fichier TSV contient uniquement les claims réductibles : namespace, nom du
claim, consommation, plafonds actuels du ResourceQuota, valeurs cibles et indicateurs de réduction
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

Le script génère aussi `rightsizer-claims.json`, une liste de manifests
ResourceQuotaClaim applicable avec `kubectl apply -f rightsizer-claims.json`.
Le chemin se configure avec `MANIFEST_FILE`. Sans changement, la liste est vide.
Les deux fichiers ne sont générés qu’après une évaluation réussie.

Vérification locale sans accès à un cluster (kubectl simulé) :

    python3 -B -m unittest discover -s tests -v
