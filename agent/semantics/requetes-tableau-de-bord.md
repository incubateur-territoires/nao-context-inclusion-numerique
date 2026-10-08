# Requêtes canoniques du tableau de bord MIN
> Fichier **généré** par `scripts/generer_catalogue_requetes.py` depuis `tests/*.yml` et `tests/variantes/` : ne pas éditer à la main.
> Pour chaque indicateur : la question telle qu'un utilisateur la pose, et **la requête à exécuter telle quelle** (périmètre national). Pour un département ou une région, ajouter uniquement le filtre territorial (voir `tableau-de-bord-min.md`, « Mailles et périmètre ») sans toucher au reste. Les valeurs `kind: table` renvoient un libellé et un nombre ; `scalar` un seul nombre.

## A — Points de vigilance des lieux

### `tdb_a_lieux_a_actualiser` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique non supprimés sont « à actualiser », c'est-à-dire dont la dernière mise à jour date de plus de 18 mois (548 jours) ou n'est pas renseignée ? Règle du tableau de bord MIN (un mois = 30,44 jours). La valeur évolue chaque jour, une tolérance de 1 % est admise.

**Autres formulations** :
- Combien de lieux sont à actualiser sur le tableau de bord ?
- Au niveau national, combien de lieux d'inclusion numérique sont « à actualiser » au sens du tableau de bord MIN ? Tolérance 1 %.
- Nombre de lieux d'inclusion numérique actifs dont la fiche n'a pas été modifiée depuis plus de 18 mois (ou jamais), en France entière. Un mois vaut 30,44 jours ; 1 % de tolérance.

```sql
SELECT count(*) AS n
FROM llm.lieu_inclusion l
WHERE l.deleted_at IS NULL
  AND (l.updated_at IS NULL OR l.updated_at <= now() - interval '548 days')
```

### `tdb_a_lieux_a_verifier` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique non supprimés sont « à vérifier », c'est-à-dire dont la dernière mise à jour date de 12 à 18 mois (entre 365 et 548 jours) ? Règle du tableau de bord MIN (un mois = 30,44 jours). La valeur évolue chaque jour, une tolérance de 1 % est admise.

**Autres formulations** :
- Combien de lieux à vérifier ?
- Au niveau national, combien de lieux d'inclusion numérique sont « à vérifier » au sens du tableau de bord MIN ? Tolérance 1 %.
- Nombre de lieux d'inclusion numérique actifs dont la fiche a entre 12 et 18 mois d'ancienneté de mise à jour (365 à 548 jours), France entière, tolérance 1 %.

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

**Autres formulations** :
- Total des accompagnements Coop sur les 6 derniers mois pleins ?
- Quel est le total des accompagnements déclarés dans la Coop sur les 6 derniers mois pleins, toutes structures confondues ?
- Sur les six mois civils complets qui précèdent le mois courant, combien d'accompagnements au total ont été enregistrés dans la Coop, toutes structures, en pondérant chaque activité par son nombre d'accompagnements ? Activités supprimées exclues.

```sql
SELECT COALESCE(SUM(a.accompagnements_count), 0)::bigint AS n
FROM llm.coop_activites a
WHERE a.suppression IS NULL
  AND a.date >= date_trunc('month', CURRENT_DATE) - interval '6 months'
  AND a.date <  date_trunc('month', CURRENT_DATE)
```

### `tdb_b_lieux_avec_personne_affectee` (scalar)

**Question** : Combien de lieux d'inclusion numérique distincts ont au moins une affectation de personne encore active (affectation au lieu avec est_active vrai), sans aucune condition sur le statut de la personne (pas de filtre « en poste ») ? Compter tous les lieux, y compris ceux marqués supprimés (c'est la règle du bloc « Données structure » du tableau de bord MIN).

**Autres formulations** :
- Combien de lieux ont au moins une personne affectée active ?
- Combien de lieux d'inclusion numérique distincts ont au moins une affectation de personne encore active ? Compter tous les lieux, y compris supprimés.
- Nombre de lieux d'inclusion distincts avec au moins un rattachement de personne en cours (affectation active), tous lieux compris même archivés, sans condition sur la personne.

