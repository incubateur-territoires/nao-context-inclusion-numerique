# Coop de la médiation numérique — réplique `coop` vue par l'agent

La Coop (coop-mediation-numerique) est l'application où les médiateurs numériques
déclarent leurs activités, leurs bénéficiaires et leurs lieux. Sa base Prisma est
répliquée dans le schéma `coop` de l'entrepôt. L'agent n'y accède que par des vues
`llm.coop_*`, sans donnée nominative (V178).

## Entités et clés

| Vue | Clé | Ce que c'est |
|-----|-----|--------------|
| `llm.coop_users` | `id` uuid | Compte Coop. Identité masquée : rôle, dates, drapeaux d'inscription, `siret` déclaré. **`llm.personne.coop_id` = `llm.coop_users.id`.** |
| `llm.coop_mediateurs` | `id` uuid ; `user_id` → `coop_users` | Profil médiateur d'un compte (compteurs d'activités, visibilité carto). |
| `llm.coop_coordinateurs` | `id` uuid ; `user_id` → `coop_users` | Profil coordinateur d'un compte. |
| `llm.coop_employes_structures` | `user_id` ⋈ `structure_id` | Emploi déclaré : qui travaille pour quelle structure employeuse (`debut_emploi`, `fin_emploi`, `suppression`). `structure_main_id` → `llm.structure_administrative`. |
| `llm.coop_mediateurs_en_activite` | `mediateur_id` ⋈ `structure_id` | Lieux d'activité d'un médiateur. **`structure_id` pointe `coop_lieu_inclusion`, pas une structure.** |
| `llm.coop_mediateurs_coordonnes` | `mediateur_id` ⋈ `coordinateur_id` | Équipe : quel coordinateur suit quel médiateur. |
| `llm.coop_invitations_equipes` | `coordinateur_id`, `mediateur_id` | Invitations à rejoindre une équipe (courriel invité retiré). |
| `llm.coop_structure_administrative` | `id` uuid ; `siret` | Structures employeuses côté Coop. Pour l'entité canonique : `llm.structure_administrative.structure_coop_id` = cet `id`. |
| `llm.coop_lieu_inclusion` | `id` uuid | Lieux d'activité côté Coop. Entité canonique : `llm.lieu_inclusion.structure_coop_id` = cet `id`. |
| `llm.coop_activites` | `id` uuid ; `mediateur_id` | Une activité déclarée (individuel, collectif, démarche). `structure_id` → `coop_lieu_inclusion` (lieu), `structure_employeuse_id` → `coop_structure_administrative`. Millions de lignes. |
| `llm.coop_accompagnements` | `activite_id` ⋈ `beneficiaire_id` | Qui a été accompagné dans quelle activité. Millions de lignes. |
| `llm.coop_beneficiaires` | `id` uuid ; `mediateur_id` | Bénéficiaires, identité et année de naissance retirées : ne restent que genre, tranche d'âge, statut social, commune. |
| `llm.coop_activite_coordination` | `id` uuid ; `coordinateur_id` | Activités de coordination (animation, événement, partenariat). |
| `llm.coop_tags`, `llm.coop_activite_tags`, `llm.coop_activite_coordination_tags` | | Étiquettes libres posées par les médiateurs et coordinateurs. |
| `llm.coop_partage_statistiques` | | Autorisations de partage de statistiques médiateur → coordinateur. |
| `llm.coop_cras_conseiller_numerique_v1` | `id` texte | Comptes rendus d'activité de l'ancienne plateforme Conseiller numérique (v1), importés. Historique antérieur à la Coop. |
| `llm.coop_rdv_*` | | Rendez-vous synchronisés depuis RDV Service Public (organisations, lieux, motifs, rendez-vous, participations). Les usagers RDV ne sont pas exposés. |

## Relations utiles

```
llm.personne.coop_id ─────────────────────► llm.coop_users.id
llm.coop_mediateurs.user_id ──────────────► llm.coop_users.id
llm.coop_coordinateurs.user_id ───────────► llm.coop_users.id
llm.coop_employes_structures.user_id ─────► llm.coop_users.id
llm.coop_employes_structures.structure_id ► llm.coop_structure_administrative.id
llm.coop_employes_structures.structure_main_id ► llm.structure_administrative.id
llm.coop_mediateurs_en_activite.structure_id ► llm.coop_lieu_inclusion.id   (un LIEU)
llm.coop_activites.mediateur_id ──────────► llm.coop_mediateurs.id
llm.coop_activites.structure_id ──────────► llm.coop_lieu_inclusion.id      (un LIEU)
llm.coop_activites.structure_employeuse_main_id ► llm.structure_administrative.id
llm.coop_accompagnements ─────────────────► activite_id ⋈ beneficiaire_id
llm.coop_beneficiaires.fusion_vers_id ────► llm.coop_beneficiaires.id (doublon fusionné)
llm.coop_lieu_inclusion.id ◄──────────────  llm.lieu_inclusion.structure_coop_id
llm.coop_structure_administrative.id ◄────  llm.structure_administrative.structure_coop_id
```

## Recette : rattacher un compte Coop à son employeur

Un compte peut avoir **plusieurs** lignes d'emploi (anciens emplois conservés) et un
SIRET porte **plusieurs** structures administratives (siège + antennes). Joindre sans
filtrer multiplie les lignes (constaté : 4 548 activités de coordination → 17 571
lignes exportées). La seule jointure correcte :

```sql
LEFT JOIN llm.coop_employes_structures es
       ON es.user_id = u.id
      AND es.suppression IS NULL
      AND es.fin_emploi IS NULL            -- emploi en cours
LEFT JOIN llm.structure_administrative sa
       ON sa.id = es.structure_main_id      -- id canonique, jamais par SIRET
```

Pour un coordinateur : `llm.coop_activite_coordination.coordinateur_id` →
`llm.coop_coordinateurs.id` → `user_id` → la jointure ci-dessus. S'il reste plus
d'un emploi en cours, prendre le plus récent (`DISTINCT ON (u.id) … ORDER BY
es.debut_emploi DESC`).

**Avant de livrer un export ligne à ligne, compter** : le résultat ne doit pas avoir
plus de lignes que la table de base filtrée (`SELECT count(*) FROM
llm.coop_activite_coordination WHERE suppression IS NULL`). S'il en a plus, une
jointure multiplie.

## Pièges

- Dans la Coop, `structure_id` désigne presque toujours un **lieu** (`coop_lieu_inclusion`)
  et non une structure employeuse : lire la relation avant de joindre.
- Suppression logique partout : `suppression` (timestamp) non nul = supprimé ; `deleted`
  sur `coop_users`. Les activités supprimées restent en base.
- `llm.activites_coop` (entrepôt, V144) est déjà une projection de `coop.activites`
  jointe aux entités canoniques (`personne_id`, `lieu_id`) : pour un agrégat
  « entrepôt », la préférer ; pour le détail Coop (statut d'un compte, équipe,
  lieu déclaré par un médiateur), utiliser `llm.coop_*`.
- Les ids Coop sont des uuid, ceux de l'entrepôt des entiers : ne jamais les comparer
  directement ; passer par `coop_id` / `structure_coop_id`.
