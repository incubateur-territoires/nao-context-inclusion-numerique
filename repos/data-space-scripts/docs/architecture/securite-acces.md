# 11 — Sécurité et gestion des accès aux données

← [Retour au document central](README.md)

## Le concept

La sécurité data applique un principe unique — **le moindre privilège** — à chaque maillon :
un acteur (humain, service, pipeline) n'a accès qu'aux données strictement nécessaires à sa
fonction, en lecture ou écriture, et ces accès sont **déclarés, versionnés et auditables**.

Les pratiques de référence :

| Pratique | Question traitée |
|----------|------------------|
| **Matrice rôles × schémas** | Qui a le droit de faire quoi, où — écrite avant d'être implémentée |
| **Rôles de groupe (RBAC)** | Les droits sont portés par des rôles fonctionnels, jamais par des comptes individuels |
| **Séparation lecture/écriture par couche** | Un consommateur ne peut pas écrire ; un pipeline n'écrit que sa couche |
| **Row-Level Security (RLS)** | Filtrage par ligne quand des consommateurs ne doivent voir qu'un sous-ensemble |
| **Gestion des secrets** | Les credentials ne vivent ni dans le code, ni dans les logs |
| **Audit des accès** | Savoir qui a lu/modifié quoi (complément du `audit_trail` applicatif) |

## État actuel du projet

- Des rôles PostgREST existent (`postgrest_[entity]_[usage]`) — bonne convention de nommage,
  mais les GRANT sont écrits **au cas par cas dans chaque migration**, sans doctrine : des
  incidents de grants incomplets ont déjà eu lieu (droits manquants découverts en prod).
- Pas de matrice écrite : impossible de répondre rapidement à "quels rôles peuvent écrire
  dans `main` ?" sans grepper toutes les migrations.
- L'authentification API repose sur des JWT (schéma `auth`, tokens PostgREST) — en place,
  mais la politique de rotation/révocation des tokens partenaires n'est pas documentée.
- Le pipeline Airflow se connecte vraisemblablement avec un rôle très (trop ?) privilégié,
  identique pour toutes les étapes.
- Le principe append-only de la couche `source` (aucun UPDATE/DELETE pour les rôles
  applicatifs) est une décision de sécurité par les permissions — c'est exactement la bonne
  approche, à généraliser.

## Mise en place sur ce projet

### 1. La matrice d'accès — le document fondateur

Une page, versionnée dans ce dossier, qui fait foi. Toute migration contenant un GRANT s'y
réfère ; tout écart est un bug.

| Rôle | source | staging | main | api | dataviz | min | Justification |
|------|--------|---------|------|-----|---------|-----|---------------|
| `etl_extract` | INSERT | — | — | — | — | — | N'écrit que le brut, ne peut pas le modifier (append-only) |
| `etl_transform` | SELECT | ALL | — | — | — | — | Travaille en staging, ne touche pas gold |
| `etl_load` | — | SELECT | INSERT/UPDATE | — | — | — | Seul écrivain de `main` ; pas de DELETE (soft delete) |
| `min_scalingo` | — | SELECT `staging.rejets`¹ | SELECT + écritures ciblées (+ INSERT `audit_trail` seul) | — | — | ALL | L'appli MIN |
| `postgrest_*` | — | — | — | SELECT (par vue) | — | — | Lecture seule, jamais les tables sous-jacentes |
| `metabase_reader` | — | — | — | — | SELECT | — | Dashboards |
| `dev_readonly` | SELECT | SELECT | SELECT | SELECT | SELECT | — | Debugging humain sans risque |

¹ Exception justifiée : la vue de quarantaine exposée dans MIN (fiche 03) — accès en
lecture à `staging.rejets` uniquement, pas au reste de staging (et écriture d'un statut de
traitement si la revue des rejets se fait dans MIN).

Principes transverses :

- **Personne n'utilise de superuser au quotidien** — réservé à Flyway (DDL) et aux
  interventions exceptionnelles, tracées.
- **Un rôle par fonction, pas par personne** : les humains héritent de rôles de groupe
  (`GRANT dev_readonly TO alice`), révocables individuellement.
- `DELETE` n'est accordé nulle part par défaut (le projet a déjà du soft delete — cohérent) ;
  chaque exception est documentée dans la matrice.

### 2. Industrialiser les GRANT (le point de douleur connu)

Les oublis de grants viennent du fait que chaque migration réinvente sa liste. Deux parades :

- **`ALTER DEFAULT PRIVILEGES`** par schéma : les droits standards s'appliquent
  automatiquement aux nouvelles tables/vues du schéma — plus d'oubli possible pour le cas
  nominal :

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA api
    GRANT SELECT ON TABLES TO postgrest_anon;
