# Questions métier en cours

Liste des questions identifiées pendant la rédaction de la documentation
métier des sources de données du dataspace, à clarifier avec l'équipe
métier (notamment Kevin, PO).

**Cycle de vie** : mise à jour en continu. Quand une question est résolue,
sa réponse est intégrée dans la doc concernée (`docs/<source>.md`) et
l'entrée est retirée d'ici. Quand toutes les questions sont closes, le
fichier est supprimé.

**Lecture pour les répondants** : chaque question est auto-portante
(contexte + question + référence code). Pas besoin de relire la session
qui l'a produite.

---

## Coop (`coop-import`)

### Q1 — Coordinateurs forcés en médiateurs (`force_coordinators_to_mediators`)

Dans le DAG `coop-import`, une tâche SQL `force_coordinators_to_mediators`
lancée après l'ingest des utilisateurs met `is_mediateur = TRUE` pour
toutes les personnes ayant `is_coordinateur = TRUE AND is_mediateur = FALSE`
(`coop-dag.py:1584-1599`).

**Question** : c'est une règle métier voulue (un coordinateur exerce
de fait l'activité de médiateur, donc même si l'API le renvoie non-médiateur
on l'override côté ETL), ou un palliatif technique (l'API renvoie parfois
`is_mediateur = false` à tort, à corriger côté API) ?

Selon la réponse : soit on garde la règle explicite côté ETL et on la
documente comme telle, soit on remonte le bug API et on supprime la règle.

### Q2 — Endpoints non importés (`archives-v1/cras`, `statistiques`)

L'API Coop expose 7 endpoints (vérifié via `https://coop-numerique.anct.gouv.fr/api/v1/openapi`).
Le dataspace en importe 3 : `/structures`, `/utilisateurs`, `/activites`.

Les endpoints `/api/v1/archives-v1/cras` et `/api/v1/statistiques` ne
sont pas importés. C'est volontaire (pas pertinent pour le dataspace,
ou information dérivable d'autres endpoints) ou un trou à combler ?

### Q3 — `mediateurs_en_activite` insertable mais pas updaté

La colonne `mediateurs_en_activite` est dans le INSERT incoming des
structures Coop (`coop-dag.py:1215`, branche `ins`), mais n'apparaît pas dans la liste
des champs UPDATE côté `up_by_coop` / `up_by_ukey` du CTE
(`coop-dag.py:1144-1203`).

