# 22 — Conception : les corrections humaines (MIN) comme source

← [Retour au document central](../../architecture/README.md)

> **Document de conception, AVANT tout code** — prérequis n°3 de la bascule dbt
> ([fiche 05](../../architecture/transformations-elt-dbt.md#prérequis-avant-le-premier-modèle)),
> concrétise la [fiche 04 §4](../../architecture/mdm-reconciliation.md). Points de décision M1-M5 à
> valider ; dépendances côté équipe MIN explicitées en fin de fiche.
>
> Statut : **spec en attente de validation** — rédigée le 2026-07-31.

## Le problème

Des humains corrigent le gold directement dans MIN (fusions de doublons, canonisation
de noms, corrections de valeurs). Or :

- **Une transformation qui redérive le gold depuis les silvers écraserait ces
  corrections à chaque run** — c'est LE piège identifié fiche 04 (« le pipeline
  nocturne qui annule les corrections MIN détruit la confiance du métier durablement »).
- C'est déjà partiellement le cas aujourd'hui : seule `lieu_inclusion` protège les
  éditions MIN (garde `updated_at_min` dans le `GREATEST`, V115/V116). Sur
  `structure_administrative`, `personne` et `adresse`, un import peut recouvrir une
  correction humaine — la survie repose sur le hasard des champs touchés.

La réponse de principe est actée ([fiche 20, décision T2](../survivance-gold/decisions-survivance.md)) :
les corrections humaines ont la **priorité de survivance maximale**. Cette fiche
conçoit le *comment* : pour qu'une correction survive à une reconstruction, elle doit
être **une donnée d'entrée de la transformation** — c'est-à-dire une source à part
entière du médaillon, pas une écriture directe dans une table de sortie.

## Ce qui existe déjà — et c'est la bonne fondation

`source.min__evenements` (V124/V125) : MIN est **déjà une source bronze**. Chaque
action y est capturée : `action` (create/update/delete), `entity_id`, `user_id`,
`value` — les updates portent `{"old", "new"}`. Autrement dit : la matière première
des overrides existe, capturée au bon endroit (bronze, append-only).

Ce qui manque : personne ne **relit** ces événements. Ils sont une trace, pas une
source — aucun silver n'en est dérivé, aucune écriture du gold ne les consulte.

## Décision M1 — Périmètre : qu'est-ce qu'un « override » ?

Les écritures MIN sont de deux natures très différentes :

| Nature | Exemples | Traitement proposé |
|---|---|---|
| **Correction de valeur** (champ par champ) | corriger un nom, une adresse, un contact | **Override** — objet de cette fiche : donnée pérenne, priorité de survivance maximale |
| **Opération d'identité** | fusion de doublons, défusion, canonisation d'antenne, migration d'identifiant source | **Hors périmètre** : c'est le domaine du crosswalk ([fiche 21](../crosswalk/conception-crosswalk.md), C7) et de `merge_log` |

**Proposition** : tout `update` MIN sur un champ métier = override par défaut (l'humain
a exprimé une intention, on la préserve) ; les creates/deletes MIN = cycle de vie, à
traiter comme les désactivations des autres sources (fiche 20). Séparer proprement les
deux natures dans les événements émis (voir dépendances MIN).

Décision : ☐

## Décision M2 — Où vit l'état des overrides ?

Deux options :

| Option | Principe | Limites |
|---|---|---|
| **A. Dérivé du bronze existant** | Un silver `staging.min__overrides` est dérivé de `source.min__evenements` (dernier `update` par entité × champ = override actif) — MIN suit le même chemin médaillon que toutes les sources | Les corrections antérieures à V124 n'ont pas d'événement (pas de backfill possible) ; exige que MIN émette des événements exhaustifs et fiables |
| B. Table d'overrides dédiée, écrite par MIN | MIN maintient explicitement « ce champ est verrouillé à cette valeur » | Deuxième chemin d'écriture à construire côté MIN ; divergence possible événements ↔ table ; MIN devient une source qui ne passe pas par le médaillon |

**Proposition : A.** Cohérence totale avec l'architecture (MIN = une source comme les
autres : bronze → silver → consommé par la transformation), zéro nouveau canal. La
limite pré-V124 est actée : les corrections passées non ré-émises ne sont pas des
overrides (elles survivent aujourd'hui par chance ; si un import les écrase, le métier
les re-corrige dans MIN et elles deviennent durables).

Décision : ☐

### Complément M2 (validé 2026-07-31) — quand dériver le silver ?

