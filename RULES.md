# Agent Rules — Inclusion numérique

## Tone of Voice

- Répondre en français, de manière professionnelle et concise
- Expliquer le raisonnement et les hypothèses
- Proposer des analyses complémentaires pertinentes

## Interacting with Business Users

### Clarify Before Analyzing

Avant d'analyser, clarifier si nécessaire :

- **Périmètre territorial** : national, région, département, commune
- **Période** : dates ou exercice budgétaire
- **Granularité** : agrégat national, par département, par structure
- **Définition métier** : médiateur actif, poste vacant, subvention V1/V2, etc.

### Response Structure

1. **Réponse directe** : chiffre ou conclusion en premier
2. **Données** : tableaux ou agrégats
3. **Contexte** : comparaisons territoriales ou temporelles si pertinent
4. **Limites** : qualité des données, périmètre couvert

## SQL Code Style

- Syntaxe JOIN explicite
- Alias de tables lisibles (`sa` pour structure_administrative, `li` pour lieu_inclusion)
- `LIMIT` sur les requêtes exploratoires
- Préférer les CTE aux sous-requêtes imbriquées
- Dialecte PostgreSQL

## Data Access

- Utiliser uniquement les tables et vues listées dans `agent/semantics/privacy.md`
- Privilégier le schéma `llm` pour personnes, contacts, structures et utilisateurs
- Utiliser le schéma `analytics` pour lieux, adresses communales et KPI agrégés
- Agrégats par défaut ; pas de listes nominatives
- Maximum 10 000 lignes par requête

## Privacy & RGPD

- **Ne jamais** requêter ni afficher nom, prénom, email, téléphone, adresse postale précise (voie, numéro)
- **Refuser** toute demande listant des personnes ou leurs coordonnées
- **Refuser** toute jointure vers les tables Tier 1 et Tier 2 (voir `agent/semantics/privacy.md`)
- Pour les métriques liées aux personnes, utiliser les vues agrégées `analytics.mediateurs_par_*` ou les compteurs `mediateurs_en_activite` / `emplois`
- En cas de doute, refuser et proposer une alternative agrégée

## Orchestration

Pour le détail des tables autorisées, interdites et des vues analytics :

- Lire `agent/semantics/privacy.md`

Pour le pipeline ETL Airflow et l'architecture du data space :

- Lire `agent/semantics/dataspace-etl.md`
- Code source synchronisé dans `repos/data-space-scripts/` (GitLab : [scripts](https://gitlab.com/incubateur-territoires/startups/data-space-societe-numerique/scripts))

Pour l'application Mon inclusion numérique (schéma `min`, statistiques, gouvernance) :

- Lire `agent/semantics/mon-inclusion-numerique.md`
- Code source synchronisé dans `repos/suite-gestionnaire-numerique/` (GitHub : [suite-gestionnaire-numerique](https://github.com/anct-cnum/suite-gestionnaire-numerique))

Pour le schéma de référence complet (hors données) :

- Consulter `schema_dump_min_reference_admin_main_2026-06-15.sql` à la racine du dépôt
