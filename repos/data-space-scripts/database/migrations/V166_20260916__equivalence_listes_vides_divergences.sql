-- V166 — SEPT #1724 : listes vides — `{}` et NULL sont ÉQUIVALENTS dans les
-- comparaisons référentiel ↔ coop.
--
-- Constat prod (2026-09-15, contrôle de santé post-déploiement coop #615) :
-- la double écriture coop pose `[]` pour une nomenclature vide — les listes
-- scalaires Prisma sont non-nullables par conception, elle ne PEUT pas écrire
-- NULL — là où l'historique du référentiel (normalisation carto `_normalize_
-- array`, backfill V160) porte NULL. Résultat : ~50 fausses divergences (un
-- lieu aux nomenclatures vides divergeait d'un coup sur 8 champs), et un
-- ping-pong quotidien filet ↔ double écriture (le filet re-normalisait en
-- NULL, l'écriture coop suivante reposait `{}`) qui aurait empêché
-- `metier_rafraichi` de retomber à 0 — notre signal d'alarme.
--
-- Convention actée : pour les colonnes listes du référentiel, « vide » s'écrit
-- `{}` OU NULL, indifféremment — les deux formes cohabitent (coop → `{}`,
-- flux historiques → NULL) et tous les consommateurs les traitent pareil.
-- Les COMPARATEURS normalisent les deux côtés : cette vue (ci-dessous) et le
-- rattrapage métier du filet (etl/load/registre_lieux_coop.py, même MR).
-- Aucune action côté coop.
--
-- Bloc défensif (doctrine V144/V151/V153) : sans schéma coop, migration ignorée.

DO $mig$
BEGIN
    IF to_regclass('coop.lieu_inclusion') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V166 ignorée.';
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
        ('contact.site_web',                r.contact->>'site_web',                     NULLIF(cl.site_web, ''))
    ) AS d(champ, valeur_referentiel, valeur_coop)
    WHERE cl.suppression IS NULL
      AND d.valeur_referentiel IS DISTINCT FROM d.valeur_coop
    $v$;

    EXECUTE $c$
    COMMENT ON VIEW main.lieu_divergences_coop IS
        'SEPT #1724 — une ligne par (lieu coop vivant, champ où le référentiel '
        'diverge de la fiche coop). Les listes vides {} et NULL sont '
        'équivalentes (V166 — les écritures Prisma coop posent [], '
        'l''historique porte NULL). État nominal : uniquement des lignes '
        'contact.* (stock combiné depuis l''archive mednum).'
    $c$;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coop') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO coop';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'min_scalingo') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO min_scalingo';
    END IF;
END $mig$;
