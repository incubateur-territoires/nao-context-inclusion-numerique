-- ============================================================
-- V122 – Intégration coop : colonnes métier de main.lieu_inclusion en ENUM
-- ============================================================
-- CONTEXTE (issue SEPT #1700) :
-- coop-mediation-numerique type ses colonnes métier avec des enums Postgres
-- (schéma coop, valeurs = labels français des @map Prisma). Pour la bascule
-- de la coop sur main.lieu_inclusion, on aligne les 10 colonnes TEXT[] de
-- l'Entrepôt sur ces mêmes enums. `autres_formations_labels` reste TEXT[]
-- (texte libre côté coop aussi).
--
-- ⚠️ VALEURS VERBATIM : les valeurs ci-dessous sont copiées caractère par
-- caractère depuis coop-mediation-numerique/apps/web/prisma/schema.prisma
-- (@map des enums, qui sont les valeurs stockées en base côté coop) :
-- accents, guillemets français « », et apostrophe typographique U+2019 dans
-- «Ce lieu n’accueille pas de public». Le moindre écart casserait la lecture
-- côté coop à la convergence. Les types sont créés dans `main` et possédés
-- par Flyway (ne PAS référencer les types du schéma coop, gérés par Prisma).
--
-- ⚠️ CONSOMMATEURS À COORDONNER (cassent à la lecture de ces colonnes tant
-- que leur mapping reste String[]/text[]) :
--   - min/prisma/schema.prisma (model main_lieu_inclusion) — PR min requise ;
--   - coop apps/web/prisma/entrepot/schema.prisma — côté équipe coop ;
--   - coop-dag.py / carto-dag-import.py — adaptés dans la même MR que ce fichier.
--
-- ORDRE DES VALEURS : identique au schema.prisma coop (l'ordre d'un enum
-- Postgres définit son ordre de tri ; on le garde aligné pour la convergence).
-- ============================================================

-- ------------------------------------------------------------
-- 1) Types enum (schéma main, propriété Flyway)
-- ------------------------------------------------------------

CREATE TYPE main.typologie AS ENUM (
    'ACI', 'ACIPHC', 'AFPA', 'AI', 'ASE', 'ASSO', 'ASSO_CHOMEUR', 'Autre',
    'AVIP', 'BIB', 'CAARUD', 'CADA', 'CAF', 'CAP_EMPLOI', 'CAVA', 'CC',
    'CCAS', 'CCONS', 'CD', 'CDAS', 'CFP', 'CHRS', 'CHU', 'CIAS', 'CIDFF',
    'CITMET', 'CMP', 'CMS', 'CPAM', 'CPH', 'CS', 'CSAPA', 'CSC', 'DEETS',
    'DEPT', 'DIPLP', 'E2C', 'EA', 'EATT', 'EI', 'EITI', 'ENM', 'EPCI',
    'EPI', 'EPIDE', 'EPN', 'ES', 'ESAT', 'ESS', 'ETTI', 'EVS', 'FABLAB',
    'FABRIQUE', 'FAIS', 'FT', 'GEIQ', 'HUDA', 'LA_POSTE', 'MDE', 'MDH',
    'MDEF', 'MDPH', 'MDS', 'MJC', 'ML', 'MQ', 'MSA', 'MSAP', 'MUNI',
    'OACAS', 'ODC', 'OF', 'OIL', 'OPCS', 'PAD', 'PENSION', 'PI', 'PIJ_BIJ',
    'PIMMS', 'PJJ', 'PLIE', 'PREF', 'PREVENTION', 'REG', 'RELAIS_LECTURE',
    'RESSOURCERIE', 'RFS', 'RS_FJT', 'SCP', 'SPIP', 'TIERS_LIEUX', 'UDAF'
);

CREATE TYPE main.service AS ENUM (
    'Aide aux démarches administratives',
    'Maîtrise des outils numériques du quotidien',
    'Insertion professionnelle via le numérique',
    'Utilisation sécurisée du numérique',
    'Parentalité et éducation avec le numérique',
    'Loisirs et créations numériques',
    'Compréhension du monde numérique',
    'Accès internet et matériel informatique',
    'Acquisition de matériel informatique à prix solidaire'
);

CREATE TYPE main.public_specifiquement_adresse AS ENUM (
    'Jeunes',
    'Étudiants',
    'Familles et/ou enfants',
    'Seniors',
    'Femmes'
);

CREATE TYPE main.prise_en_charge_specifique AS ENUM (
    'Surdité',
    'Handicaps moteurs',
    'Handicaps mentaux',
    'Illettrisme',
    'Langues étrangères (anglais)',
    'Langues étrangères (autres)',
    'Déficience visuelle'
);

CREATE TYPE main.frais_a_charge AS ENUM (
    'Gratuit',
    'Gratuit sous condition',
    'Payant'
);

