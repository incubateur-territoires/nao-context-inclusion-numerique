# Analyse des écarts de la bascule V153 (vue d'union `main.lieu_inclusion`)

*2026-08-19 — analyse des différences entre la vue d'union (branche coop lue en direct dans
`coop.lieu_inclusion`) et l'ancienne table répliquée (devenue `main.lieu_inclusion_registre`).
Complète la MR !970 et `besoin_1724_lieux_inclusion.md` (§5.1/5.2). Mesures sur
`dataspace_dev` (synchro prod), 10 879 lignes coop.*

## 1. Dispositifs nationaux — l'écart majeur (+1 672 « Conseillers numériques »)

**Constat baseline** : compteur « Conseillers numériques » 7 736 → 9 408 ; labellisés
10 515 → 12 180.

**Sens des écarts (lieux coop)** :

| Label | Gagnés par la vue | Perdus par la vue |
|---|---|---|
| Conseillers numériques | **1 700** | 28 |
| France Services | 26 | 29 |

**Validité du signal coop (contrôle croisé avec les conseillers réellement actifs — personne
avec `conseiller_numerique_id`/`cn_pg_id` et affectation active sur le lieu)** :
- lieux CN *gagnés* : **1 499/1 700 = 88 %** ont un conseiller actif réel ;
- taux de contrôle (lieux CN déjà au registre) : 7 213/7 669 = **94 %**.
→ Le label coop est **crédible** (même ordre de fiabilité que l'existant).

**Cause racine (confirmée)** : sur les 1 700 gains, **1 670 (98 %) ont une `modification`
coop ≤ `updated_at_coop` répliqué** — la coop a backfillé `dispositif_programmes_nationaux`
(début juillet 2026) **sans bumper `modification`**. La garde de fraîcheur du coop-dag
(`updated_at_coop > updated_at`) a donc bloqué la réplication **définitivement** : la
réplique ne pouvait jamais rattraper ces valeurs. Les 30 restants = lag normal.
→ Démonstration structurelle : **toute réplication gardée par date est aveugle aux backfills
source sans bump de date**. La lecture directe (la vue) est la seule voie robuste.

**Anomalie inverse à remonter à la coop** : 26 des 28 lieux qui *perdent* le label CN ont
pourtant un conseiller numérique actif — le label manque **côté coop** sur ces 26 lieux
(liste : lieux coop avec conseiller actif et `dispositif_programmes_nationaux` sans
« Conseillers numériques »).

**France Services** : ±26/29, quasi équilibré — bruit de synchronisation bilatéral, pas de
biais.

## 2. Noms — 283 écarts, dont 40 substantiels

| Catégorie | Volume | Nature |
|---|---|---|
| Casse seule | 61 | « MAIRIE » vs « Mairie » — cosmétique |
| Préfixe/suffixe | 147 | nos scripts avaient suffixé la commune, ou tronqué — quasi cosmétique |
| Proches (similarité ≥ 0.5) | 35 | reformulations mineures |
| **Vraiment différents** | **40** | **le nom coop est souvent celui de la STRUCTURE, le nom du registre celui du LIEU** |

Exemples des 40 : « COMMUNE DE NOISY LE SEC » (coop) vs « Bus France services de
Noisy-le-Sec » (registre) ; « CC DU VAL DE SULLY » vs « Maison Pour Tous Maison France
Services » ; « COMMUNE DE ROSPORDEN » vs « Médiathèque De Rosporden ».

**Lecture** : sur ces ~40 lieux, la fiche coop porte un nom de structure porteuse plutôt que
le nom du lieu d'accueil — le nom « perdu » venait du flux carto (souvent plus juste pour un
usager). C'est une **dette de qualité côté coop** (fiche lieu nommée comme la structure), pas
un artefact de la bascule ; à traiter par le canal étape 6 (proposer le nom carto à la coop)
ou par une remontée directe. Liste complète reproductible :

```sql
SELECT v.id, v.nom AS nom_coop, r.nom AS nom_registre
FROM main.lieu_inclusion v JOIN main.lieu_inclusion_registre r USING (id)
WHERE v.nom IS DISTINCT FROM r.nom
  AND public.similarity(lower(public.unaccent(v.nom)), lower(public.unaccent(r.nom))) < 0.5
  AND NOT (lower(public.unaccent(btrim(r.nom))) LIKE lower(public.unaccent(btrim(v.nom))) || '%'
        OR lower(public.unaccent(btrim(v.nom))) LIKE lower(public.unaccent(btrim(r.nom))) || '%');
```