```sql
SELECT count(DISTINCT pal.lieu_id) AS n
FROM main.personne_affectations_lieu pal
WHERE pal.est_active = true
```

## C — État des lieux de l'inclusion numérique

### `tdb_c_accompagnements_realises_total` (scalar)

**Question** : Au niveau national, quel est le nombre total d'accompagnements réalisés, tous dispositifs confondus, selon la règle du bloc « État des lieux » du tableau de bord MIN : somme des accompagnements déclarés par les aidants numériques (Aidants Connect, personnes dont le type d'accompagnateur est « aidant numérique ») + somme des accompagnements de toutes les activités Coop non supprimées, toutes périodes confondues (sans filtre de date). Donne le nombre exact.

**Autres formulations** :
- Combien d'accompagnements réalisés au total, Coop et Aidants Connect ?
- Au niveau national, quel est le nombre total d'accompagnements réalisés, tous dispositifs confondus, selon le bloc « État des lieux » du tableau de bord MIN ?
- Indicateur « accompagnements réalisés » du bloc État des lieux, national : accompagnements des aidants numériques (Aidants Connect) additionnés aux accompagnements de toutes les activités Coop non supprimées, sans borne de date. Chiffre exact.

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

**Autres formulations** :
- Top 10 des départements les plus fragiles numériquement ? Tableau département / score à 2 décimales.
- Quels sont les 10 départements dont l'indice de fragilité numérique est le plus élevé ? Tableau nom du département / score arrondi à 2 décimales, du plus fragile au moins fragile.
- Classement des dix départements au score de fragilité numérique (IFN) le plus fort, du plus fragile au moins fragile ; tableau nom du département / score arrondi à deux décimales.

```sql
SELECT d.nom AS departement, round(i.score::numeric, 2) AS score
FROM admin.ifn_departement i
JOIN admin.departement d ON d.code = i.code
ORDER BY i.score DESC, d.nom
LIMIT 10
```

### `tdb_c_lieux_inclusion_avec_adresse` (scalar)

**Question** : Au niveau national, combien de lieux d'inclusion numérique disposent d'une adresse rattachée ? Compter tous les lieux ayant une adresse, y compris les lieux archivés / supprimés (règle du bloc « État des lieux » du tableau de bord MIN) ; les lieux sans adresse sont exclus.

**Autres formulations** :
- Combien de lieux d'inclusion ont une adresse ?
- Au niveau national, combien de lieux d'inclusion numérique disposent d'une adresse rattachée ?
- Nombre de lieux d'inclusion numérique géolocalisables (rattachés à une adresse), en comptant aussi les lieux archivés, France entière.

```sql
SELECT count(*) AS n
FROM llm.lieu_inclusion l
JOIN llm.adresse a ON a.id = l.adresse_id
```

### `tdb_c_mediateurs_et_aidants_en_poste` (scalar)

**Question** : Au niveau national, combien de personnes sont actuellement médiateur numérique en poste OU aidant numérique en poste (une personne qui est les deux compte une fois) ? C'est l'indicateur « Médiateurs et aidants numériques » du bloc « État des lieux » du tableau de bord MIN.

**Autres formulations** :
- Combien de médiateurs et aidants numériques en poste ?
- Au niveau national, combien de personnes sont actuellement médiateur numérique ou aidant numérique en poste ? (indicateur « Médiateurs et aidants numériques » du tableau de bord MIN)
- Nombre de personnes actuellement en poste comme médiateur numérique ou comme aidant numérique, chaque personne comptée une seule fois, France entière.

```sql
SELECT count(*) AS n
FROM llm.personne_enrichie
WHERE est_actuellement_aidant_numerique_en_poste = true
   OR est_actuellement_mediateur_en_poste = true
```

## D — Médiateurs et aidants

### `tdb_d_detail_mediateurs` (table)

**Question** : Parmi les médiateurs numériques actuellement en poste au niveau national, donne un tableau avec trois lignes : « Coordinateurs » (médiateurs en poste ayant le rôle de coordinateur), « Conseillers numériques » (médiateurs en poste qui sont actuellement conseiller numérique) et « Aidants Connect » (médiateurs en poste habilités Aidants Connect), avec le nombre pour chacun. Chaque ligne est filtrée sur les médiateurs actuellement en poste.

