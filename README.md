# ResourceQuotaClaim Rightsizer

Le ResourceQuota est la seule source de vérité. Le script lit `status.used`
(consommation des quotas) et `spec.hard` (plafonds actuels), sans lire de
ResourceQuotaClaim. Il calcule `used + MARGIN_PERCENT` et réduit uniquement les
valeurs strictement inférieures aux plafonds. CPU et mémoire sont indépendants ;
une dimension non réductible conserve son plafond actuel.

Les clés sélectionnées dans `spec.hard` sont `requests.cpu` et `requests.memory`
en priorité, sinon `cpu` et `memory`. Les mêmes clés sont lues dans `status.used`.
Une valeur absente ou invalide n'est jamais assimilée à zéro.

## Simulation et fichiers générés

```bash
DRY_RUN=true ./resourcequota-rightsizer.sh namespaces.txt
```

À la fin de l'évaluation, en simulation comme en application, le script génère
ces trois fichiers dans le répertoire courant et affiche leurs chemins absolus :

- `rightsizer-changes.tsv` : changements applicables des namespaces évalués,
  avec consommation, plafonds actuels, cibles CPU/mémoire et gains prévus ;
- `rightsizer-claims.json` : liste JSON des ResourceQuotaClaim générés ;
- `rightsizer-errors.log` : erreurs par namespace, notamment les refus d'accès.
  Vide si toute l'évaluation a réussi.

Les namespaces sans ResourceQuota sont ignorés. Les namespaces inaccessibles,
les quotas multiples et les données invalides sont signalés dans le journal,
puis l'évaluation continue sur les autres namespaces. Les doublons sont ignorés.

**Une évaluation partielle produit quand même les trois fichiers**, mais termine
avec le code `2` et n'applique aucun claim. Les manifests partiels contiennent
uniquement les changements des namespaces évalués : ils ne constituent pas un
plan complet. Sans changement applicable, le TSV contient seulement l'en-tête
et le JSON une liste vide. Les fichiers existants sont remplacés à chaque export,
et le journal est vidé lors d'une évaluation sans erreur.

Une erreur de configuration, une dépendance manquante ou un échec d'écriture
peut empêcher l'export ; le script affiche alors une erreur explicite.

Chemins personnalisés (les répertoires parents sont créés si nécessaire) :

```bash
DRY_RUN=true \
DRY_RUN_FILE=./rapports/changements.tsv \
MANIFEST_FILE=./rapports/claims.json \
ERROR_REPORT_FILE=./rapports/erreurs.log \
./resourcequota-rightsizer.sh namespaces.txt
```

## Gains de quota

Le TSV contient, pour chaque changement, `GAIN_CPU_M` (millicores),
`GAIN_MEMORY_MI` (Mi), `GAIN_CPU_PERCENT` et `GAIN_MEMORY_PERCENT`.
Chaque gain vaut le plafond ResourceQuota actuel moins la cible retenue.
Une dimension inchangée a un gain nul.

Le script affiche aussi le total CPU (millicores et cores), le total mémoire
(Mi et Gi) et les pourcentages rapportés à la somme des plafonds de tous les
namespaces évalués, y compris ceux sans réduction. Les namespaces sans quota
ou en erreur sont exclus des totaux. Une évaluation partielle est signalée.

Exemple : passer de `2` CPU à `1050m` et de `2Gi` à `1076Mi` libère
`950m` CPU (47,50 %) et `972Mi` mémoire (47,46 %).

Ces gains sont des **réductions de quota prévues**, pas des mesures d'économie
réelle de CPU ou RAM. En dry run, aucune ressource n'est modifiée. Après
application, le résultat effectif dépend de la réconciliation par le contrôleur.

## Application

```bash
./resourcequota-rightsizer.sh namespaces.txt
```

Après l'évaluation et la génération du plan, si aucune erreur n'existe et qu'au
moins un changement est applicable, le script exécute `kubectl apply -f` sur le
plan temporaire généré. Le nom des claims est `managed-quota` par défaut.
L'application crée ou met à jour les claims ; leur contrôleur réconcilie les
ResourceQuota. L'application de plusieurs claims n'est pas atomique.

Un plan complet issu du dry run peut également être appliqué manuellement :

```bash
kubectl apply -f rightsizer-claims.json
```

## Configuration et prérequis

Bash (y compris Bash 3.2 de macOS), `kubectl`, `jq`, `awk`, `sed` et `tee`.
Le contexte kubectl courant est utilisé. Aucun accès au cluster n'est effectué
par les tests locaux.

| Variable | Défaut | Description |
| --- | --- | --- |
| `DRY_RUN` | `false` | `true` pour simuler ; seules ces deux valeurs sont acceptées |
| `MARGIN_PERCENT` | `5` | Marge positive ou nulle, décimale acceptée |
| `CLAIM_NAME` | `managed-quota` | Nom des claims générés |
| `REQUEST_TIMEOUT` | `30s` | Délai maximal par lecture kubectl |
| `DRY_RUN_FILE` | `rightsizer-changes.tsv` | Rapport des changements |
| `MANIFEST_FILE` | `rightsizer-claims.json` | Manifests générés |
| `ERROR_REPORT_FILE` | `rightsizer-errors.log` | Journal des erreurs |

CPU : nombres de cores (`1`, `0.5`) ou millicores (`500m`).
Mémoire : octets sans suffixe (dont `0`), `Ki`, `Mi`, `Gi`, `Ti`, décimales
acceptées. La comparaison utilise les octets ; la cible est arrondie au Mi
supérieur après ajout de la marge. La cible CPU est arrondie au millicore
supérieur. Les cibles minimales sont `1m` et `1Mi`, mais ne sont retenues que si
elles réduisent le plafond existant, y compris lorsque celui-ci vaut zéro.
Les autres formats sont signalés comme non supportés.

Codes retour : `0` = évaluation complète et succès ; `2` = évaluation partielle,
fichiers générés et application bloquée ; autre code non nul = échec de
configuration, d'export ou d'application.

## Vérification

```bash
bash -n resourcequota-rightsizer.sh
shellcheck resourcequota-rightsizer.sh
python3 -B -m unittest discover -s tests -v
```
