# `api.carto` — règles métier d'affichage des structures

Ce document décrit les règles qui gouvernent l'exposition d'une **structure** (un lieu) dans `api.carto`, ainsi que l'origine et la forme de chaque attribut renvoyé.

Pour la logique d'affichage des **médiateurs rattachés** (règles par personne, branches UNION), voir [`api-carto-regles.md`](api-carto-regles.md).
Pour la logique de peuplement de la table `main.structure`, voir [`main-structure-regles.md`](main-structure-regles.md) *(à rédiger, si pas encore présent)*.

## 1. Structure d'une ligne du flux

Une ligne de `api.carto` représente **une et une seule structure**. Elle agrège :
- les attributs propres à la structure (`main.structure`),
- son adresse (`main.adresse` via `structure.adresse_id`),
- ses contacts de structure (téléphone, emails, site web — niveau structure, **pas** niveau personne),
- la liste de ses médiateurs rattachés (`mediateurs` — logique décrite dans `api-carto-regles.md`).

```json
{
  "id": "Coop-numérique_<uuid>",
  "pivot": "<siret|rna>",
  "nom": "...",
  "adresse": { "numero_voie": ..., "nom_voie": ..., "code_postal": ..., "commune": ..., "code_insee": ... },
  "latitude": ..., "longitude": ...,
  "typologie": [...],
  "telephone": "...",
  "courriels": "email1|email2|...",
  "site_web": "...",
  "horaires": "...",
  "presentation_resume": "...",
  "presentation_detail": "...",
  "source": "...",
  "itinerance": [...],
  "date_maj": "...",
  "services": [...],
  "publics_specifiquement_adresses": [...],
  "prise_en_charge_specifique": [...],
  "frais_a_charge": [...],
  "dispositif_programmes_nationaux": [...],
  "formations_labels": [...],
  "autres_formations_labels": [...],
  "modalites_acces": [...],
  "modalites_accompagnement": [...],
  "prise_rdv": "...",
  "mediateurs": [ { ... }, { ... } ]
}
```

## 2. Conditions d'apparition d'une structure

Une ligne de `main.structure` est incluse dans `api.carto` **si et seulement si** elle satisfait cumulativement :

### 2.1 Identité cartographie nationale

```sql
structure.structure_cartographie_nationale_id IS NOT NULL
```

La structure a un identifiant dans le référentiel cartographie nationale, attribué par `carto-dag-import.py` à l'importation depuis mednum-cli.

### 2.2 Drapeau de visibilité

```sql
structure.visible_pour_cartographie_nationale = TRUE
```

Drapeau source indiquant que la structure doit être exposée publiquement. Piloté principalement par carto (mis à TRUE à l'import, mis à FALSE à la fin du DAG pour les structures absentes du nouvel import). Peut aussi être modifié manuellement (admin, `sonum`, `editor`).

### 2.3 Filtre d'activité (V061 / V063)

```sql
(
    -- Option A : pas de lieu_activite connu → on ne sait rien, on garde
    NOT EXISTS (
        SELECT 1 FROM main.personne_affectations pa
        WHERE pa.structure_id = structure.id
          AND pa.type = 'lieu_activite'
          AND pa.est_active = TRUE
    )
    OR
    -- Option B : au moins un médiateur actif avec un emploi non-AC actif
    EXISTS (
        SELECT 1
        FROM main.personne_affectations pa_lieu
        JOIN main.personne_affectations pa_emploi
             ON pa_emploi.personne_id = pa_lieu.personne_id
            AND pa_emploi.type = 'structure_emploi'
            AND pa_emploi.est_active = TRUE
            AND pa_emploi.source != 'aidants-connect'
        WHERE pa_lieu.structure_id = structure.id
          AND pa_lieu.type = 'lieu_activite'
          AND pa_lieu.est_active = TRUE
    )
)
```

**Lecture métier** :

- Une structure **sans aucun `lieu_activite`** connu reste visible (on ne dispose pas d'info sur l'activité, on ne pénalise pas).
- Une structure **avec des `lieu_activite`** n'est visible que si **au moins un des médiateurs rattachés** a par ailleurs un `structure_emploi` actif **non-AC** (coop ou idposte).

**Intention** : filtrer les structures dont la seule activité déclarée est un médiateur Aidants Connect qui n'exerce plus (ex: ancien aidant dont le lieu_activite n'a pas été désactivé).

## 3. Conditions de non-apparition

Une structure est **exclue** de `api.carto` dès qu'elle ne remplit pas une des trois conditions ci-dessus :

| Cause | Signification |
|---|---|
| `structure_cartographie_nationale_id IS NULL` | Pas encore rattachée au référentiel cartographie nationale (ex : structure uniquement en base idposte ou coop interne). |
| `visible_pour_cartographie_nationale = FALSE` | Drapeau désactivé (ex : structure supprimée côté carto, ou demande métier de ne pas exposer). |
| Filtre V063 échoué | A des `lieu_activite` actifs, mais aucun des médiateurs rattachés n'a d'emploi non-AC actif. |