CREATE TYPE main.dispositif_programme_national AS ENUM (
    'Aidants Connect',
    'Bibliothèques numérique de référence',
    'Certification PIX',
    'Conseillers numériques',
    'Emmaüs Connect',
    'France Services',
    'Grande école du numérique',
    'La Croix Rouge',
    'Point d''accès numérique CAF',
    'Promeneurs du net',
    'Relais numérique (Emmaüs Connect)'
);

CREATE TYPE main.formation_label AS ENUM (
    'Formé à « Mon Espace Santé »',
    'Formé à « DUPLEX » (illettrisme)',
    'Arnia/MedNum BFC (Bourgogne-Franche-Comté)',
    'Collectif ressources et acteurs réemploi (Normandie)',
    'Fabriques de Territoire',
    'Les Éclaireurs du numérique (Drôme)',
    'Mes Papiers (Métropole de Lyon)',
    'ORDI 3.0',
    'SUD LABS (PACA)'
);

CREATE TYPE main.itinerance AS ENUM (
    'Itinérant',
    'Fixe'
);

CREATE TYPE main.modalite_acces AS ENUM (
    'Se présenter',
    'Téléphoner',
    'Contacter par mail',
    'Prendre un RDV en ligne',
    'Ce lieu n’accueille pas de public',
    'Envoyer un mail avec une fiche de prescription'
);

CREATE TYPE main.modalite_accompagnement AS ENUM (
    'En autonomie',
    'Accompagnement individuel',
    'Dans un atelier collectif',
    'À distance'
);

COMMENT ON TYPE main.typologie IS
  'Aligné sur l''enum coop.typologie (coop-mediation-numerique, schema.prisma). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.service IS
  'Aligné sur l''enum coop.service (coop-mediation-numerique, schema.prisma). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.public_specifiquement_adresse IS
  'Aligné sur l''enum coop.public_specifiquement_adresse (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.prise_en_charge_specifique IS
  'Aligné sur l''enum coop.prise_en_charge_specifique (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.frais_a_charge IS
  'Aligné sur l''enum coop.frais_a_charge (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.dispositif_programme_national IS
  'Aligné sur l''enum coop.dispositif_programme_national (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.formation_label IS
  'Aligné sur l''enum coop.formation_label (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.itinerance IS
  'Aligné sur l''enum coop.itinerance (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.modalite_acces IS
  'Aligné sur l''enum coop.modalite_acces (coop-mediation-numerique). Contient '
  'l''apostrophe typographique U+2019 («n’accueille»), à préserver verbatim. '
  'Toute évolution doit être coordonnée avec l''équipe coop.';
COMMENT ON TYPE main.modalite_accompagnement IS
  'Aligné sur l''enum coop.modalite_accompagnement (coop-mediation-numerique). '
  'Toute évolution doit être coordonnée avec l''équipe coop.';

-- ------------------------------------------------------------
-- 2) Nettoyage : listes Python stringifiées stockées comme un seul élément
-- ------------------------------------------------------------
-- 11 lignes (edited_by = 'coop') portent des éléments de la forme
-- «['Gratuit']» ou «['A', 'B']» : bug de _normalize_array (coop-dag.py, une
-- repr Python échoue le json.loads à cause des apostrophes simples et tombe
-- dans le fallback [s]), corrigé dans la même MR. On re-splitte ces éléments
-- avant le cast — aucune valeur légitime de ces colonnes ne contient de
-- virgule. `autres_formations_labels` (texte libre, jamais casté) est exclu :
-- on ne re-splitte pas du texte libre.

DO $do$
DECLARE
    col text;
    nb  integer;
BEGIN
    FOREACH col IN ARRAY ARRAY[
        'typologies', 'services', 'publics_specifiquement_adresses',
        'prise_en_charge_specifique', 'frais_a_charge',
        'dispositif_programmes_nationaux', 'formations_labels',
        'itinerance', 'modalites_acces', 'modalites_accompagnement'
    ]
    LOOP
        EXECUTE format($sql$
            UPDATE main.lieu_inclusion
            SET %1$I = (
                SELECT array_agg(DISTINCT btrim(part, ' ''"'))
                FROM unnest(%1$I) AS e
                CROSS JOIN LATERAL regexp_split_to_table(
                    CASE WHEN e ~ '^\[.*\]$' THEN btrim(e, '[]') ELSE e END, ','
                ) AS part
            )
            WHERE EXISTS (SELECT 1 FROM unnest(%1$I) AS e WHERE e ~ '^\[.*\]$')
        $sql$, col);
        GET DIAGNOSTICS nb = ROW_COUNT;
        IF nb > 0 THEN
            RAISE NOTICE 'V122 nettoyage % : % ligne(s)', col, nb;
        END IF;
    END LOOP;
END
$do$;

