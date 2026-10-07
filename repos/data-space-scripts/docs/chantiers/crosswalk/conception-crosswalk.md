# 21 — Conception du crosswalk d'identifiants

← [Retour au document central](../../architecture/README.md)

> **Document de conception, AVANT tout code** — prérequis n°2 de la bascule dbt
> ([fiche 05](../../architecture/transformations-elt-dbt.md#prérequis-avant-le-premier-modèle)),
> concrétise la [fiche 04 §1](../../architecture/mdm-reconciliation.md). Les choix structurants sont
> présentés en points de décision (proposition + case à trancher). Aucune migration ne
> doit être écrite tant que ces points ne sont pas validés.
>
> Statut : **spec en attente de validation** — rédigée le 2026-07-31.

## Rappel du problème (audité 2026-07-29, fiche 04)

- Les ID pivots du gold (`main.personne.id`, `structure_administrative.id`,
  `lieu_inclusion.id`) sont des **entiers de séquence** : stables tant que la base vit,
  mais **non reproductibles** — toute reconstruction du gold (ce que fait dbt) les
  changerait, cassant MIN et les consommateurs API qui les stockent.
- La correspondance « entité réelle ↔ identifiants sources » n'existe que sous forme de
  **colonnes dans les tables gold** (`coop_id`, `structure_ac_id`…) : elle disparaît
  avec la ligne (fusion = DELETE du perdant), ne garde aucun historique (rotation des
  UUID coop = écrasement), et rend la défusion impossible.

Le crosswalk inverse la dépendance : l'identité devient une **donnée pérenne,
indépendante du cycle de vie des tables gold** — le gold peut alors être reconstruit
sans que personne ne perde ses références.

## Ce que le crosswalk est — et n'est pas

| Est | N'est pas |
|---|---|
| Le registre pérenne « tel identifiant source = telle entité pivot » | Un outil de matching : il **enregistre** les rapprochements décidés (par les règles ou par un humain), il ne les calcule pas (ça reste fiche 04 §2) |
| Le contrat de stabilité des ID exposés (MIN, API) | Une table de plus à maintenir à la main : elle est alimentée par les mêmes événements que le gold |
| Le support structurel des fusions/défusions | La règle de survivance (fiche 20) : il dit « qui est qui », pas « quelle valeur gagne » |

## Décision C1 — Périmètre des entités

**Proposition : 3 entités en v1, dans cet ordre.**

| Entité | Dans le périmètre ? | Justification |
|---|---|---|
| `structure_administrative` | **Oui — v1** | 3 identifiants sources + clé siret/antenne ; c'est là que les fusions/défusions font le plus mal |
| `personne` | **Oui — v1** | 4 identifiants sources ; seule entité avec fusion automatique mensuelle (DELETE physique) — le crosswalk en garde enfin la trace structurelle |
| `lieu_inclusion` | **Oui — v1** | 2 identifiants sources, rapprochement coop↔carto par regex à tracer |
| `adresse` | **Non** | Pas un problème d'identité multi-source : la BAN fournit déjà l'identifiant pivot (`code_ban`) ; les clés naturelles suffisent |
| `poste` / `contrat` | **Non (bloqué)** | TRUNCATE à chaque millésime et `contrat` sans aucune clé métier — dépend de la décision fiche 20 (définir une clé métier d'abord). À réévaluer ensuite |

Décision : ☐

## Décision C2 — Une table par entité vs une table générique

**Proposition : une table par entité** (`crosswalk.structure`, `crosswalk.personne`,
`crosswalk.lieu` — schéma : voir C8), colonnes identiques.

- Pour : contraintes propres (enum de sources par entité), volumétrie et index séparés,
  requêtes lisibles, FK possibles vers la table gold correspondante pendant la
  transition.
- Contre (générique) : une seule table à administrer — mais `source_key` perdrait tout
  typage sémantique et les contraintes par entité deviennent des CHECK conditionnels.

Décision : ☐

## Décision C3 — Schéma de table

**Proposition** (par entité, ici structure) :

```sql
CREATE TABLE crosswalk.structure (   -- schéma : décision C8
    uuid          uuid        NOT NULL,             -- ID pivot exposé (MIN, API)
    source        text        NOT NULL,             -- namespace d'identifiant, cf. C4
    source_key    text        NOT NULL,             -- valeur de l'identifiant dans la source
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    retired_at    timestamptz,                      -- clé plus jamais émise par la source
                                                    -- (rotation coop, fusion) — jamais DELETE
    PRIMARY KEY (source, source_key)
);
CREATE INDEX ON crosswalk.structure (uuid);
```

Points notables :

- **PK sur `(source, source_key)`** : une clé source pointe vers exactement un pivot à
  la fois. Une fusion réattribue le `uuid` de la ligne (UPDATE), l'historique de la
  réattribution vit dans `merge_log` (pas de duplication ici).
- **Jamais de DELETE** : une clé disparue (rotation coop, source morte) est marquée
  `retired_at`. « Un UUID attribué ne change jamais » ; une clé retirée qui réapparaît
  retrouve son pivot.
- **Pas de colonne de données métier** : le crosswalk ne porte que l'identité. Scores et
  règles de matching restent dans les tables de similarités (fiche 04 §2), les valeurs
  dans le gold.

Décision : ☐

## Décision C4 — Namespaces `source`

Un « identifiant source » n'est pas juste « la source » : personne en a 4 dont 2 pour la
même source amont. **Proposition : un namespace par TYPE d'identifiant**, énuméré par
CHECK :

| Entité | Namespaces proposés | Colonne gold actuelle correspondante |
|---|---|---|
| structure | `coop`, `ac`, `idposte`, `siret_antenne` | `structure_coop_id`, `structure_ac_id`, `structure_tp_id`, `(siret, denomination_antenne)` sérialisé `siret\|antenne` |
| personne | `coop`, `ac`, `conseiller_numerique`, `cn_pg` | `coop_id`, `aidant_connect_id`, `conseiller_numerique_id`, `cn_pg_id` |
| lieu | `carto`, `coop` | `structure_cartographie_nationale_id`, `structure_coop_id` |

Le namespace `siret_antenne` (clé fédératrice actuelle, pas un ID source à proprement
parler) est inclus : c'est LA clé par laquelle les sources se rencontrent aujourd'hui —
l'exclure rendrait le crosswalk incapable d'exprimer le matching existant.

Décision : ☐

## Décision C5 — Attribution des UUID pivots

Deux stratégies possibles :

| Stratégie | Principe | Limite |
|---|---|---|
| **UUID généré à la première apparition** (v7 recommandé : triable par temps) | Le déterminisme vient de la **pérennité de la table** (jamais tronquée, sauvegardée en criticité maximale — fiche 13), pas d'un calcul | La table devient un actif critique : la perdre = perdre les identités |
| UUID déterministe calculé (uuid5 de `source+key`) | Recalculable from scratch sans la table | **Casse à la fusion** : le pivot d'une entité fusionnée n'est plus le uuid5 d'aucune de ses clés — le calcul ment dès la première fusion. Faux sentiment de sécurité |

**Proposition : génération à la première apparition (v7)** + classement de la table en
criticité maximale dans la doctrine DR (fiche 13). Le uuid5 est écarté : dès qu'il y a
fusion (notre cas d'usage central), le déterminisme calculatoire est illusoire.

Décision : ☐

## Décision C6 — Cohabitation avec les ID séquence existants

Les consommateurs (MIN, API) utilisent aujourd'hui les ID séquence. **Proposition de
transition en 3 temps, sans big bang :**

1. **Backfill** : ajout d'une colonne `uuid UNIQUE` sur les 3 tables gold ; pour chaque
   ligne existante, génération du pivot + insertion dans le crosswalk d'une ligne par
   identifiant source non-NULL déjà porté. Aucun consommateur n'est touché : les ID
   séquence continuent de fonctionner.
2. **Double exposition** : les vues `api.*` et MIN exposent le `uuid` EN PLUS de l'id
   actuel (doctrine de versionnement fiche 12) ; les nouveaux usages prennent le uuid.
3. **Bascule** : quand plus aucun consommateur ne dépend des ID séquence, ils
   redeviennent un détail interne (et le gold devient reconstructible). Pas de date :
   piloté par le registre des consommateurs (fiche 12).

Décision : ☐

## Décision C7 — Qui maintient le crosswalk au runtime (transition)

En cible dbt, la transformation silver→gold maintient le crosswalk (le matching est un
modèle). **Mais pendant la transition**, les écrivains actuels du gold doivent le tenir
à jour, sinon il diverge dès le premier run. Points d'écriture à brancher (constat
fiche 18) :

| Événement | Site actuel | Action crosswalk |
|---|---|---|
| Upsert d'une entité avec identifiant source | W1/W3/W5 (structure), P1/P2/P3 (personne), C1/C2 (lieu) | UPSERT `(source, source_key)` → uuid de la ligne gold ; `last_seen_at = now()` |
| Rotation d'identifiant coop | W1 (écrase `structure_coop_id`) | Ancienne clé : `retired_at` ; nouvelle clé : même uuid |
| Fusion (mensuelle auto ou MIN) | personne-similarities-merge, MIN | Réattribuer les clés du perdant au uuid gagnant + `merge_log` ; le uuid perdant n'est plus référencé mais son historique reste dans `merge_log` |
| Défusion (nouveau cas rendu possible) | MIN (à construire, fiche 04 §4) | Réattribuer les clés séparées à un nouveau uuid + `merge_log` |

C'est le coût principal de la transition : ~8 sites d'écriture à instrumenter.
Alternative évaluée — trigger PostgreSQL sur les tables gold qui synchronise le
crosswalk : moins de sites à toucher, mais logique d'identité cachée dans un trigger
(contraire à la lisibilité visée) et aveugle aux rotations (il ne voit pas « ancienne
clé retirée »). **Proposition : instrumentation explicite des écrivains.**

Décision : ☐

## Décision C8 — Dans quel schéma ? **DÉCIDÉ : schéma dédié autonome**

Le croquis initial (fiche 04) plaçait le crosswalk dans `main` — commode (mêmes GRANT,
FK faciles) mais **faux sur le cycle de vie** :

- Dans la cible dbt, tout `main` devient **dérivé** : reconstructible depuis les
  silvers, regénéré par la transformation.
- Le crosswalk est l'exact inverse : **de l'état pérenne, jamais tronqué, jamais
  dérivé** — sa raison d'être est précisément de survivre aux reconstructions du gold.

Les mélanger dans le même schéma brouille la frontière « dérivé vs état » : le jour où
`main` est traité comme intégralement reconstructible, le crosswalk se fait embarquer —
et perdre le crosswalk = perdre les identités.

**Décision (2026-07-31, validée)** : un **schéma dédié, neuf et autonome : `crosswalk`**.
Le schéma porte le concept, les tables portent l'entité — `crosswalk.structure`,
`crosswalk.personne`, `crosswalk.lieu` (pas de préfixe redondant). Il ne s'adosse à
aucun schéma existant : `audit` (qui porte `merge_log`) a été évalué et écarté — c'est
un dépôt en vrac sans doctrine, pas une fondation. Le schéma `crosswalk` naît avec ses
propres règles :

- contenu : les tables de correspondance uniquement (et, plus tard, tout ce qui relève
  de l'identité pérenne — jamais de données métier) ;
- cycle de vie : append/update seulement, jamais de TRUNCATE ni DELETE, hors périmètre
  dbt — la frontière Flyway/dbt de la fiche 05 devient : dbt ne touche JAMAIS `crosswalk` ;
- criticité DR maximale (fiche 13) ;
- GRANT explicites par consommateur (lecture MIN/PostgREST, écriture ETL seulement),
  matrice fiche 11.

Question ouverte associée : `merge_log` a vocation à déménager de `audit` vers
`crosswalk` (c'est de l'historique d'identité, pas de l'audit générique) — à trancher
séparément, pas dans le périmètre v1.

Décision : ☑ schéma dédié autonome `crosswalk`, tables `crosswalk.{structure,personne,lieu}` (2026-07-31)

## Ordre de mise en œuvre proposé (après validation de la spec)

1. Migration : 3 tables crosswalk + colonne `uuid` sur les 3 tables gold (additif pur,
   aucun consommateur impacté).
2. Backfill depuis l'existant (script one-shot, idempotent, vérifiable par comptages).
3. Instrumentation des écrivains, entité par entité (structure d'abord — c'est elle qui
   bloque le plus la suite), avec test d'invariant en CI : « toute ligne gold avec un
   identifiant source a sa ligne crosswalk ».
4. Branchement des fusions (personne-similarities-merge, doctrine MIN).
5. Double exposition API/MIN (fiche 12) — chantier séparé, hors ETL.

Chaque étape est une MR indépendante ; les étapes 1-2 sont sans risque (additives), les
étapes 3-4 touchent les écrivains existants.

## Pièges connus

- **Croire le crosswalk rétroactif** : il enregistre l'identité À PARTIR de sa mise en
  place ; les fusions passées (DELETE des perdants) sont perdues — seul `merge_log` en
  garde une trace partielle.
- **Le peupler sans le lire** : tant qu'aucun consommateur n'utilise les uuid, les bugs
  d'alimentation sont invisibles. D'où le test d'invariant CI dès l'étape 3.
- **Traiter `siret_antenne` comme un vrai ID source** : c'est une clé de matching
  (elle peut être corrigée, une vraie clé source non) — ses lignes crosswalk suivent la
  correction du siret, à documenter dans les règles de survivance (fiche 20).
