# Banc de tests Nao

Chaque fichier `tests/*.yml` pose une question métier à l'agent (`ask_nao` via MCP),
exécute un SQL de référence avec le rôle `nao_ro` (`execute_sql`) et compare les deux.
Le script est `scripts/nao_eval.py`.

## Lancer

```bash
python3 scripts/nao_eval.py                      # tous les tests
python3 scripts/nao_eval.py -t tableau-de-bord   # un tag
python3 scripts/nao_eval.py -t S                 # un bloc du tableau de bord
python3 scripts/nao_eval.py -k beneficiaires     # motif sur le nom
python3 scripts/nao_eval.py -o rapport.json --model "nom affiché dans le rapport"
```

Le modèle n'est pas sélectionnable par l'API : `--model` n'étiquette que le rapport
(changer le modèle dans Nao, Réglages → Agent).

## Format d'un test

```yaml
name: tdb_e_gouvernances            # défaut : nom du fichier
prompt: "Combien de gouvernances … ?"   # question en français, telle qu'un PO ou le support la poserait
kind: scalar                        # scalar (un nombre) | table (libellé → nombre)
rtol: 0.01                          # tolérance relative, défaut 0.005
tags: [tableau-de-bord, E]
sql: |
  SELECT count(*) AS n FROM llm.gouvernance WHERE departement_code <> 'zzz'
```

Comparaison (`nao_eval.py`) :

- `scalar` : le SQL renvoie une ligne, une colonne numérique ; le nombre doit apparaître
  dans la réponse texte à ±`rtol` (minimum ±0,5 en absolu).
- `table` : le SQL renvoie deux colonnes (libellé, nombre), 20 lignes au plus ; chaque
  libellé de la référence doit apparaître sur une ligne de la réponse avec le nombre
  attendu. Les libellés sont rapprochés sans accents, sans casse ni ponctuation
  (`prendre_en_main_du_materiel` ≡ « Prendre en main du matériel »).

Limite connue du comparateur : l'extraction des nombres attend des séparateurs de
milliers (`7 269 287`) ou un nombre inférieur à 1 000 ; `7269287` collé n'est pas
reconnu. Les prompts demandent donc le « nombre exact », et un échec sur un grand
nombre doit être relu avant d'être imputé à l'agent.

## Conventions

- **Nom de fichier** : `tdb_<bloc>_<indicateur>.yml` pour le tableau de bord MIN
  (`bloc` = lettre de l'inventaire `agent/semantics/tableau-de-bord-min.md` : A points
  de vigilance, B données structure, C état des lieux, D médiateurs, E gouvernances,
  F financements, G bénéficiaires de financements, H label Conum, I page
  `/gouvernances`, S page Statistiques). Tags : `[tableau-de-bord, <bloc>]`.
- **Prompt** : formulé comme un utilisateur métier, sans nom de table ni de colonne,
  mais avec les précisions de définition qui lèvent l'ambiguïté (« activités non
  supprimées », « médiateurs actuellement en poste », « hors gouvernance technique
  zzz », période, unité de comptage). Les libellés attendus d'une `table` sont donnés
  dans le prompt (« avec exactement ces libellés … » ou « identifiants tels
  qu'enregistrés »).
- **SQL de référence** : uniquement des objets lisibles par `nao_ro` — `llm.*`,
  `admin.*`, `reference.*`, `main.{poste, contrat, formation, subvention,
  personne_affectations_emploi, personne_affectations_lieu,
  contact_structure_administrative}`, `min.{action, beneficiaire_subvention,
  co_financement, comite, demande_de_subvention, departement, departement_enveloppe,
  enveloppe_financement, feuille_de_route, feuille_de_route_document, groupement,
  porteur_action, postes_conseiller_numerique_synthese, region}`. Jamais `coop.*`,
  `main.personne`, `main.adresse`, `main.lieu_inclusion`, `main.structure_administrative`,
  `min.membre`, `min.gouvernance`, `min.personne_enrichie` (remplacés par les vues
  `llm.*`). Le SQL reproduit la définition MIN de l'indicateur après transposition
  (`coop.<t>` → `llm.coop_<t>`, enums en `text`, tranche d'âge dérivée =
  `llm.coop_beneficiaires.tranche_age_derivee`).
- **Validation avant livraison** : chaque SQL est exécuté sur la base locale avec le rôle
  `nao_ro` ; un test dont le SQL échoue ou renvoie 0 ligne n'est pas livré.

  ```bash
  psql "postgresql://nao_ro:nao_ro_local@localhost:5532/dataspace_dev" -At -c "<sql>"
  ```

- **Séries temporelles** : limitées aux 6 derniers mois pleins (mois en cours exclu),
  règle rappelée dans le prompt, libellé `AAAA-MM`.
- **Valeurs qui bougent** : les indicateurs qui dépendent de la date du jour
  (fraîcheur des lieux, période « jusqu'à aujourd'hui ») portent `rtol: 0.01` et le
  prompt le précise.
- **Maille** : ce premier lot est national uniquement (pas de filtre département, EPCI
  ni structure). Les blocs B et H, conçus pour une structure, sont transposés au
  national (tous les lieux ayant une affectation active, toutes les structures ayant un
  poste).

## Définitions retenues là où MIN en a plusieurs

- **Membre de gouvernance** (bloc E) : « non supprimé » = `statut <> 'supprimer'`
  (candidats et confirmés). Le code MIN compare au littéral `'supprime'`, qui ne
  correspond à aucune valeur de l'énumération (`candidat`, `confirme`, `supprimer`) :
  le tableau de bord compte donc en réalité tous les membres. Le banc teste la
  définition voulue, pas le défaut ; l'écart local est de 61 membres hors zzz.
- **Page `/gouvernances`** (bloc I) : tous les membres, quel que soit le statut, comme
  dans MIN. La liste `/gouvernances/list` (`statut = 'confirme'`) n'est pas testée.
- **Accompagnements** : « nombre d'accompagnements » = somme de
  `accompagnements_count` (S1, B3, C3) ; la série mensuelle S5 compte une ligne
  d'accompagnement par bénéficiaire, comme le graphique MIN.

## Indicateurs non couverts dans ce lot

- S6 (par jour, 30 derniers jours glissants) : change à chaque heure.
- S10 (tags spécifiques) : `llm.coop_tags.nom` est masqué, les libellés ne sont pas
  comparables ; et l'indicateur n'est rendu qu'en vue territorialisée.
- H2 (structures labellisées) : `main.conum_labellisation` est vide sur la base locale.
- C4, D5, S4, G1 : dérivés d'autres tests (S5, D1−D3−D4, S2−S3, G2+G3).
- F2, F8–F16 : enveloppe « disponible » et indicateurs à la maille département ou
  structure (prochain lot territorial).
