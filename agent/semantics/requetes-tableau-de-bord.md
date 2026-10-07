# Requêtes canoniques du tableau de bord MIN
> Fichier **généré** par `scripts/generer_catalogue_requetes.py` depuis `tests/*.yml` : ne pas éditer à la main.
> Pour chaque indicateur : la question telle qu'un utilisateur la pose, et **la requête à exécuter telle quelle** (périmètre national). Pour un département ou une région, ajouter uniquement le filtre territorial (voir `tableau-de-bord-min.md`, « Mailles et périmètre ») sans toucher au reste. Les valeurs `kind: table` renvoient un libellé et un nombre ; `scalar` un seul nombre.

## A — Points de vigilance des lieux

### `tdb_a_lieux_a_actualiser` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique non supprimés sont « à actualiser », c'est-à-dire dont la dernière mise à jour date de plus de 18 mois (548 jours) ou n'est pas renseignée ? Règle du tableau de bord MIN (un mois = 30,44 jours). La valeur évolue chaque jour, une tolérance de 1 % est admise.

```sql
SELECT count(*) AS n
FROM llm.lieu_inclusion l
WHERE l.deleted_at IS NULL
  AND (l.updated_at IS NULL OR l.updated_at <= now() - interval '548 days')
```

### `tdb_a_lieux_a_verifier` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique non supprimés sont « à vérifier », c'est-à-dire dont la dernière mise à jour date de 12 à 18 mois (entre 365 et 548 jours) ? Règle du tableau de bord MIN (un mois = 30,44 jours). La valeur évolue chaque jour, une tolérance de 1 % est admise.

```sql
SELECT count(*) AS n
FROM llm.lieu_inclusion l
WHERE l.deleted_at IS NULL
  AND l.updated_at > now() - interval '548 days'
  AND l.updated_at <= now() - interval '365 days'
```

## B — Données de la structure

### `tdb_b_accompagnements_6_mois_total` (scalar)

**Question** : Quel est le total cumulé des accompagnements déclarés dans la Coop sur les 6 derniers mois pleins, toutes structures confondues ? Les 6 derniers mois pleins = les 6 mois civils entièrement écoulés avant le mois en cours (le mois en cours est exclu). Seules les activités Coop non supprimées comptent. Un accompagnement = le nombre d'accompagnements porté par chaque activité (une activité collective compte pour autant d'accompagnements que de participants).

```sql
SELECT COALESCE(SUM(a.accompagnements_count), 0)::bigint AS n
FROM llm.coop_activites a
WHERE a.suppression IS NULL
  AND a.date >= date_trunc('month', CURRENT_DATE) - interval '6 months'
  AND a.date <  date_trunc('month', CURRENT_DATE)
```

### `tdb_b_lieux_avec_personne_affectee` (scalar)

**Question** : Combien de lieux d'inclusion numérique distincts ont au moins une affectation de personne encore active (affectation au lieu avec est_active vrai), sans aucune condition sur le statut de la personne (pas de filtre « en poste ») ? Compter tous les lieux, y compris ceux marqués supprimés (c'est la règle du bloc « Données structure » du tableau de bord MIN).

```sql
SELECT count(DISTINCT pal.lieu_id) AS n
FROM main.personne_affectations_lieu pal
WHERE pal.est_active = true
```

## C — État des lieux de l'inclusion numérique

### `tdb_c_accompagnements_realises_total` (scalar)

**Question** : Au niveau national, quel est le nombre total d'accompagnements réalisés, tous dispositifs confondus, selon la règle du bloc « État des lieux » du tableau de bord MIN : somme des accompagnements déclarés par les aidants numériques (Aidants Connect, personnes dont le type d'accompagnateur est « aidant numérique ») + somme des accompagnements de toutes les activités Coop non supprimées, toutes périodes confondues (sans filtre de date). Donne le nombre exact.

```sql
SELECT (SELECT COALESCE(SUM(pe.nb_accompagnements_ac), 0)
          FROM llm.personne_enrichie pe
         WHERE pe.type_accompagnateur = 'aidant_numerique')
     + (SELECT COALESCE(SUM(a.accompagnements_count), 0)
          FROM llm.coop_activites a
         WHERE a.suppression IS NULL) AS n
```

