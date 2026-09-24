# Modèle de données — ce que désigne chaque entité

Lire ce fichier avant toute question de support (« que s'est-il passé pour … »).
Les colonnes exactes sont dans `databases/…/columns.md` ; ici, le sens et les pièges.

## Les entités

| Entité | Où | Clé | Ce que c'est |
|--------|----|-----|--------------|
| Structure administrative | `llm.structure_administrative` | `id` entier ; `siret` | Personne morale (SIRET). Un même SIRET a souvent plusieurs lignes : le siège (`denomination_antenne` NULL) et ses antennes. |
| Lieu d'inclusion | `llm.lieu_inclusion` | `id` entier | Endroit d'accueil du public (registre unifié Coop + cartographie nationale). |
| Personne | `llm.personne`, `llm.personne_enrichie` | `id` entier ; `coop_id` uuid ; `conseiller_numerique_id` ; `aidant_connect_id` | Médiateur, conseiller numérique, aidant, coordinateur. Identité masquée. |
| Poste | `main.poste` | `id` ; `poste_conum_id` | Financement d'un ETP Conseiller numérique attribué à une structure. |
| Contrat | `main.contrat` | `id` | Contrat de travail d'un conseiller numérique. |
| Subvention | `main.subvention` | `poste_id` | Montants et dates de financement d'un poste (V1, V2). |
| Membre de gouvernance | `llm.membre` | `id` **texte** | Une **organisation** (EPCI, commune, préfecture, association…) siégeant dans la gouvernance d'un département. Pas une personne. |
| Utilisateur MIN | `llm.utilisateur` | `id` entier | Compte de l'application Mon inclusion numérique. Identité masquée : rôle, territoire, dates. |
| Gouvernance | `llm.gouvernance` | `departement_code` | Une par département ; note de contexte. |
| Feuille de route, action, comité, demande de subvention | `min.*` | `id` | Pilotage France Numérique Ensemble par département. |
| Activité Coop | `llm.activites_coop` | `coop_id` | Un accompagnement déclaré par un médiateur (individuel ou collectif). Millions de lignes. |

## Identifiants : formes et pièges

- `llm.membre.id` est un identifiant **métier texte** qui encode ce qu'il désigne :
  `epci-200068641-31` = l'EPCI de SIREN 200068641 dans la gouvernance du département 31 ;
  `commune-31395-31` = la commune INSEE 31395 ; `departement-31-31`, `region-76-76`,
  `prefecture-…`, `structure-<id>-<dep>`. Un même EPCI peut être membre de plusieurs
  gouvernances (un id par département). Pour retrouver la personne morale :
  `structure_id` → `llm.structure_administrative.id`.
- Les `id` de `llm.structure_administrative` et de `llm.lieu_inclusion` **se recouvrent**
  (1353 existe des deux côtés et ne désigne pas la même chose). Toujours qualifier.
- `llm.evenement.entity_id` est du **texte** : id numérique de structure ou id texte de
  membre selon `source_key`. Caster avant de joindre.
- `llm.membre.old_structure_id` / `llm.utilisateur.old_structure_id` renvoient à l'ancien
  référentiel `min.structure`, **hors contexte** (déprécié, id en collision avec les
  structures administratives). Ne jamais nommer une structure autrement que par
  `llm.structure_administrative.denomination_sirene`. Les `structure_id` courants pointent
  `llm.structure_administrative`.

## Relations utiles

```
llm.membre.structure_id ────────────────► llm.structure_administrative.id
llm.utilisateur.structure_id ───────────► llm.structure_administrative.id
main.poste.structure_id ────────────────► llm.structure_administrative.id
main.poste.personne_id ─────────────────► llm.personne.id            (NULL si vacant)
main.contrat.personne_id / structure_id ► llm.personne / llm.structure_administrative
main.subvention.poste_id ───────────────► main.poste.id
main.personne_affectations_emploi ──────► personne_id ⋈ structure_administrative_id (est_active)
main.personne_affectations_lieu ────────► personne_id ⋈ lieu_id (est_active)
llm.activites_coop ─────────────────────► personne_id, lieu_id (NULL si à distance / à domicile), lieu_code_insee
llm.structure_administrative.adresse_id ► llm.adresse.id   (idem llm.lieu_inclusion.adresse_id)
llm.evenement.user_id ──────────────────► llm.utilisateur.id
llm.gouvernance.departement_code ───────► llm.membre.gouvernance_departement_code
```

**Il n'y a plus de lien direct lieu ↔ structure administrative** (table d'association
supprimée en V123). Pour rattacher un lieu à un employeur : lieu → personnes affectées
au lieu → employeur de ces personnes. `llm.lieu_inclusion.siret_a_l_enrichissement` est
un SIRET déclaré à l'import, sans garantie.

