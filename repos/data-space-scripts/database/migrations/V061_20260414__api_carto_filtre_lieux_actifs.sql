-- V061 – Filtrer api.carto pour ne renvoyer que les lieux potentiellement actifs
--
-- Règles :
--   - Lieux sans personne_affectation lieu_activite → inclus (pas d'info)
--   - Lieux avec au moins 1 médiateur/CN actif (emploi non-AC) → inclus
--   - Lieux avec uniquement des aidants-connect → exclus (info non fiable)
--   - Lieux avec médiateurs/CN tous inactifs → exclus

CREATE OR REPLACE VIEW api.carto AS
WITH courriels AS (
    SELECT structure_1.id,
        string_agg(jsonb_extract_path_text(jsonb_extract_path(structure_1.contact, 'emails'), key.key), '|') AS courriels_concat
    FROM main.structure structure_1,
        LATERAL jsonb_object_keys(jsonb_extract_path(structure_1.contact, 'emails')) key(key)
    GROUP BY structure_1.id
), personnes AS (
    SELECT sub_table.structure_id,
        jsonb_strip_nulls(jsonb_agg(sub_table.mediateurs)) AS mediateurs
    FROM (
        SELECT personne_affectations.structure_id,
            jsonb_build_object(
                'prenom', personne.prenom,
                'nom', personne.nom,
                'label', CASE
                    WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL
                    THEN string_to_array('Conseiller Numerique', ',')
                    ELSE NULL
                END,
                'email', personne.contact -> 'coop' ->> 'email',
                'telephone', personne.contact -> 'coop' ->> 'telephone'
            ) AS mediateurs
        FROM main.personne_affectations
            JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
        WHERE personne_affectations.est_active = true
            AND personne_affectations.type = 'lieu_activite'
            AND (NOT (EXISTS (
                SELECT 1 FROM main.personne_affectations pa2
                WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.est_active = true AND pa2.type = 'structure_emploi'
            )) OR personne.aidant_connect_id IS NULL)
            AND (personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL)
        UNION
        SELECT personne_affectations.structure_id,
            jsonb_build_object(
                'prenom', personne.prenom,
                'nom', personne.nom,
                'label', CASE
                    WHEN personne.conseiller_numerique_id IS NOT NULL OR personne.cn_pg_id IS NOT NULL
                    THEN string_to_array('Conseiller Numerique,Aidant Connect', ',')
                    ELSE string_to_array('Aidant Connect', ',')
                END
            ) AS mediateurs
        FROM main.personne_affectations
            JOIN main.personne ON personne.id = personne_affectations.personne_id AND personne_affectations.structure_id IS NOT NULL
        WHERE personne_affectations.est_active = true
            AND personne_affectations.type = 'lieu_activite'
            AND ((EXISTS (
                SELECT 1 FROM main.personne_affectations pa2
                WHERE pa2.personne_id = personne.id AND pa2.source = 'aidants-connect' AND pa2.type = 'structure_emploi'
            )) OR personne.aidant_connect_id IS NOT NULL)
    ) sub_table
    GROUP BY sub_table.structure_id
)
SELECT structure.structure_cartographie_nationale_id AS id,
    COALESCE(structure.siret, structure.rna, '00000000000000')::varchar(14) AS pivot,
    structure.nom,
    jsonb_build_object('numero_voie', adresse.numero_voie, 'repetition', adresse.repetition, 'nom_voie', adresse.nom_voie, 'code_postal', adresse.code_postal, 'commune', adresse.nom_commune, 'code_insee', adresse.code_insee) AS adresse,
    st_y(adresse.geom) AS latitude,
    st_x(adresse.geom) AS longitude,
    structure.typologies AS typologie,
    jsonb_extract_path_text(structure.contact, 'telephone') AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(structure.contact, 'site_web') AS site_web,
    structure.horaires,
    structure.presentation_resume,
    structure.presentation_detail,
    structure.source,
    structure.itinerance,
    COALESCE(structure.updated_at, structure.created_at) AS date_maj,
    structure.services,
    structure.publics_specifiquement_adresses,
    structure.prise_en_charge_specifique,
    structure.frais_a_charge,
    structure.dispositif_programmes_nationaux,
    structure.formations_labels,
    structure.autres_formations_labels,
    structure.modalites_acces,
    structure.modalites_accompagnement,
    structure.prise_rdv,
    personnes.mediateurs
FROM main.structure
    LEFT JOIN main.adresse ON adresse.id = structure.adresse_id
    LEFT JOIN courriels ON courriels.id = structure.id
    LEFT JOIN personnes ON personnes.structure_id = structure.id
WHERE structure.structure_cartographie_nationale_id IS NOT NULL
    AND structure.visible_pour_cartographie_nationale
    AND (
        -- Pas de lieu_activite connu → pas d'info sur l'activité → on garde
        NOT EXISTS (
            SELECT 1 FROM main.personne_affectations pa
            WHERE pa.structure_id = structure.id
                AND pa.type = 'lieu_activite'
                AND pa.est_active = TRUE
        )
        OR
        -- Au moins un médiateur/CN rattaché a un emploi actif (source non aidants-connect)
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
    );

NOTIFY pgrst, 'reload schema';