## 4. Attributs exposés — origine et règles

Chaque champ du JSON retourné a une origine précise et une règle de résolution.

### 4.1 Identifiants

| Champ | Source | Règle |
|---|---|---|
| `id` | `structure.structure_cartographie_nationale_id` | Format `Coop-numérique_<uuid>` côté coop, `<source>_<id>` ailleurs. |
| `pivot` | `COALESCE(structure.siret, structure.rna, '00000000000000')` | Castée en `varchar(14)`. |

### 4.2 Identification de la structure

| Champ | Source | Règle |
|---|---|---|
| `nom` | `structure.nom` | Valeur brute, dernière source à écrire. |
| `source` | `structure.source` | Identifiant de la source d'origine (ex : `"Coop numérique"`, `"Paca"`...). |

### 4.3 Adresse (via `LEFT JOIN main.adresse ON adresse.id = structure.adresse_id`)

| Champ | Sous-clé | Source |
|---|---|---|
| `adresse.numero_voie` | entier ou `null` | `adresse.numero_voie` |
| `adresse.nom_voie` | texte | `adresse.nom_voie` |
| `adresse.repetition` | "bis", "ter", ... | `adresse.repetition` |
| `adresse.code_postal` | 5 chiffres | `adresse.code_postal` |
| `adresse.commune` | nom commune | `adresse.nom_commune` |
| `adresse.code_insee` | 5 caractères | `adresse.code_insee` |
| `latitude` | `st_y(adresse.geom)` | dérivé de `geom` |
| `longitude` | `st_x(adresse.geom)` | dérivé de `geom` |

Si la structure n'a pas d'`adresse_id` ou si l'adresse est incomplète, ces champs sont `null`.

### 4.4 Contact de la structure (pas de la personne)

Lu depuis `structure.contact` (JSONB) :

| Champ | Clé JSONB | Remarque |
|---|---|---|
| `telephone` | `structure.contact.telephone` | Téléphone de la structure (accueil, ligne générique). |
| `site_web` | `structure.contact.site_web` | URL du site. |
| `courriels` | concat `structure.contact.emails.*` avec `'\|'` | Agrégé via CTE `courriels` avec `string_agg`. |

À ne pas confondre avec le contact des personnes dans `mediateurs[]` — ces contacts proviennent de `main.personne.contact` et suivent des règles différentes (voir [`api-carto-regles.md`](api-carto-regles.md)).

### 4.5 Attributs descriptifs et éditoriaux

| Champ | Source `main.structure` |
|---|---|
| `typologie` | `typologies` (`text[]`) |
| `horaires` | `horaires` |
| `presentation_resume` | `presentation_resume` |
| `presentation_detail` | `presentation_detail` |
| `itinerance` | `itinerance` (`text[]`) |
| `prise_rdv` | `prise_rdv` |

### 4.6 Services, publics, frais, accompagnement

Champs de type `text[]`, écrits tels quels :

| Champ | Source |
|---|---|
| `services` | `structure.services` |
| `publics_specifiquement_adresses` | `structure.publics_specifiquement_adresses` |
| `prise_en_charge_specifique` | `structure.prise_en_charge_specifique` |
| `frais_a_charge` | `structure.frais_a_charge` |
| `dispositif_programmes_nationaux` | `structure.dispositif_programmes_nationaux` |
| `formations_labels` | `structure.formations_labels` |
| `autres_formations_labels` | `structure.autres_formations_labels` |
| `modalites_acces` | `structure.modalites_acces` |
| `modalites_accompagnement` | `structure.modalites_accompagnement` |

### 4.7 Horodatage

| Champ | Règle |
|---|---|
| `date_maj` | `COALESCE(structure.updated_at, structure.created_at)` |

**Attention** : `updated_at` est bumpé par **n'importe quelle** écriture sur la ligne, y compris quand aucune donnée métier ne change (ex : `edited_by` qui bascule d'une source à l'autre). Ce n'est pas un signal fiable de « dernière mise à jour métier » — voir [`main-personne-regles.md §5`](main-personne-regles.md) pour un diagnostic similaire côté personne.

### 4.8 Médiateurs

| Champ | Règle |
|---|---|
| `mediateurs` | Agrégat JSONB des personnes rattachées à la structure via `personne_affectations.type = 'lieu_activite'` actif, selon les branches UNION décrites dans [`api-carto-regles.md`](api-carto-regles.md). |

## 5. Sources et DAGs producteurs de `main.structure`