```

- **Test automatique de conformité** : une requête sur `information_schema.role_table_grants`
  comparée à la matrice, exécutée dans la CI `test_migration` — une migration qui crée un
  objet sans les droits attendus (ou avec des droits en trop) fait échouer la CI. C'est la
  réponse structurelle aux incidents de grants incomplets.

### 3. Row-Level Security — quand et comment

RLS filtre les *lignes* selon le rôle ou un contexte de session. Cas d'usage réalistes ici :

- **Visibilité des personnes** : plutôt que de compter sur chaque vue `api` pour filtrer
  `is_visible` (l'oubli = l'incident connu), une politique RLS sur la table porte la règle
  **une seule fois, au niveau du moteur** :

```sql
ALTER TABLE main.personne ENABLE ROW LEVEL SECURITY;
CREATE POLICY visibilite_publique ON main.personne
    FOR SELECT TO postgrest_anon
    USING (is_visible IS DISTINCT FROM false);
```

- **Partenaires territorialisés** (si un jour un partenaire ne doit voir qu'un
  département) : RLS sur le code département + claim JWT — PostgREST transmet les claims
  en variables de session, c'est le pattern standard.

À doser : le RLS ajoute de l'invisible (une requête "qui ne renvoie rien" peut être une
policy) — le documenter dans la matrice et le dictionnaire.

### 4. Secrets et credentials

- Connexions Airflow : dans le secret backend d'Airflow (les `Connections`), jamais dans le
  code des DAGs ni dans les logs — `gitleaks` en pre-commit couvre déjà le repo, étendre la
  vigilance aux logs de tâches (masquage Airflow).
- Tokens PostgREST partenaires : registre des tokens émis (à qui, quand, quel scope, quelle
  date d'expiration), procédure de révocation écrite et **testée**. Rotation des secrets
  JWT documentée.
- Rotation des mots de passe des rôles techniques : procédure écrite (même simple), sinon
  elle n'arrivera jamais.

### 5. Audit des accès

- `audit_trail` (V124) trace les écritures applicatives — c'est l'audit *métier*.
- Pour l'audit *technique* (qui s'est connecté, requêtes sensibles) : `log_connections` +
  `pgaudit` si le besoin de conformité se précise. À cette échelle, commencer par logger
  les connexions et les DDL suffit.

## Par où commencer

1. Écrire la matrice d'accès par rétro-ingénierie des GRANT existants — l'exercice révélera
   les incohérences accumulées (rôles trop larges, droits orphelins).
2. `ALTER DEFAULT PRIVILEGES` sur `api` et `dataviz` + test de conformité des grants en CI.
3. Scinder le rôle pipeline en `etl_extract` / `etl_transform` / `etl_load` (peut se faire
   progressivement).
4. Étudier la policy RLS sur la visibilité des personnes (défense en profondeur contre la
   répétition de l'incident `is_visible`).
5. Registre des tokens partenaires + procédure de révocation.

## Pièges connus

- **La matrice non maintenue** : comme le dictionnaire, sa maintenance doit être
  structurelle — c'est le rôle du test CI de conformité, qui force la synchronisation.
- **Le rôle "temporairement" superuser** : chaque raccourci de droits pris sous pression
  devient permanent. Le test CI de conformité attrape aussi les droits *en trop*.
- **RLS partout** : puissant mais opaque ; le réserver aux règles de sécurité réelles
  (visibilité, cloisonnement partenaire), pas au filtrage métier ordinaire.
- **Tester les GRANT seulement en positif** : vérifier aussi que les rôles ne peuvent PAS
  faire ce qu'ils ne doivent pas (un test `SET ROLE postgrest_anon; UPDATE ... → doit
  échouer` vaut dix relectures).

## Aller plus loin

- **Chiffrement au repos et en transit** : TLS sur les connexions (à vérifier/forcer côté
  hébergeur), chiffrement disque géré par l'infra. Le chiffrement applicatif par colonne
  (pgcrypto) ne se justifierait ici que pour des données ultra-sensibles qui n'existent pas
  encore en base.
- **Dynamic data masking** : masquer nom/email selon le rôle (extension `anon` de la CNIL/
  Dalibo — française, conçue pour le secteur public). Pertinent pour donner un accès
  `dev_readonly` réellement anonymisé à la prod, au lieu du dump pseudonymisé actuel.
  Signal de bascule : si le debugging sur données réelles devient fréquent.
- **Fine-grained access via catalogue** (Immuta, purpose-based access) : hors d'échelle —
  la matrice + RLS couvrent le besoin tant que le nombre de consommateurs reste en dizaines.
- **Zero-trust / BeyondCorp pour la data** : pertinent à l'échelle d'un SI d'État complet,
  pas d'un produit — mais les principes (jamais de confiance implicite par le réseau,
  authentification de chaque accès) sont déjà respectés si la matrice est appliquée.

## Références

- PostgreSQL — *Privileges*, *Row Security Policies*, `ALTER DEFAULT PRIVILEGES`
- PostgREST — *Authentication* (JWT, impersonation de rôles, claims en session)
- PostgreSQL Anonymizer (Dalibo/CNIL) — masquage et anonymisation
- ANSSI — recommandations de sécurisation PostgreSQL
