# Ménage doublons lieux carto/coop

Outil CLI qui fusionne les lieux d'inclusion en doublon (min#1585) et génère un rapport Markdown de ce qui a été fait — la trace de l'opération, aucune donnée n'est marquée en base.

## Contexte

Quand mednum-cli fusionne un lieu Coop numérique avec une autre source (France Services, Dora, hubs régionaux…), l'id cartographie nationale devient composite (`Coop-numérique_<uuid>__France-Services_789`) et le champ `structure_coop_id` du flux arrive vide. Le DAG carto ne rapprochait pas le lieu coop existant et créait un doublon : fiche « carto » visible mais vide + fiche « coop » cachée portant les activités et les conum.

L'outil fusionne chaque paire : la fiche coop (riche) récupère l'id carto et la visibilité, la fiche carto (vide) est supprimée. Les attributs carto (nom, contact, horaires…) sont rafraîchis par le run suivant du DAG `carto-dag-import` (match nominal par carto_id).

## Pré-requis

- Python >= 3.12
- [uv](https://docs.astral.sh/uv/)
- Accès à une base PostgreSQL contenant les schémas `main` et `import`

## Installation

```bash
cd tools/menage-doublons-lieux
uv sync
```

## Utilisation

```bash
uv run main.py <DSN>              # dry-run : détecte, rapporte, ne modifie rien
uv run main.py <DSN> --execute    # applique les fusions
```

Exemple :

```bash
uv run main.py postgresql://min:min@localhost:5432/min --execute
```

Un rapport `rapport_menage_doublons_<mode>_<date>.md` est généré dans le répertoire courant, y compris en dry-run : cartouche (base, mode, compteurs), détail de chaque paire fusionnée (fiche conservée, fiche supprimée, commune, activités, associations transférées, id carto transféré), et liste des paires exclues avec le motif.

## Garde-fous

- **Dry-run par défaut** : sans `--execute`, aucune écriture.
- Une fiche carto portant des activités ou des personnes n'est **jamais** supprimée (paire exclue, fusion manuelle requise).
- Une paire dont la fiche coop porte déjà un autre id carto est exclue (doublon côté cartographie nationale, à traiter en amont).
- Toutes les écritures se font dans **une seule transaction** (tout ou rien).
- Idempotent : ré-exécutable sans effet si aucune paire ne subsiste.

## ⚠️ Ordre d'exécution

À lancer **avant** le premier run du DAG `carto-dag-import` corrigé (extraction de l'UUID coop depuis l'id composite). Sinon l'étape « 0b » du DAG transfère le coop_id sur la fiche vide et les paires ne sont plus détectables par l'outil.