## Colonnes exactes des vues d'historique

À utiliser telles quelles, sans deviner (`status` et non `statut`, `action` et non `type`) :

| Vue | Colonnes |
|-----|----------|
| `llm.structure_merge_log` | `id`, `merged_at`, `status`, `dag_id`, `run_id`, `task_id`, `map_index`, `try_number`, `winner_id`, `loser_id`, `similarity_score`, `similarity_threshold`, `winner_before`, `loser_before`, `winner_after`, `moved_identifiers`, `error_message` |
| `llm.personne_merge_log` | idem + `match_type` (après `try_number`) |
| `llm.evenement` | `id`, `ingested_at`, `source_key`, `action`, `entity_id` (texte), `user_id`, `valeur_avant`, `valeur_apres` |

Chercher une structure dans les fusions : `WHERE winner_id = X OR loser_id = X`, trier par
`merged_at`. Chercher une entité dans le journal MIN : `WHERE entity_id = 'X'` (texte),
trier par `ingested_at`. Les intitulés d'une fusion se lisent dans
`winner_before ->> 'denomination_sirene'` et `loser_before ->> 'denomination_sirene'`.

## Cycle de vie : rien n'est vraiment supprimé

| Entité | Suppression logique | Trace de fusion |
|--------|--------------------|-----------------|
| Structure administrative | `deleted_at` | `llm.structure_merge_log` (`loser_id` absorbée par `winner_id`, `moved_identifiers` = SIRET/RNA transférés) |
| Personne | `deleted_at` (posé par une seule source, Aidants Connect ; ne signifie pas « partie ») | `llm.personne_merge_log` |
| Lieu | `deleted_at` | rapprochements carto : `llm.lieu_appariement` |
| Membre | `statut = 'supprimer'` + `date_suppression` (la ligne reste) | — |
| Utilisateur | `is_supprime` | — |
| Poste | `etat = 'rendu'` + `date_rendu_poste` | — |
| Contrat | `date_rupture` (fin anticipée) ; **actif = `date_rupture IS NULL`**, pas `date_fin` | — |

Une structure peut être **recréée** par un import après une fusion : chercher par SIRET
renvoie alors plusieurs lignes, dont une supprimée. `llm.structure_merge_log.dag_id =
'min-ui'` et `similarity_score` NULL = fusion manuelle depuis l'admin MIN ; un score et
un seuil = appariement automatique.

## Valeurs de référence

- `main.poste.typologie` : `conum` (conseiller), `coordo` (coordinateur), `dns`.
  `etat` : `occupe`, `vacant`, `rendu`.
- `main.contrat.type` : `CDD`, `CDI`, `CDP` (contrat de projet), `PEC`, NULL.
- `main.personne_affectations_emploi.source` : `aidants-connect`, `coop`, `idposte`.
- `llm.utilisateur.role` : `gestionnaire_structure`, `gestionnaire_departement`,
  `gestionnaire_groupement`, `gestionnaire_region`, `administrateur_dispositif`.
- `llm.membre.categorie_membre` : `structure`, `epci`, `commune`, `departement`,
  `prefecture_departementale`, `prefecture_regionale`… ; `statut` : `candidat`,
  `confirme`, `supprimer`.
- `llm.activites_coop.type` : `individuel`, `collectif`.

## Territoires

`admin.commune` (code INSEE, EPCI, département), `admin.epci`, `admin.departement`,
`admin.region`, `admin.zonage` (QPV, FRR…), `admin.ifn_*` (indice de fragilité
numérique). Rattacher une structure ou un lieu à un territoire : `adresse_id` →
`llm.adresse.code_insee` → `admin.commune`.
