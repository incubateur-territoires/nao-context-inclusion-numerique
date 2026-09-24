-- V165 — SEPT #1940 : formaliser la règle « qui est visible sur la carte »
-- dans une vue dédiée, main.personne_visibilite_carto, consommée par api.carto.
--
-- ISO-COMPORTEMENT : aucune règle ne change. La vue reprend à l'identique le
-- CTE `personnes` de V164 (lieu actif, compte coop non supprimé, drapeau
-- is_visible, autorisation par l'emploi selon le profil CN / AC / autre
-- médiateur, labels, email, téléphone) mais expose CHAQUE critère dans une
-- colonne et un `motif_exclusion` lisible. api.carto se contente désormais
-- d'agréger les lignes `expose = true`.
--
-- Pourquoi : la règle était recalculée dans api.carto à partir de flags
-- eux-mêmes calculés dans trois DAGs et par la coop (personne_affectations_
-- emploi). Une vue unique la rend interrogeable (compter les exclus par motif,
-- vérifier un cas) et testable (tests/carto/cas_visibilite.yml).
--
-- Grain : une ligne par (personne, lieu) de main.personne_affectations_lieu,
-- active ou non — les lignes non exposées portent le motif.
-- Les critères côté lieu (identifiant carto, visible_pour_cartographie_
-- nationale, deleted_at) restent dans api.carto : ils ne concernent pas la
-- personne.
--
-- Bloc défensif (doctrine V151/V164) : sans schéma coop (CI/base neuve), rien
-- n'est créé et api.carto reste telle quelle.

DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V165 ignorée.';
        RETURN;
    END IF;

    -- 1) La règle, critère par critère
    EXECUTE $v0$
    CREATE OR REPLACE VIEW main.personne_visibilite_carto AS
    SELECT s.personne_id,
           s.lieu_id,
           s.prenom,
           s.nom,
           s.lieu_actif,
           s.compte_coop_actif,
           s.visible_coop,
           s.est_cn,
           s.est_ac,
           s.a_emploi_actif_non_ac,
           s.emploi_autorise,
           (s.lieu_actif AND s.compte_coop_actif AND s.visible_coop AND s.emploi_autorise) AS expose,
           CASE
               WHEN NOT s.lieu_actif        THEN 'lieu_inactif'
               WHEN NOT s.compte_coop_actif THEN 'compte_coop_supprime'
               WHEN NOT s.visible_coop      THEN 'masque_coop'
               WHEN NOT s.emploi_autorise   THEN 'cn_sans_emploi_actif'
           END AS motif_exclusion,
           ARRAY( SELECT labels.lbl
                  FROM ( SELECT 1 AS ord, 'Conseiller Numerique'::text AS lbl WHERE s.est_cn
                         UNION ALL
                         SELECT 2, 'Aidant Connect'::text WHERE s.est_ac
                         UNION ALL
                         SELECT 3, 'Médiateur numérique'::text WHERE NOT s.est_cn AND NOT s.est_ac) labels
                  ORDER BY labels.ord) AS label,
           s.email,
           s.telephone
    FROM ( SELECT pal.personne_id,
                  pal.lieu_id,
                  p.prenom,
                  p.nom,
                  pal.est_active AS lieu_actif,
                  (u.deleted IS NULL) AS compte_coop_actif,
                  (m.is_visible IS DISTINCT FROM false) AS visible_coop,
                  flags.est_cn,
                  flags.est_ac,
                  flags.a_emploi_actif_non_ac,
                  (flags.est_ac
                   OR flags.est_cn AND flags.a_emploi_actif_non_ac
                   OR NOT flags.est_cn AND NOT flags.est_ac) AS emploi_autorise,
                  COALESCE(NULLIF(btrim(u.email), ''::text),
                           (p.contact -> 'idposte'::text) ->> 'mail_pro'::text,
                           (p.contact -> 'idposte'::text) ->> 'mail_perso'::text) AS email,
                  COALESCE(main.normaliser_telephone(u.phone),
                           (p.contact -> 'idposte'::text) ->> 'telephone'::text) AS telephone
           FROM main.personne_affectations_lieu pal
           JOIN main.personne p ON p.id = pal.personne_id
           JOIN coop.users u ON u.id = p.coop_id
           JOIN coop.mediateurs m ON m.user_id = u.id
           CROSS JOIN LATERAL (
               SELECT p.conseiller_numerique_id IS NOT NULL OR p.cn_pg_id IS NOT NULL AS est_cn,
                      (EXISTS ( SELECT 1 FROM main.personne_affectations_emploi pa_ac
                                WHERE pa_ac.personne_id = p.id
                                  AND pa_ac.source::text = 'aidants-connect'::text
                                  AND pa_ac.est_active = true)) AS est_ac,
                      (EXISTS ( SELECT 1 FROM main.personne_affectations_emploi pa_emp
                                WHERE pa_emp.personne_id = p.id
                                  AND pa_emp.est_active = true
                                  AND pa_emp.source::text <> 'aidants-connect'::text)) AS a_emploi_actif_non_ac
           ) flags
         ) s
    $v0$;

    EXECUTE $c0$ COMMENT ON VIEW main.personne_visibilite_carto IS $t0$ Règle de visibilité d'une personne sur la cartographie nationale (V165, SEPT #1940), une ligne par (personne, lieu) de main.personne_affectations_lieu. `expose` = tous les critères personne réunis ; `motif_exclusion` = premier critère en défaut (lieu_inactif, compte_coop_supprime, masque_coop, cn_sans_emploi_actif). Les critères côté lieu restent dans api.carto. Iso-comportement V164. Spécification exécutable : tests/carto/cas_visibilite.yml. $t0$ $c0$;
    EXECUTE $c1$ COMMENT ON COLUMN main.personne_visibilite_carto.lieu_actif IS 'Affectation lieu active (coop.mediateurs_en_activite non supprimée, fin_activite non passée).' $c1$;
    EXECUTE $c2$ COMMENT ON COLUMN main.personne_visibilite_carto.compte_coop_actif IS 'coop.users.deleted IS NULL.' $c2$;
    EXECUTE $c3$ COMMENT ON COLUMN main.personne_visibilite_carto.visible_coop IS 'coop.mediateurs.is_visible non faux (drapeau posé par le médiateur).' $c3$;
    EXECUTE $c4$ COMMENT ON COLUMN main.personne_visibilite_carto.est_cn IS 'Conseiller numérique : conseiller_numerique_id ou cn_pg_id renseigné sur main.personne.' $c4$;
    EXECUTE $c5$ COMMENT ON COLUMN main.personne_visibilite_carto.est_ac IS 'Affectation emploi source aidants-connect active.' $c5$;
    EXECUTE $c6$ COMMENT ON COLUMN main.personne_visibilite_carto.a_emploi_actif_non_ac IS 'Affectation emploi active de source idposte ou coop.' $c6$;
    EXECUTE $c7$ COMMENT ON COLUMN main.personne_visibilite_carto.emploi_autorise IS 'AC actif, OU CN avec emploi actif non-AC, OU ni CN ni AC (autre médiateur, sans condition).' $c7$;

    -- 2) api.carto : le CTE personnes agrège la vue (colonnes et OID inchangés)
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
  WHERE li.structure_cartographie_nationale_id IS NOT NULL AND li.visible_pour_cartographie_nationale = true
   AND (li.structure_coop_id IS NULL OR li.deleted_at IS NULL)
    $v1$;

    EXECUTE $c8$ COMMENT ON VIEW api.carto IS $t8$ Vue cartographie publique — LA photo du dataspace (V162, SEPT #1724) : lecture pure du référentiel main.lieu_inclusion. `mediateurs` : agrégation de main.personne_visibilite_carto (V165, SEPT #1940 — règle de visibilité formalisée, iso V164 : coordonnées et visibilité lues en direct dans la coop, #1868). `pivot` non renseigné depuis #1711. $t8$ $c8$;
END
$mig$;

NOTIFY pgrst, 'reload schema';
