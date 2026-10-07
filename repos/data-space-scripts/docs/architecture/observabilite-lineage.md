# 06 — Observabilité data : fraîcheur, volumétrie, alerting, lineage

← [Retour au document central](README.md)

## Le concept

L'observabilité applicative répond à "le service tourne-t-il ?". L'**observabilité data**
répond à "les données sont-elles bonnes, fraîches et complètes ?" — un DAG vert peut
produire des données fausses, vides ou périmées sans qu'aucune alerte ne parte.

L'état de l'art (Monte Carlo, et la littérature "data observability") définit cinq piliers :

| Pilier | Question | Exemple d'anomalie |
|--------|----------|--------------------|
| **Fraîcheur** | Les données sont-elles à jour ? | coop non rafraîchi depuis 4 jours, personne ne s'en aperçoit |
| **Volumétrie** | Le nombre de lignes est-il plausible ? | Une source renvoie 200 lignes au lieu de 40 000 (API paginée cassée) |
| **Distribution** | Les valeurs sont-elles plausibles ? | Taux de NULL sur `siret` passe de 5 % à 60 % |
| **Schéma** | La structure a-t-elle changé ? | Couvert par les data contracts (fiche 02) |
| **Lineage** | D'où vient cette donnée, qui en dépend ? | "Si je change `main.structure`, qu'est-ce qui casse dans `api` et `dataviz` ?" |

Principe : ces signaux sont **calculés automatiquement à chaque run et historisés** — les
anomalies se détectent par comparaison avec l'historique, pas par des seuils devinés.

## État actuel du projet

- Aucun suivi de fraîcheur : si un DAG est en échec silencieux (ou désactivé), les
  consommateurs voient des données périmées sans le savoir.
- Volumétrie : vérifiée à l'œil via `rapport_comptage.py`, quand quelqu'un le lance.
- Lineage : reconstitué de tête ("quelles vues `api` lisent `main.personne` ?" = grep dans
  les migrations).
- Alerting : notifications Mattermost sur échec de DAG (cf. `docs/guides/notifications-mattermost.md`)
  — c'est de l'observabilité *pipeline*, pas *data* : elle ne voit pas les succès qui
  produisent des données fausses.

## Mise en place sur ce projet

### 1. Table de métriques de runs — le socle, trivial à mettre en place

```sql
CREATE TABLE admin.pipeline_metrics (
    mesure_at   timestamptz NOT NULL DEFAULT now(),
    dag_id      text NOT NULL,
    run_id      text NOT NULL,
    flux        text NOT NULL,          -- 'coop__personnes'
    etape       text NOT NULL,          -- 'extract', 'staging', 'main'
    n_lignes    bigint NOT NULL,
    n_rejets    bigint DEFAULT 0,       -- lien avec la quarantaine (fiche 03)
    metriques   jsonb                   -- taux de NULL par colonne clé, distributions
);
```

Chaque tâche significative écrit une ligne en fin d'exécution. Trois usages immédiats :

- **Détection d'anomalie** : la tâche de tests qualité compare le run courant à la médiane
  des N derniers runs (volumétrie ±X %, taux de NULL) — seuils appris, pas devinés.
- **Fraîcheur** : `max(mesure_at)` par flux vs SLA déclaré dans le contrat (fiche 02).
  Un DAG de supervision léger (ou un simple check quotidien) alerte sur Mattermost si un
  flux dépasse son SLA — **ce check attrape les échecs silencieux, y compris un DAG
  désactivé par erreur**, ce que l'alerting sur échec ne peut pas faire.
- **Dashboard Metabase "santé du pipeline"** : l'équipe a déjà Metabase — un dashboard
  fraîcheur/volumétrie/rejets par flux est le moyen le moins cher d'avoir de
  l'observabilité visible par tous, métier inclus.

### 2. Exposer la fraîcheur aux consommateurs

Les utilisateurs de MIN et de l'API doivent savoir sur quoi ils travaillent :

- Vue `api.metadata_flux` (flux, dernière mise à jour, statut) exposée via PostgREST.
- MIN affiche "données coop à jour du JJ/MM à HH:MM" — transforme les tickets "il manque
  une structure" en "ah, le flux date d'avant sa création".

### 3. Lineage

Deux niveaux, complémentaires :

- **Airflow 3 + OpenLineage** (natif) : lineage au niveau des tâches/datasets entre DAGs.
  Activer l'émission d'événements est peu coûteux ; les skills
  `data:annotating-task-lineage` et `data:tracing-*-lineage` du repo couvrent le sujet.
  Sans backend dédié (Marquez), commencer par annoter les tâches (`inlets`/`outlets`) —
  déjà utile comme documentation exécutable.
- **dbt docs** (si fiche 05 adoptée) : lineage colonne/table de toute la couche transform,
  généré gratuitement. C'est le lineage le plus utile au quotidien ("qui lit cette colonne ?").
- Pour les vues `api`/`dataviz` gérées par Flyway : PostgreSQL connaît les dépendances
  (`pg_depend`) — une requête de service "quelles vues dépendent de main.X" suffit,
  inutile d'outiller davantage.

### 4. Alerting : peu, mais fiable

Règle d'or : **une alerte ignorée deux fois doit être supprimée ou corrigée**. Canaux :

- Bloquant (tests qualité rouges, SLA fraîcheur dépassé) → Mattermost, canal dédié, avec
  le contexte (flux, métrique, valeur attendue/observée, lien run Airflow).
- Informatif (drift de distribution, warn de contrat) → digest quotidien, pas du temps réel.

## Par où commencer

1. `admin.pipeline_metrics` + écriture depuis les tâches de load (1-2 jours).
2. Check quotidien de fraîcheur vs SLA → alerte Mattermost.
3. Dashboard Metabase "santé du pipeline".
4. `inlets`/`outlets` sur les tâches des DAGs principaux ; dbt docs viendra avec la fiche 05.

## Pièges connus

- **Observabilité sans historique** : des métriques calculées mais non stockées ne
  permettent pas de détecter les dérives — l'historisation est le point clé.
- **Alerting bavard** : trop d'alertes = zéro alerte. Commencer avec 3-4 alertes bloquantes
  maximum.
- **Outil avant besoin** : pas besoin de plateforme d'observabilité dédiée (Monte Carlo,
  Elementary…) à cette échelle — une table, un dashboard Metabase et deux checks couvrent
  90 % de la valeur.

## Références

- Barr Moses et al. — *Data Quality Fundamentals* (O'Reilly, les 5 piliers)
- OpenLineage / Marquez — standard et backend de lineage (natif Airflow 3)
- Elementary (dbt-native observability) — si dbt est adopté et que le besoin grandit
