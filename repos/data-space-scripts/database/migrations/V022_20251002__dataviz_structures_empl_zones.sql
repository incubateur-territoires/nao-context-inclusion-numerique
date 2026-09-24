DROP VIEW dataviz.structures_employeuses;

CREATE VIEW dataviz.structures_employeuses AS (
WITH coordinateurs AS (
    SELECT
        e.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE is_coordinateur IS TRUE AND suppression IS NULL
    GROUP BY e.structure_id
),

conseillers AS (
    SELECT
        e.structure_id,
        count(*) AS nbr
    FROM main.personne
    INNER JOIN main.personne_affectations AS e ON personne.id = e.personne_id AND type = 'structure_emploi'
    WHERE (conseiller_numerique_id IS NOT NULL OR cn_pg_id IS NOT NULL) AND suppression IS NULL
    GROUP BY e.structure_id
),

aidants_connect AS (
    SELECT
        e.structure_id,
        COUNT(*) AS nbr_rattach,
        SUM(COALESCE(CASE WHEN s.structure_ac_id IS NOT NULL THEN p.nb_accompagnements_ac ELSE 0 END, 0)) AS nbr_accompagnements
    FROM main.personne AS p
    INNER JOIN main.personne_affectations AS e
        ON p.id = e.personne_id
       AND e.type = 'structure_emploi'
       AND e.suppression IS NULL
    LEFT JOIN main.structure s ON e.structure_id = s.id
    WHERE (p.is_active_ac IS TRUE OR p.aidant_connect_id IS NOT NULL)
    GROUP BY e.structure_id
),

coop AS (
    SELECT
        structure_id,
        count(*) AS nbr
    FROM main.activites_coop
    INNER JOIN main.structure ON activites_coop.structure_id = structure.id AND structure.structure_coop_id IS NOT NULL
    GROUP BY structure_id
)

SELECT
    structure.id AS structure_id,
    structure.nom AS nom,
    structure.siret,
    structure.rna,
    structure.code_activite_principale AS code_naf,
    categories_juridiques.nom AS "catégorie_juridique_de_la_structure",
    structure.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie)::text AS adresse,
    CASE WHEN zonage.type = 'QPV' THEN zonage.libelle ELSE 'Non' END AS qpv,
    CASE WHEN zonage.type = 'FRR' THEN 'Oui' ELSE 'Non' END AS frr,
    CASE WHEN COALESCE(conseillers.nbr, 0) > 0 THEN 'Oui' ELSE 'Non' END AS est_conum,
    CASE WHEN COALESCE(aidants_connect.nbr_rattach, 0) > 0 THEN 'Oui' ELSE 'Non' END AS est_aidant_connect,
    CASE WHEN 'France Services' = ANY(structure.dispositif_programmes_nationaux) THEN 'Oui' ELSE 'Non' END AS est_france_services,
    mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    aidants_connect.nbr_rattach AS nombre_aidants_connect,
    coordinateurs.nbr AS nombre_de_coordinateurs,
    nb_mandats_ac::integer AS mandats_aidants_connect,
    aidants_connect.nbr_accompagnements AS accompagnements_aidants_connect,
    coop.nbr AS "nombre_accompagnements_médiateurs_numériques",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
FROM main.structure
LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
LEFT JOIN admin.coll_terr ON adresse.code_insee = coll_terr.code_insee
LEFT JOIN admin.zonage ON (type = 'FRR' AND adresse.code_insee = zonage.code_insee) OR (type = 'QPV' AND st_contains(zonage.geom, adresse.geom))
LEFT JOIN reference.categories_juridiques ON structure.categorie_juridique = categories_juridiques.code
LEFT JOIN coordinateurs ON structure.id = coordinateurs.structure_id
LEFT JOIN conseillers ON structure.id = conseillers.structure_id
LEFT JOIN aidants_connect ON structure.id = aidants_connect.structure_id
LEFT JOIN coop ON structure.id = coop.structure_id
);



COMMENT ON COLUMN dataviz.structures_employeuses.nom IS 'Nom de la structure';
COMMENT ON COLUMN dataviz.structures_employeuses.siret IS 'Code SIRET de la structure. https://annuaire-entreprises.data.gouv.fr/';
COMMENT ON COLUMN dataviz.structures_employeuses.rna IS 'Identifiant du Répertoire National des Associations (RNA)';
COMMENT ON COLUMN dataviz.structures_employeuses.code_naf IS 'Code NAF de l''activité principale (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."état_administratif_de_la_structure" IS 'Etat administratif de l''entreprise et de l''établissement (Base SIRENE INSEE)';
COMMENT ON COLUMN dataviz.structures_employeuses."catégorie_juridique_de_la_structure" IS 'Catégorie juridique de l''INSEE';
COMMENT ON COLUMN dataviz.structures_employeuses.est_conum IS 'Oui si au moins un Conseiller numérique est rattaché à la structure (conseillers.nbr > 0), sinon Non.';
COMMENT ON COLUMN dataviz.structures_employeuses.est_aidant_connect IS 'Oui si au moins un Aidant Connect est rattaché à la structure (affectations actives type ''structure_emploi'' ; aidants_connect.nbr_rattach > 0), sinon';
COMMENT ON COLUMN dataviz.structures_employeuses.est_france_services IS 'Oui si la structure est labellisée France Services, sinon';
COMMENT ON COLUMN dataviz.structures_employeuses.nombre_aidants_connect IS 'Nombre de personnes Aidants Connect rattachées à la structure (affectations actives type ''structure_emploi'').';
COMMENT ON COLUMN dataviz.structures_employeuses.accompagnements_aidants_connect IS 'Somme des accompagnements réalisés par les Aidants Connect de la structure (nb_accompagnements_ac).';


