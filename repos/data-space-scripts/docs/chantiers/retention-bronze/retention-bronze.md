# Rétention de la couche bronze (`source.*`) — vue 360

## Le problème en une phrase

La couche bronze est append-only par conception (fiche 01) et **aucune politique de
rétention n'existe** : chaque run empile sa capture brute pour toujours. Tant que les
flux étaient des deltas, c'était négligeable ; avec les flux en stock complet ré-émis
quotidiennement (carto, AC structures, coop, idposte), la croissance est linéaire et
dominée par de la redondance quasi totale (J et J-1 diffèrent de moins de 1 %).

Ce n'est **pas** un problème de performance des runs : les lectures silver filtrent
par `run_id` (indexé, V118), le volume historique n'est jamais parcouru. Le coût
réel est ailleurs : stockage prod, durée des backups/restores (RPO/RTO, fiche 13),
vacuum/analyze, taille des copies de travail (base min).

## Volumétrie observée (base min, 2026-07-30)

| Table | Lignes | Taille | Runs | Depuis | Rythme | Classe |
|---|---:|---:|---:|---|---:|---|
| `carto__structures` | 1 816 108 | 2 815 MB | 103 | 2026-03-30 | ~14 900/j (~17 600/run) | stock complet |
| `coop__activites` | 401 537 | 542 MB | 48 | 2026-06-09 | ~7 900/j | **delta** |
| `ac__structures` | 370 690 | 226 MB | 45 | 2026-06-09 | ~7 300/j (~8 300/run) | stock complet |
| `coop__utilisateurs` | 295 518 | 333 MB | 48 | 2026-06-09 | ~5 800/j | stock complet |
| `coop__structures` | 246 089 | 297 MB | 49 | 2026-06-09 | ~4 800/j | stock complet |
| `idposte__conum` | 110 136 | 196 MB | 13 | 2026-06-16 | ~8 500/run | stock complet |
| `frr__zonage` | 39 868 | 24 MB | 2 | 2026-07-01 | ponctuel | statique |
| `ac__aidants` | 30 484 | 37 MB | 46 | 2026-06-09 | 3–690/j (delta) + 18 539/snapshot mensuel | delta + snapshot |
| `ban__adresses` | 11 983 | 11 MB | 9 | 2026-07-29 | dépend des cache miss | pull |
| `sirene__etablissements` | 8 542 | 15 MB | 51 | 2026-06-09 | ~170/j | pull |
| `qpv__zonage` | 3 552 | 24 MB | 2 | 2026-07-01 | ponctuel | statique |

**Total : ~4,5 GB accumulés en 4 mois** (dont 62 % pour carto seul).

Note : `ban__adresses` n'est capturé que depuis le branchement du sink (2026-07-28) et
son rythme dépendra du taux de cache miss (V137) — élevé pendant la montée en cache,
faible ensuite. Chiffres à revalider en prod (la base min est une copie récente).

## Projection à 12 mois, politique inchangée

Coût unitaire observé (taille totale / lignes, index compris) : ~0,6 KB/ligne
(ac__structures) à ~1,8 KB/ligne (idposte), ~1,55 KB pour carto.

| Table | Croissance annuelle estimée |
|---|---:|
| `carto__structures` | ~8,4 GB |
| `coop__activites` | ~3,9 GB |
| `coop__utilisateurs` | ~2,4 GB |
| `coop__structures` | ~2,1 GB |
| `ac__structures` | ~1,6 GB |
| `idposte__conum` | ~1,6 GB |
| Autres | < 0,5 GB |
| **Total** | **~20 GB/an** |

**Si le fetch AC quotidien passe en complet** (projet de mutualisation
aidants + accompagnements) : `ac__aidants` passe de ~600 lignes/j à 18 539/j,
soit **+8,2 GB/an supplémentaires** (~70× la trajectoire actuelle) → ~28 GB/an au total.

## Ce que la rétention doit préserver (invariants)

1. **Le silver reste re-dérivable** : les tables `staging.*` se reconstruisent depuis
   le *dernier* run (`run_id` courant). Toute rétention ≥ quelques jours suffit ;
   90 jours donne une marge de rejeu/debug confortable.
2. **Les deltas sont irremplaçables** : pour `coop__activites` et les deltas
   `ac__aidants`, la concaténation des runs EST l'historique — l'API ne permet pas
   de rejouer un état intermédiaire passé. Ne jamais les purger sans décision explicite.
3. **Les snapshots mensuels AC sont la seule trace au-delà de M-5** : la fenêtre
   glissante `get_supports_number_last_six_months` sort de l'API. Le gold
   (`main.ac_accompagnements_mensuels`) porte la série consolidée, mais le brut
   permet de la re-dériver. 12 snapshots/an ≈ 265 MB/an : conserver tout.
4. **Un futur besoin SCD (fiche 09) se nourrit du bronze** : garder au minimum un
   échantillon mensuel des stocks complets préserve la capacité de reconstruire une
   historisation a posteriori, à coût quasi nul.
5. **La purge est un DAG dédié, jamais une tâche des DAGs d'ingestion** — et
   `source.capture_run` (méta des runs) n'est jamais purgé : la trace qu'un run a
   existé survit à ses données.

## Politique cible par classe de flux