**Question** : oubli ou décision explicite de ne pas mettre à jour ce
champ après création (ex : une autre source d'autorité prime) ?

### Q4 — Branche `up_by_ukey` adopte `structure_coop_id`

Quand `structure_ingest` matche par clé naturelle (`siret + LOWER(nom) + adresse_id`)
une ligne sans `structure_coop_id` (typiquement créée par `schema-idPoste`),
la branche `up_by_ukey` adopte le `structure_coop_id` incoming via
`COALESCE(s.structure_coop_id, inc.structure_coop_id)` (`coop-dag.py:1170-1203`).

**Question** : décision métier explicite (les unifier après reconnaissance
manuelle ?) ou effet de bord constaté et conservé pour éviter les doublons ?

### Q20 — Catégories `TEXT[]` jamais updatées sur `up_by_coop` / `up_by_ukey`

Sur `main.structure`, six catégories `TEXT[]` sont **insérées** côté Coop (branche `ins`) mais **jamais updatées** par les CTE `up_by_coop` / `up_by_ukey` :
- `prise_en_charge_specifique`
- `frais_a_charge`
- `formations_labels`
- `autres_formations_labels`
- `itinerance`
- `modalites_acces`

À l'inverse, six autres catégories du même type (`typologies`, `services`, `publics_specifiquement_adresses`, `dispositif_programmes_nationaux`, `modalites_accompagnement`) sont updatées sous garde temporelle (`coop-dag.py` recherche `up_by_coop AS`, SET clauses).

**Question** : asymétrie volontaire (ex : ces catégories ont une sémantique "admin uniquement", mises à jour hors API Coop) ou oubli historique au moment d'écrire les CTE ?

### Q21 — `horaires` et `prise_rdv` insérés mais jamais mis à jour

Sur `main.structure`, `horaires` (TEXT) et `prise_rdv` (TEXT) sont **insérés** par Coop mais **jamais updatés** ensuite (absents des SET de `up_by_coop` / `up_by_ukey`).

**Question** : c'est précisément le type de donnée qui change (extension d'amplitude, fermeture estivale, changement de modalité de RDV). Est-ce un oubli ou une décision (autre source d'autorité) ? Si oubli, l'update sous garde temporelle paraît trivial à ajouter.

### Q5 — Exhaustivité des 27 colonnes incoming structures

Le CSV intermédiaire produit par `enrich_structures_batch` contient 27 colonnes
(siret, rna, nom, code_activite_principale, adresse_id, structure_coop_id,
etat_administratif, categorie_juridique, denomination_sirene, typologies,
presentation_resume, presentation_detail, contact, horaires, prise_rdv,
services, publics_specifiquement_adresses, prise_en_charge_specifique,
frais_a_charge, dispositif_programmes_nationaux, formations_labels,
autres_formations_labels, itinerance, modalites_acces, modalites_accompagnement,
mediateurs_en_activite, emplois).

Pas de transformation explicite dans `_transform_data` côté `coop_structures`
(`http_airflow.py`) — les colonnes viennent directement des `attributes.<champ>`
JSON Coop.

**Question** : ces 27 colonnes couvrent-elles toute la donnée métier
que vous voulez exposer côté dataspace ? Y a-t-il des champs critiques
(ex: `frais_a_charge`, `formations_labels`, `prise_en_charge_specifique`)
à souligner pour la doc ?

---

## Conseillers Numériques (`schema-idPoste`)

### Q6 — Pourquoi `reset_dag_run=True` sur les triggers de réconciliation ?

Les triggers vers `structures-similarities-merge` et `personne-similarities-merge`
passent `reset_dag_run=True` (`schema-idPoste.py:1185, 1190` ; wiring lignes
1216-1217). Comportement : si une exécution avec la même `logical_date` existe
déjà pour le DAG cible, elle est supprimée et rejouée. Effet : perte de
l'historique du run précédent si on rejoue par erreur.

**Question** : voulu (rejouer proprement à chaque schema-idPoste, qui ne
tourne que toutes les 2 semaines) ou copié-collé d'un autre DAG sans
intention claire ?

Concerne aussi `carto-dag-import` qui utilise le même flag.

---

## Cartographie nationale (`carto-dag-import`)

### Q7 — Orphelinage temporaire `import.carto.structure_id`

Après UPDATE/INSERT en `main.structure`, chaque `import.carto` est reliée
à sa structure résultante via FK `structure_id` (ON DELETE SET NULL,
migration `V060_20260413__add_structure_id_to_import_carto.sql`). Si un merge aval (`structures-similarities-merge`)
supprime un loser, la FK passe à NULL et est recréée au run suivant.

**Question** : c'est intentionnel (lien diagnostique seulement, on accepte
l'orphelinage temporaire) ou à corriger ?

### Q8 — Pourquoi désassocier Paca/Paris à chaque run ?

`delete_paca_paris_ids` (`carto-dag-import.py:619-635`) désactive
`structure_cartographie_nationale_id` et met
`visible_pour_cartographie_nationale = FALSE` pour les structures
sources Paca/Paris **encore visibles avec carto_id** à chaque run
(filtre SQL : `source IN ('Paca','Paris') AND visible_pour_cartographie_nationale IS TRUE AND structure_cartographie_nationale_id IS NOT NULL`).
Ré-association au run suivant si présents dans la source mednum-cli.

**Question** : conflit de source (données locales prioritaires sur la
cartographie nationale) ? Comment décide-t-on qu'ils sont "dans la source"
mednum-cli au run suivant ?

### Q9 — Contrat des transformers mednum-cli

Le DAG lit dynamiquement `package.json` pour découvrir les commandes
`transformer.*` à exécuter dans mednum-cli (`carto-dag-import.py:50-62`).

**Question** : qui ajoute / maintient ces transformers côté mednum-cli ?
Faut-il documenter le contrat (noms attendus, schéma CSV de sortie) pour
éviter qu'un nouveau transformer casse l'ingest dataspace ?

### Q18 — Divergence regex `ban_numero` Python vs SQL

Le parsing `"33bis" → (33, "bis")` est fait à deux endroits qui ne sont pas
strictement alignés :

- Python à l'ingest dans `import.carto`
  (`load_to_postgresql.py:172-179`) : regex
  `^(\d+)\s*(bis|ter|quater|quinquies|[a-zA-Z])?$` — accepte un suffixe
  d'**une lettre quelconque** en plus du set explicite.
- SQL `integration_adresses` (`carto-dag-import.py:311`) et `_match`
  (`carto-dag-import.py:450`) : regex
  `^(\d+)\s*(bis|ter|quater|quinquies)?\s+(.*)$` — limité au set fermé.

**Question** : la divergence est-elle volontaire (couverture plus large à
l'ingest pour ne pas perdre `123A`) ou un oubli ? Si volontaire, le suffixe
à une lettre stocké côté `import.carto.ban_repetition` ne sera pas matché
par le fallback SQL `_match` (la lookup `repetition` côté `main.adresse`
échouera). À aligner ou documenter explicitement.

---

## Aidants Connect (`aidants-connect-import`)

### Q10 — Périmètre `/fne_organisations/`

`GET /api/DfHGbvUGCHQD/fne_organisations/` retourne-t-il **toutes** les structures
Aidants Connect (labellisées + en cours + désactivées) ou uniquement les habilitées
actives ? Faut-il un filtre côté ETL ?

### Q11 — Cohérence `updated_at__gte` sur `/fne_aidants/`

Le filtre incrémental `?updated_at__gte=<ISO8601>` sur `/fne_aidants/` remonte-t-il
les aidants modifiés ET les structures liées modifiées dans la même fenêtre, ou
faut-il deux fetchs distincts pour garantir la cohérence ?

### Q12 — Champs `city_insee_code` parfois absent ?

Le DAG dérive `code_insee` depuis (`code_postal`, `nom_commune`) via
`admin.insee_cp × admin.commune` quand l'API n'a pas fourni `city_insee_code`
(`aidants-connect-dag.py:74-129`, fix `2474f9c`).

**Question** : `city_insee_code` est-il systématiquement absent dans certains cas
(lacune côté Aidants Connect à corriger), ou cas métier légitime (structures sans
adresse stable) ?

### Q13 — `deleted_at` côté DB

Quand `is_active_ac = FALSE`, on positionne `deleted_at = updated_at_ac` côté
`main.structure` (timestamp API — `etl/load/aidants_connect.py:405-408` à
l'INSERT, `:515-520` à l'UPDATE CTE). Préférable `now()` côté Airflow (heure
de réception) pour distinguer "désactivé côté API à telle date" vs
"désactivé en base à telle date" ?

> Note : `ingest_utilisateurs` ne touche pas `deleted_at`/`deleted_by` côté
> `main.personne` — la désactivation d'un aidant passe uniquement par
> `est_active = FALSE` côté `main.personne_affectations` (post-V043).

---

## Schéma cible `main.structure` (cross-source — équipe technique)

> Ces questions touchent au modèle DB partagé entre les 4 sources. Audience tech d'abord (besoin de connaître le schéma cible). Kevin / PO peut lire pour comprendre, mais la décision est tech-side ou produit-tech.

### Q14 — Colonne `contact` JSONB encore utilisée ou dépréciée ?

La migration V047 (2026-02-26) a créé `main.contact` + `main.contact_structure`
pour migrer le contenu jusque-là stocké dans `main.structure.contact` (JSONB).
La colonne `main.structure.contact` existe toujours en base.

**Question** : la colonne est-elle dépréciée (les 4 DAGs devraient arrêter
d'y écrire) ou cohabite-t-elle avec les nouvelles tables ?

Si dépréciée : confirmer côté Coop, schema-idPoste, Aidants Connect, Carto que
les inserts/updates n'alimentent plus cette colonne (ou planifier le drop).

### Q19 — Harmoniser la stratégie de fraîcheur SIRENE entre les 4 DAGs ?

> L'ancienne Q15 (qui posait `last_sirene_enrich_at`) a été résolue, synthèse
> intégrée à [`enrichissement-sirene-ban.md`](enrichissement-sirene-ban.md)
> §"Champ `last_sirene_enrich_at`". Q19 (ex Q15 bis) reste ouverte sur l'harmonisation.

schema-idPoste et Carto enrichissent systématiquement (toute la donnée à chaque run). Coop et AC utilisent un cutoff 4 mois. Décision : conserver l'asymétrie (volumes différents : carto = TRUNCATE complet ; idposte = lot CoNum modeste) ou aligner ?

### Q16 — Champs `publique` et `fiche_acces_libre` — qui les alimente ?

Sur `main.structure` :
- `publique BOOLEAN` — vu écrit par schema-idPoste (depuis colonne CSV "publique/privée")
- `fiche_acces_libre VARCHAR` — vu côté schéma incoming Cartographie

**Question** : les autres sources (Coop, Aidants Connect) ne les remplissent
pas. C'est correct (ces champs ont une sémantique propre à une source) ou
c'est un trou (information disponible côté API mais ignorée à l'ingest) ?

---

## Notes pour amélioration / refactoring (équipe technique, pas Kevin)

### Q17 — Régénération MCD.svg et data_dict.md

`database/MCD.svg` et `database/data_dict.md` ont été ajoutés sur `main` au
commit `27683c9` ("Documentation de la base de données", 2026-03-13). Ils
constituent la meilleure source de vérité pour le schéma de la base. **Mais** :
- Pas à jour : ne reflètent pas les migrations postérieures à fin mars 2026
  (V057 `is_referent_ac`, V058_20260402 `updated_at_ac`, V062 `is_visible`,
  V064 `updated_at_coop`/`updated_at_idposte`, V059 trigger updated_at,
  V060 FK `import.carto.structure_id`, V061/V063 vues API carto).
- Pas de script de régénération trouvé dans le repo (probablement maintenus
  manuellement via DbSchema, DBeaver, ou outil ERD similaire — auteur :
  Romain MAZIÈRE selon `git log -1 27683c9`).

**Question / décision à prendre** :
- Qui maintient ces fichiers ? Quelle cadence ?
- Faut-il automatiser la régénération (script `scripts-dev/dump-schema.sh`
  + job CI à chaque merge en prod, ou cron hebdo) ?

Sans automatisation, ces fichiers vont continuer à dériver et la doc qui
y pointe (`docs/coop.md` § "Schéma cible") devra rappeler la fraîcheur à
chaque consultation.

### Autres améliorations

- **Versions non-tech des docs sources** : les `docs/<source>.md` actuelles
  (`coop.md`, `cartographie-nationale.md`, `conseillers-numeriques.md`,
  `aidants-connect.md`) sont **techniques** (jargon SQL, noms de fonctions,
  noms de tables internes). À créer en parallèle : `docs/<source>-metier.md`,
  versions reformulées sans jargon, lisibles par PO / partenaires / équipe
  métier. Même pattern que `CHANGELOG.md` / `CHANGELOG-metier.md`.
- **Fail-fast SIRENE token — asymétrie à harmoniser** : Coop (`coop-dag.py:299`)
  et Aidants Connect (`aidants-connect-dag.py:373`) skippent silencieusement si
  `API_SIRENE_TOKEN` absent (warning seulement). schema-idPoste
  (`schema-idPoste.py:137`) et Carto (`carto-dag-import.py:103`) lèvent
  `KeyError` immédiatement (déjà fail-fast). Décision : aligner les 4 DAGs
  sur fail-fast (recommandé pour lisibilité opérationnelle — un DAG qui crashe
  est plus clair qu'un DAG qui semble réussir avec données partielles), ou
  conserver l'asymétrie et la documenter explicitement.
- **Working_dir statiques** : tous les DAGs utilisent un chemin hardcodé
  (`/tmp/tmp.coop`, `/tmp/tmp.aidants-connect`, `/tmp/tmp.4ger4ger8`,
  `/tmp/tmp.8EE4C22C`). Pas de collision inter-DAGs (chemins distincts) mais
  risque si deux runs concurrents du même DAG. À rendre dynamique (ex:
  `{{ dag_run.id }}`).
- **Double parsing `ban_numero`** dans `carto-dag-import` : extraction
  `"33bis" → (33, "bis")` faite en Python (`load_to_postgresql.py:172-179`) ET en
  SQL dans `integration_adresses`. Une seule devrait suffire — sûrement une
  erreur historique.

## Notes pour doc transverse (philosophie cross-source)

Validé par Adrien : **chaque source de données gère ses entités à sa façon**, pas
de modèle unifié forcé. Exemples :

- Pas de `siret` pour les lieux de la cartographie nationale est normal (1 lieu
  n'est pas forcément 1=1 avec un établissement).
- Coop a la distinction médiateur/coordinateur (deux rôles dans son API), pas
  CoNum (un seul rôle = conseiller numérique = médiateur).
- Aidants Connect utilise `aidant_connect_id` (entier), Coop utilise UUID, CoNum
  utilise `id_pg` (entier) et `conseiller_numerique_id` (UUID).

### Tableau cross-source `main.personne_affectations`

Clé d'unicité = `(structure_id, personne_id, type, source)`. Une même paire
(personne, structure) peut avoir jusqu'à 4 affectations distinctes :

| Source | `type` | `source` | Quand |
|---|---|---|---|
| Coop | `lieu_activite` | `coop` | Toujours quand utilisateur Coop a `mediateur.en_activite` |
| Coop | `structure_emploi` | `coop` | Uniquement si `cn_pg_id IS NULL OR conseiller_numerique_id IS NULL` (= pas pleinement identifié CoNum, `http_airflow.py:702`) |
| schema-idPoste | `structure_emploi` | `idposte` | Toujours (CoNum officiels) |
| Aidants Connect | `structure_emploi` | `aidants-connect` | Toujours |
| Cartographie nationale | — | — | N'écrit pas dans cette table |

Cette ségrégation par `source` évite les doublons cross-source et permet une vue
riche du parcours d'une personne à travers plusieurs dispositifs.