### `tdb_c_ifn_top10_departements` (table)

**Question** : Quels sont les 10 départements dont l'indice de fragilité numérique (IFN départemental, données Mednum) est le plus élevé ? Donne un tableau nom du département / score arrondi à 2 décimales, du plus fragile au moins fragile.

```sql
SELECT d.nom AS departement, round(i.score::numeric, 2) AS score
FROM admin.ifn_departement i
JOIN admin.departement d ON d.code = i.code
ORDER BY i.score DESC, d.nom
LIMIT 10
```

### `tdb_c_lieux_inclusion_avec_adresse` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique disposent d'une adresse rattachée ? Compter tous les lieux ayant une adresse, y compris les lieux archivés / supprimés (règle du bloc « État des lieux » du tableau de bord MIN) ; les lieux sans adresse sont exclus.

```sql
SELECT count(*) AS n
FROM llm.lieu_inclusion l
JOIN llm.adresse a ON a.id = l.adresse_id
```

### `tdb_c_mediateurs_et_aidants_en_poste` (scalar)

**Question** : Au niveau national, combien de personnes sont actuellement médiateur numérique en poste OU aidant numérique en poste (une personne qui est les deux compte une fois) ? C'est l'indicateur « Médiateurs et aidants numériques » du bloc « État des lieux » du tableau de bord MIN.

```sql
SELECT count(*) AS n
FROM llm.personne_enrichie
WHERE est_actuellement_aidant_numerique_en_poste = true
   OR est_actuellement_mediateur_en_poste = true
```

## D — Médiateurs et aidants

### `tdb_d_detail_mediateurs` (table)

**Question** : Parmi les médiateurs numériques actuellement en poste au niveau national, donne un tableau avec trois lignes : « Coordinateurs » (médiateurs en poste ayant le rôle de coordinateur), « Conseillers numériques » (médiateurs en poste qui sont actuellement conseiller numérique) et « Aidants Connect » (médiateurs en poste habilités Aidants Connect), avec le nombre pour chacun. Chaque ligne est filtrée sur les médiateurs actuellement en poste.

```sql
SELECT 'Coordinateurs' AS indicateur, count(*) AS n
  FROM llm.personne_enrichie
 WHERE est_actuellement_mediateur_en_poste = true AND is_coordinateur = true
UNION ALL
SELECT 'Conseillers numériques', count(*)
  FROM llm.personne_enrichie
 WHERE est_actuellement_mediateur_en_poste = true AND est_actuellement_conseiller_numerique = true
UNION ALL
SELECT 'Aidants Connect', count(*)
  FROM llm.personne_enrichie
 WHERE est_actuellement_mediateur_en_poste = true AND labellisation_aidant_connect = true
```

### `tdb_d_mediateurs_numeriques` (scalar)

**Question** : Au niveau national, combien de médiateurs numériques sont actuellement en poste ? (indicateur « Médiateurs numériques » du bloc « Médiateurs numériques et Aidants Connect » du tableau de bord MIN)

```sql
SELECT count(*) AS n
FROM llm.personne_enrichie
WHERE est_actuellement_mediateur_en_poste = true
```

## E — Gouvernances

### `tdb_e_actions` (scalar)

**Question** : Combien d'actions sont enregistrées dans les feuilles de route de MIN, toutes gouvernances confondues ?

```sql
SELECT count(*) AS n
FROM min.action a
JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
```

### `tdb_e_feuilles_de_route` (scalar)

**Question** : 

```sql
SELECT count(*) AS n FROM min.feuille_de_route
```

### `tdb_e_gouvernances` (scalar)

**Question** : Combien de gouvernances départementales existent dans MIN ?

```sql
SELECT count(*) AS n FROM llm.gouvernance
```

### `tdb_e_gouvernances_coportees` (scalar)

**Question** : Combien de gouvernances départementales sont co-portées, c'est-à-dire ont au moins 2 membres coporteurs non supprimés (membres candidats ou confirmés, hors statut « supprimé ») ?