> **Mise à jour 2026-08-28 (V159, #1707)** : les tables `coop__activites` et
> `coop__structures` sont **supprimées** (`coop__utilisateurs` suit) — le flux coop
> n'a plus de bronze : sa source vit dans le même cluster (schéma `coop`), qui porte
> lui-même l'historique (`creation` / `modification` / `suppression`). Les
> projections ci-dessus (~8,4 GB/an pour les trois) deviennent sans objet ; la
> politique reste valable pour les sources **externes** au cluster.


| Classe | Tables | Rétention | Justification |
|---|---|---|---|
| Stock complet ré-émis | carto, ac__structures, ~~coop__structures, coop__utilisateurs~~ (V159), idposte__conum, ac__aidants (quotidien complet depuis la fusion 2026-07-31) | **90 j intégral, puis 1 run par mois conservé** | redondance J/J-1 < 1 % ; l'échantillon mensuel couvre debug long terme + reconstruction SCD, et porterait la sémantique des ex-snapshots mensuels AC |
| Delta incrémental | ~~coop__activites~~ (V159), ac__aidants historiques (source_key avec `updated_at__gte`, avant 2026-07-31) | **illimitée** (réévaluer au-delà de 10 GB/table) | chaque ligne est unique, c'est l'historique lui-même |
| Snapshot mensuel (historique) | ac__aidants (snapshots de l'ex-DAG mensuel, avant 2026-07-31) | **illimitée** | seule trace au-delà de M-5 pour la période pré-fusion, volume négligeable |
| Pull d'enrichissement | sirene__etablissements, ban__adresses | **6 mois** (TTL cache 4 mois + marge) | re-interrogeable à volonté ; utilité = debug + re-remplissage cache |
| Statique | frr__zonage, qpv__zonage | rien à faire | 2 runs en 4 mois |

Volume en régime stationnaire avec cette politique : **~5–6 GB stables** (dont carto
~3 GB : 90 jours × 17 600 lignes + 24 archives mensuelles), au lieu de +20 GB/an.

## Quand le faire — déclencheurs

Par ordre de priorité :

1. **La bascule du fetch AC quotidien en complet.** Elle a eu lieu le 2026-07-31
   (fusion aidants + accompagnements) **sans** mise en place de rétention —
   décision explicite du 2026-07-31 : la rétention reste documentée ici, son
   implémentation est une décision d'équipe à prendre séparément. Coût assumé en
   attendant : `source.ac__aidants` croît de ~8,2 GB/an (~70× la trajectoire
   d'avant fusion).
2. **carto : déjà en zone orange.** 2,8 GB en 4 mois, ~8,4 GB/an. À traiter dans les
   prochains mois, sans urgence de la semaine.
3. **Seuils d'alerte génériques** (à brancher sur l'observabilité, fiche 06) :
   schéma `source` > 10 GB, une table > 5 GB, durée de backup/restore dégradée,
   `pg_stat_user_tables.n_dead_tup` massif après purge (vacuum à surveiller).

Tant qu'aucun déclencheur n'est atteint, **ne rien faire est un choix valide** :
le statu quo coûte ~1,7 GB/mois et n'affecte pas les runs.

## Comment — mécanique

**Phase 1 (suffisante durablement) : DELETE périodique + autovacuum.**

- DAG Airflow mensuel dédié (ex. `source-retention`), une tâche par table concernée,
  DELETE par lots sur `ingested_at`, en préservant l'échantillon mensuel :

```sql
-- esquisse : purge stock complet > 90 j, sauf le premier run de chaque mois
DELETE FROM source.carto__structures t
WHERE t.ingested_at < now() - interval '90 days'
  AND t.run_id NOT IN (
      SELECT DISTINCT ON (date_trunc('month', ingested_at)) run_id
      FROM source.carto__structures
      ORDER BY date_trunc('month', ingested_at), ingested_at
  );
```

- Après purge : `VACUUM (ANALYZE)` — pas de `VACUUM FULL`. Le fichier ne rétrécit
  pas, mais l'espace mort est recyclé par les inserts suivants : la table atteint un
  **régime stationnaire** et cesse de croître. C'est le compromis assumé : simple,
  sans migration, sans verrou long.
- Logger la volumétrie purgée (lignes, période) à chaque exécution.

**Phase 2 (signal de bascule, cf. doctrine fiche 14) : partitionnement mensuel natif**
sur `ingested_at`, purge par `DROP PARTITION` (instantané, récupère réellement
l'espace). À n'engager que si : le DELETE mensuel dépasse plusieurs minutes ou bloque,
ou une table dépasse ~20 GB malgré la phase 1. Coûte une migration lourde
(recréation de table + réattachement), injustifiée aujourd'hui.

**Rythme d'exécution** : mensuel. Une purge plus fréquente n'apporte rien (le coût
est du stockage, pas de la latence) ; moins fréquente laisse grossir les lots DELETE.

## Ce qui reste à décider au moment de l'implémentation

- Durées exactes (90 j / 24 mois / 6 mois sont des propositions raisonnables, pas des
  contraintes mesurées) — les acter dans les contrats (`contracts/*.yml`, section
  garanties) pour que la rétention soit documentée là où les consommateurs regardent.
- Sort de `coop__activites` à long terme : c'est le seul delta volumineux (~4 GB/an).
  Si le gold est jugé suffisant comme historique, une rétention 24 mois est possible —
  mais c'est une perte définitive de brut, à décider explicitement, pas par défaut.
- Vérifier les chiffres en prod avant de calibrer (cette fiche est chiffrée sur la
  base min du 2026-07-30).