-- 2b) Alias hors référentiel écrits historiquement par l'UI d'édition MIN
-- (PrismaLieuInclusionRepository) : « Se présenter sur place » au lieu de
-- « Se présenter », « Atelier collectif » au lieu de « Dans un atelier
-- collectif ». L'UI MIN est corrigée dans la PR min associée (#1700) ; on
-- normalise l'existant AVANT le cast (sinon il échouerait sur ces valeurs)
-- et APRÈS le dépliage 2a (un alias emprisonné dans une repr Python doit
-- d'abord être déplié pour être normalisé ici).

UPDATE main.lieu_inclusion
SET modalites_acces = array_replace(modalites_acces, 'Se présenter sur place', 'Se présenter')
WHERE 'Se présenter sur place' = ANY (modalites_acces);

UPDATE main.lieu_inclusion
SET modalites_accompagnement = array_replace(modalites_accompagnement, 'Atelier collectif', 'Dans un atelier collectif')
WHERE 'Atelier collectif' = ANY (modalites_accompagnement);

-- ------------------------------------------------------------
-- 3) DROP des vues dépendantes (fermeture transitive vérifiée : aucune vue
--    ne dépend de ces 6 vues — pas de cascade)
-- ------------------------------------------------------------

DROP VIEW IF EXISTS api.carto;
DROP VIEW IF EXISTS dataviz.structures;
DROP VIEW IF EXISTS dataviz.lieux_inclusion_numerique;
DROP VIEW IF EXISTS dataviz.personne;
DROP VIEW IF EXISTS dataviz.personne_pseudonymisee;
DROP VIEW IF EXISTS dataviz.structures_employeuses;

-- ------------------------------------------------------------
-- 4) main.sorted_text_array : text[] → anyarray
-- ------------------------------------------------------------
-- La version V115 n'accepte que text[] ; les DAGs l'appliquent aux colonnes
-- métier qui deviennent enum[] (pas de cast implicite enum[]→text[] en
-- contexte d'appel de fonction). La version polymorphe accepte les deux et
-- renvoie toujours text[] : les comparaisons des DAGs restent valides sans
-- toucher aux ~20 sites d'appel.

DROP FUNCTION main.sorted_text_array(text[]);

CREATE FUNCTION main.sorted_text_array(arr anyarray)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    -- COALESCE sur l'entrée : préserve la distinction tableau vide '{}' vs NULL
    -- (unnest('{}') ne produit aucune ligne → array_agg renvoie NULL).
    SELECT COALESCE(
        (SELECT array_agg(elem::text ORDER BY elem::text) FROM unnest(arr) AS elem),
        arr::text[]
    );
$$;

COMMENT ON FUNCTION main.sorted_text_array(anyarray) IS
    'Renvoie le tableau trié (ordre lexical, en text[]) pour comparer des arrays '
    'indépendamment de l''ordre des éléments. Accepte text[] et enum[] (V122). '
    'Préserve NULL et tableau vide. Utilisé par carto-dag / coop-dag pour ne pas '
    'détecter un faux changement métier lors d''un simple réordonnancement '
    '(seule la comparaison est triée, pas la valeur stockée).';

-- ------------------------------------------------------------
-- 5) Conversion des colonnes (un seul rewrite de table)
-- ------------------------------------------------------------

ALTER TABLE main.lieu_inclusion
    ALTER COLUMN typologies TYPE main.typologie[]
        USING typologies::main.typologie[],
    ALTER COLUMN services TYPE main.service[]
        USING services::main.service[],
    ALTER COLUMN publics_specifiquement_adresses TYPE main.public_specifiquement_adresse[]
        USING publics_specifiquement_adresses::main.public_specifiquement_adresse[],
    ALTER COLUMN prise_en_charge_specifique TYPE main.prise_en_charge_specifique[]
        USING prise_en_charge_specifique::main.prise_en_charge_specifique[],
    ALTER COLUMN frais_a_charge TYPE main.frais_a_charge[]
        USING frais_a_charge::main.frais_a_charge[],
    ALTER COLUMN dispositif_programmes_nationaux TYPE main.dispositif_programme_national[]
        USING dispositif_programmes_nationaux::main.dispositif_programme_national[],
    ALTER COLUMN formations_labels TYPE main.formation_label[]
        USING formations_labels::main.formation_label[],
    ALTER COLUMN itinerance TYPE main.itinerance[]
        USING itinerance::main.itinerance[],
    ALTER COLUMN modalites_acces TYPE main.modalite_acces[]
        USING modalites_acces::main.modalite_acces[],
    ALTER COLUMN modalites_accompagnement TYPE main.modalite_accompagnement[]
        USING modalites_accompagnement::main.modalite_accompagnement[];

-- ------------------------------------------------------------
-- 6) Recréation de api.carto — identique à V116 §4 (les colonnes converties
--    y sont exposées telles quelles : leur type devient enum[], le JSON
--    PostgREST reste identique)
-- ------------------------------------------------------------