Le silver `staging.min__overrides` est dérivé **en première tâche du DAG de
transformation silver → gold**, pas par un DAG source dédié. Raison : MIN est la seule
source sans fetch — l'app pousse ses événements en continu dans le bronze ; un DAG MIN
séparé n'aurait rien à « aller chercher » et introduirait un décalage d'horloge entre
la dérivation des overrides et leur consommation (fenêtre pendant laquelle une
correction fraîche serait ignorée par l'arbitrage de survivance). Dériver en tête du
DAG de transformation garantit la fraîcheur maximale des corrections au moment exact
où elles servent.

Trois propriétés à préserver :

1. **Dérivation pure et déterministe** (TRUNCATE + INSERT depuis
   `source.min__evenements`) — re-dérivable à tout moment, comme tout silver.
2. **La transformation ne lit que des silvers** — le modèle de survivance consomme
   `staging.min__overrides`, jamais le bronze directement.
3. **Silver requêtable dans `staging`** — les overrides actifs sont inspectables en SQL
   comme n'importe quel autre état intermédiaire.

## Décision M3 — Granularité : le champ, pas la fiche

**Proposition** : un override porte sur **un champ d'une entité** (`personne X, champ
nom`), pas sur la fiche entière. Verrouiller la fiche entière figerait des champs que
l'humain n'a pas regardés (et priverait la fiche des mises à jour légitimes des
sources). C'est aussi la granularité naturelle des événements V124 (`{"old","new"}`
par update).

Référence d'entité : l'ID pivot du crosswalk (fiche 21) dès qu'il existe — un override
doit survivre aux fusions (il suit l'entité, pas la ligne).

Décision : ☐

## Décision M4 — Cycle de vie d'un override

| Question | Proposition |
|---|---|
| Un override expire-t-il ? | **Jamais automatiquement.** Il tient tant qu'un humain ne le lève pas |
| Comment le lever ? | Action explicite dans MIN (« reprendre la valeur des sources »), qui émet un événement — le silver le voit disparaître |
| Et si la source finit par donner la même valeur que l'override ? | L'override reste (inoffensif) ; optionnel : le signaler dans MIN comme « résorbé, levable » |
| Et si la source CONTREDIT durablement un override ? | Ne jamais écraser ; **rendre le conflit visible dans MIN** (écran de stewardship, fiche 04 §4) — c'est de l'information, pas un arbitrage automatique |

Décision : ☐

## Décision M5 — Transition : que fait-on AVANT la bascule dbt ?

Aujourd'hui les imports peuvent écraser les corrections MIN sur SA/personne/adresse.
Options :

| Option | Coût | Effet |
|---|---|---|
| A. Rien — assumer jusqu'à la bascule | 0 | Les écrasements continuent ; le métier re-corrige (et, post-M2, ses re-corrections deviennent durables) |
| B. Généraliser la garde `updated_at_min` (mécanisme lieu_inclusion) à SA et personne | Moyen (touche les écrivains actuels) | Protection immédiate — mais du code jetable si la bascule dbt suit |

**Proposition : A par défaut**, sauf si le métier signale des écrasements fréquents et
douloureux (auquel cas B sur la table concernée uniquement). À arbitrer avec le PO —
c'est un choix de douleur acceptable, pas un choix technique.

Décision : ☐

## Comment la transformation consommera les overrides (cible)

Dans les modèles dbt (fiche 05), les overrides sont une entrée comme les autres —
la règle de survivance devient, pour chaque champ :

```
1. override humain actif (staging.min__overrides)   → sa valeur, toujours
2. sinon : règle de survivance du champ (fiche 20)  → coop/AC/idposte/BAN…
```

La provenance par champ (fiche 04) affiche alors « valeur verrouillée par <user> le
<date> » dans MIN — l'humain voit que sa correction tient.

## Dépendances côté équipe MIN (hors de ce repo)

1. **Exhaustivité des événements** : toute écriture MIN doit émettre son événement
   V124 (si des écrans écrivent sans émettre, les overrides correspondants n'existent
   pas). À auditer côté app.
2. **Distinguer les natures** (M1) : les événements de fusion/canonisation doivent
   être distinguables des corrections de valeur (aujourd'hui : même canal ; un champ
   `action` plus riche ou une convention sur `value` suffit).
3. **Écran de gestion** (peut venir plus tard) : voir les overrides actifs d'une
   fiche, en lever un, voir les conflits source ↔ override (M4).

Le point 1 est **bloquant** pour M2-option A ; les points 2-3 peuvent suivre.

## Pièges connus

- **Tout verrouiller** : si chaque passage MIN pose des overrides sur des champs non
  réellement corrigés (ex. formulaire qui resoumets tous les champs), le gold se fige
  champ par champ et les sources ne servent plus à rien. L'émission d'événements doit
  ne porter QUE les champs réellement modifiés (diff, pas snapshot).
- **L'override orphelin** : un override référençant une entité fusionnée/supprimée
  doit suivre le crosswalk, pas mourir en silence.
- **Confondre override et donnée** : l'override dit « cette valeur est verrouillée »,
  il ne remplace pas la capture des valeurs sources — on doit toujours pouvoir
  répondre « qu'est-ce que la source dit, même si on l'ignore ? ».
