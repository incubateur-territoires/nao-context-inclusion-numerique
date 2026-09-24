-- Migration : refonte de api.get_mediateur sur le modèle SA / lieu_inclusion
--
-- La dernière définition (V047) lisait l'ancien modèle (main.personne_affectations
-- + main.structure) et la table main.contact_structure, renommée en V080 en
-- main.contact_structure_administrative. Conséquence : depuis V080 tout appel à
-- api.get_mediateur échouait (« relation "main.contact_structure" does not exist »).
-- De plus la sous-requête 'contrats' comparait main.contrat.structure_id (FK vers
-- main.structure_administrative depuis la refonte) à main.structure.id : 100 % des
-- contrats étaient invisibles.
--
-- Cette migration refond la fonction sur le nouveau modèle (cf. docs/refonte-structure-plan.md, §344) :
--   - structures_employeuses : personne_affectations_emploi -> structure_administrative
--     (dédupliqué par structure_administrative_id : une même SA peut être pointée
--      par plusieurs affectations source)
--   - lieux_activite        : personne_affectations_lieu -> lieu_inclusion
--                             (-> lieu_inclusion_structure_administrative -> structure_administrative
--                              pour le SIRET et les contacts de gouvernance)
--   - contrats              : contrat.structure_id = structure_administrative.id (jointure naturelle)
--   - contacts              : main.contact_structure_administrative
-- Le payload conserve la même structure (structures_employeuses[], lieux_activite[]).

CREATE OR REPLACE FUNCTION api.get_mediateur(email text)
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    var_personne_id integer;
BEGIN
    -- Rechercher la personne par email (toutes sources)
    SELECT p.id
    INTO var_personne_id
    FROM main.personne p
    WHERE p.contact -> 'coop' ->> 'email' = email
       OR p.contact -> 'idposte' ->> 'mail_pro' = email
       OR p.contact -> 'idposte' ->> 'mail_perso' = email
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
        SELECT pae.personne_id,
            jsonb_agg(
                jsonb_build_object(
                    'ids', jsonb_build_object(
                        'dataspace', sa.id,
                        'aidant_connect', sa.structure_ac_id,
                        'coop', sa.structure_coop_id,
                        'pg_id', sa.structure_tp_id),
                    'siret', sa.siret,
                    'nom', COALESCE(sa.denomination_antenne, sa.denomination_sirene),
                    'contacts', (
                        SELECT COALESCE(jsonb_agg(
                            jsonb_build_object(
                                'nom', c.nom,
                                'prenom', c.prenom,
                                'email', c.email,
                                'telephone', c.telephone,
                                'fonction', c.fonction,
                                'est_referent_fne', c.est_referent_fne
                            )
                        ), '[]'::jsonb)
                        FROM main.contact_structure_administrative cs
                        JOIN main.contact c ON c.id = cs.contact_id
                        WHERE cs.structure_administrative_id = sa.id
                    ),
                    'adresse', jsonb_build_object(
                        'code_postal', adresse.code_postal,
                        'code_insee', adresse.code_insee,
                        'nom_commune', adresse.nom_commune,
                        'nom_voie', adresse.nom_voie,
                        'repetition', adresse.repetition,
                        'numero_voie', adresse.numero_voie
                    ),
                    'contrats', (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'date_debut', contrat.date_debut,
                                'date_fin', contrat.date_fin,
                                'date_rupture', contrat.date_rupture,
                                'type', contrat.type
                            )
                        )
                        FROM main.contrat
                        WHERE (contrat.structure_id = sa.id OR contrat.structure_id IS NULL)
                          AND contrat.personne_id = pae.personne_id
                    )
                )
            ) AS structures
        FROM (
            SELECT DISTINCT personne_id, structure_administrative_id
            FROM main.personne_affectations_emploi
            WHERE personne_id = var_personne_id
        ) pae
        INNER JOIN main.structure_administrative sa ON sa.id = pae.structure_administrative_id
        LEFT JOIN main.adresse adresse ON adresse.id = sa.adresse_id
        GROUP BY pae.personne_id
    ),
    lieux_activite AS (
        SELECT pal.personne_id,
        jsonb_agg(
            jsonb_build_object(
                'siret', (
                    SELECT sa.siret
                    FROM main.lieu_inclusion_structure_administrative asso
                    JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
                    WHERE asso.lieu_id = li.id
                    LIMIT 1
                ),
                'nom', li.nom,
                'contacts', (
                    SELECT COALESCE(jsonb_agg(
                        jsonb_build_object(
                            'nom', c.nom,
                            'prenom', c.prenom,
                            'email', c.email,
                            'telephone', c.telephone,
                            'fonction', c.fonction,
                            'est_referent_fne', c.est_referent_fne
                        )
                    ), '[]'::jsonb)
                    FROM main.lieu_inclusion_structure_administrative asso
                    JOIN main.contact_structure_administrative cs ON cs.structure_administrative_id = asso.structure_administrative_id
                    JOIN main.contact c ON c.id = cs.contact_id
                    WHERE asso.lieu_id = li.id
                ),
                'adresse', jsonb_build_object(
                    'code_postal', adresse.code_postal,
                    'code_insee', adresse.code_insee,
                    'nom_commune', adresse.nom_commune,
                    'nom_voie', adresse.nom_voie,
                    'repetition', adresse.repetition,
                    'numero_voie', adresse.numero_voie
                ),
                'id_carto', li.structure_cartographie_nationale_id
            )
        ) AS lieux
        FROM main.personne_affectations_lieu pal
        INNER JOIN main.lieu_inclusion li ON li.id = pal.lieu_id
        LEFT JOIN main.adresse adresse ON adresse.id = li.adresse_id
        WHERE pal.personne_id = var_personne_id
        GROUP BY pal.personne_id
    ),
    is_cn AS (
        SELECT pae.personne_id
        FROM main.personne_affectations_emploi pae
        WHERE pae.personne_id = var_personne_id
        AND pae.source = 'idposte'
        AND pae.est_active = TRUE
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
$function$;

NOTIFY pgrst, 'reload schema';