CREATE VIEW api.carto AS (
  WITH courriels AS (
    SELECT li.id,
           string_agg(
             jsonb_extract_path_text(jsonb_extract_path(li.contact, 'emails'), key.key),
             '|'
           ) AS courriels_concat
    FROM main.lieu_inclusion li,
         LATERAL jsonb_object_keys(jsonb_extract_path(li.contact, 'emails')) key(key)
    GROUP BY li.id
  ),
  personnes AS (
    SELECT sub.lieu_id,
           jsonb_strip_nulls(jsonb_agg(
             jsonb_build_object(
               'prenom', sub.prenom,
               'nom', sub.nom,
               'label', sub.label,
               'email', sub.email,
               'telephone', sub.telephone
             )
           )) AS mediateurs
    FROM (
      SELECT pal.lieu_id,
             p.prenom,
             p.nom,
             COALESCE(
               (p.contact -> 'coop') ->> 'email',
               (p.contact -> 'idposte') ->> 'mail_pro',
               (p.contact -> 'idposte') ->> 'mail_perso'
             ) AS email,
             COALESCE(
               (p.contact -> 'coop') ->> 'telephone',
               (p.contact -> 'idposte') ->> 'telephone'
             ) AS telephone,
             -- Une seule ligne par personne : labels cumulés, ordre CN → AC → Médiateur.
             ARRAY(
               SELECT lbl FROM (
                 SELECT 1 AS ord, 'Conseiller Numerique'::text AS lbl
                 WHERE flags.est_cn
                 UNION ALL
                 SELECT 2, 'Aidant Connect'
                 WHERE flags.est_ac
                 UNION ALL
                 SELECT 3, 'Médiateur numérique'
                 WHERE p.is_mediateur = TRUE
                   AND NOT flags.est_cn
                   AND NOT flags.est_ac
               ) labels
               ORDER BY ord
             ) AS label
      FROM main.personne_affectations_lieu pal
      JOIN main.personne p ON p.id = pal.personne_id
      CROSS JOIN LATERAL (
        SELECT
          (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL) AS est_cn,
          EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_ac
            WHERE pa_ac.personne_id = p.id
              AND pa_ac.source = 'aidants-connect'
              AND pa_ac.est_active = TRUE
          ) AS est_ac,
          EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_emp
            WHERE pa_emp.personne_id = p.id
              AND pa_emp.est_active = TRUE
              AND pa_emp.source <> 'aidants-connect'
          ) AS a_emploi_actif_non_ac
      ) flags
      WHERE pal.est_active = TRUE
        AND p.is_visible IS DISTINCT FROM FALSE
        AND (
          -- Aidant Connect actif
          flags.est_ac
          -- Conseiller Numérique avec un emploi actif non-AC
          OR (flags.est_cn AND flags.a_emploi_actif_non_ac)
          -- Médiateur numérique simple (ni CN ni AC actif)
          OR (p.is_mediateur = TRUE AND NOT flags.est_cn AND NOT flags.est_ac)
        )
    ) sub
    GROUP BY sub.lieu_id
  )
  SELECT
    li.structure_cartographie_nationale_id AS id,
    COALESCE(sa.siret, sa.rna, '00000000000000')::character varying(14) AS pivot,
    li.nom,
    jsonb_build_object(
      'numero_voie', a.numero_voie,
      'repetition', a.repetition,
      'nom_voie', a.nom_voie,
      'code_postal', a.code_postal,
      'commune', a.nom_commune,
      'code_insee', a.code_insee
    ) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    li.typologies AS typologie,
    jsonb_extract_path_text(li.contact, 'telephone') AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(li.contact, 'site_web') AS site_web,
    li.horaires,
    li.presentation_resume,
    li.presentation_detail,
    li.source,
    li.itinerance,
    COALESCE(li.updated_at, li.created_at) AS date_maj,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.prise_rdv,
    personnes.mediateurs
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse a ON a.id = li.adresse_id
  LEFT JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
  LEFT JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
  LEFT JOIN courriels ON courriels.id = li.id
  LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    AND li.visible_pour_cartographie_nationale = TRUE
);

COMMENT ON VIEW api.carto IS
  'Vue cartographie publique (V105). Source : main.lieu_inclusion + asso vers '
  'structure_administrative pour SIRET/RNA. Médiateurs : une ligne par personne '
  '(personne_affectations_lieu), labels cumulés CN/AC/Médiateur. Le label Aidant '
  'Connect requiert une affectation emploi aidants-connect active. Depuis #1348, '
  'le lieu reste exposé même si tous ses médiateurs sont inactifs (mediateurs = NULL).';

GRANT SELECT ON TABLE api.carto TO postgrest_anct_carto;
GRANT SELECT ON TABLE api.carto TO postgrest_anct_data_incl;

-- ------------------------------------------------------------
-- 7) Recréation de dataviz.structures — identique à V116 §5, SAUF les
--    NULL::text[] des branches UNION (cas 2, SA pure) qui deviennent des
--    NULL typés enum[] pour que l'UNION reste homogène.
--    Grant Metabase auto via ALTER DEFAULT PRIVILEGES IN SCHEMA dataviz (V005).
-- ------------------------------------------------------------

