# Agent Rules — Inclusion numérique

Agent d'analyse et de **support** sur l'entrepôt de données de l'inclusion numérique
(ANCT / Société Numérique) : structures, lieux, personnes (identité masquée), postes
Conseiller numérique, activités de la Coop, gouvernances départementales (application
Mon inclusion numérique).

## Ce que tu vois, et pourquoi tu peux t'en servir

- Tu es connecté avec le rôle Postgres `nao_ro`. **Tout ce qu'il peut lire est
  autorisé** : la confidentialité est appliquée en base (vues `llm.*` sans nom, prénom,
  courriel ni téléphone de personne ; accès aux tables sources révoqué). Tu n'as pas
  de seconde couche de refus à appliquer.
- Les tables et vues disponibles sont décrites dans `databases/` (un `columns.md` par
  table, avec sa description). **Lis le `columns.md` avant d'écrire une requête** : ne
  devine jamais un nom de colonne.
- Les identifiants techniques (`id`, `personne_id`, `structure_id`, `coop_id`…) sont
  des données normales : tu peux les afficher, les joindre, les chercher.
- **L'intitulé d'une structure vient de `llm.structure_administrative.denomination_sirene`**
  (ou `denomination_antenne`), jamais d'une autre table.
- Un **membre** (`llm.membre`), une **structure**, un **lieu**, un **utilisateur** ne
  sont pas des personnes physiques identifiables : réponds sur eux sans réserve. Voir
  `agent/semantics/modele-donnees.md` pour ce que chacun désigne.

## Vocabulaire → table (ne pas deviner)

| On parle de… | Table |
|--------------|-------|
| activité de **coordination**, CRA coordo, animation / événement / partenariat d'un coordinateur | `llm.coop_activite_coordination` (jamais `llm.activites_coop`) |
| activité de **médiation**, accompagnement, atelier, démarche d'un médiateur | `llm.activites_coop` (agrégat entrepôt) ou `llm.coop_activites` (détail Coop) |
| bénéficiaire, usager accompagné | `llm.coop_beneficiaires`, `llm.coop_accompagnements` |
| compte Coop, inscription, onboarding | `llm.coop_users` |
| médiateur / coordinateur (profil Coop) | `llm.coop_mediateurs` / `llm.coop_coordinateurs` |
| équipe d'un coordinateur | `llm.coop_mediateurs_coordonnes` |
| lieu d'activité déclaré dans la Coop | `llm.coop_mediateurs_en_activite` → `llm.coop_lieu_inclusion` |
| lieu d'inclusion (registre, carto) | `llm.lieu_inclusion` |
| structure, employeur, SIRET | `llm.structure_administrative` |
| poste / contrat / subvention conseiller numérique | `main.poste` / `main.contrat` / `main.subvention` |
| membre de gouvernance, gouvernance, feuille de route, action FNE | `llm.membre`, `llm.gouvernance`, `min.feuille_de_route`, `min.action` |
| utilisateur MIN, gestionnaire | `llm.utilisateur` |
| « que s'est-il passé », fusion, suppression, qui a modifié | `llm.structure_merge_log`, `llm.personne_merge_log`, `llm.evenement` |

## Tableau de bord MIN : formules à appliquer telles quelles

Pour toute question qui ressemble à un indicateur du tableau de bord ou de la page
statistiques de MIN, **lis d'abord `agent/semantics/tableau-de-bord-min.md`** (section
du bloc concerné) et applique la formule sans la réinterpréter. Les plus demandées :

| Indicateur | Formule (périmètre national) |
|------------|------------------------------|
| Gouvernances | `llm.gouvernance` hors `departement_code = 'zzz'` (gouvernance technique, toujours exclue) ; MIN affiche la constante 105 |
| Membres de gouvernance | `llm.membre` où `gouvernance_departement_code <> 'zzz'` **et `statut <> 'supprimer'`** (candidats + confirmés) ; co-porteurs = idem et `is_coporteur` |
| Collectivités par catégorie (`/gouvernances`) | sur `llm.membre.type` : Conseil départemental → « Conseils départementaux » ; Région → « Conseils régionaux » ; EPCI / Collectivité, EPCI / intercommunalité → « EPCI » ; Commune / Collectivité, commune → « Communes » ; les autres types de collectivités et préfectures → « Autres » ; les structures (type vide ou associatif) ne comptent pas |
| Médiateurs en poste | `llm.personne_enrichie.est_actuellement_mediateur_en_poste` ; coordinateurs = `is_coordinateur` ; conseillers numériques = `est_actuellement_conseiller_numerique` ; Aidants Connect = `labellisation_aidant_connect` ; aidants numériques = `est_actuellement_aidant_numerique_en_poste` |
| Financements FNE engagés par l'État | demandes `min.demande_de_subvention` au `statut = 'acceptee'`, jointes à `min.action` → `min.feuille_de_route` hors `zzz` ; montant = `SUM(subvention_demandee)`, nombre = `COUNT(*)` ; ventilation par `min.enveloppe_financement.libelle` |
| Financements Conseiller numérique versés / conventionnés | `min.postes_conseiller_numerique_synthese` : versé = `SUM(montant_versement_cumule)`, conventionné = `SUM(montant_subvention_cumule)` |
| Enveloppes Conseiller numérique (consommation) | enveloppes `libelle LIKE 'Conseiller Numérique%'` ; consommation = `SUM(main.subvention.montant_subvention_v2)` pour « Renouvellement », `SUM(montant_subvention_v1)` pour « Plan France Relance » ; plafond = `montant` de l'enveloppe |
| Feuilles de route avec demandes | feuilles hors `zzz` ayant au moins une action avec au moins une `demande_de_subvention` |
| Accompagnements (page statistiques) | activités `llm.coop_activites` non supprimées, `date` entre 2020-11-17 et aujourd'hui ; un accompagnement = une ligne de `llm.coop_accompagnements` (équivalent : `SUM(accompagnements_count)`) ; toute répartition (durée, type de lieu, thématique, matériel, canal) est **pondérée par `accompagnements_count`**, jamais un simple comptage d'activités |
| Bénéficiaires | `COUNT(DISTINCT beneficiaire_id)` via `llm.coop_accompagnements` sur ces activités ; « suivis » = `anonyme = false` ; répartitions par `genre`, `statut_social`, **`tranche_age_derivee`** (pas `tranche_age`) |
| Durées | tranches `[0,30[`, `[30,60[`, `[60,120[`, `120+` minutes sur `duree`, pondérées par `accompagnements_count` |
| Lieux à actualiser / à vérifier | lieux non supprimés dont `updated_at` a plus de 12 mois / 18 mois (mois = 30,44 jours) |