## 3. Autres familles (déjà actées le 2026-08-19)

- **Labels de zonage FRR/QPV** (2 786 lieux) : abandonnés — enrichissement local dérivable
  d'`admin.zonage` ; disparaissent d'api.carto/data.gouv pour les lieux coop.
- **Contacts issus des fusions mednum** (478 lieux) : perdus — archivés dans le registre
  (colonnes gelées depuis la réduction de l'upsert coop-dag), premier lot du canal étape 6.
- **Convention `contact = {}`** (2 398 lieux passent de NULL à `{}`) : neutre pour tous les
  consommateurs (`contact->'clef'`).
- **Micro-résidus** (~100-300/colonne : typologies 265, services 293, horaires 101…) :
  pollution d'union des fusions mednum d'avant l'étape 4, où la coop est la vérité.

## 4. Actions dérivées

1. **Remontée coop** : les 26 lieux CN sans label + les ~40 fiches nommées comme la
   structure (et, en creux, la pratique du backfill sans bump de `modification` — elle
   casserait toute future logique de fraîcheur, la leur comprise).
2. **Canal étape 6** : réinjecter noms carto (40) et contacts (478) comme propositions.
3. **Argumentaire** : le cas « backfill invisible à vie » est l'argument n°1 pour la lecture
   directe vs réplication.

## 5. Visibilité (complément du 2026-08-19, après revue)

Écarts directs entre le drapeau du registre (cycle de vie carto) et le drapeau déclaré coop :

- **20 lieux affichés sur api.carto alors que le médiateur avait désactivé la visibilité**
  (exposition directe, sans passer par un doublon). **Corrigé dans V153** : la vue sert
  désormais `visible = cycle de vie carto ET drapeau coop` (conservatif) → api.carto passe
  de 18 414 à 18 394 lignes, 0 exposition restante.
- **524 lieux voulus visibles côté coop mais masqués chez nous** (aucun carto_id : sortis du
  fichier national, ou jamais entrés). Composition : **0 cas de lag** (aucun créé/modifié
  récemment — absence structurelle), 7 sans adresse (incomplets), **70 représentés par un
  doublon** déjà en table d'appariements (résolution via la validation), **454 réellement
  invisibles partout**. Pistes de résolution : (a) les 70 via la résorption des doublons ;
  (b) « présence par liste » — réintégrer dans api.carto les lignes coop au drapeau visible
  avec un id dérivé stable `Coop-numérique_<uuid>` (bénéficie à api.carto/data.gouv/MIN,
  mais PAS à la carte nationale tant qu'elle consomme la sortie mednum — rejoint la
  discussion « la carte peut-elle se sourcer sur api.carto ? ») ; (c) remontée coop : comprendre
  pourquoi leur export vers la mednum exclut ces lieux (critères de complétude ?).

## 6. Posture transitoire de l'export public (V154, 2026-08-19)

Décision (Philippe) : tant que la décision métier du canal n'est pas prise, **l'export public
ne change pas de nature** — `api.carto`, `opendata.lieux_mednum` et `opendata.lieux_geojson`
servent la **photo mednum** en priorité **sur les fiches des lieux coop uniquement** (champs
métier lus dans `staging.carto__structures` quand le record est au fichier national du run
courant, normalisation identique à l'ancien `_CARTO_COMMON_SET`) ; **les lieux externes
restent servis depuis le registre**, qui est déjà la photo mednum matérialisée chaque nuit —
ce qui préserve, comme avant le chantier, les éditions locales (MIN) gardées par fraîcheur.
Validation du périmètre (2026-08-20) : lignes externes = 0 écart vs l'avant-chantier (contenu
et date_maj) ; lignes coop = contenu quasi identique (~25 micro-résidus), date_maj en date
source (voulu). MIN/dataviz continuent de lire la
vérité coop. C'est l'option « divergence assumée », temporaire et réversible (U154).

Validation (baseline vs référence d'avant-V153) : contenu d'api.carto revenu à l'identique de
l'ancien monde, aux résidus voulus près — **-20 lignes** (fix visibilité conservé) et
**`date_maj` = date déclarée par la source** (minuit) au lieu de l'heure de notre pipeline
(plus conforme au schéma data-inclusion). Le fichier national portant déjà 5 843 labels
« Conseillers numériques » sur les records coop, l'export n'en perd qu'une partie marginale.
Perf : count complet 53 ms (jointure silver comprise).

⚠️ Résidu documenté : les 20 lieux masqués figurent encore dans `opendata.lieux_mednum`
(filtre V145 : `carto_id OU visible` — sémantique volontairement différente d'api.carto) et
dans le fichier national lui-même, jusqu'à ce que l'export coop les retire. À trancher si on
aligne le filtre opendata.

## 7. Le trou du registre (2026-08-20, découvert par le filet V155)

**1 829 lieux coop actifs sans AUCUNE ligne registre** — donc invisibles de la vue, du
matching, et de toutes nos analyses précédentes (shadow 5.1 et « 524 » énuméraient depuis le
registre : une ligne manquante était hors de leur champ). Cause — vérifiée couche par couche
(2026-08-20, bronze/silver/transformer ; l'API coop renvoyait tout, hors de cause) : DEUX
trous empilés. (1) `transformer_structures` excluait toute structure visible-ou-liée-carto
(« elles arrivent par le flux carto ») : 494 lieux, dont 135 des 144 à médiateurs actifs —
quand le lieu était aussi absent du fichier national, aucun chemin d'entrée n'existait.
(2) Sélection par rôle pour les autres : 1 335 lieux passaient le transformer mais aucun
utilisateur du payload ne les déclarait (0 rôle au silver) → skippés, sans rattrapage. Dont
497 voulus visibles (qui rejoignent la famille des 524 → ~1 000 lieux voulus visibles absents
de la carte au total) et 145 avec médiateurs actifs. Réparé par `reconcilier_identites_coop`
(V155) : vue 21 599 → 23 428, api.carto inchangée. Restent 4 sans adresse exploitable.
**Leçon de méthode : les contrôles de complétude doivent énumérer depuis la SOURCE, jamais
depuis notre propre référentiel.** Effet secondaire attendu : le prochain run d'appariement
évaluera ces 1 829 lieux → de nouveaux doublons candidats peuvent apparaître.

**Légitimité des 1 829 vérifiée (2026-08-20)** : 0 lieu inerte. 1 666 (91 %) portent des
activités déclarées (CRA), 1 360 avec activites_count > 0, 100 % modifiés en 2026, 495 avec
emploi actif, 144 avec médiateur actif, 494 voulus visibles (871 issus de v1 mais vivants).
Le paradoxe : ces lieux existaient dans les sélecteurs de l'app coop (les médiateurs y
déclaraient leurs CRA) tout en étant invisibles chez nous. **Effet bonus majeur : 513 979
activités (794 647 accompagnements, ~13 % du total) avaient lieu_id NULL et viennent de
gagner leur rattachement** — tous les rapports par lieu/département en bénéficient.

**Caractérisation des 1 335 « sans déclarant » (2026-08-20)** : ce sont pour l'essentiel des
**lieux d'accompagnement ponctuels** — 1 323/1 335 (99 %) portent des CRA (**462 626
accompagnements**), mais seulement 11 ont jamais été le « lieu d'activité régulier » de
quelqu'un (`mediateurs_en_activite`). La coop distingue deux relations médiateur↔lieu : le
lien régulier (« mes lieux d'activité », ce que l'API expose dans `mediateur.en_activite[]`
et que lisait notre sélection) et l'usage ponctuel (le lieu choisi/créé au moment de la
saisie d'un CRA — mairie de permanence itinérante, bibliothèque d'un après-midi…). L'erreur
conceptuelle de l'ancienne règle : confondre « être le lieu régulier de quelqu'un » avec
« être un lieu ». Cohérent avec le modèle d'activité coop (une activité = un lieu
d'accompagnement, pas forcément un lieu à médiateurs).

Nature et usage : valeur **statistique et territoriale** (rattachement des CRA), pas
cartographique — non visibles carto (cohérent), descriptions souvent minimales. Ils
apparaissent dans le listing MIN comme lieux non visibles ; si le bruit gêne, un marqueur
« lieu d'accompagnement ponctuel » est dérivable trivialement (zéro ligne
`mediateurs_en_activite`).