CREATE VIEW dataviz.structures AS (
  -- Cas 1 : SA mixte avec asso → 1 ligne par couple (SA, LI)
  SELECT
    sa.id,
    li.structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    COALESCE(li.adresse_id, sa.adresse_id) AS adresse_id,
    li.contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    li.fiche_acces_libre,
    sa.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.structure_administrative sa
  JOIN main.lieu_inclusion_structure_administrative asso ON asso.structure_administrative_id = sa.id
  JOIN main.lieu_inclusion li ON li.id = asso.lieu_id
  LEFT JOIN main.adresse adresse ON adresse.id = COALESCE(li.adresse_id, sa.adresse_id)
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))

  UNION ALL

  -- Cas 2 : SA pure (sans asso) → 1 ligne, champs metier NULL
  SELECT
    sa.id,
    NULL::uuid AS structure_coop_id,
    sa.structure_ac_id,
    sa.structure_tp_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.denomination_sirene,
    sa.siret,
    sa.rna,
    sa.adresse_id,
    NULL::jsonb AS contact,
    sa.etat_administratif,
    sa.code_activite_principale,
    sa.categorie_juridique,
    sa.nb_mandats_ac,
    sa.publique,
    NULL::varchar AS structure_cartographie_nationale_id,
    NULL::boolean AS visible_pour_cartographie_nationale,
    NULL::main.typologie[] AS typologies,
    NULL::text AS presentation_resume,
    NULL::text AS presentation_detail,
    NULL::varchar AS horaires,
    NULL::varchar AS prise_rdv,
    NULL::main.service[] AS services,
    NULL::main.public_specifiquement_adresse[] AS publics_specifiquement_adresses,
    NULL::main.prise_en_charge_specifique[] AS prise_en_charge_specifique,
    NULL::main.frais_a_charge[] AS frais_a_charge,
    NULL::main.dispositif_programme_national[] AS dispositif_programmes_nationaux,
    NULL::main.formation_label[] AS formations_labels,
    NULL::text[] AS autres_formations_labels,
    NULL::main.itinerance[] AS itinerance,
    NULL::main.modalite_acces[] AS modalites_acces,
    NULL::main.modalite_accompagnement[] AS modalites_accompagnement,
    NULL::integer AS mediateurs_en_activite,
    NULL::integer AS emplois,
    sa.last_sirene_enrich_at,
    sa.created_at,
    sa.updated_at,
    NULL::varchar AS fiche_acces_libre,
    sa.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    cj.nom AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.structure_administrative_id = sa.id
  )

  UNION ALL

  -- Cas 3 : LI pure (sans asso) → 1 ligne, champs SIRENE NULL
  SELECT
    li.id,
    li.structure_coop_id,
    NULL::uuid AS structure_ac_id,
    NULL::integer AS structure_tp_id,
    li.nom,
    NULL::varchar AS denomination_sirene,
    NULL::varchar AS siret,
    NULL::varchar AS rna,
    li.adresse_id,
    li.contact,
    NULL::varchar AS etat_administratif,
    NULL::varchar AS code_activite_principale,
    NULL::varchar AS categorie_juridique,
    NULL::integer AS nb_mandats_ac,
    NULL::boolean AS publique,
    li.structure_cartographie_nationale_id,
    li.visible_pour_cartographie_nationale,
    li.typologies,
    li.presentation_resume,
    li.presentation_detail,
    li.horaires,
    li.prise_rdv,
    li.services,
    li.publics_specifiquement_adresses,
    li.prise_en_charge_specifique,
    li.frais_a_charge,
    li.dispositif_programmes_nationaux,
    li.formations_labels,
    li.autres_formations_labels,
    li.itinerance,
    li.modalites_acces,
    li.modalites_accompagnement,
    li.mediateurs_en_activite,
    li.emplois,
    NULL::date AS last_sirene_enrich_at,
    li.created_at,
    li.updated_at,
    li.fiche_acces_libre,
    li.edited_by,
    adresse.clef_interop AS addr_clef_interop,
    adresse.code_ban AS addr_code_ban,
    adresse.departement AS addr_departement,
    adresse.code_postal AS addr_code_postal,
    adresse.code_insee AS addr_code_insee,
    adresse.nom_commune AS addr_nom_commune,
    adresse.nom_voie AS addr_nom_voie,
    adresse.repetition AS addr_repetition,
    adresse.numero_voie AS addr_numero_voie,
    coll_terr.region_code AS coll_terr_region_code,
    coll_terr.region_nom AS coll_terr_region_nom,
    coll_terr.departement_code AS coll_terr_departement_code,
    coll_terr.departement_nom AS coll_terr_departement_nom,
    coll_terr.code_insee AS coll_terr_code_insee,
    coll_terr.commune_nom AS coll_terr_commune_nom,
    NULL::text AS categories_juridiques_nom,
    zonage.type AS zonage_type,
    zonage.code AS zonage_code,
    zonage.libelle AS zonage_libelle,
    zonage.commentaire AS zonage_complement,
    st_y(adresse.geom) AS addr_latitude,
    st_x(adresse.geom) AS addr_longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  WHERE NOT EXISTS (
    SELECT 1 FROM main.lieu_inclusion_structure_administrative asso
    WHERE asso.lieu_id = li.id
  )
);

