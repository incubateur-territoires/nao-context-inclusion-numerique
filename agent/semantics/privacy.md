# Privacy & accès aux données — Inclusion numérique

Ce document définit les tables autorisées et interdites pour l'agent analytics Nao. Il complète la configuration [`nao_config.yaml`](../../nao_config.yaml) et le rôle Postgres `nao_ro`.

**Décisions :**
- Vues `llm.*` — même grain que les tables sources, colonnes PII retirées. Voir [`database/sql/00_llm_views.sql`](../../database/sql/00_llm_views.sql).
- Vues `analytics.*` — lieux, adresses communales et KPI agrégés. Voir [`database/decisions/tier3-analytics-views.md`](../../database/decisions/tier3-analytics-views.md).

## Principes

1. Le rôle `nao_ro` n'a pas accès aux tables sources contenant des PII.
2. Le contexte Nao (`nao sync`) n'inclut pas `preview` ni `profiling` sur les tables sensibles.
3. L'agent doit refuser toute requête visant à identifier ou lister des personnes physiques.

## Mapping source → vue `llm.*`

| Source (accès révoqué) | Vue autorisée | Colonnes PII retirées |
|------------------------|---------------|------------------------|
| `main.personne` | `llm.personne` | prenom, nom, contact jsonb, edited_by, deleted_by |
| `main.contact` | `llm.contact` | nom, prenom, email, telephone |
| `main.structure_administrative` | `llm.structure_administrative` | nom/prenom/courriels du jsonb contact (garde site_web + telephone org) |
| `min.utilisateur` | `llm.utilisateur` | nom, prenom, email_de_contact, sso_email, sso_id, telephone |
| `min.structure` | `llm.structure` | contact jsonb (référent nommé), adresse postale |
| `min.membre` | `llm.membre` | contact, contact_technique (emails perso) |
| `min.personne_enrichie` | `llm.personne_enrichie` | prenom, nom, contact jsonb, edited_by, deleted_by |

### Accès coupé (pas de remplaçant)

| Table | Raison |
|-------|--------|
| `main.structure` | Table legacy en voie de disparition |
| `min.contact_membre_gouvernance` | Table 100 % PII (vue supprimée en V103) |
| `main.contact_structure_administrative` | Liaison vers `main.contact` |

## Tier 2 — Interdit (ré-identification)

Tables avec `personne_id`, `membre_id` ou liens vers utilisateurs :

| Schéma | Table / vue |
|--------|-------------|
| `main` | `personne_affectations`, `personne_affectations_emploi`, `personne_affectations_lieu` |
| `main` | `formation`, `contrat`, `coordination_mediation`, `poste`, `activites_coop` |
| `min` | `postes_conseiller_numerique_synthese`, `beneficiaire_subvention`, `co_financement`, `porteur_action` |
| `min` | `demande_de_subvention`, `action`, `comite`, `feuille_de_route`, `gouvernance` |

**Alternative agrégée :** utiliser `analytics.mediateurs_par_structure`, `analytics.mediateurs_par_lieu`, `analytics.postes_synthese`.

## Tier 3 — Sources brutes interdites, vues analytics autorisées

Pour les lieux et adresses (pas de vue `llm.*` équivalente) :

| Source interdite | Vue autorisée |
|------------------|---------------|
| `main.lieu_inclusion` | `analytics.lieu_inclusion_publique` |
| `main.adresse` | `analytics.adresse_publique` |

Colonnes absentes des vues analytics : `contact`, `edited_by`, `deleted_by`, adresse précise (`numero_voie`, `nom_voie`, `geom`), `import_warnings`.

## Tier 4 — Autorisé

### Schéma `admin` (intégralité)

`commune`, `departement`, `region`, `epci`, `commune_epci`, `coll_terr`, `icp_departement`, `ifn_commune`, `ifn_departement`, `insee_cp`, `insee_historique`, `zonage`

### Schéma `reference` (intégralité)

`categories_juridiques`, `naf`

### Schéma `main`

- `subvention` — montants et dates de financement (sans noms)
- `lieu_inclusion_structure_administrative` — liaison N:N lieu / structure

### Schéma `min`

- `departement`, `region`, `groupement`
- `enveloppe_financement`, `departement_enveloppe`

### Schémas `llm` et `analytics`

Toutes les vues définies dans [`database/sql/00_llm_views.sql`](../../database/sql/00_llm_views.sql) et [`database/sql/01_analytics_views.sql`](../../database/sql/01_analytics_views.sql).

## Exemples de requêtes

### Autorisé

```sql
-- Structures administratives par département (via adresse communale)
SELECT a.departement, COUNT(*) AS nb_structures
FROM llm.structure_administrative sa
JOIN analytics.adresse_publique a ON a.id = sa.adresse_id
GROUP BY a.departement
ORDER BY nb_structures DESC
LIMIT 20;
```

```sql
-- Médiateurs en poste par structure (sans identité)
SELECT sa.denomination_sirene, COUNT(*) AS nb_mediateurs
FROM llm.personne_enrichie pe
JOIN llm.structure_administrative sa ON sa.id = pe.structure_employeuse_id
WHERE pe.est_actuellement_mediateur_en_poste
GROUP BY sa.denomination_sirene
ORDER BY nb_mediateurs DESC
LIMIT 20;
```

```sql
-- Montant cumulé des subventions V2
SELECT SUM(montant_subvention_v2) AS total_v2
FROM main.subvention;
```

### Refusé

```sql
-- INTERDIT : table source avec PII
SELECT prenom, nom, contact FROM main.personne LIMIT 10;

-- INTERDIT : email des utilisateurs MIN
SELECT email_de_contact FROM min.utilisateur;

-- INTERDIT : table legacy sans remplaçant
SELECT nom, contact FROM main.structure;

-- INTERDIT : jointure Tier 2 vers identité
SELECT p.nom, sa.denomination_sirene
FROM main.personne p
JOIN main.personne_affectations_emploi pae ON pae.personne_id = p.id
JOIN llm.structure_administrative sa ON sa.id = pae.structure_administrative_id;
```

## Déploiement base de données

1. Exécuter `database/sql/00_llm_views.sql`
2. Exécuter `database/sql/01_analytics_views.sql`
3. Exécuter `database/sql/02_nao_readonly_role.sql` (changer le mot de passe)
4. Configurer les variables d'environnement `NAO_DB_USER` / `NAO_DB_PASSWORD`
5. Lancer `nao sync`
