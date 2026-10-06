# Tableau de bord et statistiques de MIN — définitions des indicateurs

> Inventaire du 2026-10-06 depuis le code de MIN (`src/gateways/tableauDeBord/`, `PrismaStatistiquesCoopLoader`). Pour reconstruire un indicateur côté agent : remplacer `coop.<table>` par `llm.coop_<table>`, `main.adresse` → `llm.adresse`, `main.structure_administrative` → `llm.structure_administrative`, `main.lieu_inclusion` → `llm.lieu_inclusion`, `min.membre` → `llm.membre`, `min.gouvernance` → `llm.gouvernance`, `min.personne_enrichie` → `llm.personne_enrichie` ; les enums Coop deviennent `text` / `text[]`. La tranche d'âge dérivée est `llm.coop_beneficiaires.tranche_age_derivee` (V179).

## (a) Table récapitulative

Colonne « Nao » : `oui` = toutes les tables/colonnes sont dans le périmètre `nao_ro` (vues `llm.*` ou tables listées dans `nao_config.yaml`) ; `partiel` = reconstructible avec un écart ou via un substitut ; `non` = table non exposée.

| # | Bloc (page) | Libellé affiché | Tables sources | Filtre territorial | Col. sensible | Nao |
|---|---|---|---|---|---|---|
| A1 | Points de vigilance (TdB, tous rôles) | « N lieux à actualiser (informations de plus de 18 mois) » | `main.lieu_inclusion`, `main.adresse`, (`admin.commune/commune_epci/epci` à l'EPCI), (`main.personne_affectations_lieu/emploi`, `min.personne_enrichie` au scope structure) | `adresse.departement` / `adresse.code_insee` / structure via affectations | non | oui |
| A2 | Points de vigilance | « N lieux à vérifier (informations de 12 à 18 mois) » | idem A1 | idem | non | oui |
| B1 | Données structure (TdB gestionnaire de structure) | « Lieux d'inclusion numérique gérés par votre structure » | `main.lieu_inclusion`, `main.personne_affectations_lieu`, `main.personne_affectations_emploi`, `min.personne_enrichie` | `structure_administrative_id = id` | non | oui |
| B2 | Données structure | « Médiateurs et aidants numériques gérés par votre structure » | `min.personne_enrichie`, `main.personne_affectations_emploi` | idem | non | oui |
| B3 | Données structure | « Accompagnements des 6 derniers mois — Total cumulé des dispositifs » | `coop.activites` | `structure_employeuse_main_id = id` | non | oui (`llm.coop_activites`) |
| B4 | Données structure | Histogramme 6 mois (MM/AA) | idem B3 | idem | non | oui |
| C1 | État des lieux (TdB admin/dépt/région/coporteur) | « Lieux d'inclusion numérique » | `main.lieu_inclusion` ⋈ `main.adresse` | `adresse.departement` / `code_insee` | non | oui |
| C2 | État des lieux | « Médiateurs et aidants numériques » | `min.personne_enrichie`, `main.structure_administrative`, `main.adresse` | SA employeuse → adresse | non | oui |
| C3 | État des lieux | « Accompagnements réalisés » (depuis 2021, CN + AC) | `min.personne_enrichie` (AC) + `coop.activites` (Coop, S1) | AC : SA → adresse ; Coop : `lieu_code_insee` | non | oui |
| C4 | État des lieux | « Accompagnements des 6 derniers mois » (barres, Coop) | `coop.activites`, `coop.accompagnements` | `lieu_code_insee` | non | oui |
| C5 | État des lieux | Carte « Indice de Fragilité numérique » (score par commune / département, popup `x/10`) | `admin.ifn_commune`, `admin.ifn_departement`, `admin.icp_departement` | `code_insee LIKE 'DD%'`, liste INSEE, liste dépts | non | oui |
| D1 | Médiateurs numériques et Aidants Connect (TdB, hors structure) | « Médiateurs numériques » (total) | `min.personne_enrichie`, SA, adresse | SA → adresse | non | oui |
| D2 | idem | « Coordinateurs » | idem | idem | non | oui |
| D3 | idem | « Conseillers numériques » | idem | idem | non | oui |
| D4 | idem | « Aidants habilités Aidants Connect » | idem | idem | non | oui |
| D5 | idem | « Médiateurs non-habilités Aidants Connect » | dérivé D1−D3−D4 | — | non | oui |
| E1 | Gouvernances (TdB national) | « Gouvernances » | `min.gouvernance` | aucun (≠ 'zzz') | non | oui (`llm.gouvernance`) |
| E2 | Gouvernances (national) | « dont N gouvernances co-portées » | `min.gouvernance`, `min.membre` | — | non | oui (`llm.membre`) |
| E3 | Gouvernances (national) | « Feuilles de route déposées » | `min.feuille_de_route` | ≠ 'zzz' | non | oui |
| E4 | Gouvernances (national) | « comprenant N actions enregistrées » | `min.feuille_de_route`, `min.action` | ≠ 'zzz' | non | oui |
| E5 | Gouvernances (TdB dépt/région) | « Membres de la gouvernance » | `min.membre` | `gouvernance_departement_code` | non | oui |
| E6 | idem | « dont N coporteurs » | `min.membre` | idem | non | oui |
| E7 | idem | « Feuilles de route déposées » | `min.feuille_de_route` | idem | non | oui |
| E8 | idem | « comprenant N actions enregistrées » | `min.feuille_de_route`, `min.action` | idem | non | oui |
| F1 | Financements (TdB national) | « Financements FNE engagés par l'État » | `min.demande_de_subvention`, `min.action`, `min.feuille_de_route`, `min.enveloppe_financement` | ≠ 'zzz' | non | oui |
| F2 | Financements (national) | « sur X disponible » | `min.enveloppe_financement` | aucun | non | oui |
| F3 | Financements (national) | « Financements Conseiller Numérique versés » | `min.postes_conseiller_numerique_synthese` | aucun | non | oui |
| F4 | Financements (national) | « sur X conventionnés sur les postes liés à la gouvernance » | idem F3 | aucun | non | oui |
| F5 | Financements (national) | « N financement(s) engagé(s) par l'État » | comme F1 | ≠ 'zzz' | non | oui |
| F6 | Financements (national) | Ventilation par enveloppe FNE (montant + « % de l'enveloppe consommée ») | comme F1 | ≠ 'zzz' | non | oui |
| F7 | Financements (national) | Enveloppes « Conseiller Numérique … » (consommation + % du plafond) | `main.subvention`, `min.enveloppe_financement` | aucun | non | oui |
| F8 | Financements (TdB dépt/région) | « Financements FNE engagés par l'État » | `min.feuille_de_route`, `min.action`, `min.demande_de_subvention`, `min.enveloppe_financement` | `gouvernance_departement_code` | non | oui |
| F9 | idem | « sur X de votre budget global renseigné » | `min.feuille_de_route`, `min.action` | idem | non | oui |
| F10 | idem | « Financements Conseiller Numérique versés » | `min.postes_conseiller_numerique_synthese`, SA, adresse | SA → `adresse.departement` | non | oui |
| F11 | idem | « sur X conventionnés sur les postes liés à la gouvernance » | idem F10 | idem | non | oui |
| F12 | idem | « N financement(s) engagé(s) par l'État » | comme F8 | idem | non | oui |
| F13 | idem | Ventilation par enveloppe FNE (montant ; % consommé calculé, affiché seulement en national) | comme F8 | idem | non | oui |
| F14 | idem | Enveloppes Conum (consommation, plafond départemental) | `main.subvention`, `main.poste`, SA, adresse, `min.enveloppe_financement`, `min.departement_enveloppe` | `adresse.departement` | non | oui |
| F15 | Financements (TdB structure) | « Financements engagés par l'État » (total FNE + Conum) | `min.membre`, `min.beneficiaire_subvention`, `min.demande_de_subvention`, `min.enveloppe_financement`, `main.subvention`, `main.poste` | `membre.structure_id` / `poste.structure_id` | non | oui |
| F16 | Financements (structure) | « Dont » ventilation par enveloppe (FNE + Conum) | idem F15 | idem | non | oui |
| G1 | Bénéficiaires de financements (TdB admin/dépt/région) | « Bénéficiaires » (total) | `min.demande_de_subvention`, `min.beneficiaire_subvention`, `min.enveloppe_financement`, `main.subvention`, `main.poste`, SA, adresse | `gouvernance_departement_code` + `adresse.departement` | non | oui |
| G2 | idem | « Nombre de bénéficiaires par financements » — enveloppes FNE | `min.*` ci-dessus | idem | non | oui |
| G3 | idem | idem — enveloppes « Conseiller Numérique … » | `main.subvention`, `main.poste`, SA, adresse, `min.enveloppe_financement` | `adresse.departement` | non | oui |
| H1 | Bandeau label Conum (TdB structure, bêta-testeurs) | « Votre structure est éligible au label conseiller numérique » | `main.poste` | `structure_id = id` | non | oui |
| H2 | Bandeau label Conum | « Votre structure est labellisée conseiller numérique » | `main.conum_labellisation` | idem | non (mais `utilisateur_id`) | **non** (table hors périmètre) |
| I1 | Page `/gouvernances` (admin) | « Gouvernances territoriales » : total (105 fixe), « dont N co-portées », ventilation par type de coporteur, « Sans coporteur » | `min.gouvernance`, `min.membre` | ≠ 'zzz' | non | oui |
| I2 | Page `/gouvernances` | « Feuilles de route » : total, « dont N avec demandes de subvention », ventilation par périmètre | `min.feuille_de_route`, `min.action`, `min.demande_de_subvention` | ≠ 'zzz' | non | oui |
| I3 | Page `/gouvernances` | « Collectivités impliquées dans la gouvernance » : total, « dont N membres coporteurs », ventilation | `min.membre` | ≠ 'zzz' | non | oui |
| I4 | Page `/gouvernances` | « Autres structures impliquées dans la gouvernance » : total, coporteurs, ventilation | `min.membre` | ≠ 'zzz' | non | oui |
| S1 | Statistiques — générales | « Accompagnements » (total) + infobulle individuels / participations / ateliers | `coop.activites` (+ jointures de filtre) | `lieu_code_insee` / `coop.lieu_inclusion.code_insee` ; structure via `structure_employeuse_main_id` | non | oui |
| S2 | Statistiques — générales | « Bénéficiaires accompagnés » | `coop.activites`, `coop.accompagnements`, `coop.beneficiaires` | idem | non | oui |
| S3 | idem | « N bénéficiaires suivis » | idem | idem | non | oui |
| S4 | idem | « N bénéficiaires anonymes » | dérivé S2−S3 | idem | non | oui |
| S5 | idem | « Nombre d'accompagnements — Par mois » (≤ 12 derniers mois de la période) | `coop.activites`, `coop.accompagnements` | idem | non | oui |
| S6 | idem | « Nombre d'accompagnements — Par jour » | idem | idem | non | oui |
| S7 | Statistiques — accompagnements | « Types d'activités » : Accompagnement individuel / Atelier collectif (« sur N ateliers ») | `coop.activites` | idem | non | oui |
| S8 | idem | « Thématiques des accompagnements de médiation numérique » (19 items) | `coop.activites.thematiques` | idem | non | oui |
| S9 | idem | « Thématiques des accompagnements de démarches administratives » (11 items) | idem | idem | non | oui |
| S10 | idem | « Tags spécifiques » (vue territorialisée seulement) | `coop.accompagnements`, `coop.activites`, `coop.activite_tags`, `coop.tags` | idem | `tags.nom` (texte libre, masqué côté llm) | partiel |
| S11 | idem | « Matériel utilisé lors des accompagnements » (5 items) | `coop.activites.materiel` | idem | non | oui |
| S12 | idem | « Canaux des accompagnements » (4 items `type_lieu`) | `coop.activites` | idem | non | oui |
| S13 | idem | « Durée des accompagnements » (4 tranches) | `coop.activites.duree` | idem | non | oui |
| S14 | Statistiques — bénéficiaires | « Genres » (3) | `coop.beneficiaires.genre` | idem | non | oui |
| S15 | idem | « Tranches d'âge » (8) | **`coop.beneficiaires.annee_naissance`** + `tranche_age` | idem | **oui** (`annee_naissance`) | **partiel/bloquant** |
| S16 | idem | « Statuts » (5) | `coop.beneficiaires.statut_social` | idem | non | oui |

Calculés mais **non affichés** (ne pas chercher à les reproduire) : `statistiquesicp` (répartition ICP nationale, loader `getForFrance`), `totaux.beneficiaires.nouveaux` (page statistiques), `nombreDeFinancementsEngagesParLEtat` sur le bloc structure, `totaux.*.demarches` (toujours 0), `communes` / `structures` (toujours `[]` → sections « Commune de résidence » et « Nombre d'accompagnements par lieux » jamais rendues), `disponible` des enveloppes Conum.

---

## (b) Détail par indicateur

### Mailles et périmètre du tableau de bord

- Territoire (`TerritoireTableauDeBord`) : `france` | `departement {code}` | `region {codesDepartement}` | `epci {codesInsee}` | `structure {structureId}`. Région = cumul des départements de la région (liens de détail masqués) ; EPCI = liste de codes INSEE des communes ; à l'EPCI les blocs gouvernance, financements et bénéficiaires sont masqués (`registreBlocs.ts`).
- `FiltreTerritorial` → `conditionTerritoriale(filtre, alias)` (`gateways/shared/filtreTerritorialSql.ts`) :

```sql
-- communes     : <alias>.code_insee = ANY($codesInsee)
-- departement  : <alias>.departement = $code
-- departements : <alias>.departement = ANY($codes)
-- national     : TRUE
```

  `main.adresse.departement` porte le code département tel quel (`'2A'`, `'971'`) : pas de règle DOM-TOM à appliquer côté entrepôt. Nao : `llm.adresse.departement` / `llm.adresse.code_insee`.
- Scope (droits) `ScopeFiltre` : `national` | `departemental {codes}` | `structure {id}` (`ResoudreContexte.scopeFiltre()`).

### A — Points de vigilance des lieux (`PrismaPointsVigilanceLieuxLoader`)

Libellés : « Points de vigilance des lieux d'inclusion numérique » ; lignes « 🔴 N lieux à actualiser (informations de plus de 18 mois) » et « 🟠 N lieux à vérifier (informations de 12 à 18 mois) ». Une ligne n'est rendue que si son compteur > 0 ; la section disparaît si les deux sont nuls.

[SQL] (`WITH ${scopeCte}` = CTE `lieux_dans_scope` ci-dessous, statut `actif`) :

```sql
WITH lieux_dans_scope AS (...)
SELECT
  SUM(CASE WHEN l.updated_at IS NULL OR l.updated_at <= $jusqua_18m THEN 1 ELSE 0 END) AS nb_a_actualiser,
  SUM(CASE WHEN l.updated_at > $apres_18m AND l.updated_at <= $jusqua_12m THEN 1 ELSE 0 END) AS nb_a_verifier
FROM main.lieu_inclusion l
JOIN lieux_dans_scope lds ON lds.id = l.id
```

Bornes (`shared/fraicheur.ts`) : un mois = 30,44 jours ; `jusqua_18m = now − 18 × 30,44 j`, `apres_18m = now − 18 × 30,44 j`, `jusqua_12m = now − 12 × 30,44 j`. En SQL pur : `now() - interval '548 days'` (18 × 30,44 = 547,9) et `now() - interval '365 days'` (12 × 30,44 = 365,3). `updated_at IS NULL` compte dans « à actualiser ».

CTE `lieux_dans_scope` (`gateways/shared/lieuxDansScope.ts`, statut actif ⇒ `AND l.deleted_at IS NULL`) selon la maille :

```sql
-- departement / region (type 'departemental', codes = [code] ou codesDepartement)
lieux_dans_scope AS (
  SELECT l.id FROM main.lieu_inclusion l
  LEFT JOIN main.adresse a ON a.id = l.adresse_id
  WHERE a.departement = ANY($codes) AND l.deleted_at IS NULL)
-- epci (type 'communes')
lieux_dans_scope AS (
  SELECT l.id FROM main.lieu_inclusion l
  LEFT JOIN main.adresse a ON a.id = l.adresse_id
  WHERE a.code_insee = ANY($codesInsee) AND l.deleted_at IS NULL)
-- structure
lieux_dans_scope AS (
  SELECT l.id FROM main.lieu_inclusion l
  WHERE EXISTS (
      SELECT 1 FROM main.personne_affectations_lieu pal
      WHERE pal.lieu_id = l.id AND pal.est_active = true
        AND pal.personne_id IN (
          SELECT pae.personne_id FROM main.personne_affectations_emploi pae
          WHERE pae.structure_administrative_id = $id AND pae.est_active = true
          UNION
          SELECT pe.id FROM min.personne_enrichie pe
          WHERE pe.structure_employeuse_id = $id))
    AND l.deleted_at IS NULL)
-- france
lieux_dans_scope AS (SELECT l.id FROM main.lieu_inclusion l WHERE true AND l.deleted_at IS NULL)
```

Période : aucune (instantané à `now`). Nao : `llm.lieu_inclusion` expose `updated_at`, `deleted_at`, `adresse_id` ; `llm.personne_enrichie.structure_employeuse_id` ; tables d'affectations en accès direct.

### B — Données de la structure (`PrismaDonneesStructureLoader`, bloc `donneesStructure`)

Affiché pour un gestionnaire de structure sans coportage. Valeur `'-'` si `structureId = 0` ou erreur.

B1 « Lieux d'inclusion numérique — gérés par votre structure » [SQL] :

```sql
SELECT COUNT(DISTINCT l.id)::bigint AS total
FROM main.lieu_inclusion l
WHERE EXISTS (
    SELECT 1 FROM main.personne_affectations_lieu pal
    WHERE pal.lieu_id = l.id AND pal.est_active = true
      AND pal.personne_id IN (
        SELECT pae.personne_id FROM main.personne_affectations_emploi pae
        WHERE pae.structure_administrative_id = $structureId AND pae.est_active = true
        UNION
        SELECT pe.id FROM min.personne_enrichie pe
        WHERE pe.structure_employeuse_id = $structureId
      )
  )
```

Particularité : pas de filtre `deleted_at` ici (contrairement à A).

B2 « Médiateurs et aidants numériques — gérés par votre structure » [SQL] :

```sql
SELECT COUNT(DISTINCT pe.id)::bigint AS total
FROM min.personne_enrichie pe
WHERE (pe.est_actuellement_mediateur_en_poste = true OR pe.est_actuellement_aidant_numerique_en_poste = true)
  AND (
    pe.structure_employeuse_id = $structureId
    OR EXISTS (
      SELECT 1 FROM main.personne_affectations_emploi pae
      WHERE pae.personne_id = pe.id AND pae.est_active = true AND pae.structure_administrative_id = $structureId
    )
  )
```

B3/B4 « Accompagnements des 6 derniers mois — Total cumulé des dispositifs » + histogramme [SQL] :

```sql
SELECT
  to_char(date_trunc('month', a.date), 'YYYY-MM-DD') AS mois,
  COALESCE(SUM(a.accompagnements_count), 0)::bigint AS nombre
FROM coop.activites a
WHERE a.structure_employeuse_main_id = $structureId
  AND a.suppression IS NULL
  AND a.date >= $debutPeriode::date
  AND a.date < $finPeriode::date
GROUP BY date_trunc('month', a.date)
ORDER BY mois
```

Période : `debutPeriode` = 1er jour du mois `M−5`, `finPeriode` = 1er jour du mois `M+1` (6 mois glissants incluant le mois courant). Le total B3 = somme des 6 valeurs mensuelles ; les mois sans activité valent 0 ; libellés `MM/AA`, mois courant surligné. Nao : `llm.coop_activites` (colonnes `structure_employeuse_main_id`, `accompagnements_count`, `suppression`, `date` exposées).

### C — État des lieux de l'inclusion numérique (bloc `etatDesLieux`)

Sous-titre : « Données cumulées de tous les dispositifs d'inclusion numérique ». Filtre = `filtreTerritorialDuTerritoire(territoire)` ; **quirk** : à la maille `structure`, le bloc passe `{ code: String(structureId), type: 'departement' }` → C1/C2 comparent `adresse.departement` à l'id de structure (résultat 0).

C1 « Lieux d'inclusion numérique » (infobulle : lieux référencés sur la Cartographie nationale) — `PrismaLieuxInclusionNumeriqueLoader` [SQL] :

```sql
SELECT COUNT(*) AS nb_lieux
FROM main.lieu_inclusion
INNER JOIN main.adresse ON lieu_inclusion.adresse_id = adresse.id
WHERE <conditionTerritoriale(filtre, 'adresse')>
```

Particularités : INNER JOIN (lieux sans adresse exclus) ; **aucun filtre `deleted_at`** (lieux archivés comptés) ; formaté `toLocaleString('fr-FR')`.

C2 « Médiateurs et aidants numériques » (infobulle : inscrits sur la Coop et/ou labellisés Aidants Connect) — `PrismaMediateursEtAidantsLoader` [P] :

```sql
-- national
SELECT COUNT(*) FROM min.personne_enrichie
WHERE est_actuellement_aidant_numerique_en_poste = true OR est_actuellement_mediateur_en_poste = true;
-- territorial (2 requêtes Prisma : ids des SA du périmètre, puis count)
SELECT COUNT(*) FROM min.personne_enrichie pe
WHERE (pe.est_actuellement_aidant_numerique_en_poste = true OR pe.est_actuellement_mediateur_en_poste = true)
  AND pe.structure_employeuse_id IN (
    SELECT s.id FROM main.structure_administrative s JOIN main.adresse a ON a.id = s.adresse_id
    WHERE <communes : a.code_insee IN (...) | departement : a.departement = $code | departements : a.departement IN (...)>);
```

Particularité : en territorial, les personnes sans `structure_employeuse_id` sont exclues (incluses au national).

C3 « Accompagnements réalisés » (infobulle : depuis 2021, Conseillers Numériques et Aidants Connect) — `fetchAccompagnementsRealises` = AC + Coop :

AC (`PrismaAccompagnementsRealisesParACLoader`) [SQL] :

```sql
-- national
SELECT COALESCE(SUM(pe.nb_accompagnements_ac), 0) AS total_accompagnements
FROM min.personne_enrichie pe
WHERE pe.type_accompagnateur = 'aidant_numerique';
-- territorial
SELECT COALESCE(SUM(pe.nb_accompagnements_ac), 0) AS total_accompagnements
FROM min.personne_enrichie pe
LEFT JOIN main.structure_administrative s ON s.id = pe.structure_employeuse_id
LEFT JOIN main.adresse a ON a.id = s.adresse_id
WHERE pe.type_accompagnateur = 'aidant_numerique'
  AND <conditionTerritoriale(filtre, 'a')>
```

(`type_accompagnateur = 'aidant_numerique'` ⇔ `is_mediateur` faux ou NULL, cf. V092.)

Coop : `PrismaStatistiquesCoopLoader.recupererStatistiques(filtres)` avec `filtres = { departements: [code] }` (département), `{ departements: codes }` (région), `{ communes: codesInsee }` (EPCI), `undefined` (France) — **sans `du`/`au`** → totaux toutes périodes. Valeur ajoutée = `totaux.accompagnements.total` (S1 ci-dessous, sans filtre de période). Résultat mis en cache 1 h (`CachedApiCoopStatistiquesLoader`).

`nombreTotal = total_AC + totaux.accompagnements.total` ; formaté `fr-FR`. À la maille `structure`, le même emplacement affiche `fetchAccompagnementsRealisesParStructure` = **B3** (somme 6 mois seulement, malgré le libellé « depuis 2021 »).

C4 « Accompagnements des 6 derniers mois » (infobulle : saisis sur La Coop) = `accompagnementsParMois.slice(-6)` de S5 avec `du/au` absents ⇒ fenêtre 12 derniers mois dont on garde les 6 derniers (libellé `MM/AA`). Même requête que S5. Maille structure : histogramme B4.

C5 Carte « Indice de Fragilité numérique » (infobulle : données Mednum 2021) — `PrismaIndicesDeFragiliteLoader` [P] :

```sql
-- departement : communes du département
SELECT code_insee, score FROM admin.ifn_commune WHERE code_insee LIKE $codeDepartement || '%';
-- epci
SELECT code_insee, score FROM admin.ifn_commune WHERE code_insee IN ($codesInsee);
-- region
SELECT code, score FROM admin.ifn_departement WHERE code IN ($codesDepartement);
-- france
SELECT code, score FROM admin.ifn_departement;
SELECT code, label FROM admin.icp_departement;   -- ICP : comptés par label mais non affichés
```

Présentation : `indice = round(score, 2)` ; couleur = `FRAGILITE_COLORS[max(1, ceil(score × 7 / 10))]` ; popup France `score/10`. Particularité : `startsWith(codeDepartement)` sur 5 caractères INSEE — pour `'2A'`/`'2B'` et les DOM (`'971'`) le préfixe fonctionne ; aucun retraitement.

### D — Médiateurs numériques et Aidants Connect (`PrismaStatistiquesMediateursLoader`, bloc `mediateurs`)

Sous-titre : « Chiffres clés des médiateurs numériques et Aidants Connect identifiés sur le territoire ». Non affiché à la maille structure.

[SQL] (national = même SELECT sans jointures ni condition territoriale) :

```sql
SELECT
  COUNT(*) FILTER (WHERE pe.est_actuellement_mediateur_en_poste = true) AS mediateurs,
  COUNT(*) FILTER (WHERE pe.is_coordinateur = true AND pe.est_actuellement_mediateur_en_poste = true) AS coordinateurs,
  COUNT(*) FILTER (WHERE pe.est_actuellement_conseiller_numerique = true) AS conseillers_numeriques,
  COUNT(*) FILTER (WHERE pe.labellisation_aidant_connect = true AND pe.est_actuellement_mediateur_en_poste = true) AS aidants_connect
FROM min.personne_enrichie pe
LEFT JOIN main.structure_administrative s ON s.id = pe.structure_employeuse_id
LEFT JOIN main.adresse a ON a.id = s.adresse_id
WHERE pe.est_actuellement_mediateur_en_poste = true
AND <conditionTerritoriale(filtre, 'a')>
```

- D1 « Médiateurs numériques » = `mediateurs` ; D2 « Coordinateurs » ; D3 « Conseillers numériques » (le WHERE global impose aussi `est_actuellement_mediateur_en_poste`) ; D4 « Aidants habilités Aidants Connect ».
- D5 « Médiateurs non-habilités Aidants Connect » = `max(0, D1 − D3 − D4)` (presenter `BlocMediateurs.tsx`). Les 4 détails alimentent un demi-donut.
- Territorial : via la SA employeuse (LEFT JOIN, donc personnes sans SA exclues par la condition sur `a`).

### E — Gouvernances (blocs `gouvernance`)

E1–E4 national (`PrismaGouvernanceAdminLoader`) [P] :

```sql
-- E1 « Gouvernances »
SELECT COUNT(*) FROM min.gouvernance WHERE departement_code <> 'zzz';
-- E2 « dont N gouvernances co-portées » : gouvernances ayant >= 2 coporteurs non supprimés
SELECT COUNT(*) FROM (
  SELECT g.departement_code
  FROM min.gouvernance g
  JOIN min.membre m ON m.gouvernance_departement_code = g.departement_code
                   AND m.is_coporteur = true AND m.statut <> 'supprime'
  WHERE g.departement_code <> 'zzz'
  GROUP BY g.departement_code HAVING COUNT(*) >= 2) t;
-- E3 « Feuilles de route déposées »
SELECT COUNT(*) FROM min.feuille_de_route WHERE gouvernance_departement_code <> 'zzz';
-- E4 « comprenant N actions enregistrées »
SELECT COUNT(*) FROM min.action a JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
WHERE f.gouvernance_departement_code <> 'zzz';
```

E5–E8 département / région (`PrismaGouvernanceTableauDeBordLoader`, `$filtre` = `= $code` | `IN ($codes)` | `<> 'zzz'` pour `'France'`) [P] :

```sql
-- E5 « Membres de la gouvernance »
SELECT COUNT(*) FROM min.membre WHERE gouvernance_departement_code $filtre AND statut <> 'supprime';
-- E6 « dont N coporteurs »
SELECT COUNT(*) FROM min.membre WHERE gouvernance_departement_code $filtre AND statut <> 'supprime' AND is_coporteur = true;
-- E7 / E8 : comme E3 / E4 avec $filtre
```

Note : « déposées » ne signifie rien de plus que « existantes » dans ces blocs (toute ligne `min.feuille_de_route` compte). Nao : `llm.membre` expose `gouvernance_departement_code`, `statut`, `is_coporteur`, `type`, `structure_id` ; `llm.gouvernance` expose `departement_code` ; `min.feuille_de_route`, `min.action` en accès direct.

### F — Financements (blocs `financements`)

Règle de classification (`shared/enveloppeFinancement.ts`) : enveloppe « Conseiller Numérique » ⇔ `libelle LIKE 'Conseiller Numérique%'` ; sinon FNE. Formatage : national `formatMontantEnMillions` (`≥ 1 M€ → x,xx M€`, `≥ 10 000 → x,xx K€`, sinon `n €`) ; département/structure `formatMontant` (`n €`).

**National — `PrismaFinancementsAdminLoader` (composant `FinancementsAdmin`, sous-titre « Chiffres clés des enveloppes de financement »)** [P] :

```sql
-- base : demandes acceptées rattachées à une feuille de route hors 'zzz'
WITH demandes AS (
  SELECT d.*, e.libelle AS enveloppe_libelle, e.montant AS enveloppe_montant
  FROM min.demande_de_subvention d
  JOIN min.action a ON a.id = d.action_id
  JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
  JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
  WHERE f.gouvernance_departement_code <> 'zzz' AND d.statut = 'acceptee')
-- F1 « Financements FNE engagés par l'État »
SELECT COALESCE(SUM(subvention_demandee), 0) FROM demandes;
-- F5 « N financement(s) engagé(s) par l'État » (infobulle : demandes de subventions validées des feuilles de route)
SELECT COUNT(*) FROM demandes;
-- F6 ventilation : une ligne par libellé d'enveloppe, total = somme, enveloppeTotale = e.montant
SELECT enveloppe_libelle AS label, SUM(subvention_demandee) AS total, MAX(enveloppe_montant) AS enveloppe_totale
FROM demandes GROUP BY enveloppe_libelle;
-- F2 « sur X disponible » : somme des |montant| des enveloppes FNE (toutes, sans filtre de date)
SELECT COALESCE(SUM(ABS(montant)), 0) FROM min.enveloppe_financement WHERE libelle NOT LIKE 'Conseiller Numérique%';
```

F6 : « % de l'enveloppe consommée » = `round(100 × total / enveloppeTotale)` (0 si `enveloppeTotale ≤ 0`) ; barre plafonnée à 100 %.

F3/F4 « Financements Conseiller Numérique versés » / « sur X conventionnés sur les postes liés à la gouvernance » [SQL] :

```sql
SELECT
  COALESCE(SUM(v.montant_subvention_cumule), 0)::bigint AS conventionne,
  COALESCE(SUM(v.montant_versement_cumule), 0)::bigint AS verse
FROM min.postes_conseiller_numerique_synthese v
```

F7 enveloppes Conum nationales (`PrismaEnveloppesConseillerNumeriqueLoader.#queryFrance`) [SQL] :

```sql
WITH agg AS (
  SELECT
    COALESCE(SUM(s.montant_subvention_v1), 0)::bigint AS total_v1,
    COALESCE(SUM(s.montant_subvention_v2), 0)::bigint AS total_v2
  FROM main.subvention s
)
SELECT
  e.libelle,
  e.date_debut AS "dateDeDebut",
  e.date_fin AS "dateDeFin",
  e.montant AS plafond,
  CASE
    WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2
    WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1
    ELSE 0
  END AS consommation
FROM min.enveloppe_financement e
CROSS JOIN agg
-- Type « Conseiller Numérique » : règle canonique classifierTypeEnveloppe (@/shared/enveloppeFinancement)
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

Présentation : `total = formatMontantEnMillions(consommation)` ; `pourcentageConsomme = round(100 × consommation / plafond)` (0 si plafond ≤ 0). Liste masquée si vide.

**Département / région — `PrismaFinancementsLoader` (composant `FinancementsPref`, sous-titre « Chiffres clés des budgets et financements »)** [P] (`$filtre` = `= $code` ou `IN ($codes)`) :

```sql
WITH fdr AS (SELECT * FROM min.feuille_de_route WHERE gouvernance_departement_code $filtre),
demandes AS (
  SELECT d.subvention_demandee, e.libelle, e.montant AS enveloppe_montant
  FROM fdr f JOIN min.action a ON a.feuille_de_route_id = f.id
  JOIN min.demande_de_subvention d ON d.action_id = a.id
  JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
  WHERE d.statut = 'acceptee')
-- F9 « sur X de votre budget global renseigné »
SELECT COALESCE(SUM(a.budget_global), 0) FROM fdr f JOIN min.action a ON a.feuille_de_route_id = f.id;
-- F8 « Financements FNE engagés par l'État » = somme de toutes les ventilations
SELECT COALESCE(SUM(subvention_demandee), 0) FROM demandes;
-- F12 « N financement(s) engagé(s) par l'État » (infobulle : … des feuilles de route de votre gouvernance)
SELECT COUNT(*) FROM demandes;
-- F13 ventilation par enveloppe
SELECT libelle AS label, SUM(subvention_demandee) AS total, MAX(enveloppe_montant) AS enveloppe_totale FROM demandes GROUP BY libelle;
```

Attention : ici aucune restriction `LIKE 'Conseiller Numérique%'` — toute demande acceptée compte dans « FNE engagés » quel que soit le libellé d'enveloppe (en pratique les demandes de feuilles de route sont FNE).

F10/F11 Conum versé / conventionné territorial [SQL] (`${filtreTerritoire}` = `WHERE a.departement = $code` ou `WHERE a.departement = ANY($codes)`) :

```sql
SELECT
  COALESCE(SUM(v.montant_subvention_cumule), 0)::bigint AS conventionne,
  COALESCE(SUM(v.montant_versement_cumule), 0)::bigint AS verse
-- Refonte 2026 : v.structure_id pointe sur SA (V078 dataspace).
FROM min.postes_conseiller_numerique_synthese v
LEFT JOIN main.structure_administrative st ON st.id = v.structure_id
LEFT JOIN main.adresse a ON a.id = st.adresse_id
WHERE a.departement = $code
```

F14 enveloppes Conum départementales (`#queryDepartement`) [SQL] :

```sql
WITH agg AS (
  SELECT
    COALESCE(SUM(s.montant_subvention_v1), 0)::bigint AS total_v1,
    COALESCE(SUM(s.montant_subvention_v2), 0)::bigint AS total_v2
  -- Refonte 2026 : main.poste.structure_id pointe sur SA (V078 dataspace).
  FROM main.subvention s
  JOIN main.poste p ON p.id = s.poste_id
  JOIN main.structure_administrative st ON st.id = p.structure_id
  JOIN main.adresse a ON a.id = st.adresse_id
  WHERE a.departement = $code
)
SELECT
  e.libelle,
  e.date_debut AS "dateDeDebut",
  e.date_fin AS "dateDeFin",
  COALESCE(de.plafond, 0) AS plafond,
  CASE
    WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2
    WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1
    ELSE 0
  END AS consommation
FROM min.enveloppe_financement e
CROSS JOIN agg
LEFT JOIN min.departement_enveloppe de
  ON de.enveloppe_id = e.id AND de.departement_code = $code
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

Région (`getPourDepartements`) : même structure avec `a.departement = ANY($codes)` et `plafonds AS (SELECT de.enveloppe_id, SUM(de.plafond)::int AS plafond FROM min.departement_enveloppe de WHERE de.departement_code = ANY($codes) GROUP BY de.enveloppe_id)` joint sur `enveloppe_id`. Le % consommé est calculé mais la barre n'est rendue qu'en contexte `admin`.

Écart notable : F3/F4 (national) sont calculés depuis la **vue synthèse** (`montant_subvention_cumule` = V1 + V2 avec bonification, dédoublonné par tuple poste/structure) alors que F7/F14 (enveloppes) somment **brut** `main.subvention.montant_subvention_v1/v2` (toutes lignes, y compris historique). Les deux chiffres ne sont donc pas censés se recouper exactement.

**Structure — `PrismaFinancementsStructureLoader` + `getParStructure` (composant `FinancementsStructure`, sous-titre « Chiffres clés de vos financements »)** [P] :

```sql
-- FNE : demandes acceptées dont la structure est bénéficiaire (via ses lignes min.membre)
SELECT e.libelle AS label, SUM(d.subvention_demandee) AS total, MAX(e.montant) AS enveloppe_totale, COUNT(*) AS nb
FROM min.membre m
JOIN min.beneficiaire_subvention b ON b.membre_id = m.id
JOIN min.demande_de_subvention d ON d.id = b.demande_de_subvention_id AND d.statut = 'acceptee'
JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
WHERE m.structure_id = $structureId
GROUP BY e.libelle;
```

Conum structure [SQL] (`getParStructure`) :

```sql
WITH agg AS (
  SELECT
    COALESCE(SUM(s.montant_subvention_v1), 0)::bigint AS total_v1,
    COALESCE(SUM(s.montant_subvention_v2), 0)::bigint AS total_v2
  FROM main.subvention s
  JOIN main.poste p ON p.id = s.poste_id
  WHERE p.structure_id = $structureId
)
SELECT
  e.libelle,
  e.date_debut AS "dateDeDebut",
  e.date_fin AS "dateDeFin",
  0 AS plafond,
  CASE
    WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2
    WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1
    ELSE 0
  END AS consommation
FROM min.enveloppe_financement e
CROSS JOIN agg
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

Presenter (`financementsStructurePresenter`, fix #1557) : ventilation = lignes FNE ∪ enveloppes Conum avec `consommation > 0` ; F15 « Financements engagés par l'État » = somme de cette ventilation (FNE + Conum) ; F16 « Dont » = chaque ligne. Si ventilation vide : « 👻 Aucun financement trouvé pour la structure ». Un membre peut avoir plusieurs lignes `min.membre` (plusieurs gouvernances) : chaque `beneficiaire_subvention` compte une fois par ligne de membre.

### G — Bénéficiaires de financements (`PrismaBeneficiairesLoader`, bloc `beneficiaires`)

Sous-titre : « Chiffres clés sur les bénéficiaires de financements » ; note : « Un bénéficiaire peut cumuler plusieurs financements ». `collectivite` vaut toujours 0 (ligne « dont N collectivités » jamais rendue).

G2 par enveloppe FNE [P] (`$filtre` sur `gouvernance_departement_code` : `= $code`, `IN ($codes)`, `<> 'zzz'` pour la France) :

```sql
SELECT e.libelle AS label, COUNT(DISTINCT b.membre_id) AS total
FROM min.demande_de_subvention d
JOIN min.action a ON a.id = d.action_id
JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
JOIN min.beneficiaire_subvention b ON b.demande_de_subvention_id = d.id
WHERE f.gouvernance_departement_code $filtre AND d.statut = 'acceptee'
GROUP BY e.libelle;
-- total FNE distinct (toutes enveloppes confondues)
SELECT COUNT(DISTINCT b.membre_id) FROM ... (mêmes jointures/filtres);
```

G3 par enveloppe Conum [SQL] (`${filtreTerritoire}` = vide / `WHERE a.departement = $code` / `WHERE a.departement = ANY($codes)`) :

```sql
WITH agg AS (
  SELECT
    COUNT(DISTINCT CASE WHEN s.montant_subvention_v1 > 0 THEN p.structure_id END) AS total_v1,
    COUNT(DISTINCT CASE WHEN s.montant_subvention_v2 > 0 THEN p.structure_id END) AS total_v2
  -- Refonte 2026 : main.poste.structure_id pointe sur SA (V078 dataspace).
  FROM main.subvention s
  JOIN main.poste p ON p.id = s.poste_id
  LEFT JOIN main.structure_administrative st ON st.id = p.structure_id
  LEFT JOIN main.adresse a ON a.id = st.adresse_id
  ${filtreTerritoire}
)
SELECT
  e.libelle AS label,
  CASE WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2 WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1 ELSE 0 END AS total
FROM min.enveloppe_financement e
CROSS JOIN agg
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

G1 « Bénéficiaires » = `COUNT DISTINCT membre_id (FNE, toutes enveloppes)` **+** `Σ total des lignes Conum` (une structure financée en V1 et V2 compte deux fois ; les bénéficiaires FNE sont des membres `min.membre`, les Conum des `structure_administrative` : unités hétérogènes, simplement additionnées). Demi-donut sur les détails.

### H — Bandeau label Conum (`PrismaEligibiliteLabelConumLoader`, bloc `labelConum`)

Visible pour un gestionnaire de structure bêta-testeur. Label actif prioritaire sur l'éligibilité. [P] :

```sql
-- H2 « Votre structure est labellisée conseiller numérique » si la dernière attestation est encore valide
SELECT date_attestation FROM main.conum_labellisation WHERE structure_id = $id ORDER BY date_attestation DESC LIMIT 1;
-- actif ⇔ now < dateRenouvellementLabelConum(derniere_attestation)  (fonction non lue : durée de validité dans AttesterLabellisationStructure.ts)
-- H1 « Votre structure est éligible au label conseiller numérique » ⇔ au moins un poste Conum dans l'historique
SELECT COUNT(*) > 0 FROM main.poste WHERE structure_id = $id;
```

Nao : `main.conum_labellisation` n'est pas dans `nao_config.yaml` → H2 non reconstructible ; H1 l'est (`main.poste`).

### I — Page admin `/gouvernances` (loaders `tableauDeBord/`, composants `Gouvernances/*`)

Toutes ces requêtes partent de `SELECT * FROM min.membre WHERE gouvernance_departement_code <> 'zzz'` (**sans** filtre `statut`, donc membres supprimés inclus — à la différence de E) puis agrègent en TypeScript. Un donut + liste par carte, « Données mises à jour le JJ/MM/AAAA » = date de génération.

I1 « Gouvernances territoriales » (`PrismaGouvernancesTerritorialesLoader`) :

```sql
-- gouvernances avec leurs coporteurs (tous statuts)
SELECT g.departement_code, m.type
FROM min.gouvernance g
LEFT JOIN min.membre m ON m.gouvernance_departement_code = g.departement_code AND m.is_coporteur = true
WHERE g.departement_code <> 'zzz';
```

- `nombreTotal` = **105 (constante codée)**, pas un COUNT.
- « Sans coporteur » = nombre de gouvernances ayant **exactement 1** coporteur (la préfecture) : `HAVING COUNT(m.id) = 1`.
- « dont N co-portées » (composant) = `105 − sansCoporteur`.
- Ventilation par type de coporteur : pour chaque gouvernance, ensemble distinct des `m.type` hors `'Préfecture départementale'` (`NULL → 'Autre'`) ; `count` = nombre de gouvernances distinctes par type, tri décroissant. SQL : `SELECT COALESCE(type,'Autre') AS type, COUNT(DISTINCT gouvernance_departement_code) FROM min.membre WHERE is_coporteur AND gouvernance_departement_code <> 'zzz' AND type IS DISTINCT FROM 'Préfecture départementale' GROUP BY 1 ORDER BY 2 DESC`.

I2 « Feuilles de route » (`PrismaFeuillesDeRouteDeposeesLoader`) :

```sql
-- total
SELECT COUNT(*) FROM min.feuille_de_route WHERE gouvernance_departement_code <> 'zzz';
-- « dont N avec demandes de subvention » (au moins une action ayant une demande, quel que soit son statut)
SELECT COUNT(*) FROM min.feuille_de_route f WHERE f.gouvernance_departement_code <> 'zzz'
  AND EXISTS (SELECT 1 FROM min.action a JOIN min.demande_de_subvention d ON d.action_id = a.id WHERE a.feuille_de_route_id = f.id);
-- ventilation par périmètre (NULL → 'Autre', masqué de la liste mais présent dans le donut)
SELECT COALESCE(perimetre_geographique, 'Autre') AS perimetre, COUNT(*) FROM min.feuille_de_route
WHERE gouvernance_departement_code <> 'zzz' GROUP BY 1 ORDER BY 2 DESC;
```

Libellés : `departemental → « Feuilles de route départementales »`, `groupementsDeCommunes → « Feuilles de route infra-départementales »`, `regional → « Feuilles de route régionales »`.

I3 « Collectivités impliquées dans la gouvernance » / I4 « Autres structures impliquées dans la gouvernance » (`PrismaCollectivitesLoader`, `PrismaAutresStructuresLoader`) :

- Liste `typesCollectivites` = {'Collectivité, commune', 'Collectivité, EPCI', 'Collectivité, intercommunalité', 'Collectivité territoriale', 'Commune', 'Conseil départemental', 'EPCI', 'Préfecture départementale', 'Préfecture régionale', 'Région'}.
- I3 : membres dont `type` ∈ liste (NULL traité comme `''` → exclu) ; total = COUNT ; « dont N membres coporteurs » = COUNT WHERE is_coporteur ; catégories : `Conseil départemental → Conseils départementaux`, `Région → Conseils régionaux`, `EPCI | Collectivité, EPCI | Collectivité, intercommunalité → EPCI`, `Commune | Collectivité, commune → Communes`, reste → `Autres` (donc préfectures et « Collectivité territoriale » dans Autres).
- I4 : membres dont `type IS NOT NULL` et ∉ liste ; catégories : `Association | Structure associative → Associations`, `Entreprise privée | Opérateur | Partenaire privé → Entreprises privées`, `type LIKE '%Syndicat%' → Syndicats mixtes`, `GIE → GIE`, reste → `Autres`.
- Tri des ventilations : count décroissant.

Annexe — page `/gouvernances/list` (`PrismaGouvernancesInfosLoader`, hors `tableauDeBord/`) : cartes « Gouvernances territoriales » (= nb départements listés, « dont N co-portées » = `coporteurCount ≥ 2`), « Feuilles de route » (« dont N actions »), « Crédits engagés par l'état » (`Σ (subvention_etp + subvention_prestation)` des demandes `statut = 'acceptee'`, « pour N demandes de subvention ») ; tableau par département : membres **`statut = 'confirme'`** (encore une autre règle), coporteurs, FDR, actions, « Dotation État » = `SUM(min.departement_enveloppe.plafond)` par département, « Montant engagé » = Σ etp+prestation, « Co-finan. » = `SUM(min.co_financement.montant)` via action→FDR, « Montant total » = engagé + co-financement. Trois définitions différentes de « membre » coexistent (E : `≠ 'supprime'` ; I : tous ; liste : `= 'confirme'`) et deux de « montant engagé » (F : `subvention_demandee` ; liste : `etp + prestation`).

### S — Page `/statistiques` (« Statistiques médiation numérique » / « Statistiques de {structure} »)

Source unique : `PrismaStatistiquesCoopLoader.recupererStatistiques(filtres)` (remplace l'API Coop `GET /api/v1/statistiques` ; repli possible `COOP_STATS_SOURCE=api`). Sans cache sur cette page.

**Construction des filtres** (`statistiquesServeur.ts`) :

- Période : `clamperPeriode(du, au, aujourd'hui)` → `du` défaut `2020-11-17` (`DATE_DEBUT_DISPOSITIF`), `au` défaut aujourd'hui ; bornes forcées dans `[2020-11-17, aujourd'hui]` ; format invalide → défaut. **`du` et `au` sont donc toujours renseignés** sur la page.
- Scope `departemental` sans choix explicite → `departements = codes du scope` ; les départements choisis dans l'URL sont intersectés avec le scope. Scope `structure` → `structuresEmployeuses = [id]` (filtre à la maille **activité** `structure_employeuse_main_id`, pas médiateur) et le filtre structures est ignoré. Scope `national` → pas de filtre implicite.
- `lieux` (ids `main.lieu_inclusion`) → traduits en uuid Coop par `PrismaLieuxCoopLoader.recupererCoopIds` (non lu en détail ; correspond à `main.lieu_inclusion.structure_coop_id`).
- `communes` = codes INSEE ; `types` ∈ {Collectif, Demarche, Individuel} ; thématiques en clés PascalCase.
- `vueTerritorialisee` (tags affichés) ⇔ au moins un filtre départements / communes / lieux / structures employeuses.

**Clause WHERE commune** (`construireRequete`) :

```sql
act.suppression IS NULL
[AND act.date::date >= $du::date] [AND act.date::date <= $au::date]
[AND act.type IN ('individuel', 'collectif')]                           -- types ; 'Demarche' ignoré (pas de valeur BDD)
[AND act.thematiques && ARRAY['...']::coop.thematique[]]                -- union thématiques non-admin + admin
[AND act.structure_id = ANY(ARRAY[...]::uuid[])]                        -- lieux
[AND COALESCE(str.code_insee, act.lieu_code_insee) = ANY(ARRAY[...]::text[])]       -- communes
[AND COALESCE(str.code_insee, act.lieu_code_insee) LIKE ANY (ARRAY['DD%', ...]::text[])]  -- départements
[AND EXISTS (SELECT 1 FROM coop.accompagnements acc_beneficiaire WHERE acc_beneficiaire.beneficiaire_id = ANY(...) AND acc_beneficiaire.activite_id = act.id)]
[AND act.mediateur_id = ANY(ARRAY[...]::uuid[])]
[AND act.structure_employeuse_main_id = ANY(ARRAY[...]::int[])]        -- structures employeuses (ids SA)
[AND u.is_conseiller_numerique = TRUE|FALSE]                            -- jamais posé par la page MIN
```

Jointures ajoutées : `LEFT JOIN coop.lieu_inclusion str ON str.id = act.structure_id` si communes ou départements ; `LEFT JOIN coop.mediateurs med ON act.mediateur_id = med.id LEFT JOIN coop.users u ON med.user_id = u.id` si `conseillerNumerique` (non utilisé par la page).

Territorial Coop : le département d'une activité = préfixe du code INSEE du **lieu de l'activité** (`coop.lieu_inclusion.code_insee`), à défaut `act.lieu_code_insee` (activités à distance / à domicile). Motif `LIKE 'DD%'` : `'2A%'`, `'971%'` fonctionnent sur des codes INSEE à 5 caractères ; aucune autre règle DOM-TOM. Les activités sans aucun code INSEE sont exclues du filtre territorial.

**S1 / S7 / S8 / S9 / S11 / S12 / S13 — `recupererStatistiquesActivites`** [SQL] (une seule requête, agrégats pondérés) :

```sql
SELECT COUNT(*)::int AS nombre_activites,
  COALESCE(SUM(CASE WHEN act.type = 'individuel' THEN 1 ELSE 0 END), 0)::int AS nombre_individuels,
  COALESCE(SUM(CASE WHEN act.type = 'collectif' THEN 1 ELSE 0 END), 0)::int AS nombre_collectifs,
  COALESCE(SUM(act.accompagnements_count), 0)::int AS total_accompagnements,
  COALESCE(SUM(CASE WHEN act.type = 'collectif' THEN act.accompagnements_count ELSE 0 END), 0)::int
    AS participants_collectifs,
  -- pour chaque entrée des référentiels :
  COALESCE(SUM(CASE WHEN <predicat> THEN act.accompagnements_count ELSE 0 END), 0)::int AS <alias>
FROM coop.activites act
  <jointures>
WHERE <where>
```

Prédicats : types `act.type = 'individuel' | 'collectif'` ; durées `act.duree >= min AND act.duree < max` avec tranches `[0,30)` « Moins de 30 min », `[30,60)` « 30min à 1 h », `[60,120)` « 1 h à 2 h », `[120, 2^31)` « 2 h et plus » (**`duree NULL` n'entre dans aucune tranche**) ; types de lieu `act.type_lieu = 'lieu_activite' | 'autre' | 'domicile' | 'a_distance'` (libellés « Lieu d'activité », « Autre lieu », « À domicile », « À distance ») ; thématiques `'<valeur>' = ANY(act.thematiques)` (30 valeurs : 19 médiation numérique, 11 démarches — liste exacte dans le loader, enum `coop.thematique`) ; matériels `'<valeur>' = ANY(act.materiel)` (ordinateur, telephone, tablette, autre, aucun → « Pas de matériel »).

- S1 « Accompagnements » = `total_accompagnements` (Σ `accompagnements_count`, pas un COUNT d'activités). Infobulle : « N accompagnements individuels » = `nombre_individuels` ; « N participations lors de M ateliers » = `participants_collectifs` / `nombre_collectifs`.
- S7 « Types d'activités » : items `Accompagnement individuel` (count = `type_individuel_count`, pondéré) et `Atelier collectif` (count = `type_collectif_count` = participations) ; proportion par `allouerPourcentages` sur ces deux counts ; mention « · sur N ateliers » = `nombre_collectifs`.
- S8/S9/S11/S12/S13 : `count` = agrégat pondéré ci-dessus ; `proportion` = `round(100000 × count / Σ counts des items du même référentiel) / 1000` (3 décimales, 0 si Σ = 0). Donc pour les thématiques / matériels (multi-valués) la somme des proportions fait 100 sur l'ensemble du référentiel, **pas** une part du total d'accompagnements. Affichage trié par `count` décroissant (thématiques, démarches, tags) ; ordre du référentiel pour canaux / durées / matériel.

**S2 / S3 / S4 / S14 / S15 / S16 — `recupererStatistiquesBeneficiaires`** [SQL] :

```sql
SELECT COUNT(DISTINCT ben.id)::int AS total_beneficiaires,
  COUNT(DISTINCT CASE WHEN ben.anonyme = false THEN ben.id END)::int AS total_beneficiaires_suivis,
  -- genres : pour chaque valeur v de (masculin, feminin, non_communique[défaut])
  COUNT(DISTINCT CASE WHEN ben.genre = 'v' [OR ben.genre IS NULL si défaut] THEN ben.id END)::int AS genre_v_count,
  -- statuts : retraite, sans_emploi, en_emploi, scolarise, non_communique[défaut]
  COUNT(DISTINCT CASE WHEN ben.statut_social = 'v' [...] THEN ben.id END)::int AS statut_social_v_count,
  -- tranches d'âge : expression TRANCHE_AGE_DERIVEE (ci-dessous), 8 valeurs, non_communique[défaut]
  COUNT(DISTINCT CASE WHEN <TRANCHE_AGE_DERIVEE> = 'v' [...] THEN ben.id END)::int AS tranche_age_v_count
FROM coop.activites act
  INNER JOIN coop.accompagnements acc ON acc.activite_id = act.id
  INNER JOIN coop.beneficiaires ben ON ben.id = acc.beneficiaire_id
  <jointures>
WHERE <where>
```

```sql
-- TRANCHE_AGE_DERIVEE (identique à derivedTrancheAgeSql de la Coop)
COALESCE(
  CASE
    WHEN ben.annee_naissance IS NULL
      OR ben.annee_naissance < 1900
      OR ben.annee_naissance > EXTRACT(YEAR FROM CURRENT_DATE) THEN NULL
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 12 THEN 'moins_de_douze'
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 18 THEN 'douze_dix_huit'
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 25 THEN 'dix_huit_vingt_quatre'
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 40 THEN 'vingt_cinq_trente_neuf'
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 60 THEN 'quarante_cinquante_neuf'
    WHEN EXTRACT(YEAR FROM CURRENT_DATE) - ben.annee_naissance < 70 THEN 'soixante_soixante_neuf'
    ELSE 'soixante_dix_plus'
  END,
  ben.tranche_age::text)
```

- S2 « Bénéficiaires accompagnés » = `total_beneficiaires` (bénéficiaires distincts ayant ≥ 1 accompagnement dans le périmètre ; les fiches anonymes sont **une fiche par accompagnement** — infobulle « comptabilisés comme 1 nouveau bénéficiaire à chaque accompagnement »).
- S3 « bénéficiaires suivis » = `anonyme = false` ; S4 « anonymes » = total − suivis.
- S14 « Genres » (Masculin, Féminin, Non communiqué), S16 « Statuts » (Retraité, Sans emploi, En emploi, Scolarisé, « Non communiqué ou hétérogène »), S15 « Tranches d'âge » (70 ans et plus, 60-69, 40-59, 25-39, 18-24, 12-17, Moins de 12 ans, Non communiqué) : `count` distinct, `proportion` à 3 décimales sur la somme des items ; la valeur « défaut » absorbe les NULL. Les bénéficiaires de l'ensemble filtré ne sont pas dédupliqués entre valeurs si une fiche a été fusionnée (`fusion_vers_id` ignoré).

**S5 / S6 — séries temporelles** (`recupererAccompagnementsParMois` / `ParJour`) [SQL] :

```sql
-- S5 par mois ; fin = $au::date (ou CURRENT_DATE si absent) ; debut = $du::date (ou DATE_TRUNC('month', fin - INTERVAL '11 months'))
WITH accompagnements_filtres AS (
  SELECT act.date
  FROM coop.activites act
    INNER JOIN coop.accompagnements acc ON acc.activite_id = act.id
    <jointures>
  WHERE <where>
    AND act.date <= $fin
    AND act.date >= $debut
),
mois AS (
  SELECT DATE_TRUNC('month', generate_series($debut, $fin, '1 month'::interval)) AS mois
)
SELECT EXTRACT(MONTH FROM mois.mois)::int AS mois,
       EXTRACT(YEAR FROM mois.mois)::int AS annee,
       COUNT(accompagnements_filtres.date)::int AS count
FROM mois
  LEFT JOIN accompagnements_filtres ON DATE_TRUNC('month', accompagnements_filtres.date) = mois.mois
GROUP BY mois.mois
ORDER BY mois.mois
-- S6 par jour ; debut = $du::date (ou DATE_TRUNC('day', fin - INTERVAL '29 days'))
... jours AS (SELECT generate_series($debut, $fin, '1 day'::interval) AS jour)
SELECT TO_CHAR(jours.jour, 'DD/MM') AS label, COUNT(accompagnements_filtres.date)::int AS count
FROM jours LEFT JOIN accompagnements_filtres ON accompagnements_filtres.date = jours.jour
GROUP BY jours.jour ORDER BY jours.jour
```

Particularités : ici l'unité est la **ligne `coop.accompagnements`** (1 par bénéficiaire), pas `accompagnements_count` — cohérent avec S1 seulement si chaque activité a autant de lignes d'accompagnement que son `accompagnements_count`. Libellé mois `MM/AA` ; la page garde les **12 derniers** points (`slice(-12)`), le tableau de bord les 6 derniers. Quirk : la série mensuelle est engendrée par pas d'un mois à partir de la date exacte `du` puis tronquée au mois : si le jour de `au` est antérieur au jour de `du` (ex. du = 20/01, au = 10/03), le dernier mois n'est pas généré et ses accompagnements disparaissent du graphe.

**S10 — Tags spécifiques** (`recupererTags`, tags « organisationnels » #1811) [SQL] :

```sql
SELECT t.id::text AS id,
       t.nom AS label,
       COUNT(act.id)::int AS count
FROM coop.accompagnements acc
  INNER JOIN coop.activites act ON acc.activite_id = act.id
  INNER JOIN coop.activite_tags activite_tag ON activite_tag.activite_id = act.id
  INNER JOIN coop.tags t ON t.id = activite_tag.tag_id
  <jointures>
WHERE (t.equipe = true OR (t.mediateur_id IS NULL AND t.coordinateur_id IS NULL))
  AND t.suppression IS NULL
  AND <where>
GROUP BY t.id, t.nom
ORDER BY count DESC
```

Pondéré par ligne d'accompagnement ; proportions à 3 décimales sur la somme des tags ; affiché seulement en vue territorialisée, top 10 + « Voir tous les tags ».

**Totaux dérivés** (`recupererStatistiques`) : `totaux.activites = {individuels: nombre_individuels, collectifs: {total: nombre_collectifs, participants: participants_collectifs}, total: nombre_activites}` avec proportions `allouerPourcentages([nombre_individuels, nombre_collectifs])` ; `totaux.accompagnements = {individuels: nombre_individuels, collectifs: participants_collectifs, total: total_accompagnements}` avec proportions `allouerPourcentages([nombre_individuels, participants_collectifs])` ; `demarches = {0, 0}` (le type `demarche` n'existe pas dans l'enum `coop.type_activite` répliqué : individuel, collectif) ; `nouveaux` = `COUNT(*) FROM coop.accompagnements acc JOIN coop.activites act … WHERE acc.premier_accompagnement = true AND <where>` uniquement si `du` et `au` sont tous deux fournis (sinon 0) — non affiché.

`allouerPourcentages(valeurs)` : `total = Σ valeurs` ; chaque part = `round(100000 × v / total) / 1000` ; toutes à 0 si total = 0 (pas d'algorithme « largest remainder » malgré le nom dans la doc périmée).

---

## (c) Colonnes sensibles et agrégats de substitution

Périmètre `nao_ro` constaté (base locale, cohérent avec `nao_config.yaml`) : schéma `llm.*` (40 vues), `admin.*`, `reference.*`, `main.{contact_structure_administrative, contrat, formation, personne_affectations_emploi, personne_affectations_lieu, poste, subvention}`, `min.{action, beneficiaire_subvention, co_financement, comite, demande_de_subvention, departement, departement_enveloppe, enveloppe_financement, feuille_de_route, feuille_de_route_document, groupement, porteur_action, postes_conseiller_numerique_synthese, region}`. Aucun accès direct à `coop.*`, `main.personne`, `main.adresse`, `main.lieu_inclusion`, `main.structure_administrative`, `min.membre`, `min.gouvernance`, `min.personne_enrichie` (remplacés par les vues `llm.*`).

| Colonne / table utilisée par MIN | Indicateurs | Statut pour Nao | Substitut minimal |
|---|---|---|---|
| **`coop.beneficiaires.annee_naissance`** | S15 (tranches d'âge dérivées) | **Bloquant** : retirée de `llm.coop_beneficiaires` (V178 : commune + genre + année = ré-identifiable) | Ajouter à `llm.coop_beneficiaires` une colonne calculée `tranche_age_derivee` = expression `TRANCHE_AGE_DERIVEE` ci-dessus (pas l'année), ou exposer une vue d'agrégat `llm.coop_beneficiaires_tranche_age (beneficiaire_id, tranche_age_derivee)`. Sans cela, Nao ne peut utiliser que `tranche_age` stocké (écart sur les fiches où l'année est renseignée et plausible — c'est précisément le cas majoritaire visé par la Coop). |
| `coop.beneficiaires.id`, `anonyme`, `genre`, `statut_social`, `tranche_age` | S2–S4, S14, S16 | Exposés dans `llm.coop_beneficiaires` | — |
| `coop.users.is_conseiller_numerique` | filtre `conseillerNumerique` (API only) | Non exposé dans `llm.coop_users` ; **absent de la réplique `coop.users` locale** | Non requis par la page MIN. Si besoin : `llm.personne_enrichie.est_actuellement_conseiller_numerique` via `coop_id`. |
| `coop.tags.nom` (texte libre) | S10 | Exposé **masqué** (`llm.masquer_coordonnees`) dans `llm.coop_tags` | Reconstructible ; libellés contenant un courriel/téléphone apparaissent neutralisés. |
| `coop.activites.{type, date, duree, type_lieu, thematiques, materiel, accompagnements_count, structure_id, lieu_code_insee, structure_employeuse_main_id, mediateur_id, suppression}` | S1, S5–S13, B3, C3, C4 | Tous exposés dans `llm.coop_activites` (enums castés en `text` : remplacer `::coop.thematique[]` par `::text[]`) | — |
| `coop.accompagnements.*`, `coop.activite_tags.*` | S2–S6, S10 | `SELECT *` exposé | — |
| `coop.lieu_inclusion.code_insee` | filtres communes / départements | Exposé dans `llm.coop_lieu_inclusion` | — |
| `min.personne_enrichie.{prenom, nom, contact}` | aucun indicateur ne les lit | Retirées de `llm.personne_enrichie` | Sans objet : seuls `id`, flags `est_actuellement_*`, `is_coordinateur`, `labellisation_aidant_connect`, `type_accompagnateur`, `nb_accompagnements_ac`, `structure_employeuse_id` sont nécessaires, tous exposés. |
| `main.adresse.{departement, code_insee}` | A, C1, C2, C3-AC, D, F10–F14, G3 | `llm.adresse` | — |
| `main.structure_administrative.{id, adresse_id}` | C2, C3, D, F, G3 | `llm.structure_administrative` | — |
| `main.lieu_inclusion.{id, adresse_id, updated_at, deleted_at}` | A, B1, C1 | `llm.lieu_inclusion` | — |
| `min.membre.{gouvernance_departement_code, statut, is_coporteur, type, structure_id}` | E, F15, G, I | `llm.membre` (`nom` = nom de la structure membre, conservé) | — |
| `min.gouvernance.departement_code` | E1, E2, I1 | `llm.gouvernance` | — |
| `main.conum_labellisation` | H2 | **Table hors périmètre** (`utilisateur_id` = clé vers `min.utilisateur`) | Ajouter une vue `llm.conum_labellisation (id, structure_id, date_attestation)` ou l'ajouter à l'allowlist. |
| `min.{feuille_de_route, action, demande_de_subvention, beneficiaire_subvention, enveloppe_financement, departement_enveloppe, co_financement}` | E, F, G, I | Accès direct | — |
| `main.{poste, subvention}`, `min.postes_conseiller_numerique_synthese`, `main.personne_affectations_{emploi,lieu}` | B, F, G3, H1 | Accès direct | — |
| `admin.{ifn_commune, ifn_departement, icp_departement, commune, commune_epci, epci}` | A (EPCI), C5 | Accès direct | — |

Notes pour la reconstruction côté Nao :

1. Remplacer systématiquement `coop.<table>` par `llm.coop_<table>`, `main.adresse → llm.adresse`, `main.structure_administrative → llm.structure_administrative`, `main.lieu_inclusion → llm.lieu_inclusion`, `min.membre → llm.membre`, `min.gouvernance → llm.gouvernance`, `min.personne_enrichie → llm.personne_enrichie`. Les enums Coop deviennent `text` / `text[]`.
2. `llm.activites_coop` (sur `main.activites_coop`, V144) est un **autre** jeu de données (activités rapprochées de l'entrepôt, `beneficiaires` en jsonb, colonne `thematiques_demarche_administrative` séparée) : il ne reproduit pas la page MIN, qui lit `coop.activites` directement. Utiliser `llm.coop_activites` pour être iso-MIN.
3. Les blocs E/I et la liste `/gouvernances/list` ne partagent pas la même définition de « membre » (`statut <> 'supprime'` / tous / `= 'confirme'`) : préciser la règle attendue dans le prompt de Nao.
4. Les constantes à reporter : 105 gouvernances (I1), `DATE_DEBUT_DISPOSITIF = '2020-11-17'`, mois = 30,44 jours (A), seuils 12/18 mois, tranches de durée `[0,30,60,120]`, arrondi des proportions à 3 décimales.