COMMENT ON VIEW dataviz.structures IS
  'Vue dataviz refondue phase 5.5 (V094). UNION ALL 3 cas SA+LI / SA pure / LI pure.';

-- ------------------------------------------------------------
-- 8) Recréation de dataviz.lieux_inclusion_numerique — identique à V094 §4,
--    SAUF li.formations_labels casté ::text[] pour la concaténation avec
--    autres_formations_labels (resté text[] ; pas de || entre enum[] et text[]).
-- ------------------------------------------------------------

CREATE VIEW dataviz.lieux_inclusion_numerique AS (
  WITH conseillers AS (
    SELECT pal.lieu_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_lieu pal ON pal.personne_id = p.id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pal.est_active = TRUE
    GROUP BY pal.lieu_id
  ), coop_lieu AS (
    SELECT lieu_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY lieu_id
  )
  SELECT
    li.id AS structure_id,
    li.nom,
    sa.siret,
    sa.rna,
    cj.nom AS "catégorie_juridique_de_la_structure",
    sa.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    li.presentation_resume AS "présentation_résumée",
    li.presentation_detail AS "présentation_détaillée",
    li.horaires AS horaires_accueil,
    array_to_string(li.services, ', ') AS "services_proposés",
    array_to_string(li.dispositif_programmes_nationaux, ', ') AS dispositifs_nationaux,
    array_to_string(
      li.formations_labels::text[] ||
      NULLIF(NULLIF(NULLIF(li.autres_formations_labels, '{ZRR}'::text[]), '{QPV}'::text[]), '{QPV,ZRR}'::text[]),
      ', '
    ) AS formations,
    array_to_string(li.itinerance, ', ') AS "itinérance",
    array_to_string(li.modalites_acces, ', ') AS "modalités_accès",
    array_to_string(li.modalites_accompagnement, ', ') AS "modalités_accompagnement",
    li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    coop_lieu.nbr AS nombre_accompagnements,
    array_to_string(li.typologies, ', ') AS typologies,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN 'France Services' = ANY (li.dispositif_programmes_nationaux) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services,
    CASE WHEN sa.structure_coop_id IS NOT NULL OR li.structure_coop_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "employeur_conseiller_numérique",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.lieu_inclusion li
  LEFT JOIN main.adresse ON li.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
  LEFT JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN conseillers ON li.id = conseillers.lieu_id
  LEFT JOIN coop_lieu ON li.id = coop_lieu.lieu_id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
);

COMMENT ON VIEW dataviz.lieux_inclusion_numerique IS
  'Vue dataviz refondue phase 5.5 (V094). Cote LI avec asso optionnelle vers SA pour SIRENE.';

-- ------------------------------------------------------------
-- 9) Recréation de dataviz.personne — identique à V094 §5
--    ('France Services' = ANY(enum[]) : le littéral est coercé, inchangé)
-- ------------------------------------------------------------

CREATE VIEW dataviz.personne AS (
  WITH lieux AS (
    SELECT pal.personne_id,
           MIN(qpv.id) AS qpv,
           MIN(frr.id) AS frr,
           COUNT(*) AS nbr,
           CASE WHEN bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN main.adresse adresse ON adresse.id = li.adresse_id
    LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV' AND st_contains(qpv.geom, adresse.geom)
    LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR' AND adresse.code_insee::text = frr.code_insee::text
    WHERE pal.est_active = TRUE
    GROUP BY pal.personne_id
  ), coop AS (
    SELECT personne_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY personne_id
  )
  SELECT
    personne.id AS "Personne ID",
    sa.id AS "Structure employeuse ID",
    personne.nom AS "Nom",
    personne.prenom AS "Prénom",
    (personne.contact -> 'coop') ->> 'telephone' AS "Téléphone",
    concat_ws(', ', (personne.contact -> 'coop') ->> 'email',
                    (personne.contact -> 'idposte') ->> 'mail_pro',
                    (personne.contact -> 'idposte') ->> 'mail_perso') AS emails,
    CASE WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "Conseiller Numérique",
    CASE WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
         WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Coordinateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id
             AND pae.source = 'aidants-connect' AND pae.est_active = TRUE
         ) THEN 'Oui'::text
         WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
         ELSE NULL::text END AS "Aidants Connect",
    CASE WHEN personne.is_mediateur = TRUE THEN 'Médiateur'::text
         WHEN personne.is_mediateur = FALSE OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
         ELSE NULL::text END AS "Type accompagnateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id AND pae.est_active = TRUE
         ) THEN 'Oui'::text ELSE 'Non'::text END AS "En poste",
    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification PIX",
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification REMN"
  FROM main.personne
  LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = TRUE
  LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN lieux ON personne.id = lieux.personne_id
  LEFT JOIN coop ON personne.id = coop.personne_id
);

