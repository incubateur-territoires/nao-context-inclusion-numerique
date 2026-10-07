# 02 — Data contracts (contrats de schéma avec les sources)

← [Retour au document central](README.md)

## Le concept

Un **data contract** formalise l'accord entre un producteur de données (carto, coop,
aidants-connect…) et son consommateur (notre pipeline). Il décrit, dans un fichier versionné :

- le **schéma** : colonnes/champs, types, nullabilité
- la **sémantique** : signification de chaque champ, valeurs autorisées (enums)
- les **garanties** : unicité des clés, fraîcheur attendue, volumétrie approximative
- le **versionnement** : comment les changements sont annoncés et gérés

Deux modes d'application :

1. **Contrat subi** (notre cas majoritaire) : on ne contrôle pas les sources ; le contrat
   sert de **détecteur de drift** — on documente ce qu'on attend et on alerte quand la
   réalité s'en écarte.
2. **Contrat négocié** : quand une relation existe avec l'équipe source (beta.gouv inter-SE,
   c'est possible !), le contrat devient un engagement bilatéral et les changements sont
   annoncés en amont.

## Pourquoi c'est critique ici

Le pipeline consomme des APIs et exports qu'il ne maîtrise pas. Aujourd'hui :

- Le schéma attendu de chaque source n'est **décrit nulle part** — il est implicite dans le
  code de `etl/transform/ingest/` (renommages de colonnes, parsing).
- Un champ renommé côté source → `KeyError` en prod (le cas favorable) ou colonne
  silencieusement NULL (le cas grave : cf. l'incident `is_visible` lu au mauvais endroit,
  où 24 835 personnes ont eu leur visibilité ignorée pendant des mois **sans aucune erreur**).
- Un changement de sémantique (une source change le sens d'un statut) est indétectable.

Le drift silencieux est le pire risque d'un pipeline multi-sources : il ne casse rien,
il fausse tout.

## Mise en place sur ce projet

### 1. Un contrat par flux, en YAML versionné

```yaml
# contracts/coop__personnes.yml
source: coop
dataset: personnes
endpoint: /api/personnes           # documentation, pas exécution
primary_key: [id]
freshness_sla: 24h                 # exploité par la fiche 06
expected_volume: {min: 20000, max: 60000}
fields:
  - name: id
    type: string
    required: true
  - name: attributes.mediateur.is_visible   # chemin JSON explicite = le bug is_visible
    type: boolean                           #   aurait été un échec de contrat, pas un
    required: false                         #   incident silencieux de plusieurs mois
  - name: attributes.statut
    type: string
    enum: [actif, inactif, suspendu]
policy:
  on_missing_field: fail        # champ requis absent → échec de l'extract
  on_new_field: warn            # nouveau champ → alerte (opportunité, pas erreur)
  on_type_change: fail
  on_enum_violation: quarantine # → fiche 03
```

### 2. Validation à la frontière (extract)

Le contrat est vérifié **au moment de la capture**, entre la source et la couche bronze,
dans une tâche Airflow dédiée par flux :

```
extract ──► valider_contrat ──► écrire en source.* ──► staging...
                 │
                 └─► échec/warn → alerte Mattermost + le DAG s'arrête AVANT d'écrire en aval
```

Implémentation pragmatique : `pandera` (si on reste en pandas) ou une validation jsonschema
sur les payloads. Pas besoin d'un framework lourd — la valeur est dans le fichier de contrat
et le fait que la vérification soit **systématique et bloquante**, pas dans l'outil.

### 3. Le contrat comme documentation vivante

Le YAML est la **seule** description de ce qu'on attend de chaque source :

- Un nouveau dev comprend un flux en lisant son contrat, pas en décryptant `ingest/`.
- Les échanges avec les équipes sources s'appuient dessus ("voici ce qu'on consomme,
  prévenez-nous si ça bouge").
- Le dictionnaire de données (fiche 07) se génère en partie depuis les contrats.

### 4. Gestion des évolutions

- Contrat modifié = MR revue, avec entrée `CHANGELOG.md` — le drift accepté est tracé.
- Champ ajouté par la source : `warn` d'abord ; l'intégrer est une décision, pas un réflexe.
- Breaking change source : le contrat garde l'ancienne et la nouvelle version le temps de
  la transition (`fields_v2`), le code d'ingest gère les deux, puis on nettoie.

## Par où commencer

1. Écrire le contrat des **flux déjà existants**, par rétro-ingénierie de `etl/transform/ingest/`
   — exercice très rentable : il révèle systématiquement des hypothèses implicites et des
   champs morts.
2. Brancher la validation en mode **warn-only** deux semaines (observer le bruit réel).
3. Passer en mode bloquant flux par flux.

## Pièges connus

- **Contrat trop strict d'emblée** : mode `fail` sur tout → DAGs rouges en permanence →
  contrats désactivés → retour case départ. Commencer permissif, durcir progressivement.
- **Contrat non maintenu** : s'il diverge du code, il devient pire qu'inutile (fausse
  confiance). D'où l'importance de la validation *exécutée* — un contrat vérifié à chaque
  run ne peut pas pourrir.
- **Confondre contrat et test qualité** : le contrat vérifie la *forme* de ce que la source
  envoie ; les tests qualité (fiche 03) vérifient le *fond* de ce que nous produisons.

## Références

- Andrew Jones — *Driving Data Quality with Data Contracts*
- Open Data Contract Standard (ODCS) — format YAML standardisé si on veut s'aligner
- `pandera` (validation de DataFrames), `jsonschema`
