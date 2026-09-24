-- ============================================================
-- V044 – Améliorer min.personne_enrichie + api.get_mediateur :
--        utiliser personne_affectations.source au lieu de la
--        table contrat pour est_actuellement_conseiller_numerique
-- ============================================================

DROP VIEW IF EXISTS min.personne_enrichie;

CREATE VIEW min.personne_enrichie AS
WITH personne_avec_status AS (
  SELECT
    p.*,

    -- Type d'accompagnateur (médiateur ou aidant numérique exclusif)
    CASE
      WHEN p.is_mediateur = true THEN 'mediateur'
      WHEN p.is_mediateur = false OR p.is_mediateur IS NULL THEN 'aidant_numerique'
    END AS type_accompagnateur,

    -- Labellisation aidant connect (un médiateur peut être labellisé AC)
    EXISTS (
      SELECT 1 FROM main.personne_affectations pa
      WHERE pa.personne_id = p.id
        AND pa.source = 'aidants-connect'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
    ) AS labellisation_aidant_connect,

    -- Est actuellement en poste en tant que médiateur (idposte ou coop actif)
    CASE
      WHEN p.is_mediateur = true
        AND EXISTS (
          SELECT 1 FROM main.personne_affectations pa
          WHERE pa.personne_id = p.id
          AND pa.type = 'structure_emploi'
          AND pa.est_active = TRUE
          AND pa.source IN ('idposte', 'coop')
        )
      THEN true
      ELSE false
    END AS est_actuellement_mediateur_en_poste,

    -- Est actuellement en poste en tant qu'aidant numérique exclusif
    CASE
      WHEN (p.is_mediateur = false OR p.is_mediateur IS NULL)
        AND EXISTS (
          SELECT 1 FROM main.personne_affectations pa
          WHERE pa.personne_id = p.id
            AND pa.source = 'aidants-connect'
            AND pa.est_active = TRUE
            AND pa.type = 'structure_emploi'
        )
      THEN true
      ELSE false
    END AS est_actuellement_aidant_numerique_en_poste

  FROM main.personne p
)
SELECT
  *,
  -- Est actuellement conseiller numérique (affectation idposte active)
  CASE
    WHEN EXISTS (
        SELECT 1 FROM main.personne_affectations pa
        WHERE pa.personne_id = personne_avec_status.id
        AND pa.source = 'idposte'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
      )
    THEN true
    ELSE false
  END AS est_actuellement_conseiller_numerique,

  -- Est actuellement coordinateur actif
  CASE
    WHEN is_coordinateur = true
      AND (est_actuellement_mediateur_en_poste = true OR est_actuellement_aidant_numerique_en_poste = true)
    THEN true
    ELSE false
  END AS est_actuellement_coordo_actif,

  -- ID de la structure employeuse (depuis personne_affectations)
  (
    SELECT pa.structure_id
    FROM main.personne_affectations pa
    WHERE pa.personne_id = personne_avec_status.id
    AND pa.type = 'structure_emploi'
    AND pa.est_active = TRUE
    ORDER BY pa.structure_id ASC
    LIMIT 1
  ) AS structure_employeuse_id

FROM personne_avec_status;


-- ============================================================
-- Améliorer api.get_mediateur :
--   is_conseiller_numerique via personne_affectations (source=idposte)
--   au lieu de contrat.date_rupture IS NULL
-- ============================================================

CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'courriels' ->> 'mail_pro' = email
       OR p.contact -> 'courriels' ->> 'mail_perso' = email
    LIMIT 1;

    RETURN QUERY
    WITH cn_coordonnes AS (
        SELECT coordinateur_id,
        jsonb_agg(
            jsonb_build_object(
                'ids', jsonb_build_object(
                    'dataspace', personne.id,
                    'aidant_connect', personne.aidant_connect_id,
                    'conseiller_numerique', personne.conseiller_numerique_id,
                    'pg_id', personne.cn_pg_id,
                    'coop', personne.coop_id),
                'nom', personne.nom,
                'prenom', personne.prenom,
                'contact', personne.contact
            )
        ) AS conseillers_numerique_coordonnes
        FROM main.coordination_mediation
        INNER JOIN main.personne ON personne.id = mediateur_id
        WHERE coordination_mediation.suppression IS NULL
        AND coordinateur_id = var_personne_id
        GROUP BY coordinateur_id
    ),
    structures_employeuses AS (
        SELECT personne_affectations.personne_id,
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', structure.id,
                        'aidant_connect', structure.structure_ac_id,
                        'coop', structure.structure_coop_id,
                        'pg_id', structure.structure_tp_id),
                    'siret', structure.siret,
                    'nom', structure.nom,
                    'contact', structure.contact,
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                    ),
                    'contrats', (SELECT
                    jsonb_agg(
                        jsonb_build_object(
                            'date_debut', contrat.date_debut,
                            'date_fin', contrat.date_fin,
                            'date_rupture', contrat.date_rupture,
                            'type', contrat.type
                        )
                    )
                    FROM main.contrat
                    WHERE (contrat.structure_id = structure.id OR contrat.structure_id IS NULL) AND contrat.personne_id = personne_affectations.personne_id)
                )
            ) AS structures
        FROM main.personne_affectations
        INNER JOIN main.structure ON structure.id = personne_affectations.structure_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        WHERE personne_affectations.personne_id = var_personne_id
        AND personne_affectations.type = 'structure_emploi'
        GROUP BY personne_affectations.personne_id
    ),
    lieux_activite AS (
        SELECT personne_id,
        jsonb_agg(
            jsonb_build_object(
                'siret', structure.siret,
                'nom', structure.nom,
                'contact', structure.contact,
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                ),
                'id_carto', structure_cartographie_nationale_id
            )
        ) AS lieux
        FROM main.personne_affectations AS lieux
        INNER JOIN main.structure ON structure.structure_coop_id = lieux.structure_coop_id
        LEFT JOIN main.adresse ON structure.adresse_id = adresse.id
        LEFT JOIN admin.coll_terr ON coll_terr.code_insee = adresse.code_insee
        WHERE personne_id = var_personne_id AND type = 'lieu_activite'
        GROUP BY personne_id
    ),
    is_cn AS (
        SELECT pa.personne_id
        FROM main.personne_affectations pa
        WHERE pa.personne_id = var_personne_id
        AND pa.source = 'idposte'
        AND pa.est_active = TRUE
        AND pa.type = 'structure_emploi'
        LIMIT 1
    )
    SELECT jsonb_build_object(
        'id', personne.id,
        'is_conseiller_numerique', CASE WHEN is_cn.personne_id IS NOT NULL THEN True ELSE False END,
        'pg_id', personne.cn_pg_id,
        'is_coordinateur', CASE WHEN is_coordinateur IS True THEN True ELSE False END,
        'structures_employeuses', structures.structures,
        'conseillers_numeriques_coordonnes', cn_coordonnes.conseillers_numerique_coordonnes,
        'lieux_activite', lieux_activite.lieux
    )
    FROM main.personne
    LEFT JOIN cn_coordonnes ON cn_coordonnes.coordinateur_id = personne.id
    LEFT JOIN lieux_activite ON lieux_activite.personne_id = personne.id
    LEFT JOIN structures_employeuses AS structures ON structures.personne_id = personne.id
    LEFT JOIN is_cn ON is_cn.personne_id = personne.id
    WHERE personne.id = var_personne_id
    GROUP BY personne.id, conseiller_numerique_id, is_coordinateur, structures.structures, cn_coordonnes.conseillers_numerique_coordonnes, lieux_activite.lieux, is_cn.personne_id;
END;
$$;

COMMENT ON FUNCTION api.get_mediateur IS 'Endpoint pour obtenir les infos d''un médiateur à partir de son courriel.';

DO $$ BEGIN
  PERFORM 1 FROM pg_roles WHERE rolname = 'postgrest_coop';
  IF FOUND THEN EXECUTE 'GRANT EXECUTE ON FUNCTION api.get_mediateur TO postgrest_coop'; END IF;
END $$;