COMMENT ON VIEW dataviz.personne IS
  'Vue dataviz refondue phase 5.5 (V094). paf_emploi pour structure employeuse (SA), paf_lieu pour lieux d''activite (LI).';

-- ------------------------------------------------------------
-- 10) Recréation de dataviz.personne_pseudonymisee — identique à V094 §6
-- ------------------------------------------------------------

CREATE VIEW dataviz.personne_pseudonymisee AS (
  WITH lieux AS (
    SELECT pal.personne_id,
           MIN(qpv.id) AS qpv,
           MIN(frr.id) AS frr,
           COUNT(*) AS nbr,
           CASE WHEN bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services
    FROM main.personne_affectations_lieu pal
    JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
    JOIN main.adresse adresse ON adresse.id = li.adresse_id
    LEFT JOIN admin.zonage qpv ON qpv.type::text = 'QPV' AND st_contains(qpv.geom, adresse.geom)
    LEFT JOIN admin.zonage frr ON frr.type::text = 'FRR' AND adresse.code_insee::text = frr.code_insee::text
    WHERE pal.est_active = TRUE
    GROUP BY pal.personne_id
  ), coop AS (
    SELECT personne_id, COUNT(*) AS nbr
    FROM main.activites_coop
    GROUP BY personne_id
  )
  SELECT
    CASE WHEN personne.conseiller_numerique_id IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "Conseiller Numérique",
    CASE WHEN personne.is_coordinateur IS TRUE THEN 'Oui'::text
         WHEN personne.is_coordinateur IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Coordinateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id
             AND pae.source = 'aidants-connect' AND pae.est_active = TRUE
         ) THEN 'Oui'::text
         WHEN personne.aidant_connect_id IS NOT NULL THEN 'Non'::text
         ELSE NULL::text END AS "Aidants Connect",
    CASE WHEN personne.is_mediateur = TRUE THEN 'Médiateur'::text
         WHEN personne.is_mediateur = FALSE OR personne.is_mediateur IS NULL THEN 'Aidant numérique'::text
         ELSE NULL::text END AS "Type accompagnateur",
    CASE WHEN EXISTS (
           SELECT 1 FROM main.personne_affectations_emploi pae
           WHERE pae.personne_id = personne.id AND pae.est_active = TRUE
         ) THEN 'Oui'::text ELSE 'Non'::text END AS "En poste",
    CASE WHEN lieux.qpv IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "QPV",
    CASE WHEN lieux.frr IS NOT NULL THEN 'Oui'::text ELSE 'Non'::text END AS "FRR",
    lieux.nbr AS "Lieux activités",
    lieux.est_france_services AS lieux_france_services,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS "Structure employeuse",
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse_structure_employeuse,
    adresse.code_postal AS code_postal_structure_employeuse,
    commune.nom AS commune_structure_employeuse,
    personne.nb_accompagnements_ac AS nombre_accompagnements_aidants_connect,
    coop.nbr AS nombre_accompagnements_coop,
    NULLIF(COALESCE(personne.nb_accompagnements_ac, 0) + COALESCE(coop.nbr, 0::bigint), 0) AS nombre_accompagnements_totaux,
    CASE WHEN personne.formation_fne_ac IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS "Formation FNE",
    formation.label AS "Formation",
    formation.date_debut AS "date de début formation",
    formation.date_fin AS "date de fin formation",
    CASE WHEN formation.pix IS TRUE THEN 'Oui'::text
         WHEN formation.pix IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification PIX",
    CASE WHEN formation.remn IS TRUE THEN 'Oui'::text
         WHEN formation.remn IS FALSE THEN 'Non'::text
         ELSE NULL::text END AS "Certification REMN"
  FROM main.personne
  LEFT JOIN main.personne_affectations_emploi pae ON personne.id = pae.personne_id AND pae.est_active = TRUE
  LEFT JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.commune ON adresse.code_insee::text = commune.code_insee::text
  LEFT JOIN main.formation ON personne.id = formation.personne_id
  LEFT JOIN lieux ON personne.id = lieux.personne_id
  LEFT JOIN coop ON personne.id = coop.personne_id
);

-- ------------------------------------------------------------
-- 11) Recréation de dataviz.structures_employeuses — identique à V094 §7
-- ------------------------------------------------------------

