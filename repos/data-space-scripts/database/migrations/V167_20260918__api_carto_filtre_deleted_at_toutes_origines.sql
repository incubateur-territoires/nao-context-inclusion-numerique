-- V167 — api.carto : un lieu supprimé (deleted_at) n'est plus servi, quelle que
-- soit son origine (SEPT #1950).
--
-- Avant (V162 → V165) le filtre `deleted_at` ne visait que les lignes coop
-- (`structure_coop_id IS NULL OR deleted_at IS NULL`) : une ligne mednum
-- supprimée depuis MIN restait servie dès que son drapeau visible était vrai —
-- et le carto-dag la rallumait chaque nuit (corrigé dans le même lot, cf.
-- etl/load/carto_integration_lieux.py).
--
-- Doctrine « l'état d'un lieu n'est pas une donnée »
-- (docs/cycle-de-vie-lieux-personnes.md §1.3) : la suppression est une décision
-- de gestion (Coop ou MIN) ; la carte la respecte pour toutes les lignes.
--
-- Seul le WHERE change : colonnes, types et ordre identiques à V165 →
-- CREATE OR REPLACE conserve l'OID et les GRANT (postgrest_anct_carto,
-- postgrest_anct_data_incl). Bloc défensif identique à V165 : sur une base
-- sans schéma coop (CI test_migration), la vue V165 n'existe pas → no-op.
-- Spécification exécutable : tests/carto/cas_cycle_de_vie_lieux.yml
-- (cas `min_supprime_mais_visible`, `coop_supprime_present`).

DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V167 ignorée.';
        RETURN;
    END IF;

    EXECUTE $v1$
    CREATE OR REPLACE VIEW api.carto AS
 WITH courriels AS (
         SELECT li_1.id,
            string_agg(v.value, '|'::text) AS courriels_concat
           FROM main.lieu_inclusion li_1,
            LATERAL jsonb_each_text(jsonb_extract_path(li_1.contact, VARIADIC ARRAY['courriels'::text])) v(key, value)
          WHERE v.key = 'email'::text
          GROUP BY li_1.id
        ), personnes AS (
         SELECT pv.lieu_id,
            jsonb_strip_nulls(jsonb_agg(jsonb_build_object('prenom', pv.prenom, 'nom', pv.nom, 'label', pv.label, 'email', pv.email, 'telephone', pv.telephone))) AS mediateurs
           FROM main.personne_visibilite_carto pv
          WHERE pv.expose
          GROUP BY pv.lieu_id
        )
 SELECT li.structure_cartographie_nationale_id AS id,
    '00000000000000'::character varying(14) AS pivot,
    li.nom,
    jsonb_build_object('numero_voie', a.numero_voie, 'repetition', a.repetition, 'nom_voie', a.nom_voie, 'code_postal', a.code_postal, 'commune', a.nom_commune, 'code_insee', a.code_insee) AS adresse,
    st_y(a.geom) AS latitude,
    st_x(a.geom) AS longitude,
    li.typologies AS typologie,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['telephone'::text]) AS telephone,
    courriels.courriels_concat AS courriels,
    jsonb_extract_path_text(li.contact, VARIADIC ARRAY['site_web'::text]) AS site_web,
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
     LEFT JOIN courriels ON courriels.id = li.id
     LEFT JOIN personnes ON personnes.lieu_id = li.id
  WHERE li.structure_cartographie_nationale_id IS NOT NULL
    AND li.visible_pour_cartographie_nationale = true
    AND li.deleted_at IS NULL
    $v1$;

    EXECUTE $c8$ COMMENT ON VIEW api.carto IS $t8$ Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion. `mediateurs` : agrégation de main.personne_visibilite_carto (V165, SEPT #1940 — règle de visibilité formalisée, iso V164 : coordonnées et visibilité lues en direct dans la coop, #1868). Un lieu s'affiche s'il est référencé (carto_id), visible et non supprimé — deleted_at filtré pour TOUTES les origines depuis V167 (SEPT #1950 : l'état d'un lieu appartient aux outils de gestion). `pivot` non renseigné depuis #1711. $t8$ $c8$;
END
$mig$;

NOTIFY pgrst, 'reload schema';
