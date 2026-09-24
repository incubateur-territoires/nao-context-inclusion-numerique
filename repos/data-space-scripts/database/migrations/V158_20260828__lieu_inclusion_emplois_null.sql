-- ============================================================
-- V158 – SEPT #1707 : main.lieu_inclusion.emplois passe à NULL pour les
--   lignes coop (plus de dépendance à coop.employes_structures).
-- ============================================================
-- V155 calculait, pour les lignes coop de la vue d'union, `emplois` par
-- count(*) sur coop.employes_structures (jointure es.structure_id = cl.id,
-- uuid partagé lieu/employeuse hérité du split coop). Cette table est
-- ABANDONNÉE par la coop depuis la bascule « pur main » (#1707, août 2026 :
-- plus aucune écriture, dernière ligne le 2026-08-06) et sera droppée à
-- l'échange final → compteur figé aujourd'hui, vue cassée demain.
--
-- Recompter depuis main (structure_administrative.structure_coop_id = cl.id
-- → personne_affectations_emploi actives) ne couvrirait que le stock
-- (3 127 lieux sur 12 712 partagent un uuid avec une SA main ; les nouvelles
-- SA n'ont plus de structure_coop_id) et perpétuerait un lien lieu↔SA que
-- #1711 a déjà écarté. Un compteur d'emplois est une notion d'employeuse,
-- pas de lieu : NULL, comme dataviz.structures.
--
-- Aucun consommateur de la colonne (vérifié 2026-08-28 : pg_views api /
-- dataviz / min / llm, code MIN, DAGs). `mediateurs_en_activite` reste calculé
-- depuis coop.mediateurs_en_activite (table vivante). Les lignes non-coop
-- continuent de lire r.emplois (registre).
--
-- CREATE OR REPLACE : mêmes colonnes, mêmes types → le trigger INSTEAD OF
-- UPDATE (lieu_inclusion_vue_update_tg, V153) et les grants sont conservés.
--
-- Même garde que V153/V155 : sur une base sans schéma coop (CI, base
-- neuve) le registre et la vue d'union n'existent pas → no-op.
-- ------------------------------------------------------------

DO $lot$
BEGIN
    IF to_regclass('coop.lieu_inclusion') IS NULL
       OR to_regclass('main.lieu_inclusion_registre') IS NULL THEN
        RAISE NOTICE 'Schéma coop ou registre absent (CI/base neuve) : vue ignorée.';
        RETURN;
    END IF;

    EXECUTE $vue$
CREATE OR REPLACE VIEW main.lieu_inclusion AS
 SELECT r.id,
    r.old_main_structure_id,
    cl.nom::character varying AS nom,
    r.adresse_id,
    r.structure_cartographie_nationale_id,
    r.visible_pour_cartographie_nationale IS TRUE AND cl.visible_pour_cartographie_nationale IS TRUE AS visible_pour_cartographie_nationale,
    NULLIF(cl.fiche_acces_libre, ''::text)::character varying AS fiche_acces_libre,
    NULLIF(cl.presentation_resume, ''::text) AS presentation_resume,
    NULLIF(cl.presentation_detail, ''::text) AS presentation_detail,
    NULLIF(cl.horaires, ''::text)::character varying AS horaires,
    NULLIF(cl.prise_rdv, ''::text)::character varying AS prise_rdv,
    NULLIF(cl.itinerance::text[], '{}'::text[])::main.itinerance[] AS itinerance,
    NULLIF(cl.services::text[], '{}'::text[])::main.service[] AS services,
    NULLIF(cl.modalites_acces::text[], '{}'::text[])::main.modalite_acces[] AS modalites_acces,
    NULLIF(cl.modalites_accompagnement::text[], '{}'::text[])::main.modalite_accompagnement[] AS modalites_accompagnement,
    NULLIF(cl.publics_specifiquement_adresses::text[], '{}'::text[])::main.public_specifiquement_adresse[] AS publics_specifiquement_adresses,
    NULLIF(cl.prise_en_charge_specifique::text[], '{}'::text[])::main.prise_en_charge_specifique[] AS prise_en_charge_specifique,
    NULLIF(cl.frais_a_charge::text[], '{}'::text[])::main.frais_a_charge[] AS frais_a_charge,
    NULLIF(cl.formations_labels::text[], '{}'::text[])::main.formation_label[] AS formations_labels,
    NULLIF(cl.autres_formations_labels, '{}'::text[]) AS autres_formations_labels,
    NULLIF(cl.dispositif_programmes_nationaux::text[], '{}'::text[])::main.dispositif_programme_national[] AS dispositif_programmes_nationaux,
    NULLIF(cl.typologies::text[], '{}'::text[])::main.typologie[] AS typologies,
    jsonb_strip_nulls(jsonb_build_object('telephone', NULLIF(cl.telephone, ''::text), 'courriels',
        CASE
            WHEN cl.courriels IS NOT NULL AND array_length(cl.courriels, 1) > 0 THEN jsonb_build_object('email', array_to_string(cl.courriels, '|'::text))
            ELSE NULL::jsonb
        END, 'site_web', NULLIF(cl.site_web, ''::text))) AS contact,
    (SELECT count(*) FROM coop.mediateurs_en_activite mea
      WHERE mea.structure_id = cl.id
        AND mea.suppression IS NULL AND mea.fin_activite IS NULL)::integer AS mediateurs_en_activite,
    -- V158 : plus de compteur d'emplois par lieu (NULL, comme dataviz.structures).
    -- coop.employes_structures est figée depuis la bascule #1707 et promise au
    -- DROP ; le pont lieu↔employeuse par uuid partagé ne couvre que le stock.
    NULL::integer AS emplois,
    r.source,
    r.edited_by,
    r.created_at,
    r.structure_coop_id,
    r.import_warnings,
    r.updated_at_carto,
    GREATEST(r.updated_at_coop, cl.modification) AS updated_at_coop,
    r.updated_at_min,
    GREATEST(r.updated_at_carto, GREATEST(r.updated_at_coop, cl.modification), r.updated_at_min) AS updated_at,
    r.complement_adresse,
    r.siret_a_l_enrichissement,
    r.nom_usage,
    r.deleted_at
   FROM main.lieu_inclusion_registre r
     JOIN coop.lieu_inclusion cl ON cl.id = r.structure_coop_id
  WHERE r.structure_coop_id IS NOT NULL AND cl.suppression IS NULL
UNION ALL
 SELECT r.id,
    r.old_main_structure_id,
    r.nom,
    r.adresse_id,
    r.structure_cartographie_nationale_id,
    r.visible_pour_cartographie_nationale,
    r.fiche_acces_libre,
    r.presentation_resume,
    r.presentation_detail,
    r.horaires,
    r.prise_rdv,
    r.itinerance,
    r.services,
    r.modalites_acces,
    r.modalites_accompagnement,
    r.publics_specifiquement_adresses,
    r.prise_en_charge_specifique,
    r.frais_a_charge,
    r.formations_labels,
    r.autres_formations_labels,
    r.dispositif_programmes_nationaux,
    r.typologies,
    r.contact,
    r.mediateurs_en_activite,
    r.emplois,
    r.source,
    r.edited_by,
    r.created_at,
    r.structure_coop_id,
    r.import_warnings,
    r.updated_at_carto,
    r.updated_at_coop,
    r.updated_at_min,
    r.updated_at,
    r.complement_adresse,
    r.siret_a_l_enrichissement,
    r.nom_usage,
    r.deleted_at
   FROM main.lieu_inclusion_registre r
  WHERE r.structure_coop_id IS NULL;
    $vue$;
END
$lot$;
