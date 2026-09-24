-- Migration : refonte de api.get_carto_mediateur sur le modèle lieu_inclusion / SA
--
-- La fonction (derniere definition V063) lisait encore l'ancien modele
-- (main.personne_affectations type='lieu_activite' + main.structure). Elle
-- fonctionne toujours mais sur des tables legacy vouees au DROP (phase 6 de la
-- refonte). Cette migration la bascule sur le nouveau modele, comme api.carto :
--   - lieux  : personne_affectations_lieu -> lieu_inclusion
--   - pivot  : SIRET/RNA via lieu_inclusion_structure_administrative -> structure_administrative
--   - emploi : personne_affectations_emploi (filtre non-AC actif inchange)
--
-- Comportement strictement preserve : memes filtres (is_visible,
-- structure_cartographie_nationale_id NOT NULL + visible_pour_cartographie_nationale,
-- EXISTS structure_emploi non-AC actif), meme recherche trigramme, meme payload.

CREATE OR REPLACE FUNCTION api.get_carto_mediateur(name text)
RETURNS SETOF jsonb
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    SET pg_trgm.similarity_threshold = 0.5;

    RETURN QUERY
    SELECT jsonb_build_object(
        'nom', personne.nom,
        'prenom', personne.prenom,
        'lieux', jsonb_agg(
            jsonb_build_object(
            'id', li.structure_cartographie_nationale_id,
            'pivot', (COALESCE(
                (SELECT COALESCE(sa.siret, sa.rna)
                 FROM main.lieu_inclusion_structure_administrative asso
                 JOIN main.structure_administrative sa ON sa.id = asso.structure_administrative_id
                 WHERE asso.lieu_id = li.id
                 LIMIT 1),
                '00000000000000'::character varying))::character varying(14),
            'nom', li.nom,
            'commune', adresse.nom_commune,
            'code_postal', adresse.code_postal,
            'code_insee', adresse.code_insee,
            'adresse', concat_ws(' '::text, adresse.numero_voie, adresse.repetition, adresse.nom_voie),
            'complement_adresse', NULL::text,
            'latitude', st_y(adresse.geom),
            'longitude', st_x(adresse.geom)
            )
        )
    )
    FROM main.personne
    INNER JOIN main.personne_affectations_lieu AS lieux ON lieux.personne_id = personne.id
    INNER JOIN main.lieu_inclusion li ON li.id = lieux.lieu_id
    LEFT JOIN main.adresse ON li.adresse_id = adresse.id
    WHERE name % (personne.prenom || ' ' || personne.nom)
        AND personne.is_visible IS DISTINCT FROM FALSE
        AND li.structure_cartographie_nationale_id IS NOT NULL AND li.visible_pour_cartographie_nationale
        AND EXISTS (
            SELECT 1 FROM main.personne_affectations_emploi pa_emploi
            WHERE pa_emploi.personne_id = personne.id
                AND pa_emploi.est_active = true
                AND pa_emploi.source != 'aidants-connect'
        )
    GROUP BY personne.nom, personne.prenom
    ORDER BY similarity(personne.prenom || ' ' || personne.nom, name) DESC;
END;
$$;


COMMENT ON FUNCTION api.get_carto_mediateur IS $$Obtenir les lieux d'activité d'un médiateur à partir de ses nom et prénom.
L'ordre nom-prénom, prénom-nom n'a pas d'impact, la recherche est insensible à la casse et permissive à des fautes de frappe grâce à l'usage des trigrammes.
https://www.postgresql.org/docs/current/pgtrgm.html
Uniquement les personnes ayant un score de similarité > 0.5 (similarity_threshold = 0.5) seront prises en compte.
Les personnes ayant fait part de leur souhait de ne pas apparaître publiquement (is_visible = FALSE) ne sont pas prises en compte.
Les personnes sans structure_emploi non-AC actif sont également exclues (cohérence avec api.carto).
Lit le modèle lieu_inclusion / structure_administrative (refonte V098).$$;

GRANT EXECUTE ON FUNCTION api.get_carto_mediateur TO postgrest_anct_carto;

NOTIFY pgrst, 'reload schema';
