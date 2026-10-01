# Confidentialité et périmètre d'accès — Inclusion numérique

## Principe : la base décide

La protection des données personnelles est appliquée **dans Postgres**, pas dans ce
dépôt :

- le rôle `nao_ro` ne lit **aucune** table portant un nom, un prénom, un courriel ou un
  téléphone de personne physique ; à leur place, des vues `llm.*` purgées de ces
  colonnes (migrations V102, V103, V172, V173 du dépôt dataspace) ;
- les journaux (fusions, modifications MIN) sont servis à travers `llm.purger_pii()`,
  qui retire récursivement les clés nominatives des instantanés JSON ;
- les textes libres conservés passent par `llm.masquer_coordonnees()` (courriels et
  téléphones remplacés par un libellé neutre).

Conséquence pour l'agent : **tout ce qui est lisible est utilisable**. La liste
`include` de `nao_config.yaml` reproduit le périmètre de `nao_ro` et
`allow_listed_only` en fait une frontière dure à l'exécution.

## Ce que l'agent ne fait pas

- Reconstituer l'identité d'une personne (croisement d'indices, recherche d'un nom dans
  un texte libre, déduction depuis un identifiant externe).
- Présenter un identifiant technique comme une identité (« la personne 4512 est … »).

Ce sont les deux seules règles de comportement. Pas de refus sur les membres,
structures, lieux, utilisateurs, postes ou contrats : ce ne sont pas des personnes
identifiables.

## Périmètre lu par `nao_ro`

### Schéma `llm` — vues curées (38)

| Vue | Source | Ce qui est retiré |
|-----|--------|-------------------|
| `llm.personne` | `main.personne` | prénom, nom, `contact`, `edited_by`, `deleted_by` ; `profession_ac` mis à NULL s'il contient un courriel |
| `llm.personne_enrichie` | `min.personne_enrichie` | idem + garde les drapeaux d'activité |
| `llm.contact` | `main.contact` | nom, prénom, email, téléphone (reste `fonction`) |
| `llm.structure_administrative` | `main.structure_administrative` | nom / prénom / courriels du `contact` (garde site web + téléphone d'organisation) |
| `llm.lieu_inclusion` | `main.lieu_inclusion` | courriels de gestionnaire / référent, `presentation_*`, `import_warnings` ; `nom`, `horaires`, `prise_rdv`, `complement_adresse` masqués (garde site web, téléphone, courriel générique du lieu) |
| `llm.lieu_appariement` | `main.lieu_appariement` | `decide_par` (courriel du décideur) |
| `llm.adresse` | `main.adresse` | `nom_voie` mis à NULL quand la valeur importée n'était pas un nom de voie (bloc d'adresse brut avec nom / courriel) |
| `llm.activites_coop` | `main.activites_coop` | `precisions_demarche` (texte libre saisi par les médiateurs) |
| `llm.utilisateur` | `min.utilisateur` | nom, prénom, courriels, `sso_id`, téléphone |
| `llm.membre` | `min.membre` | `contact`, `contact_technique` |
| `llm.gouvernance` | `min.gouvernance` | `note_privee`, son éditeur ; `note_de_contexte` masquée |
| `llm.structure_merge_log` | `audit.structure_merge_log` | clés nominatives des instantanés |
| `llm.personne_merge_log` | `audit.personne_merge_log` | idem |
| `llm.evenement` | `source.min__evenements` | idem, `donnee` éclatée en colonnes |
| `llm.membre_transfert_log` | `min.membre_transfert_log` | `par_utilisateur` (identifiant de connexion) remplacé par `par_utilisateur_id` → `llm.utilisateur` |
| `llm.coop_users` | `coop.users` | prénom, nom, courriel, téléphone, photo, localisation, titre, description |
| `llm.coop_beneficiaires` | `coop.beneficiaires` | prénom, nom, téléphone, courriel, adresse, notes, année de naissance, liens RDV usager |
| `llm.coop_structure_administrative` | `coop.structure_administrative` | référent nommé (nom, courriel, téléphone) |
| `llm.coop_lieu_inclusion` | `coop.lieu_inclusion` | référent nommé, `courriels`, `presentation_*` ; `nom`, `horaires`, `prise_rdv` masqués |
| `llm.coop_activites` | `coop.activites` | `notes`, `precisions_demarche` ; `titre_atelier` masqué |
| `llm.coop_activite_coordination` | `coop.activite_coordination` | `notes` ; champs « autre » et `nom` masqués |
| `llm.coop_tags` | `coop.tags` | `nom` et `description` masqués |
| `llm.coop_cras_conseiller_numerique_v1` | `coop.cras_conseiller_numerique_v1` | `annotation`, courriel et téléphone de permanence |
| `llm.coop_rdvs`, `llm.coop_rdv_participations` | `coop.rdvs`, `coop.rdv_participations` | `raw_data`, `context` ; usagers RDV non exposés |
| `llm.coop_invitations_equipes` | `coop.invitations_equipes` | `email` de l'invité |
| `llm.coop_mediateurs`, `llm.coop_coordinateurs`, `llm.coop_employes_structures`, `llm.coop_mediateurs_en_activite`, `llm.coop_mediateurs_coordonnes`, `llm.coop_partage_statistiques`, `llm.coop_accompagnements`, `llm.coop_activite_tags`, `llm.coop_activite_coordination_tags`, `llm.coop_rdv_lieux`, `llm.coop_rdv_motifs` | tables `coop` du même nom | rien (identifiants, dates, compteurs, coordonnées d'organisation) |
| `llm.coop_rdv_organisations` | `coop.rdv_organisations` | `email` mis à NULL s'il est de forme prénom.nom@ |

### Tables en accès direct (pseudonymisées : identifiants, jamais de nominatif)

- `main` : `poste`, `contrat`, `formation`, `subvention`,
  `personne_affectations_emploi`, `personne_affectations_lieu`,
  `contact_structure_administrative`.
- `min` : `action`, `beneficiaire_subvention`, `co_financement`, `comite`,
  `demande_de_subvention`, `feuille_de_route`, `porteur_action`,
  `postes_conseiller_numerique_synthese`, `feuille_de_route_document`, `departement`,
  `region`, `groupement`, `enveloppe_financement`, `departement_enveloppe`.
- `admin.*` et `reference.*` en entier (référentiels territoriaux, nomenclatures).

### Sans accès (et sans remplaçant)

`main.personne`, `main.contact`, `main.structure_administrative`,
`main.lieu_inclusion`, `main.lieu_appariement`, `main.adresse`, `main.activites_coop`, `min.utilisateur`, `min.membre`,
`min.personne_enrichie`, `min.contact_membre_gouvernance`,
`min.gouvernance`, `min.membre_transfert_log`, `min._prisma_migrations`, et tous les schémas
`source`, `staging`, `audit`, `coop` (lu uniquement à travers `llm.coop_*`), `import`, `api`,
`dataviz`.

## Faire évoluer le périmètre

1. Migration Flyway côté dataspace (vue `llm.*` ou `GRANT`/`REVOKE` sur `nao_ro`).
2. Reporter la table dans `include` de `nao_config.yaml`.
3. `nao sync`, commit, « Pull latest » côté Nao.
4. `python3 scripts/verify-privacy-config.py` vérifie la cohérence des deux.