DROP VIEW dataviz.personnes_accompagnements;

CREATE VIEW dataviz.personnes_accompagnements AS (
   WITH src AS (
      SELECT
        p.id AS personne_id,
        p.nom,
        p.prenom,
        CASE
          WHEN p.cn_pg_id IS NOT NULL THEN 'CoNum'
          WHEN p.cn_pg_id IS NULL AND p.aidant_connect_id IS NULL THEN 'Médiateur'
        END AS role,
        a.periode,          -- colonne STORED indexée
        a.type,
        a.autonomie,
        a.type_lieu,
        a.thematiques,
        a.materiels
      FROM main.activites_coop a
      JOIN main.personne p ON p.id = a.personne_id
    ),
    base AS (  -- volume mensuel par personne
      SELECT personne_id, nom, prenom, periode, role, COUNT(*) AS nb_accompagnements
      FROM src
      GROUP BY personne_id, nom, prenom, periode, role
    ),
    counts AS (  -- table “longue” agrégée une fois
      -- TYPE
      SELECT personne_id, periode, 'type' AS dim, type AS key, COUNT(*) AS n
      FROM src
      WHERE type IS NOT NULL
      GROUP BY personne_id, periode, type

      UNION ALL
      -- AUTONOMIE
      SELECT personne_id, periode, 'autonomie', autonomie, COUNT(*)
      FROM src
      WHERE autonomie IS NOT NULL
      GROUP BY personne_id, periode, autonomie

      UNION ALL
      -- TYPE_LIEU
      SELECT personne_id, periode, 'type_lieu', type_lieu, COUNT(*)
      FROM src
      WHERE type_lieu IS NOT NULL
      GROUP BY personne_id, periode, type_lieu

      UNION ALL
      -- THEMATIQUES
      SELECT s.personne_id, s.periode, 'thematique', t, COUNT(*)
      FROM src s
      LEFT JOIN LATERAL unnest(COALESCE(s.thematiques, ARRAY[]::text[])) AS t ON true
      WHERE t IS NOT NULL
      GROUP BY s.personne_id, s.periode, t

      UNION ALL
      -- MATERIELS
      SELECT s.personne_id, s.periode, 'materiel', m::text, COUNT(*)::bigint
      FROM src s
      LEFT JOIN LATERAL unnest(COALESCE(s.materiels, ARRAY[]::text[])) AS m ON true
      WHERE m IS NOT NULL
      GROUP BY s.personne_id, s.periode, m
    ),
    zonages AS (
        SELECT personne_id, periode, 
            MAX(CASE WHEN z.type = 'QPV' THEN 1 ELSE 0 END)::boolean AS qpv,
            MAX(CASE WHEN z.type = 'FRR' THEN 1 ELSE 0 END)::boolean AS frr
        FROM main.activites_coop a
        INNER JOIN main.structure s ON s.id = a.structure_id
        INNER JOIN main.adresse addr ON addr.id = s.id
        INNER JOIN admin.zonage z ON (z.type = 'FRR' AND addr.code_insee = z.code_insee) OR (z.type = 'QPV' AND st_contains(z.geom, addr.geom))
        GROUP BY personne_id, periode
    )
    SELECT
      b.periode,
      b.personne_id,
      b.nom,
      b.prenom,
      b.role,
      COALESCE(z.qpv, False) AS qpv,
      COALESCE(z.frr, False) AS frr,
      b.nb_accompagnements,
      COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type'),       '{}'::jsonb) AS type_accompagnement,
      COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'materiel'),   '{}'::jsonb) AS materiel,
      COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'autonomie'),  '{}'::jsonb) AS autonomie,
      COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'type_lieu'),  '{}'::jsonb) AS type_lieu,
      COALESCE(jsonb_object_agg(c.key, c.n) FILTER (WHERE c.dim = 'thematique'), '{}'::jsonb) AS thematique
    FROM base b
    LEFT JOIN counts c ON c.personne_id = b.personne_id AND c.periode = b.periode
    LEFT JOIN zonages z ON z.personne_id = b.personne_id AND z.periode = b.periode
    GROUP BY b.periode, b.personne_id, b.nom, b.prenom, b.role, b.nb_accompagnements, z.qpv, z.frr
    ORDER BY b.periode, b.role, b.personne_id
);

COMMENT ON COLUMN dataviz.personnes_accompagnements.periode IS 'Mois des accompagnements (format YYYY-MM-DD), ramené au premier jour du mois.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.role IS 'Rôle de la personne ayant réalisé l''accompagnement : "CoNum" pour Conseiller Numérique, "Médiateur" pour Médiateur numérique.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.qpv IS 'Durant la periode considérée, la personne est''elle intervenue dans au moins un lieux en zone QPV';
COMMENT ON COLUMN dataviz.personnes_accompagnements.frr IS 'Durant la periode considérée, la personne est''elle intervenue dans au moins un lieux en zone FRR';
COMMENT ON COLUMN dataviz.personnes_accompagnements.nb_accompagnements IS 'Nombre d''accompagnements réalisés par la personne dans le mois.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.thematique IS 'Répartition mensuelle des thématiques d''accompagnement.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.type_lieu IS 'Répartition mensuelle des types de lieux d''accompagnement. Valeurs possibles : domicile, lieu_activite.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.autonomie IS 'Répartition mensuelle des niveaux d''autonomie des bénéficiaires. valuers possible : partiellement autonome, entierement accompagne, autonome.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.materiel IS 'Répartition mensuelle des matériels utilisés, valeur possibles : ordinateur, telephone, tablette.';
COMMENT ON COLUMN dataviz.personnes_accompagnements.type_accompagnement IS 'Répartition mensuelle des types d''accompagnements. Valeurs possibles : individuel, collectif.';