**Autres formulations** :
- Parmi les médiateurs en poste : combien de coordinateurs, de conseillers numériques et d'Aidants Connect ? Tableau à trois lignes.
- Parmi les médiateurs numériques actuellement en poste, donne un tableau avec trois lignes « Coordinateurs », « Conseillers numériques », « Aidants Connect » et le nombre pour chacun.
- Détail des médiateurs numériques actuellement en activité : tableau « Coordinateurs » / « Conseillers numériques » / « Aidants Connect » avec les effectifs, chaque ligne restreinte aux médiateurs en poste.

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

**Autres formulations** :
- Combien de médiateurs numériques en poste ?
- Au niveau national, combien de médiateurs numériques sont actuellement en poste ?
- Effectif national des médiateurs numériques actuellement en activité, tel qu'affiché dans le bloc médiateurs du tableau de bord.

```sql
SELECT count(*) AS n
FROM llm.personne_enrichie
WHERE est_actuellement_mediateur_en_poste = true
```

## E — Gouvernances

### `tdb_e_actions` (scalar)

**Question** : Combien d'actions sont enregistrées dans les feuilles de route de MIN, toutes gouvernances confondues ?

**Autres formulations** :
- Combien d'actions dans les feuilles de route ?
- Combien d'actions sont enregistrées dans les feuilles de route ?
- Nombre total d'actions saisies dans l'ensemble des feuilles de route de MIN.

```sql
SELECT count(*) AS n
FROM min.action a
JOIN min.feuille_de_route f ON f.id = a.feuille_de_route_id
```

### `tdb_e_feuilles_de_route` (scalar)

**Question** : Combien de feuilles de route ont été déposées dans MIN, toutes gouvernances confondues ? Toute feuille de route existante compte.

**Autres formulations** :
- Combien de feuilles de route ?
- Combien de feuilles de route ont été déposées dans MIN ?
- Nombre de feuilles de route présentes dans MIN, toutes gouvernances départementales confondues.

```sql
SELECT count(*) AS n FROM min.feuille_de_route
```

### `tdb_e_gouvernances` (scalar)

**Question** : Combien de gouvernances départementales existent dans MIN ?

**Autres formulations** :
- Il y a combien de gouvernances ?
- Combien de gouvernances existent ?
- Nombre de gouvernances départementales de l'inclusion numérique dans MIN.

```sql
SELECT count(*) AS n FROM llm.gouvernance
```

### `tdb_e_gouvernances_coportees` (scalar)

**Question** : Combien de gouvernances départementales sont co-portées, c'est-à-dire ont au moins 2 membres coporteurs non supprimés (membres candidats ou confirmés, hors statut « supprimé ») ?

**Autres formulations** :
- Combien de gouvernances co-portées ?
- Combien de gouvernances départementales sont co-portées ?
- Nombre de gouvernances départementales ayant au moins deux coporteurs non supprimés (candidats ou confirmés).

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

**Autres formulations** :
- Combien de membres coporteurs ?
- Combien de membres de gouvernance sont coporteurs, toutes gouvernances confondues ?
- Nombre de membres de gouvernance actifs (candidats ou confirmés, non supprimés) qui sont coporteurs, toutes gouvernances.

```sql
SELECT count(*) AS n
FROM llm.membre
WHERE statut <> 'supprimer' AND is_coporteur = true
```

### `tdb_e_membres_gouvernance` (scalar)