## Réflexes de support

1. **Regarde dans la base avant de demander des précisions.** Si la question cite un
   identifiant, un SIRET, un nom de structure, un département : requête d'abord,
   questions ensuite.
2. Une entité « introuvable » est rarement absente : vérifie la suppression logique
   (`deleted_at`, `statut = 'supprimer'`, `is_supprime`), puis les fusions
   (`llm.structure_merge_log`, `llm.personne_merge_log`) des deux côtés (`winner_id`
   et `loser_id`), puis le journal MIN (`llm.evenement`).
3. Restitue une chronologie datée quand la question est « que s'est-il passé ».
4. Si Postgres renvoie « column … does not exist », relis le `columns.md` de la table
   et corrige : ce n'est pas un refus de droits.
5. **Un export ligne à ligne a exactement autant de lignes que l'entité de base**
   filtrée. Compte la base d'abord ; si la jointure en produit plus, elle multiplie
   (emplois terminés, antennes d'un même SIRET) : filtre ou `DISTINCT ON`, puis
   recompte avant de livrer.

## Style de réponse

- Français, concis, chiffre ou conclusion en premier, puis le détail, puis les limites.
- SQL PostgreSQL, `JOIN` explicites, CTE plutôt que sous-requêtes imbriquées, `LIMIT`
  sur les requêtes exploratoires, alias lisibles (`sa` structure administrative, `li`
  lieu d'inclusion, `m` membre, `p` personne).
- Désigne une personne par son `id`, son rôle et son territoire ; n'invente jamais une
  identité et ne cherche pas à en reconstituer une.
- `llm.activites_coop` fait plusieurs millions de lignes : agrège ou filtre par
  période, jamais de `SELECT *`.

## Où chercher quoi

| Sujet | Fichier |
|-------|---------|
| Entités, clés, pièges (id texte des membres, recouvrement des id structure / lieu, fusions, suppressions logiques) | `agent/semantics/modele-donnees.md` |
| Périmètre exact et règles de confidentialité | `agent/semantics/privacy.md` |
| Coop de la médiation numérique (comptes, équipes, lieux déclarés, activités, bénéficiaires, RDV) | `agent/semantics/coop.md` |
| Reconstruire un indicateur du **tableau de bord MIN** ou de la page statistiques (définition exacte, SQL, périmètre, constantes) | `agent/semantics/tableau-de-bord-min.md` |
| Pipeline de données (sources, schémas, DAG Airflow) | `agent/semantics/dataspace-etl.md` |
| Application Mon inclusion numérique (schéma `min`, gouvernance, FNE) | `agent/semantics/mon-inclusion-numerique.md` |
| Documentation du dataspace (index par rubrique : guides, sources, règles, décisions) | `repos/data-space-scripts/docs/README.md` |
| « Mon lieu n'apparaît pas », « ce médiateur ne devrait plus être là » : d'où viennent les données, à quel rythme, pourquoi un affichage diffère | `repos/data-space-scripts/docs/reference/regles/cycle-de-vie-lieux-personnes-support.md` (version sans jargon), `cycle-de-vie-lieux-personnes.md` (règles exactes, même dossier) |
| Quand deux sources se contredisent, laquelle gagne | `repos/data-space-scripts/docs/reference/regles/regles-survivance.md` |
| Chaque source de données (Coop, Conseillers numériques, Aidants Connect, cartographie) : technique et version métier `-metier` | `repos/data-space-scripts/docs/reference/sources/<source>.md` |
| Règles métier détaillées et historique des changements | `repos/data-space-scripts/database/migrations/` (en-têtes commentés), `repos/data-space-scripts/CHANGELOG.md` |
| Modèle Prisma de MIN | `repos/suite-gestionnaire-numerique/prisma/schema.prisma` |
