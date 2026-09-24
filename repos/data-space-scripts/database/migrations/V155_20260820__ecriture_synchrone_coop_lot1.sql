-- V155 : lot 1 de l'écriture synchrone coop (SEPT #1724 — contrat accepté
-- par l'équipe coop le 2026-08-20, cf. dataspace/contrat_coop_ecriture_lieux_20260820.md).
--
-- 1) main.trouver_ou_creer_adresse_lieu(...) : la fonction que l'app coop
--    appellera à la création / au changement d'adresse d'un lieu, pour
--    résoudre ou créer main.adresse selon NOS conventions (parsing
--    numéro/voie et clef naturelle alignés sur integration_adresses du
--    carto-dag). SECURITY DEFINER : l'appelant n'a besoin d'aucun droit sur
--    main.adresse.
-- 2) Droits du rôle coop sur le registre : SELECT + INSERT/UPDATE limités
--    aux COLONNES D'IDENTITÉ (structure_coop_id, adresse_id, nom initial —
--    NOT NULL —, edited_by, updated_at_coop). Les colonnes métier restent
--    interdites (archive gelée) — le contrat est appliqué par PostgreSQL.
-- 3) La branche coop de la vue main.lieu_inclusion :
--    - exclut désormais les lieux supprimés côté coop (cl.suppression) —
--      la fiche disparaît, la ligne registre reste (mémoire d'identité) ;
--    - sert des compteurs CALCULÉS depuis coop.mediateurs_en_activite /
--      coop.employes_structures (plus de dépendance aux compteurs
--      dénormalisés du registre, qui gèleront avec le coop-dag).
--
-- Bloc défensif (doctrine V144/V151/V153) : sans schéma coop (CI/base
-- neuve), seuls la fonction est créée — grants et vue sont ignorés.

CREATE OR REPLACE FUNCTION main.trouver_ou_creer_adresse_lieu(
    p_adresse text,
    p_code_postal text,
    p_commune text,
    p_code_insee text,
    p_latitude double precision DEFAULT NULL,
    p_longitude double precision DEFAULT NULL,
    p_ban_id text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = main, public, pg_temp
AS $fn$
DECLARE
    v_numero smallint;
    v_voie   text;
    v_id     integer;
BEGIN
    IF p_code_insee IS NULL OR btrim(p_code_insee) = '' THEN
        RAISE EXCEPTION 'trouver_ou_creer_adresse_lieu : code_insee obligatoire';
    END IF;
    IF p_code_postal IS NULL OR btrim(p_code_postal) = ''
       OR p_commune IS NULL OR btrim(p_commune) = '' THEN
        RAISE EXCEPTION 'trouver_ou_creer_adresse_lieu : code_postal et commune obligatoires';
    END IF;

    -- Parsing aligné sur integration_adresses (carto-dag) : un préfixe
    -- numérique > 32767 (code postal collé) est traité comme partie de la voie.
    IF p_adresse IS NOT NULL AND btrim(p_adresse) <> '' THEN
        IF COALESCE((regexp_match(p_adresse, '^(\d+)'))[1]::int, 0) <= 32767 THEN
            v_numero := (regexp_match(p_adresse, '^(\d+)\s*(bis|ter|quater|quinquies)?\s+(.*)$', 'i'))[1]::smallint;
            v_voie   := initcap((regexp_match(p_adresse, '^(?:\d+\s+)?(.*)$'))[1]);
        ELSE
            v_voie := initcap(btrim(p_adresse));
        END IF;
    END IF;

    -- Lookup prioritaire par clef d'interopérabilité BAN (le ban_id coop est
    -- une clef interop, ex. « 75111_0272_00102 » — même sémantique que
    -- main.adresse.clef_interop, et même priorité que l'ancien coop-dag).
    IF p_ban_id IS NOT NULL AND btrim(p_ban_id) <> '' THEN
        SELECT a.id INTO v_id FROM main.adresse a
        WHERE a.clef_interop = p_ban_id
        LIMIT 1;
        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;
    END IF;

    SELECT a.id INTO v_id
    FROM main.adresse a
    WHERE a.code_postal = p_code_postal
      AND a.nom_commune = p_commune
      AND a.nom_voie IS NOT DISTINCT FROM v_voie
      AND COALESCE(a.numero_voie, 0) = COALESCE(v_numero, 0)
      AND COALESCE(a.repetition, '') = ''
    LIMIT 1;
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;

    INSERT INTO main.adresse (geom, clef_interop, numero_voie, repetition, nom_voie,
                              code_postal, nom_commune, code_insee)
    VALUES (CASE WHEN p_longitude IS NOT NULL AND p_latitude IS NOT NULL
                 THEN public.ST_SetSRID(public.ST_MakePoint(p_longitude, p_latitude), 4326)
            END,
            NULLIF(btrim(p_ban_id), ''), v_numero, '', v_voie,
            p_code_postal, p_commune, p_code_insee)
    ON CONFLICT (code_postal, nom_commune, nom_voie, COALESCE(numero_voie, 0), COALESCE(repetition, ''))
    DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
        -- course perdue contre un INSERT concurrent : re-lookup
        SELECT a.id INTO v_id
        FROM main.adresse a
        WHERE a.code_postal = p_code_postal
          AND a.nom_commune = p_commune
          AND a.nom_voie IS NOT DISTINCT FROM v_voie
          AND COALESCE(a.numero_voie, 0) = COALESCE(v_numero, 0)
          AND COALESCE(a.repetition, '') = '';
    END IF;
    RETURN v_id;
END
$fn$;

COMMENT ON FUNCTION main.trouver_ou_creer_adresse_lieu(text, text, text, text, double precision, double precision, text) IS
    'Résout ou crée une main.adresse selon les conventions de l''entrepôt '
    '(parsing numéro/voie et clef naturelle alignés sur integration_adresses). '
    'p_ban_id = clef d''interopérabilité BAN (stockée en clef_interop, lookup prioritaire). '
    'Appelée par l''app coop à la création / au changement d''adresse d''un '
    'lieu (contrat d''écriture synchrone, SEPT #1724). SECURITY DEFINER, '
    'idempotente, sûre en concurrence.';

DO $lot$
BEGIN
    IF to_regclass('coop.lieu_inclusion') IS NULL
       OR to_regclass('main.lieu_inclusion_registre') IS NULL THEN
        RAISE NOTICE 'Schéma coop ou registre absent (CI/base neuve) : grants et vue ignorés.';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coop') THEN
        EXECUTE 'GRANT EXECUTE ON FUNCTION main.trouver_ou_creer_adresse_lieu(text, text, text, text, double precision, double precision, text) TO coop';
        EXECUTE 'GRANT SELECT ON main.lieu_inclusion_registre TO coop';
        EXECUTE 'GRANT INSERT (structure_coop_id, adresse_id, nom, edited_by, updated_at_coop) ON main.lieu_inclusion_registre TO coop';
        EXECUTE 'GRANT UPDATE (adresse_id, edited_by, updated_at_coop) ON main.lieu_inclusion_registre TO coop';
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
    (SELECT count(*) FROM coop.employes_structures es
      WHERE es.structure_id = cl.id
        AND es.suppression IS NULL AND es.fin_emploi IS NULL)::integer AS emplois,
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