**Question** : Combien de membres de gouvernance non supprimés y a-t-il au total dans MIN (un membre = une organisation siégeant dans la gouvernance d'un département ; une même organisation présente dans plusieurs départements compte plusieurs fois) ? Règle du tableau de bord : tous les membres dont le statut n'est pas « supprimé » (candidats et confirmés inclus).

**Autres formulations** :
- Combien de membres de gouvernance au total ?
- Combien de membres de gouvernance non supprimés y a-t-il au total dans MIN ?
- Nombre total d'organisations membres des gouvernances départementales dans MIN, non supprimées (candidates ou confirmées), une organisation siégeant dans plusieurs départements étant comptée à chaque fois.

```sql
SELECT count(*) AS n
FROM llm.membre
WHERE statut <> 'supprimer'
```

## F — Financements

### `tdb_f_conum_enveloppes_consommation` (table)

**Question** : Pour chacune des enveloppes de financement « Conseiller Numérique » (libellé commençant par « Conseiller Numérique »), quelle est la consommation nationale en euros ? Règle du tableau de bord MIN : la consommation de l'enveloppe « Plan France Relance » = somme brute de toutes les subventions de première convention (V1) des postes ; celle de l'enveloppe « Renouvellement » = somme brute de toutes les subventions de renouvellement (V2). Tableau libellé complet de l'enveloppe / montant exact en euros.

**Autres formulations** :
- Consommation des enveloppes Conseiller Numérique ? Tableau enveloppe / montant.
- Pour chacune des enveloppes de financement « Conseiller Numérique », quelle est la consommation nationale en euros ? Tableau libellé complet de l'enveloppe / montant exact en euros.
- Pour les enveloppes dont le nom commence par « Conseiller Numérique », montant national consommé : enveloppe Plan France Relance = total brut des subventions V1 des postes, enveloppe Renouvellement = total brut des subventions V2. Tableau libellé de l'enveloppe / euros.

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

**Autres formulations** :
- Montants conventionné et versé pour les postes Conseiller numérique ? Tableau « conventionné » / « versé ».
- Au niveau national, quel est le montant total conventionné et le montant total versé pour les postes Conseiller numérique ? Tableau à deux lignes : « conventionné » / montant, « versé » / montant, en euros.
- D'après la synthèse des postes Conseiller numérique, total national des subventions cumulées (conventionné) et des versements cumulés (versé) : tableau à deux lignes « conventionné » et « versé », montants en euros.

```sql
SELECT 'conventionné' AS indicateur, COALESCE(SUM(v.montant_subvention_cumule), 0)::bigint AS montant
  FROM min.postes_conseiller_numerique_synthese v
UNION ALL
SELECT 'versé', COALESCE(SUM(v.montant_versement_cumule), 0)::bigint
  FROM min.postes_conseiller_numerique_synthese v
```

### `tdb_f_fne_engages_montant` (scalar)

**Question** : Quel est le montant total, en euros, des financements France Numérique Ensemble engagés par l'État, c'est-à-dire la somme des subventions demandées des demandes de subvention au statut « acceptée », rattachées à une action d'une feuille de route ? Donne le montant exact en euros, pas en millions.

**Autres formulations** :
- Montant des financements FNE engagés par l'État, en euros ?
- Quel est le montant total, en euros, des financements France Numérique Ensemble engagés par l'État ? Montant exact, pas en millions.
- Somme en euros des subventions demandées dont la demande est au statut acceptée et qui dépendent d'une action de feuille de route : c'est le montant France Numérique Ensemble engagé par l'État. Montant exact.

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

**Autres formulations** :
- Combien de financements FNE engagés par l'État ?
- Combien de financements ont été engagés par l'État au titre de France Numérique Ensemble ?
- Nombre de demandes de subvention acceptées rattachées à une action de feuille de route (financements engagés par l'État au titre de France Numérique Ensemble).

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

**Question** : Donne la ventilation par enveloppe de financement du montant des financements France Numérique Ensemble engagés par l'État : pour chaque enveloppe, la somme en euros des subventions demandées des demandes « acceptée » rattachées à une action d'une feuille de route. Règle du tableau de bord MIN : toute enveloppe compte, quel que soit son libellé, dès lors qu'elle n'est pas une enveloppe « Conseiller Numérique » (ne pas filtrer sur les mots « France Numérique Ensemble »). Tableau libellé complet de l'enveloppe / montant exact en euros.

**Autres formulations** :
- Financements FNE engagés par enveloppe ? Tableau enveloppe / montant en euros.
- Donne la ventilation par enveloppe de financement du montant des financements France Numérique Ensemble engagés par l'État. Tableau libellé complet de l'enveloppe / montant exact en euros.
- Ventilation par enveloppe des subventions demandées acceptées (rattachées à une action de feuille de route), toutes enveloppes sauf celles « Conseiller Numérique », quel que soit leur nom. Tableau libellé complet / montant exact en euros.

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

**Autres formulations** :
- Combien de structures bénéficiaires par enveloppe Conseiller Numérique ? Tableau enveloppe / nombre.
- Pour chacune des enveloppes « Conseiller Numérique », combien de structures distinctes en ont bénéficié au niveau national ? Tableau libellé complet de l'enveloppe / nombre de structures.
- Pour chaque enveloppe « Conseiller Numérique », nombre de structures distinctes ayant au moins un poste avec une subvention strictement positive : V1 pour Plan France Relance, V2 pour Renouvellement. Tableau libellé complet / nombre de structures.

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

**Autres formulations** :
- Combien de membres bénéficiaires par enveloppe FNE ? Tableau enveloppe / nombre.
- Pour chaque enveloppe de financement France Numérique Ensemble, combien de membres de gouvernance distincts en sont bénéficiaires ? Tableau libellé complet de l'enveloppe / nombre de bénéficiaires distincts.
- Par enveloppe France Numérique Ensemble, nombre de membres de gouvernance distincts désignés bénéficiaires d'une demande de subvention acceptée liée à une action de feuille de route. Tableau libellé complet / nombre.

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

**Autres formulations** :
- Combien de structures éligibles au label conseiller numérique ?
- Combien de structures sont éligibles au label « conseiller numérique » au sens du tableau de bord MIN ?
- Nombre de structures distinctes ayant eu au moins un poste Conseiller numérique, peu importe l'état du poste (occupé, vacant, rendu) : éligibilité au label au sens du tableau de bord.

```sql
SELECT count(DISTINCT p.structure_id) AS n FROM main.poste p WHERE p.structure_id IS NOT NULL
```

## I — Page admin des gouvernances

### `tdb_i_collectivites_par_categorie` (table)

**Question** : Sur la page d'administration des gouvernances de MIN, les « collectivités impliquées dans la gouvernance » sont les membres (tous statuts confondus, y compris supprimés,) dont le type est l'un des suivants : « Collectivité, commune », « Collectivité, EPCI », « Collectivité, intercommunalité », « Collectivité territoriale », « Commune », « Conseil départemental », « EPCI », « Préfecture départementale », « Préfecture régionale », « Région ». Donne leur ventilation en catégories : « Conseils départementaux » (type Conseil départemental), « Conseils régionaux » (type Région), « EPCI » (types EPCI, Collectivité, EPCI et Collectivité, intercommunalité), « Communes » (types Commune et Collectivité, commune), « Autres » (le reste, dont les préfectures). Tableau catégorie / nombre de membres.

**Autres formulations** :
- Répartition des collectivités impliquées dans les gouvernances par catégorie (page admin) ? Tableau catégorie / nombre : Conseils départementaux, Conseils régionaux, EPCI, Communes, Autres.
- Sur la page d'administration des gouvernances de MIN, donne la ventilation des « collectivités impliquées dans la gouvernance » par catégorie : « Conseils départementaux », « Conseils régionaux », « EPCI », « Communes », « Autres ». Tableau catégorie / nombre de membres.
- Page d'administration des gouvernances : nombre de membres collectivités, tous statuts y compris supprimés, selon les types retenus par la page (communes, EPCI et intercommunalités, collectivités territoriales, conseils départementaux, régions, préfectures). Tableau avec les catégories Conseils départementaux / Conseils régionaux / EPCI / Communes / Autres.

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

**Autres formulations** :
- Combien de feuilles de route ont au moins une demande de subvention ?
- Combien de feuilles de route comportent au moins une demande de subvention ?
- Nombre de feuilles de route dont une action au moins porte une demande de subvention, peu importe l'état de la demande.

```sql
SELECT count(*) AS n
FROM min.feuille_de_route f
WHERE EXISTS (SELECT 1 FROM min.action a
              JOIN min.demande_de_subvention d ON d.action_id = a.id
              WHERE a.feuille_de_route_id = f.id)
```

### `tdb_i_feuilles_de_route_par_perimetre` (table)

**Question** : Donne la répartition des feuilles de route par périmètre géographique, sous forme de tableau avec exactement ces libellés : « départemental », « infra-départemental » (périmètre « groupements de communes »), « régional », et « Autre » si le périmètre n'est pas renseigné. Une ligne par libellé avec le nombre de feuilles de route.

**Autres formulations** :
- Feuilles de route par périmètre géographique ? Tableau départemental / infra-départemental / régional / Autre.
- Donne la répartition des feuilles de route par périmètre géographique, tableau avec exactement ces libellés : « départemental », « infra-départemental », « régional », « Autre ».
- Répartition des feuilles de route selon leur échelle territoriale : « départemental », « infra-départemental » (groupements de communes), « régional », « Autre » quand le périmètre est vide. Une ligne par libellé avec le compte.

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

**Autres formulations** :
- Combien de gouvernances sans coporteur (page admin) ?
- Sur la page d'administration des gouvernances de MIN, combien de gouvernances sont « sans coporteur » ?
- Sur la page d'administration des gouvernances, nombre de gouvernances dont le seul coporteur est la préfecture (un unique membre coporteur), tous membres comptés quel que soit leur statut, supprimés inclus.

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

**Autres formulations** :
- Accompagnements par mois sur les 6 derniers mois pleins ? Tableau AAAA-MM / nombre.
- Sur la page Statistiques de MIN au niveau national, donne le nombre d'accompagnements par mois sur les 6 derniers mois pleins, tableau mois (AAAA-MM) / nombre.
- Page Statistiques, national : pour chacun des six mois civils complets précédant le mois en cours, nombre de participations de bénéficiaires à des activités Coop non supprimées (une ligne d'accompagnement par bénéficiaire). Tableau mois au format AAAA-MM / nombre.

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

**Autres formulations** :
- Nombre total d'accompagnements sur la page Statistiques ?
- Sur la page Statistiques de MIN au niveau national, quel est le nombre total d'accompagnements ? Tolérance 1 %.
- Page Statistiques, France entière : total des accompagnements depuis le début du dispositif (17/11/2020) jusqu'à aujourd'hui, activités Coop non supprimées, chaque activité pesant son nombre d'accompagnements. Tolérance 1 %.

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

**Autres formulations** :
- Combien de bénéficiaires suivis sur la page Statistiques ?
- Sur la page Statistiques de MIN au niveau national, combien de bénéficiaires suivis distincts y a-t-il ? Tolérance 1 %.
- Page Statistiques, national : nombre de bénéficiaires identifiés (fiches non anonymes) distincts ayant au moins un accompagnement dans une activité Coop non supprimée entre le 17/11/2020 et aujourd'hui. Tolérance 1 %.

```sql
SELECT count(DISTINCT ben.id) AS n 
FROM llm.coop_activites act
JOIN llm.coop_accompagnements acc ON acc.activite_id = act.id
JOIN llm.coop_beneficiaires ben ON ben.id = acc.beneficiaire_id
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE AND ben.anonyme = false
```

### `tdb_s_canaux` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par canal (type de lieu de l'activité) avec exactement ces libellés : « Lieu d'activité », « Autre lieu », « À domicile », « À distance ». Pour chaque canal, le nombre = somme du nombre d'accompagnements des activités de ce canal. Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

**Autres formulations** :
- Répartition des accompagnements par canal (page Statistiques) ? Tableau avec « Lieu d'activité », « Autre lieu », « À domicile », « À distance ».
- Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par canal, tableau avec exactement ces libellés : « Lieu d'activité », « Autre lieu », « À domicile », « À distance ». Tolérance 1 %.
- Page Statistiques, national : accompagnements selon le type de lieu de l'activité, libellés « Lieu d'activité », « Autre lieu », « À domicile », « À distance », chaque canal totalisant le nombre d'accompagnements de ses activités, depuis le 17/11/2020, activités non supprimées. Tolérance 1 %.

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

**Autres formulations** :
- Répartition des accompagnements par durée (page Statistiques) ? Tableau « Moins de 30 min », « 30min à 1 h », « 1 h à 2 h », « 2 h et plus ».
- Sur la page Statistiques de MIN au niveau national, donne la répartition des accompagnements par durée d'activité, tableau avec exactement ces libellés : « Moins de 30 min », « 30min à 1 h », « 1 h à 2 h », « 2 h et plus ». Tolérance 1 %.
- Page Statistiques, national : accompagnements par tranche de durée d'activité en minutes, bornes [0,30[ « Moins de 30 min », [30,60[ « 30min à 1 h », [60,120[ « 1 h à 2 h », 120 et plus « 2 h et plus » ; durée absente ignorée ; chaque tranche totalise le nombre d'accompagnements des activités ; depuis le 17/11/2020, non supprimées. Tolérance 1 %.

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

**Autres formulations** :
- Répartition des accompagnements par thématique de démarche administrative (page Statistiques) ? Tableau identifiant de thématique / nombre, du plus fréquent au moins fréquent.
- Sur la page Statistiques de MIN au niveau national, donne la répartition des thématiques d'accompagnement aux démarches administratives. Tableau identifiant de thématique (tel qu'enregistré : papiers_elections_citoyennete, famille_scolarite, social_sante, travail_formation, logement, transports_mobilite, argent_impots, justice, etrangers_europe, loisirs_sports_culture, associations) / nombre, du plus fréquent au moins fréquent. Tolérance 1 %.
- Page Statistiques, national : pour chaque thématique de démarches administratives (identifiants enregistrés : papiers_elections_citoyennete, famille_scolarite, social_sante, travail_formation, logement, transports_mobilite, argent_impots, justice, etrangers_europe, loisirs_sports_culture, associations), somme des accompagnements des activités concernées, multi-thématiques comptées dans chacune, depuis le 17/11/2020, non supprimées. Tableau identifiant / nombre décroissant. Tolérance 1 %.

```sql
SELECT th AS thematique, SUM(act.accompagnements_count)::bigint AS n
FROM llm.coop_activites act, unnest(act.thematiques) AS th
WHERE act.suppression IS NULL AND act.date::date >= DATE '2020-11-17' AND act.date::date <= CURRENT_DATE
  AND th IN ('papiers_elections_citoyennete','famille_scolarite','social_sante','travail_formation','logement','transports_mobilite','argent_impots','justice','etrangers_europe','loisirs_sports_culture','associations')
GROUP BY 1 ORDER BY 2 DESC
```

### `tdb_s_thematiques_mediation_top10` (table)

**Question** : Sur la page Statistiques de MIN au niveau national, quelles sont les 10 thématiques de médiation numérique les plus fréquentes ? Pour chaque thématique, le nombre = somme du nombre d'accompagnements des activités portant cette thématique (une activité multi-thématiques compte dans chacune). Période de référence de la page Statistiques : du 17/11/2020 (début du dispositif) à aujourd'hui inclus (date de l'activité). Seules les activités Coop non supprimées comptent. Les thématiques de médiation numérique sont (identifiants enregistrés) : diagnostic_numerique, prendre_en_main_du_materiel, maintenance_de_materiel, gere_ses_contenus_numeriques, navigation_sur_internet, email, bureautique, reseaux_sociaux, sante, banque_et_achats_en_ligne, entrepreneuriat, insertion_professionnelle, securite_numerique, parentalite, scolarite_et_numerique, creer_avec_le_numerique, culture_numerique, intelligence_artificielle, aide_aux_demarches_administratives. Tableau identifiant de thématique (tel qu'enregistré) / nombre, du plus fréquent au moins fréquent. Les valeurs évoluent chaque jour, une tolérance de 1 % est admise.

**Autres formulations** :
- Top 10 des thématiques de médiation numérique (page Statistiques) ? Tableau identifiant de thématique / nombre.
- Sur la page Statistiques de MIN au niveau national, quelles sont les 10 thématiques de médiation numérique les plus fréquentes ? Tableau identifiant de thématique tel qu'enregistré / nombre, du plus fréquent au moins fréquent. Tolérance 1 %.
- Page Statistiques, national : les dix thématiques de médiation numérique les plus fréquentes, chaque thématique totalisant les accompagnements des activités qui la portent (multi-thématiques comptées dans chacune), depuis le 17/11/2020, activités non supprimées. Tableau identifiant enregistré (diagnostic_numerique, prendre_en_main_du_materiel, maintenance_de_materiel, gere_ses_contenus_numeriques, navigation_sur_internet, email, bureautique, reseaux_sociaux, sante, banque_et_achats_en_ligne, entrepreneuriat, insertion_professionnelle, securite_numerique, parentalite, scolarite_et_numerique, creer_avec_le_numerique, culture_numerique, intelligence_artificielle, aide_aux_demarches_administratives) / nombre décroissant. Tolérance 1 %.

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