```sql
SELECT count(*) AS n FROM (
  SELECT m.gouvernance_departement_code
  FROM llm.gouvernance g
  JOIN llm.membre m ON m.gouvernance_departement_code = g.departement_code
                   AND m.is_coporteur = true AND m.statut <> 'supprimer'
  GROUP BY 1 HAVING count(*) >= 2) t
```

### `tdb_e_membres_coporteurs` (scalar)

**Question** : Combien de membres de gouvernance non supprimés sont coporteurs, toutes gouvernances confondues ? Règle du tableau de bord : membres dont le statut n'est pas « supprimé » (candidats et confirmés inclus).

```sql
SELECT count(*) AS n
FROM llm.membre
WHERE statut <> 'supprimer' AND is_coporteur = true
```

### `tdb_e_membres_gouvernance` (scalar)

**Question** : Combien de membres de gouvernance non supprimés y a-t-il au total dans MIN (un membre = une organisation siégeant dans la gouvernance d'un département ; une même organisation présente dans plusieurs départements compte plusieurs fois) ? Règle du tableau de bord : tous les membres dont le statut n'est pas « supprimé » (candidats et confirmés inclus).

```sql
SELECT count(*) AS n
FROM llm.membre
WHERE statut <> 'supprimer'
```

## F — Financements

### `tdb_f_conum_enveloppes_consommation` (table)

**Question** : Pour chacune des enveloppes de financement « Conseiller Numérique » (libellé commençant par « Conseiller Numérique »), quelle est la consommation nationale en euros ? Règle du tableau de bord MIN : la consommation de l'enveloppe « Plan France Relance » = somme brute de toutes les subventions de première convention (V1) des postes ; celle de l'enveloppe « Renouvellement » = somme brute de toutes les subventions de renouvellement (V2). Tableau libellé complet de l'enveloppe / montant exact en euros.

```sql
WITH agg AS (
  SELECT COALESCE(SUM(s.montant_subvention_v1), 0)::bigint AS total_v1,
         COALESCE(SUM(s.montant_subvention_v2), 0)::bigint AS total_v2
  FROM main.subvention s)
SELECT e.libelle AS enveloppe,
       CASE WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2
            WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1
            ELSE 0 END AS consommation
FROM min.enveloppe_financement e CROSS JOIN agg
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

### `tdb_f_conum_verse_conventionne` (table)

**Question** : Au niveau national, selon la synthèse des postes Conseiller numérique, quel est le montant total conventionné et le montant total versé (cumulés) ? Donne un tableau à deux lignes : « conventionné » / montant exact en euros, « versé » / montant exact en euros.

```sql
SELECT 'conventionné' AS indicateur, COALESCE(SUM(v.montant_subvention_cumule), 0)::bigint AS montant
  FROM min.postes_conseiller_numerique_synthese v
UNION ALL
SELECT 'versé', COALESCE(SUM(v.montant_versement_cumule), 0)::bigint
  FROM min.postes_conseiller_numerique_synthese v
```

### `tdb_f_fne_engages_montant` (scalar)

**Question** : Quel est le montant total, en euros, des financements France Numérique Ensemble engagés par l'État, c'est-à-dire la somme des subventions demandées des demandes de subvention au statut « acceptée », rattachées à une action d'une feuille de route ? Donne le montant exact en euros, pas en millions.

```sql
WITH demandes AS (
    SELECT d.subvention_demandee, e.libelle AS enveloppe_libelle, e.montant AS enveloppe_montant
    FROM min.demande_de_subvention d
    JOIN min.action a ON a.id = d.action_id
    JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
    JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
    WHERE d.statut = 'acceptee')
SELECT COALESCE(SUM(subvention_demandee), 0)::bigint AS n FROM demandes
```

### `tdb_f_fne_engages_nombre` (scalar)

**Question** : Combien de financements ont été engagés par l'État au titre de France Numérique Ensemble, c'est-à-dire combien de demandes de subvention au statut « acceptée » rattachées à une action d'une feuille de route ?

```sql
WITH demandes AS (
    SELECT d.subvention_demandee, e.libelle AS enveloppe_libelle, e.montant AS enveloppe_montant
    FROM min.demande_de_subvention d
    JOIN min.action a ON a.id = d.action_id
    JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
    JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
    WHERE d.statut = 'acceptee')
SELECT count(*) AS n FROM demandes
```

### `tdb_f_fne_par_enveloppe` (table)

**Question** : Donne la ventilation par enveloppe de financement du montant des financements France Numérique Ensemble engagés par l'État : pour chaque enveloppe, la somme en euros des subventions demandées des demandes « acceptée » rattachées à une action d'une feuille de route. Tableau libellé complet de l'enveloppe / montant exact en euros.

```sql
WITH demandes AS (
  SELECT d.subvention_demandee, e.libelle AS enveloppe_libelle, e.montant AS enveloppe_montant
  FROM min.demande_de_subvention d
  JOIN min.action a ON a.id = d.action_id
  JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
  JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
  WHERE d.statut = 'acceptee')

SELECT enveloppe_libelle AS enveloppe, SUM(subvention_demandee)::bigint AS montant
FROM demandes GROUP BY 1 ORDER BY 1
```

## G — Bénéficiaires de financements

### `tdb_g_beneficiaires_conum_par_enveloppe` (table)

**Question** : Pour chacune des enveloppes « Conseiller Numérique » (libellé commençant par « Conseiller Numérique »), combien de structures distinctes en ont bénéficié au niveau national ? Règle du tableau de bord MIN : une structure bénéficie de l'enveloppe « Plan France Relance » si au moins un de ses postes a une subvention de première convention (V1) strictement positive, et de l'enveloppe « Renouvellement » si au moins un de ses postes a une subvention de renouvellement (V2) strictement positive. Tableau libellé complet de l'enveloppe / nombre de structures.

```sql
WITH agg AS (
  SELECT count(DISTINCT CASE WHEN s.montant_subvention_v1 > 0 THEN p.structure_id END) AS total_v1,
         count(DISTINCT CASE WHEN s.montant_subvention_v2 > 0 THEN p.structure_id END) AS total_v2
  FROM main.subvention s
  JOIN main.poste p ON p.id = s.poste_id)
SELECT e.libelle AS enveloppe,
       CASE WHEN e.libelle LIKE '%Renouvellement%' THEN agg.total_v2
            WHEN e.libelle LIKE '%Plan France Relance%' THEN agg.total_v1
            ELSE 0 END AS n
FROM min.enveloppe_financement e CROSS JOIN agg
WHERE e.libelle LIKE 'Conseiller Numérique%'
ORDER BY e.libelle
```

### `tdb_g_beneficiaires_fne_par_enveloppe` (table)

**Question** : Pour chaque enveloppe de financement France Numérique Ensemble, combien de membres de gouvernance distincts sont bénéficiaires d'une demande de subvention « acceptée » rattachée à une action d'une feuille de route ? Tableau libellé complet de l'enveloppe / nombre de bénéficiaires distincts.

```sql
SELECT e.libelle AS enveloppe, count(DISTINCT b.membre_id) AS n
FROM min.demande_de_subvention d
JOIN min.action a ON a.id = d.action_id
JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
JOIN min.enveloppe_financement e ON e.id = d.enveloppe_financement_id
JOIN min.beneficiaire_subvention b ON b.demande_de_subvention_id = d.id
WHERE d.statut = 'acceptee'
GROUP BY 1 ORDER BY 1
```

## H — Label Conseiller numérique

### `tdb_h_structures_eligibles_label_conum` (scalar)

**Question** : Combien de structures sont éligibles au label « conseiller numérique » au sens du tableau de bord MIN, c'est-à-dire ont au moins un poste Conseiller numérique dans leur historique (quel que soit l'état du poste : occupé, vacant ou rendu) ? Compter les structures distinctes.

```sql
SELECT count(DISTINCT p.structure_id) AS n FROM main.poste p WHERE p.structure_id IS NOT NULL
```

## I — Page admin des gouvernances

### `tdb_i_collectivites_par_categorie` (table)

**Question** : Sur la page d'administration des gouvernances de MIN, les « collectivités impliquées dans la gouvernance » sont les membres (tous statuts confondus, y compris supprimés,) dont le type est l'un des suivants : « Collectivité, commune », « Collectivité, EPCI », « Collectivité, intercommunalité », « Collectivité territoriale », « Commune », « Conseil départemental », « EPCI », « Préfecture départementale », « Préfecture régionale », « Région ». Donne leur ventilation en catégories : « Conseils départementaux » (type Conseil départemental), « Conseils régionaux » (type Région), « EPCI » (types EPCI, Collectivité, EPCI et Collectivité, intercommunalité), « Communes » (types Commune et Collectivité, commune), « Autres » (le reste, dont les préfectures). Tableau catégorie / nombre de membres.

```sql
SELECT CASE
         WHEN type = 'Conseil départemental' THEN 'Conseils départementaux'
         WHEN type = 'Région' THEN 'Conseils régionaux'
         WHEN type IN ('EPCI', 'Collectivité, EPCI', 'Collectivité, intercommunalité') THEN 'EPCI'
         WHEN type IN ('Commune', 'Collectivité, commune') THEN 'Communes'
         ELSE 'Autres' END AS categorie,
       count(*) AS n
FROM llm.membre
WHERE type IN ('Collectivité, commune', 'Collectivité, EPCI', 'Collectivité, intercommunalité', 'Collectivité territoriale', 'Commune', 'Conseil départemental', 'EPCI', 'Préfecture départementale', 'Préfecture régionale', 'Région')
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_i_feuilles_de_route_avec_demandes` (scalar)

**Question** : Combien de feuilles de route comportent au moins une action ayant au moins une demande de subvention, quel que soit le statut de la demande ?

```sql
SELECT count(*) AS n
FROM min.feuille_de_route f
WHERE EXISTS (SELECT 1 FROM min.action a
              JOIN min.demande_de_subvention d ON d.action_id = a.id
              WHERE a.feuille_de_route_id = f.id)
```

### `tdb_i_feuilles_de_route_par_perimetre` (table)

**Question** : Donne la répartition des feuilles de route par périmètre géographique, sous forme de tableau avec exactement ces libellés : « départemental », « infra-départemental » (périmètre « groupements de communes »), « régional », et « Autre » si le périmètre n'est pas renseigné. Une ligne par libellé avec le nombre de feuilles de route.

```sql
SELECT CASE perimetre_geographique
         WHEN 'departemental' THEN 'départemental'
         WHEN 'groupementsDeCommunes' THEN 'infra-départemental'
         WHEN 'regional' THEN 'régional'
         ELSE 'Autre' END AS perimetre,
       count(*) AS n
FROM min.feuille_de_route
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_i_gouvernances_sans_coporteur` (scalar)

**Question** : Sur la page d'administration des gouvernances de MIN, combien de gouvernances sont « sans coporteur », c'est-à-dire n'ont qu'un seul membre coporteur (en pratique la préfecture) ? Règle de cette page : tous les membres comptent, quel que soit leur statut (y compris supprimés).

```sql
SELECT count(*) AS n FROM (
  SELECT g.departement_code
  FROM llm.gouvernance g
  LEFT JOIN llm.membre m ON m.gouvernance_departement_code = g.departement_code AND m.is_coporteur = true
  GROUP BY 1 HAVING count(m.id) = 1) t
```

## S — Page Statistiques (médiation numérique)

### `tdb_s_accompagnements_par_mois` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne le nombre d'accompagnements par mois sur les 6 derniers mois pleins, sous forme de tableau mois (format AAAA-MM) / nombre. Les 6 derniers mois pleins = les 6 mois civils entièrement écoulés avant le mois en cours (le mois en cours est exclu). Seules les activités Coop non supprimées comptent. Unité de ce graphique : une ligne d'accompagnement par bénéficiaire (chaque participation à une activité compte un), et non le compteur d'accompagnements de l'activité.

```sql
SELECT to_char(date_trunc('month', act.date), 'YYYY-MM') AS mois, count(*) AS n
FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
WHERE act.suppression IS NULL
  AND act.date >= date_trunc('month', CURRENT_DATE) - interval '6 months'
  AND act.date <  date_trunc('month', CURRENT_DATE)
GROUP BY 1 ORDER BY 1
```

### `tdb_s_accompagnements_total` (scalar)

**Question** : Sur la page Statistiques de MIN au niveau national, quel est le nombre total d'accompagnements ? Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Un accompagnement = le nombre d'accompagnements porté par chaque activité (une activité collective compte pour autant d'accompagnements que de participants). La valeur évolue chaque jour, une tolérance de 1 % est admise.

```sql
SELECT COALESCE(SUM(act.accompagnements_count), 0)::bigint AS n
FROM llm.coop_activites act
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
```

### `tdb_s_beneficiaires_accompagnes` (scalar)

**Question** : Sur la page Statistiques de MIN au niveau national, combien de bénéficiaires distincts ont été accompagnés, c'est-à-dire combien de fiches bénéficiaire distinctes sont rattachées à au moins un accompagnement d'une activité Coop non supprimée ? Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Les fiches anonymes comptent (une fiche anonyme par accompagnement). La valeur évolue chaque jour, une tolérance de 1 % est admise.

```sql
SELECT count(DISTINCT ben.id) AS n 
FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
```

### `tdb_s_beneficiaires_suivis` (scalar)

**Question** : Sur la page Statistiques de MIN au niveau national, combien de bénéficiaires suivis (fiches bénéficiaire non anonymes) distincts sont rattachés à au moins un accompagnement d'une activité Coop non supprimée ? Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). La valeur évolue chaque jour, une tolérance de 1 % est admise.

```sql
SELECT count(DISTINCT ben.id) AS n 
FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE AND ben.anonyme = false
```

### `tdb_s_canaux` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par canal (type de lieu de l'activité) avec exactement ces libellés : « Lieu d'activité », « Autre lieu », « À domicile », « À distance ». Pour chaque canal, le nombre = somme du nombre d'accompagnements des activités de ce canal. Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT CASE act.type_lieu
         WHEN 'lieu_activite' THEN 'Lieu d''activité'
         WHEN 'autre' THEN 'Autre lieu'
         WHEN 'domicile' THEN 'À domicile'
         WHEN 'a_distance' THEN 'À distance' END AS canal,
       SUM(act.accompagnements_count)::bigint AS n
FROM llm.coop_activites act
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
  AND act.type_lieu IN ('lieu_activite', 'autre', 'domicile', 'a_distance')
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_durees` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par durée d'activité en quatre tranches avec exactement ces libellés : « Moins de 30 min » (durée < 30), « 30min à 1 h » (30 ≤ durée < 60), « 1 h à 2 h » (60 ≤ durée < 120), « 2 h et plus » (durée ≥ 120). Durée en minutes ; les activités sans durée renseignée n'entrent dans aucune tranche. Pour chaque tranche, le nombre = somme du nombre d'accompagnements des activités de la tranche. Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT CASE WHEN act.duree < 30 THEN 'Moins de 30 min'
            WHEN act.duree < 60 THEN '30min à 1 h'
            WHEN act.duree < 120 THEN '1 h à 2 h'
            ELSE '2 h et plus' END AS tranche,
       SUM(act.accompagnements_count)::bigint AS n
FROM llm.coop_activites act
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
  AND act.duree IS NOT NULL AND act.duree >= 0
GROUP BY 1 ORDER BY min(act.duree)
```

### `tdb_s_genres` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition par genre des bénéficiaires accompagnés : nombre de fiches bénéficiaire distinctes rattachées à au moins un accompagnement d'une activité Coop non supprimée, par valeur de genre enregistrée : masculin, feminin, non_communique (les fiches sans genre renseigné comptent dans non_communique). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Tableau identifiant de genre / nombre. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT COALESCE(ben.genre, 'non_communique') AS genre, count(DISTINCT ben.id) AS n

FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_statuts_sociaux` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition par statut social des bénéficiaires accompagnés : nombre de fiches bénéficiaire distinctes rattachées à au moins un accompagnement d'une activité Coop non supprimée, par statut enregistré : retraite, sans_emploi, en_emploi, scolarise, non_communique (les fiches sans statut comptent dans non_communique). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Tableau identifiant de statut / nombre. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT COALESCE(ben.statut_social, 'non_communique') AS statut, count(DISTINCT ben.id) AS n

FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_thematiques_demarches` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition des thématiques d'accompagnement aux démarches administratives. Pour chaque thématique, le nombre = somme du nombre d'accompagnements des activités portant cette thématique (une activité multi-thématiques compte dans chacune). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les thématiques de démarches administratives sont (identifiants enregistrés) : papiers_elections_citoyennete, famille_scolarite, social_sante, travail_formation, logement, transports_mobilite, argent_impots, justice, etrangers_europe, loisirs_sports_culture, associations. Tableau identifiant de thématique (tel qu'enregistré) / nombre, du plus fréquent au moins fréquent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT th AS thematique, SUM(act.accompagnements_count)::bigint AS n
FROM llm.coop_activites act, unnest(act.thematiques) AS th
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
  AND th IN ('papiers_elections_citoyennete','famille_scolarite','social_sante','travail_formation','logement','transports_mobilite','argent_impots','justice','etrangers_europe','loisirs_sports_culture','associations')
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_thematiques_mediation_top10` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, quelles sont les 10 thématiques de médiation numérique les plus fréquentes ? Pour chaque thématique, le nombre = somme du nombre d'accompagnements des activités portant cette thématique (une activité multi-thématiques compte dans chacune). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les thématiques de médiation numérique sont (identifiants enregistrés) : diagnostic_numerique, prendre_en_main_du_materiel, maintenance_de_materiel, gere_ses_contenus_numeriques, navigation_sur_internet, email, bureautique, reseaux_sociaux, sante, banque_et_achats_en_ligne, entrepreneuriat, insertion_professionnelle, securite_numerique, parentalite, scolarite_et_numerique, creer_avec_le_numerique, culture_numerique, intelligence_artificielle, aide_aux_demarches_administratives. Tableau identifiant de thématique (tel qu'enregistré) / nombre, du plus fréquent au moins fréquent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT th AS thematique, SUM(act.accompagnements_count)::bigint AS n
FROM llm.coop_activites act, unnest(act.thematiques) AS th
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
  AND th IN ('diagnostic_numerique','prendre_en_main_du_materiel','maintenance_de_materiel','gere_ses_contenus_numeriques','navigation_sur_internet','email','bureautique','reseaux_sociaux','sante','banque_et_achats_en_ligne','entrepreneuriat','insertion_professionnelle','securite_numerique','parentalite','scolarite_et_numerique','creer_avec_le_numerique','culture_numerique','intelligence_artificielle','aide_aux_demarches_administratives')
