-- V176 — SEPT #1724 : la coop s'aligne sur le standard national
-- (@gouvfr-anct/lieux-de-mediation-numerique, migration Prisma coop
-- `20260921190000_alignement_standard`). Trois effets côté main.
--
-- 1. `coop.lieu_inclusion.site_web` devient `text[]` (plusieurs adresses
--    jointes par « | » dans un texte jusqu'ici, comme `courriels` avant lui).
--    La coop convertit par colonne intermédiaire : ADD, UPDATE, DROP de
--    l'ancienne, RENAME — PostgreSQL refuse une sous-requête dans le USING
--    d'un changement de type. Or `main.lieu_divergences_coop` (V161 → V166)
--    lit `NULLIF(cl.site_web, '')` : le DROP échoue (« cannot drop column
--    site_web … because other objects depend on it »). Constaté sur une copie
--    restaurée de la prod le 2026-09-23 : la prochaine MEP coop échouerait.
--
--    La vue lit désormais `site_web` par `to_jsonb(cl)` — une référence à la
--    ligne entière, pas à la colonne : elle ne dépend plus de son type, et
--    rend la même valeur (adresses jointes par « | ») que la colonne soit
--    texte ou liste. V176 peut donc passer AVANT la coop, sans coordination
--    de date. Une fois la coop déployée, un `array_to_string(cl.site_web,
--    '|')` suffira ; à simplifier dans une migration ultérieure.
--
-- 2. `main.modalite_acces` : « Ce lieu n’accueille pas de public » passe de
--    l'apostrophe typographique U+2019 à l'apostrophe droite U+0027, celle du
--    standard national, que la coop écrit désormais (V122 avait repris
--    verbatim les @map Prisma coop de l'époque, U+2019 compris).
--
-- 3. `main.formation_label` gagne « Étapes numériques (La Poste) », ajouté
--    au standard.
--
-- Sans 2 et 3, la double écriture coop et le cast `::main.<enum>[]` du filet
-- échouent au premier lieu portant l'une de ces valeurs. Les deux enums
-- redeviennent identiques entre coop et main (mêmes libellés, même ordre).
-- Au 2026-09-23, aucune ligne de main.lieu_inclusion ne porte le libellé
-- renommé, et aucune fonction ni vue ne le cite en dur.
--
-- ⚠️ Reste à adapter hors base : `etl/load/registre_lieux_coop.py` compare
-- `NULLIF(cl.site_web, '')` (deux occurrences) et échouera après la MEP coop ;
-- tout code qui écrit le libellé U+2019.
--
-- ADD VALUE dans une transaction : admis depuis PostgreSQL 12, tant que la
-- nouvelle valeur n'est pas utilisée dans la même transaction (c'est le cas).
--
-- Enums : blocs gardés, la migration est rejouable. Vue : bloc défensif
-- (doctrine V144/V151/V153) — sans schéma coop, recréation ignorée.

DO $mig$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_enum
        WHERE enumtypid = to_regtype('main.modalite_acces')
          AND enumlabel = 'Ce lieu n’accueille pas de public'
    ) THEN
        EXECUTE $e$
        ALTER TYPE main.modalite_acces
            RENAME VALUE 'Ce lieu n’accueille pas de public' TO 'Ce lieu n''accueille pas de public'
        $e$;
    END IF;

    IF to_regtype('main.formation_label') IS NOT NULL THEN
        EXECUTE $e$
        ALTER TYPE main.formation_label ADD VALUE IF NOT EXISTS 'Étapes numériques (La Poste)'
        $e$;
    END IF;

    IF to_regclass('coop.lieu_inclusion') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V176, vue main.lieu_divergences_coop ignorée.';
        RETURN;
    END IF;

    EXECUTE $v$
    CREATE OR REPLACE VIEW main.lieu_divergences_coop AS
    SELECT r.id                AS lieu_id,
           cl.id               AS structure_coop_id,
           cl.nom              AS nom_coop,
           d.champ,
           d.valeur_referentiel,
           d.valeur_coop,
           r.edited_by         AS referentiel_edited_by,
           r.updated_at        AS referentiel_updated_at,
           cl.modification     AS coop_modification
    FROM main.lieu_inclusion r
    JOIN coop.lieu_inclusion cl ON cl.id = r.structure_coop_id
    CROSS JOIN LATERAL (VALUES
        ('nom',                             r.nom::text,                                cl.nom),
        ('fiche_acces_libre',               r.fiche_acces_libre::text,                  NULLIF(cl.fiche_acces_libre, '')),
        ('presentation_resume',             r.presentation_resume,                      NULLIF(cl.presentation_resume, '')),
        ('presentation_detail',             r.presentation_detail,                      NULLIF(cl.presentation_detail, '')),
        ('horaires',                        r.horaires::text,                           NULLIF(cl.horaires, '')),
        ('prise_rdv',                       r.prise_rdv::text,                          NULLIF(cl.prise_rdv, '')),
        ('itinerance',                      NULLIF(r.itinerance::text, '{}'),           NULLIF(cl.itinerance::text[], '{}')::text),
        ('services',                        NULLIF(r.services::text, '{}'),             NULLIF(cl.services::text[], '{}')::text),
        ('modalites_acces',                 NULLIF(r.modalites_acces::text, '{}'),      NULLIF(cl.modalites_acces::text[], '{}')::text),
        ('modalites_accompagnement',        NULLIF(r.modalites_accompagnement::text, '{}'), NULLIF(cl.modalites_accompagnement::text[], '{}')::text),
        ('publics_specifiquement_adresses', NULLIF(r.publics_specifiquement_adresses::text, '{}'), NULLIF(cl.publics_specifiquement_adresses::text[], '{}')::text),
        ('prise_en_charge_specifique',      NULLIF(r.prise_en_charge_specifique::text, '{}'), NULLIF(cl.prise_en_charge_specifique::text[], '{}')::text),
        ('frais_a_charge',                  NULLIF(r.frais_a_charge::text, '{}'),       NULLIF(cl.frais_a_charge::text[], '{}')::text),
        ('formations_labels',               NULLIF(r.formations_labels::text, '{}'),    NULLIF(cl.formations_labels::text[], '{}')::text),
        ('autres_formations_labels',        NULLIF(r.autres_formations_labels::text, '{}'), NULLIF(cl.autres_formations_labels, '{}')::text),
        ('dispositif_programmes_nationaux', NULLIF(r.dispositif_programmes_nationaux::text, '{}'), NULLIF(cl.dispositif_programmes_nationaux::text[], '{}')::text),
        ('typologies',                      NULLIF(r.typologies::text, '{}'),           NULLIF(cl.typologies::text[], '{}')::text),
        ('contact.telephone',               r.contact->>'telephone',                    NULLIF(cl.telephone, '')),
        ('contact.courriels',               r.contact->'courriels'->>'email',
             CASE WHEN cl.courriels IS NOT NULL AND array_length(cl.courriels, 1) > 0
                  THEN array_to_string(cl.courriels, '|') END),
        ('contact.site_web',                r.contact->>'site_web',
             CASE jsonb_typeof(to_jsonb(cl)->'site_web')
                  WHEN 'array'
                  THEN NULLIF(array_to_string(ARRAY(SELECT jsonb_array_elements_text(to_jsonb(cl)->'site_web')), '|'), '')
                  ELSE NULLIF(to_jsonb(cl)->>'site_web', '')
             END)
    ) AS d(champ, valeur_referentiel, valeur_coop)
    WHERE cl.suppression IS NULL
      AND d.valeur_referentiel IS DISTINCT FROM d.valeur_coop
    $v$;

    EXECUTE $c$
    COMMENT ON VIEW main.lieu_divergences_coop IS
        'SEPT #1724 — une ligne par (lieu coop vivant, champ où le référentiel '
        'diverge de la fiche coop). Les listes vides {} et NULL sont '
        'équivalentes (V166 — les écritures Prisma coop posent [], '
        'l''historique porte NULL). coop.lieu_inclusion.site_web est lu '
        'par to_jsonb, texte ou liste (V176 — la coop le convertit en text[]). '
        'État nominal : uniquement des lignes contact.* (stock combiné depuis '
        'l''archive mednum).'
    $c$;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coop') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO coop';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'min_scalingo') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO min_scalingo';
    END IF;
END $mig$;