| Source | DAG / script | Clé source | Écrit quoi sur la structure |
|---|---|---|---|
| **carto** (mednum-cli) | `carto-dag-import.py` | `structure_cartographie_nationale_id` | `nom`, `siret`, `rna`, `typologies`, `adresse_id`, `contact` structure, `visible_pour_cartographie_nationale`, `presentation_*`, `services`, `horaires`, … |
| **coop-numerique** | `coop-dag.py` | `structure_coop_id` | `nom`, `siret`, `adresse_id`, `contact`, `typologies`, `services`, `horaires`, `presentation_*`, `emplois`, `mediateurs_en_activite`, … |
| **idposte** | `schema-idPoste.py` | `structure_tp_id` (source tabulaire multidim, dédup par tp_id requise — voir [`id-poste-regles.md`](id-poste-regles.md)) | `nom`, `siret`, `adresse_id`, `publique`, `etat_administratif`, `code_activite_principale`, `categorie_juridique`, `denomination_sirene` |
| **aidants-connect** | `aidants-connect-dag.py` | `structure_ac_id` | Crée la structure quand un aidant y est rattaché, enrichit le bloc SIRENE (`etat_administratif`, `code_activite_principale`, …). |
| **admin** | scripts manuels / interface (`sonum`, `editor`, `app_python`, `min_scalingo`) | — | Corrections ponctuelles, bascules de `visible_pour_cartographie_nationale`, etc. |

Le DAG `structures-similarities-merge` fusionnait les doublons détectés par similarité (trigram sur nom + correspondance SIRET). Décommissionné par la refonte 2026 (cf `refonte-structure-plan.md` N5) : la déduplication est portée par les contraintes UNIQUE du nouveau modèle.

## 6. Pipeline de visibilité

Le chemin typique d'une structure jusqu'à `api.carto` :

1. **Import source** : un DAG (carto, coop, idposte, AC) crée la ligne `main.structure`.
2. **Résolution carto** : si présente dans mednum-cli, `carto-dag-import` assigne `structure_cartographie_nationale_id` et `visible_pour_cartographie_nationale = TRUE`.
3. **Rattachement des personnes** : les DAGs écrivent `main.personne_affectations` (`lieu_activite` et `structure_emploi`), liant les médiateurs à la structure.
4. **Dédoublonnage** : porté par les contraintes UNIQUE du modèle (`siret`, identifiants source) — le DAG `structures-similarities-merge` est décommissionné.
5. **Exposition** : `api.carto` filtre selon les 3 conditions du §2 et agrège les médiateurs visibles.

## 7. Angles morts connus

1. **Structures à `id_pg`** : historiquement skippées par le transform `coop_structures` avec l'hypothèse que idposte les importerait. Si idposte ne les a pas dans son flux (ex : communes-mères employeuses de médiateurs non-CN), la structure n'arrive jamais en base. **Corrigé** par `fix/coop-structures-with-idpg` (2026-04-22).
2. **Doublons coop** : coop expose parfois **deux UUIDs** pour la même entité réelle (même SIRET, même nom à la casse près). Notre dédoublonnage case-insensitive garde une seule ligne en base, mais perd le second `structure_coop_id` — les affectations qui référencent l'UUID perdu sont orphelines. Voir [`ticket-coop-doublons-structures.md`](ticket-coop-doublons-structures.md).
3. **Filtre V063 strict** : 48 structures sont totalement exclues d'`api.carto` car leurs seuls médiateurs rattachés sont des coop non labellisés sans `structure_emploi` actif. Les fixes 1 (`id_pg`) et 2 (ticket coop doublons) restaureront une partie de ces emplois et devraient réduire ce nombre.
4. **`date_maj` peu fiable** : `updated_at` est bumpé par toute écriture, pas seulement par une modification métier. À interpréter avec prudence côté consommateur.

## 8. Historique des migrations impactantes

| Migration | Date | Impact sur les structures affichées |
|---|---|---|
| V029 | 2025-11-12 | Version initiale de la vue `api.carto`. |
| V046 | 2026-02-24 | Restructuration `contact` par source (concerne principalement les personnes mais touche la vue). |
| V061 | 2026-04-14 | Filtre « lieu actif » : exclut les lieux sans `lieu_activite` actif. |
| V062 | 2026-04-16 | Ajout du filtre `is_visible` (opt-out personne — affecte `mediateurs` et pas la visibilité structure). |
| V063 | 2026-04-16 | Filtre « emploi actif non-AC » : exclut les lieux dont tous les médiateurs n'ont que des emplois AC inactifs. |

## 9. Contexte d'évolution

L'API carto évolue rapidement (V061-V063 ajoutées en moins d'une semaine fin avril 2026). Les règles d'apparition se sont durcies récemment pour répondre à des demandes métier (éviter les fantômes, exclure les opt-out), au prix de quelques angles morts qui sont encore à corriger. Le présent document correspond à l'état figé à sa date de rédaction — vérifier les migrations postérieures avant d'agir sur ces règles.
