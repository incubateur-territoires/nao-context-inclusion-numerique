-- V161 — SEPT #1724 : vue des divergences référentiel ↔ coop sur les lieux.
--
-- Support du garde-fou d'édition décidé le 2026-09-09 : quand un utilisateur
-- (app coop, MIN) veut modifier un lieu coop, l'application vérifie EN AMONT
-- s'il existe une divergence entre le référentiel (main.lieu_inclusion_registre,
-- matérialisé par V160 + la double écriture coop, PR coop #615) et la fiche coop, et demande à l'utilisateur
-- de synchroniser avant d'appliquer sa modification. La divergence n'est jamais
-- arbitrée en silence : l'humain qui touche le lieu tranche.
--
-- Grain : une ligne par (lieu coop vivant, champ divergent), valeurs des deux
-- côtés en texte. Le côté coop est normalisé comme V160 l'écrit
-- (NULLIF vide→NULL, tableaux vides→NULL, contact éclaté par clé) : une ligne
-- ici = une vraie divergence de contenu, pas un artefact de format.
-- NB : la double écriture coop (par chemin) peut légitimement laisser diverger
-- les champs qu'un chemin ne porte pas — l'humain tranche via leur difftool.
-- Divergences ATTENDUES à date : les clés de contact comblées depuis l'archive
-- mednum (~330 lieux — la fiche coop ne les a pas tant qu'elle ne les reprend
-- pas). Toute autre ligne = dérive à investiguer (échec de trigger, enum
-- inconnue…) — la vue sert aussi de contrôle de fidélité de la matérialisation V160.
--
-- Consommateurs : app coop (garde-fou), MIN (garde-fou à venir), monitoring.
-- Grants conditionnels aux rôles coop et min_scalingo (pattern V155/V156).
--
-- Bloc défensif (doctrine V144/V151/V153) : sans schéma coop, migration ignorée.

DO $mig$
BEGIN
    IF to_regclass('coop.lieu_inclusion') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V161 ignorée.';
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
    FROM main.lieu_inclusion_registre r
    JOIN coop.lieu_inclusion cl ON cl.id = r.structure_coop_id
    CROSS JOIN LATERAL (VALUES
        ('nom',                             r.nom::text,                                cl.nom),
        ('fiche_acces_libre',               r.fiche_acces_libre::text,                  NULLIF(cl.fiche_acces_libre, '')),
        ('presentation_resume',             r.presentation_resume,                      NULLIF(cl.presentation_resume, '')),
        ('presentation_detail',             r.presentation_detail,                      NULLIF(cl.presentation_detail, '')),
        ('horaires',                        r.horaires::text,                           NULLIF(cl.horaires, '')),
        ('prise_rdv',                       r.prise_rdv::text,                          NULLIF(cl.prise_rdv, '')),
        ('itinerance',                      r.itinerance::text,                         NULLIF(cl.itinerance::text[], '{}')::text),
        ('services',                        r.services::text,                           NULLIF(cl.services::text[], '{}')::text),
        ('modalites_acces',                 r.modalites_acces::text,                    NULLIF(cl.modalites_acces::text[], '{}')::text),
        ('modalites_accompagnement',        r.modalites_accompagnement::text,           NULLIF(cl.modalites_accompagnement::text[], '{}')::text),
        ('publics_specifiquement_adresses', r.publics_specifiquement_adresses::text,    NULLIF(cl.publics_specifiquement_adresses::text[], '{}')::text),
        ('prise_en_charge_specifique',      r.prise_en_charge_specifique::text,         NULLIF(cl.prise_en_charge_specifique::text[], '{}')::text),
        ('frais_a_charge',                  r.frais_a_charge::text,                     NULLIF(cl.frais_a_charge::text[], '{}')::text),
        ('formations_labels',               r.formations_labels::text,                  NULLIF(cl.formations_labels::text[], '{}')::text),
        ('autres_formations_labels',        r.autres_formations_labels::text,           NULLIF(cl.autres_formations_labels, '{}')::text),
        ('dispositif_programmes_nationaux', r.dispositif_programmes_nationaux::text,    NULLIF(cl.dispositif_programmes_nationaux::text[], '{}')::text),
        ('typologies',                      r.typologies::text,                         NULLIF(cl.typologies::text[], '{}')::text),
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
        'diverge de la fiche coop). Support du garde-fou d''édition (synchroniser '
        'avant de modifier) et contrôle de fidélité de la matérialisation V160. Divergences '
        'attendues : clés de contact comblées depuis l''archive mednum.'
    $c$;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coop') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO coop';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'min_scalingo') THEN
        EXECUTE 'GRANT SELECT ON main.lieu_divergences_coop TO min_scalingo';
    END IF;
END $mig$;
