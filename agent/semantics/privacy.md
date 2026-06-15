# Privacy & accès aux données — Inclusion numérique

Ce document définit les tables autorisées et interdites pour l'agent analytics Nao. Il complète la configuration [`nao_config.yaml`](../../nao_config.yaml) et le rôle Postgres `nao_readonly`.

**Décision Tier 3 :** option B — vues `analytics.*` sans contact ni adresse précise. Voir [`database/decisions/tier3-analytics-views.md`](../../database/decisions/tier3-analytics-views.md).

## Principes

1. Le rôle `nao_readonly` n'a pas accès aux tables sources contenant des PII.
2. Le contexte Nao (`nao sync`) n'inclut pas `preview` ni `profiling` sur les tables sensibles.
3. L'agent doit refuser toute requête visant à identifier ou lister des personnes physiques.

## Tier 1 — Interdit (PII direct)

Ne jamais requêter, afficher ni inférer à partir de :

| Schéma | Table / vue | Données sensibles |
|--------|-------------|-------------------|
| `main` | `personne` | nom, prénom, contact jsonb, IDs externes |
| `main` | `contact` | nom, prénom, email, téléphone |
| `main` | `contact_structure_administrative` | liaison vers contact |
| `min` | `utilisateur` | identité, email, téléphone, SSO |
| `min` | `contact_membre_gouvernance` | email, nom, prénom |
| `min` | `membre` | nom, contact, contact_technique |
| `min` | `personne_enrichie` | vue reprenant `main.personne` |

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

| Source interdite | Vue autorisée |
|------------------|---------------|
| `main.structure_administrative` | `analytics.structure_administrative_publique` |
| `main.structure` | `analytics.structure_publique` |
| `main.lieu_inclusion` | `analytics.lieu_inclusion_publique` |
| `main.adresse` | `analytics.adresse_publique` |
| `min.structure` | `analytics.min_structure_publique` |

Colonnes absentes des vues : `contact`, `edited_by`, `deleted_by`, adresse précise (`numero_voie`, `nom_voie`, `geom`), `import_warnings`.

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

### Schéma `analytics`

Toutes les vues définies dans [`database/sql/01_analytics_views.sql`](../../database/sql/01_analytics_views.sql).

## Exemples de requêtes

### Autorisé

```sql
-- Nombre de lieux par département (via adresse communale)
SELECT a.departement, COUNT(*) AS nb_lieux
FROM analytics.lieu_inclusion_publique li
JOIN analytics.adresse_publique a ON a.id = li.adresse_id
GROUP BY a.departement
ORDER BY nb_lieux DESC
LIMIT 20;
```

```sql
-- Montant cumulé des subventions V2
SELECT SUM(montant_subvention_v2) AS total_v2
FROM main.subvention;
```

### Refusé

```sql
-- INTERDIT : liste nominative
SELECT prenom, nom, contact FROM main.personne LIMIT 10;

-- INTERDIT : email des utilisateurs MIN
SELECT email_de_contact FROM min.utilisateur;

-- INTERDIT : jointure vers personne
SELECT p.nom, sa.denomination_sirene
FROM main.personne p
JOIN main.personne_affectations_emploi pae ON pae.personne_id = p.id
JOIN analytics.structure_administrative_publique sa ON sa.id = pae.structure_administrative_id;
```

## Déploiement base de données

1. Exécuter `database/sql/01_analytics_views.sql`
2. Exécuter `database/sql/02_nao_readonly_role.sql` (changer le mot de passe)
3. Configurer les variables d'environnement `NAO_READONLY_USER` / `NAO_READONLY_PASSWORD`
4. Lancer `nao sync`
