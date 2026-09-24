# Tests unitaires

> Tests unitaires **purs** : aucune base de données, aucun appel réseau, aucun runtime
> Airflow. Exécutables partout, instantanés. Complémentaires de `tests/` (recette sur
> base réelle, intégration PG, intégration APIs externes) — on ne touche pas à `tests/`.

## Exécution

```bash
# Depuis la racine du repo, via uv (environnement autonome, voir pyproject.toml)
uv run --project tests-unitaires -- pytest tests-unitaires/ -v         # tout
uv run --project tests-unitaires -- pytest tests-unitaires/coop/ -v    # une source
```

Aucune variable d'environnement requise, aucune installation préalable : `uv` résout
les dépendances minimales (`tests-unitaires/pyproject.toml` — pytest, pandas, requests,
psycopg2-binary). Airflow est volontairement absent : `conftest.py` stubbe ses modules
car certaines fonctions testées vivent dans des opérateurs, mais rien n'est exécuté
côté Airflow. Les tests tournent aussi dans un environnement complet (Airflow installé),
le stub s'efface alors de lui-même.

## Principes

1. **Une source = un dossier autonome.** Les payloads de test vivent dans le dossier de
   la source (`payloads_<source>.py`), au plus près des tests. **Aucun import entre
   dossiers de sources**, aucun `conftest.py` partagé : supprimer un dossier ne casse
   rien ailleurs.
2. **Organisation par étape.** Dans chaque dossier, un fichier par étape du pipeline :
   `test_transform_*.py` (transformation extract), `test_ingest_*.py`, etc. Noms de
   fichiers **uniques dans tout `tests-unitaires/`** (contrainte pytest sans packages).
3. **On teste le core, pas le legacy.** Cible : les fonctions pures de l'architecture
   FCIS ([approche-data/16](../approche-data/16-architecture-code-fcis.md)) et les
   briques du pattern bronze
   ([approche-data/15](../approche-data/15-pattern-flux-reference.md)) — capture brute
   (`etl/source_capture.py`), puis transformations `etl/core/` au fil des migrations de
   flux. On ne fige PAS par des tests les transformations legacy enfouies dans les
   opérateurs : elles meurent par remplacement (décision 2026-07-27, un premier lot de
   tests transform coop a été écrit puis supprimé pour cette raison).
4. **Payloads réalistes.** Les payloads reproduisent la forme documentée dans les
   [contrats de flux](../contracts/README.md) (mêmes chemins, mêmes types). Jamais de
   données personnelles réelles.

## Couverture

| Cible | Étapes | Statut |
|---|---|---|
| [capture brute](source_capture/) (`etl/source_capture.py` + `_capture_page_to_source` de `APIClientOperator`) | sink : payload stocké intact, run_id/source_key, erreur avalée ; operator : extraction results/data, endpoint = source_key, no-op si non configurée | rédigé |
| [coop](coop/) | core structures (filtres carto, pivot, contact, pg-arrays, fix deleted_at_coop) + utilisateurs (contact dict, is_visible, rôles, affectations, coordination) + activités (date tronquée, labels avec fix majuscules internes, beneficiaires JSON compact) | rédigé (3 sous-flux) |
| ban | core parsing réponse CSV, filtre INSEE, seuil de score | à faire |
| carto | core | à faire |
| aidants_connect | core (l'ingest a déjà `tests/test_aidants_connect_ingest.py`, intégration PG) | à faire |
| sirene | core parsing (`_parse_response`, `_normalize_siret`) | à faire |
| zonages (frr, qpv) | core | à faire |