GROUP BY 1 ORDER BY 2 DESC LIMIT 10
```

### `tdb_s_tranches_age` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition par tranche d'âge des bénéficiaires accompagnés : nombre de fiches bénéficiaire distinctes rattachées à au moins un accompagnement d'une activité Coop non supprimée, par tranche d'âge dérivée (calculée depuis l'année de naissance quand elle est plausible, sinon la tranche déclarée), avec les identifiants enregistrés : moins_de_douze, douze_dix_huit, dix_huit_vingt_quatre, vingt_cinq_trente_neuf, quarante_cinquante_neuf, soixante_soixante_neuf, soixante_dix_plus, non_communique (les fiches sans tranche comptent dans non_communique). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Tableau identifiant de tranche / nombre. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT COALESCE(ben.tranche_age_derivee, 'non_communique') AS tranche_age, count(DISTINCT ben.id) AS n

FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_types_activites` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne un tableau à trois lignes : « accompagnements individuels » (nombre d'activités de type individuel), « participations aux ateliers collectifs » (somme du nombre d'accompagnements des activités de type collectif) et « ateliers collectifs » (nombre d'activités de type collectif). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

```sql
SELECT 'accompagnements individuels' AS indicateur, count(*) AS n
  FROM llm.coop_activites act WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE AND act.type = 'individuel'
UNION ALL
SELECT 'participations aux ateliers collectifs', COALESCE(SUM(act.accompagnements_count), 0)::bigint
  FROM llm.coop_activites act WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE AND act.type = 'collectif'
UNION ALL
SELECT 'ateliers collectifs', count(*)
  FROM llm.coop_activites act WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE AND act.type = 'collectif'
```
