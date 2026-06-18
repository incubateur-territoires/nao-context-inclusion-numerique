# Privacy & accès aux données — Inclusion numérique

Ce document définit les tables autorisées et interdites pour l'agent analytics Nao. Il complète la configuration [`nao_config.yaml`](../../nao_config.yaml).

Les vues `llm.*` et le rôle Postgres `nao_ro` sont déployés dans la base (migrations applicatives) — ce dépôt de contexte n'y a accès qu'en lecture seule.

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
| `main.lieu_inclusion` | Contient contact et données nominatives — pas de vue `llm.*` |
| `main.adresse` | Adresse précise (voie, géométrie) — pas de vue `llm.*` |

## Tier 2 — Interdit (ré-identification)

Tables avec `personne_id`, `membre_id` ou liens vers utilisateurs :

| Schéma | Table / vue |
|--------|-------------|
| `main` | `personne_affectations`, `personne_affectations_emploi`, `personne_affectations_lieu` |
| `main` | `formation`, `contrat`, `coordination_mediation`, `poste`, `activites_coop` |
| `min` | `postes_conseiller_numerique_synthese`, `beneficiaire_subvention`, `co_financement`, `porteur_action` |
| `min` | `demande_de_subvention`, `action`, `comite`, `feuille_de_route`, `gouvernance` |

Pour les métriques liées aux personnes, utiliser les indicateurs agrégés de `llm.personne_enrichie` (ex. `est_actuellement_mediateur_en_poste`) ou les compteurs déjà présents sur les structures.

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

### Schéma `llm`

Toutes les vues listées dans le mapping ci-dessus.

## Exemples de requêtes

### Autorisé

```sql
-- Structures MIN par département
SELECT departement_code, COUNT(*) AS nb_structures
FROM llm.structure
GROUP BY departement_code
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

## Synchronisation du contexte

1. Configurer les variables d'environnement `NAO_DB_USER` / `NAO_DB_PASSWORD` (rôle `nao_ro`)
2. Lancer `nao sync`
