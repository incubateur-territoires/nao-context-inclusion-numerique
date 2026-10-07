# 17 — Plan de remise au propre, dirigé par les tests

> Objectif : remettre le projet au propre **sans big bang**. Avancée en baby steps :
> chaque étape est une petite MR livrable, prouvée par des tests, et le projet reste
> fonctionnel en prod à chaque instant. Ce plan opérationnalise les fiches
> [15](../architecture/pattern-flux-reference.md) (bronze d'abord) et [16](../architecture/architecture-code-fcis.md)
> (FCIS) — il dit *dans quel ordre* et *par quelles MRs*.

## Principe de bout en bout

**Aucun changement de comportement sans un test qui le prouve.** Le développement est
dirigé par les tests : dans chaque boucle, les tests s'écrivent avant le code qu'ils
valident.

## Étape 0 — Le harnais (préalable absolu)

Rien ne peut être « dirigé par les tests » si rien ne les exécute.

- **0.1** Job CI `test-unitaires` (`.gitlab-ci.yml`) : `uv run --project tests-unitaires
  -- pytest tests-unitaires/` sur chaque MR, **bloquant**.
- **0.2** Premier test réel pour un job vert : la capture brute (`etl/source_capture.py`)
  — payload stocké intact, run_id/source_key corrects, erreur avalée sans casser le flux.

**Critère de sortie** : une MR qui casse un test ne peut plus merger.

## Étape 1 — La boucle de migration d'un flux (le baby step type)

La brique répétée pour chaque flux. **4 MRs indépendantes, chacune sans risque** :

| # | MR | Contenu | Preuve |
|---|----|---------|-------|
| 1 | **Capture** | Brancher la capture brute `source.*` dans le shell existant. Zéro changement du comportement aval. | Test : le sink reçoit le payload intact ; prod : `source.{flux}__*` se remplit, `main` inchangé. |
| 2 | **Core (TDD)** | Tests de la transformation cible d'abord (`tests-unitaires/{flux}/`, payloads conformes au [contrat](../../contracts/README.md)), puis la fonction pure `etl/core/{flux}.py` qui les fait passer. Code mort à ce stade — rien de branché. | Tests verts ; comparaison hors-ligne core vs legacy sur données réelles de `source.*`. |
| 3 | **Bascule** | Le DAG appelle le core au lieu de la logique enfouie ; le load lit `source.*`. | Rapport avant/après (`rapport_comptage.py`) identique, ou écarts expliqués (= bugs legacy corrigés, documentés au changelog). |
| 4 | **Nettoyage** | Suppression du code legacy du flux dans l'opérateur. | CI verte, une seule vérité. |

La comparaison core vs legacy (MR 2) est le moment où l'on **décide** des bugs connus
(`deleted_at_coop`, labels mutilés par `normalize_labels`…) : corrigés dans le core,
chiffrés, tracés au changelog. Plus jamais de correction sauvage.

## Étape 2 — Répéter la boucle (ordre de la fiche 15)

1. **coop** (3 sous-flux : structures, utilisateurs, activités — chacun peut être sa
   propre boucle si trop gros)
2. **BAN** (inclut le fix « sink jamais branché » — littéralement la MR 1 de sa boucle)
3. **carto**
4. **AC quotidien**
5. SIRENE / zonages en dernier (déjà partiellement conformes)

## Étape 3 — Hygiène opportuniste (en parallèle, jamais bloquant)

Petites MRs indépendantes, une à la fois, quand une boucle attend sa revue :

- **3.1** `pyproject.toml` racine, versions figées (remplace `requirements.txt`
  progressivement)
- **3.2** ruff seul en pre-commit (remplace black + autoflake + reorder-python-imports)
- **3.3** Garde-fou architecture en CI : `etl/core/` n'importe ni airflow, ni psycopg2,
  ni requests (fiche 16)
- **3.4** Typage progressif : mypy sur `etl/core/` uniquement — le neuf est typé, le
  legacy jamais

## Les règles du jeu (invariantes)

1. **Test d'abord** : dans une boucle, la MR 2 commence par les tests rouges, le code
   vient après.
2. **Une MR = un pas** : si une MR mélange deux étapes du tableau, elle est trop grosse.
3. **Le legacy ne se refactore pas, il se remplace** (fiche 16) — on ne touche à l'ancien
   code que pour le brancher (MR 1, 3) ou le supprimer (MR 4).
4. **Chaque bascule est mesurée** : rapport avant/après systématique, écarts documentés
   au changelog.
5. **On peut s'arrêter n'importe quand** : chaque MR laisse le projet meilleur et
   fonctionnel — pas d'état intermédiaire cassé.

## Suivi

| Étape | Statut |
|-------|--------|
| 0.1 job CI | rédigé (job `test-unitaires`, bloquant) — à valider sur une première MR |
| 0.2 tests capture brute | rédigé (20 tests, `tests-unitaires/source_capture/` : sink + chemin in-operator) |
| Boucle coop | TERMINÉE. MRs 1, 2a, 2b, 2c, 3 mergées (capture + core 92 tests + bascule). Bascule validée en local : run `coop-import` complet vert, fix labels vérifié en base (« Creer avec le numerique ») ; fix deleted_at_coop non exercé sur ce jeu (0 structure supprimée dans le brut). MR 4 (nettoyage) rédigée : legacy `_transform_data` coop supprimé de l'opérateur (539 lignes), zéro changement de comportement |
| Boucle BAN | MR 1 (capture) VALIDÉE en local : sink `source.ban__adresses` câblé chez les 3 appelants (coop-dag, aidants-connect-dag, schema-idPoste) + fix NaN→None avant json.dumps dans `GeocodeurBatch._geocoder_batch`. Preuve : run `coop-import` du 2026-07-28, 2 320 lignes capturées, payload JSONB propre. Contrat `contracts/ban__adresses.yml` mis à jour (fields `verifie: true`, casse réelle `result_banId`). MR 2 (core TDD) rédigée : 19 tests `tests-unitaires/ban/` + `etl/core/ban.py` (`transformer_reponses`) — code mort, rien de branché. Bug décidé : `code_ban` lisait `result_banid` (minuscules, clef inexistante, 100 % None) → lit `result_banId` ; rejoué sur les 2 320 lignes réelles capturées : 2 119 code_ban renseignés (avant : 0), 2 262 valides, 38 rejets INSEE. MR 3 (bascule) VALIDÉE en local : `_geocoder_batch` appelle `transformer_reponses`, chemin d'erreur via `ligne_vide` — run `coop-import` du 2026-07-28 post-bascule vert, code_ban (UUID BAN) présent sur les adresses créées/mises à jour en aval (`main.adresse`). MR 4 (nettoyage) rédigée : `AdresseGeocodee` supprimée, zéro changement de comportement. BOUCLE TERMINÉE |
| Boucle carto | MR 1 (capture) rédigée : capture déplacée en pré-transform — `load_carto_national_file` accepte `source_sink` et capture le fichier national après `json.loads`, avant les rejets (id > 2000 octets, code_insee absent) ; l'ancienne tâche dead-end `write_to_source_carto` (post-chargement, brut mutilé) supprimée. VALIDÉE en local : run du 2026-07-28, 18 482 capturées = 18 438 chargées + 44 rejets sans code_insee, payload = fichier réel (les 17 champs disparus vs ancienne capture étaient des colonnes import.carto vides à 100 %). Contrat mis à jour. MR 2 (core TDD) rédigée : 13 tests `tests-unitaires/carto/` + `etl/core/carto.py` (`transformer_lieux`, colonnes autorisées injectées) — code mort. Aucun bug décidé : rejoué sur les 18 482 lieux réels = identique au legacy (18 438 lignes, 6 102 coop_id, 44 rejets). MR 3 (bascule) VALIDÉE en local : `load_carto_national_file` appelle `transformer_lieux(lieux, set(DTYPE_CARTO))`, transformation inline supprimée (bascule et nettoyage confondus : la logique était inline) — run du 2026-07-28 16:13 vert, `import.carto` identique (18 438 lignes, 6 102 coop_id, 23 sources), rejets loggés par `etl.core.carto`. BOUCLE TERMINÉE |
| Boucle AC quotidien | MR 1 (capture) déjà en place (capture in-operator `source.ac__structures` / `source.ac__aidants`, pré-transform, pattern fiche 15). MR 2 (core TDD) rédigée : 16 tests `tests-unitaires/ac/` + `etl/core/ac.py` (`transformer_aidants`, `transformer_structures`, réutilise `parse_timestamp`/`to_pg_array` du core coop et les normalizers purs) — code mort. Aucun bug décidé : rejoué sur le stock complet brut réel du 2026-07-01 (18 539 aidants + 5 865 organisations imbriquées) = 0 écart vs `_transform_data` legacy. MR 3 (bascule) rédigée : la boucle de pages de `APIClientOperator.execute` appelle `transformer_aidants`/`transformer_structures` sur `results` (XCom = listes de dicts python, plus de passage par DataFrame) ; la branche accompagnements reste sur `_transform_data` (morte : seul appelant en `do_xcom_push=False`). VALIDÉE en local : run `aidants-connect-import` du 2026-07-29 vert, landing = capture (8 366 structures, 734 aidants delta), valeurs bien formées (noms upper, SIRET 14 chiffres, 1 429 France Services) ; au passage, premier run brut structures observé → schéma du contrat `ac__structures` confirmé (17 clés). MR 4 (nettoyage) rédigée : `_transform_data` supprimé de l'opérateur (~110 lignes) + imports normalizers/pandas devenus inutiles ; `aidants-accompagnements` avec `do_xcom_push=True` lève désormais un ValueError explicite (chemin sans consommateur). BOUCLE TERMINÉE |
| Silver staging.* (étape 4 fiche 08) | TERMINÉ (2026-07-30) — tous les flux basculés du CSV/mémoire/landing vers des tables `staging.<flux>__*` typées, TRUNCATE+INSERT par run, relues filtrées sur run_id (base = interface, fiche 15). En une MR par flux, zéro doublon (leçon du 1er lot AC rejeté) : AC quotidien V129 (+ drop landing `import.ac_*`), AC accompagnements V130, coop V131, FRR V132, QPV V133 (+ drop `import.qpv_staging`), idposte V134 (6 sous-flux ; exception documentée : CSV enrichi SIRENE/BAN non re-dérivable, cible fiche 05), sirene V135 (état mémoire→staging, structure_id capturé car sélection non re-dérivable), carto V136 en figuier étrangleur (+ drop `import.carto` avec ses 13 colonnes mortes et sa FK `lieu_inclusion_id` — unique lien import→main de la base : le silver reste en sens unique bronze→silver→gold, aucune FK staging→main, aucun write-back). Chaque lot validé : ruff + tests unitaires + DagBag conteneur + migration appliquée sur base min + contrat repointé ; carto vérifié sur run réel (18 439 lignes silver, 100 % matchées, 44 rejets quarantaine, volumes iso legacy) |
| Caches d'enrichissement — lot 1 (fiche 05, problème ouvert fiche 08) | TERMINÉ (2026-07-30) — V137 : `staging.sirene__cache` (clé SIRET normalisé) + `staging.geocodage__cache` (clé = triplet soumis à l'API : adresse/citycode/postcode), référentiels accumulés (UPSERT, jamais tronqués), TTL 4 mois à la lecture, aucune FK vers main. `etl/enrichment_cache.py` : wrappers cache-first `SireneAvecCache`/`GeocodeurAvecCache` (mêmes signatures/sorties que les batchs, write-through des seuls résultats utiles, best-effort → repli API complet sur erreur SQL). Branchés dans AC, coop et idposte ; capture bronze SIRENE (`source_sink_sirene`) branchée chez les 3 au passage. Résultat métier iso, CSV enrichis/XCom inchangés. Preuves : ruff, 190 tests unitaires (10 nouveaux `tests-unitaires/enrichment_cache/`), DagBag conteneur, V137 sur base min, contrats sirene/ban annotés. Reste (lot 2, non commencé) : supprimer les CSV enrichis + XCom (état enrichi = silver du flux ⋈ caches) et statuer sur `last_sirene_enrich_at` |
| Caches d'enrichissement — lot 2 (silver ⋈ caches) | TERMINÉ (2026-07-30). Décisions actées (2026-07-30) : géocodages score < 0.5 REJETÉS (écart assumé : ~2,8 % du volume, 130 adresses historiques conservées en base) ; ordre idposte → AC → coop (une MR par flux) ; `last_sirene_enrich_at` gardé tel quel (gate + file NULLS FIRST du backfill). **MR 1 idposte TERMINÉE (2026-07-30)** : `structure_enriched.csv` supprimé — `enrich_structures_caches` remplit les caches (cache-first, capture bronze conservée), `process_enriched_structure` joint silver ⋈ caches via `lire_cache_sirene`/`lire_cache_geocodage` + core pur `etl/core/idposte.py` (`consolider_structures`) ; normalisations de clé extraites en core `etl/core/enrichissement.py` (délégation de `SireneBatch`/`enrichment_cache`) ; `etl/structure_enrichment.py` + `etl/geocoding.py` supprimés (orphelins). Preuves : ruff, 213 tests (23 nouveaux), DagBag 25 DAGs, contrat idposte à jour. **MR 2 AC TERMINÉE (2026-07-30)** : `new_structures_enriched.csv` + XCom supprimés — `structures_ingest` re-dérive la sélection (silver + gate lazy + absentes de SA) et joint les caches via `consolider_structures_ac` (`etl/core/ac.py`, clé géocodage = adresse strippée + CP normalisé 5 chiffres sans citycode) ; `normaliser_code_postal` extrait en core ; `ingest_structures(conn, rows)` sans CSV. Preuves : ruff, mypy core (4 annotations MR 1 corrigées), 226 tests (13 nouveaux), DagBag 25 DAGs, contrat ac__structures + docs à jour. **MR 3 coop TERMINÉE (2026-07-30)** : `new_structures_enriched.csv` + XCom supprimés — `structures_ingest` re-dérive la sélection (silver, coop_id absent de SA, pas de gate lazy) et joint les caches via `consolider_structures_coop` (`etl/core/coop.py`, clé géocodage = adresse strippée + code_insee source sans CP ; nom_commune du géocodage seul, iso legacy) ; `_normalize_structure` conservé sur les lignes consolidées, aval d'ingest inchangé. Preuves : ruff, mypy core, 234 tests (8 nouveaux), DagBag 25 DAGs (26 tâches coop, topologie explicite inchangée), contrat coop__structures à jour. LOT 2 TERMINÉ : plus aucun CSV enrichi ni XCom d'état dans les 3 flux |
| Hygiène 3.1–3.4 | 3.1 rédigée : `pyproject.toml` racine + `uv.lock` — dépendances de `requirements.txt` épinglées aux versions de la stack cible (Airflow 3.1.6 / python 3.11, versions relevées dans le conteneur : pandas 2.1.4, numpy 1.26.4, sqlalchemy 1.4.54…), groupe dev (pre-commit, ruff), `package = false`. `requirements.txt` conservé tel quel (CI pip-audit/test-dag + déploiement serveur) — remplacement progressif. 3.2 rédigée : ruff seul en pre-commit (`ruff-check --fix` [F+I force-single-line] + `ruff-format` remplacent autoflake, reorder-python-imports et black ; hook AIR30 dédié conservé ; config `[tool.ruff]` dans pyproject.toml) + reformatage repo-wide (66 fichiers, cosmétique — black ne tournait que sur les fichiers touchés) + fix YAML de 5 contrats (`[` / `{` non quotés, check-yaml passait pas en --all-files). 3.3 rédigée : garde-fou architecture dans `tests-unitaires/architecture/test_core_pur.py` (job CI `test-unitaires` déjà bloquant, pas de changement de `.gitlab-ci.yml`) — vérification statique par AST (pas d'import runtime : le conftest stubbe airflow), transitive sur les imports internes `etl.*` (ex. core/ac → core/coop → transform/normalizer_utils), messages avec chaîne de provenance ; 141 tests verts, détecteur validé sur un module impur (http_airflow → requests + airflow.*). 3.4 rédigée : mypy sur `etl/core/` UNIQUEMENT — annotations ajoutées aux 4 modules core (signatures + dicts vides), config `[tool.mypy]` dans le pyproject racine (`files = ["etl/core"]`, `disallow_untyped_defs`, `explicit_package_bases` ; legacy `etl.transform.*` suivi en Any jamais vérifié, pandas sans stubs) ; exécuté par le job CI `test-unitaires` (`uv run --project tests-unitaires -- mypy etl/core`, mypy ajouté à cet env + au groupe dev racine). Validé : mypy vert sur 5 fichiers, détecteur vérifié (erreur de type injectée → échec), 141 tests verts, imports OK dans le conteneur. ÉTAPE 3 TERMINÉE |