CREATE VIEW dataviz.structures_employeuses AS (
  WITH coordinateurs AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE p.is_coordinateur IS TRUE AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), conseillers AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id
    WHERE (p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL)
      AND pae.est_active = TRUE
    GROUP BY pae.structure_administrative_id
  ), aidants_connect AS (
    SELECT pae.structure_administrative_id,
           COUNT(*) AS nbr_rattach,
           SUM(COALESCE(
             CASE WHEN sa.structure_ac_id IS NOT NULL THEN p.nb_accompagnements_ac ELSE 0 END,
             0
           )) AS nbr_accompagnements
    FROM main.personne p
    JOIN main.personne_affectations_emploi pae ON p.id = pae.personne_id AND pae.est_active = TRUE
    LEFT JOIN main.structure_administrative sa ON pae.structure_administrative_id = sa.id
    WHERE EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pae2
            WHERE pae2.personne_id = p.id
              AND pae2.source = 'aidants-connect'
              AND pae2.est_active = TRUE
          )
       OR p.aidant_connect_id IS NOT NULL
    GROUP BY pae.structure_administrative_id
  ), coop AS (
    -- activites_coop cote LI, ramene a la SA via asso.
    SELECT asso.structure_administrative_id,
           COUNT(*) AS nbr
    FROM main.activites_coop ac
    JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = ac.lieu_id
    JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
    WHERE sa.structure_coop_id IS NOT NULL
    GROUP BY asso.structure_administrative_id
  ), aggregats_li AS (
    -- mediateurs_en_activite / dispositif_programmes_nationaux / France Services
    -- vivent sur LI. On agrege a la SA via asso (max sur mediateurs, bool_or
    -- sur France Services).
    SELECT asso.structure_administrative_id,
           MAX(li.mediateurs_en_activite) AS mediateurs_en_activite,
           bool_or('France Services' = ANY (li.dispositif_programmes_nationaux)) AS est_france_services
    FROM main.lieu_inclusion li
    JOIN main.lieu_inclusion_structure_administrative asso ON asso.lieu_id = li.id
    GROUP BY asso.structure_administrative_id
  )
  SELECT
    sa.id AS structure_id,
    COALESCE(sa.denomination_antenne, sa.denomination_sirene) AS nom,
    sa.siret,
    sa.rna,
    sa.code_activite_principale AS code_naf,
    cj.nom AS "catégorie_juridique_de_la_structure",
    sa.etat_administratif AS "état_administratif_de_la_structure",
    coll_terr.region_nom AS "région",
    coll_terr.departement_nom AS "département",
    adresse.code_postal,
    coll_terr.commune_nom AS commune,
    concat_ws(' ', adresse.numero_voie, adresse.repetition, adresse.nom_voie) AS adresse,
    CASE WHEN zonage.type::text = 'QPV' THEN zonage.libelle ELSE 'Non'::varchar END AS qpv,
    CASE WHEN zonage.type::text = 'FRR' THEN 'Oui'::text ELSE 'Non'::text END AS frr,
    CASE WHEN COALESCE(conseillers.nbr, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_conum,
    CASE WHEN COALESCE(aidants_connect.nbr_rattach, 0::bigint) > 0 THEN 'Oui'::text ELSE 'Non'::text END AS est_aidant_connect,
    CASE WHEN aggregats_li.est_france_services IS TRUE THEN 'Oui'::text ELSE 'Non'::text END AS est_france_services,
    aggregats_li.mediateurs_en_activite AS "nombre_de_médiateurs",
    conseillers.nbr AS "nombre_de_conseillers_numériques",
    aidants_connect.nbr_rattach AS nombre_aidants_connect,
    coordinateurs.nbr AS nombre_de_coordinateurs,
    sa.nb_mandats_ac AS mandats_aidants_connect,
    aidants_connect.nbr_accompagnements AS accompagnements_aidants_connect,
    coop.nbr AS "nombre_accompagnements_médiateurs_numériques",
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude
  FROM main.structure_administrative sa
  LEFT JOIN main.adresse ON sa.adresse_id = adresse.id
  LEFT JOIN admin.coll_terr ON adresse.code_insee::text = coll_terr.code_insee::text
  LEFT JOIN admin.zonage ON (zonage.type::text = 'FRR' AND adresse.code_insee::text = zonage.code_insee::text)
                         OR (zonage.type::text = 'QPV' AND st_contains(zonage.geom, adresse.geom))
  LEFT JOIN reference.categories_juridiques cj ON sa.categorie_juridique::text = cj.code::text
  LEFT JOIN coordinateurs ON sa.id = coordinateurs.structure_administrative_id
  LEFT JOIN conseillers ON sa.id = conseillers.structure_administrative_id
  LEFT JOIN aidants_connect ON sa.id = aidants_connect.structure_administrative_id
  LEFT JOIN coop ON sa.id = coop.structure_administrative_id
  LEFT JOIN aggregats_li ON sa.id = aggregats_li.structure_administrative_id
);

COMMENT ON VIEW dataviz.structures_employeuses IS
  'Vue dataviz refondue phase 5.5 (V094). SA + paf_emploi + asso vers LI pour agregats metier.';

NOTIFY pgrst, 'reload schema';
