-- V160 — SEPT #1724 : la coop écrit le registre — droits d'écriture du rôle coop
-- sur main.lieu_inclusion_registre + re-matérialisation initiale des lignes coop.
--
-- Décision 2026-09-04 (Ferdinand/PO) : même donnée partout, stockage de référence
-- unique, « le dernier qui parle a raison ». Modèle affiné 2026-09-09 : la coop
-- garde sa vérité (coop.lieu_inclusion) ; le référentiel (le registre) porte la
-- vérité pour tous les autres ; quand la coop crée/modifie un lieu, elle le dit
-- au référentiel.
--
-- Le « elle le dit » est implémenté PAR LA COOP (PR coop-mediation-numerique
-- #615) : double écriture applicative dans la même transaction Prisma —
-- update par lien coop / ADOPTION d'une inscription existante sans lien
-- (anti-doublon) / insert, colonnes écrites par chemin (jamais toute la ligne),
-- adresse résolue par NOTRE fonction main.trouver_ou_creer_adresse_lieu (V155),
-- source = 'Coop numérique' posé à chaque écriture, revendication prudente du
-- carto_id (unique côté registre), suppression via deleted_at. Un trigger
-- dataspace de synchronisation (v1 de cette migration) avait été développé puis
-- RETIRÉ : miroir intégral, il aurait écrasé leur discipline par chemin et son
-- INSERT aveugle aurait cassé l'adoption sur la contrainte unique.
--
-- Rôle de cette migration :
--   1. GRANTS du rôle `coop` : ⚠️ l'app coop se connecte en réalité en `sonum`,
--      PROPRIÉTAIRE de la table (vérifié prod par la coop le 2026-09-10, et sur
--      dev) — aucun grant ne la contraint ni ne la débloque ; sa protection est
--      son typage applicatif (ColonnesDuRegistre). Les grants posés ici gardent
--      un rôle : le périmètre d'écriture OFFICIEL des colonnes coop — métier
--      saisissable + traçabilité + cycle de vie applicatif, SANS les colonnes
--      des autres écrivains (updated_at_carto/min, compteurs, import_warnings,
--      old_main_structure_id, dispositif_programmes_nationaux,
--      autres_formations_labels) — prêt pour le jour où la connexion coop
--      passera sous un rôle borné (recommandation de gouvernance ouverte).
--      + EXECUTE explicite sur la fonction d'adresse.
--   2. RE-MATÉRIALISATION du stock (~12 700 lignes coop, jamais touchées par
--      leur double écriture — PR non déployée à ce jour) : colonnes métier
--      recopiées depuis la vérité coop, avec COMBINAISON du contact clé par clé
--      (telephone/courriels/site_web) — la coop gagne, mais une clé de l'ARCHIVE
--      du registre (enrichissements des fusions mednum d'avant l'étape 4,
--      ~330 lieux, éteints des fusions par mergeOldLieux 6 mois : dernière
--      trace) survit là où la coop n'a rien. Ces valeurs restent au registre,
--      rien n'est écrit chez la coop — leur difftool les proposera à l'édition
--      (garde-fou décidé 2026-09-09 : l'humain tranche, jamais d'arbitrage
--      silencieux).
--   3. Nettoyage du trigger v1 sur les environnements où il a été posé (dev).
--
-- Aucun changement visible : la vue V153 lit toujours la coop en direct pour
-- les lignes coop. Séquencement : la coop (connectée en sonum) peut déployer
-- indépendamment ; seule contrainte molle = merger la restriction du cycle de
-- vie carto (même MR, carto-dag) avant ou peu après leur déploiement, sinon
-- ping-pong quotidien sur visible_pour_cartographie_nationale (impact borné
-- tant que la vue V153 ANDe avec le drapeau coop).
--
-- Bloc défensif (doctrine V144/V151/V153) : si main.lieu_inclusion_registre
-- n'existe pas — CI/base neuve, mais AUSSI la base dev serveur où V153 n'a
-- jamais basculé faute de schéma coop — migration entièrement ignorée.
-- (Leçon du 2026-09-10 : le rôle coop peut exister SANS la table — la garde
-- sur le seul rôle a fait échouer apply_migration_dev.)

DO $mig$
BEGIN
    IF to_regclass('main.lieu_inclusion_registre') IS NULL THEN
        RAISE NOTICE 'Registre absent (CI/base neuve/dev sans bascule V153) : V160 ignorée.';
        RETURN;
    END IF;

    -- ------------------------------------------------------------------
    -- 0) Nettoyage du trigger v1 (posé sur dev uniquement)
    -- ------------------------------------------------------------------
    IF to_regclass('coop.lieu_inclusion') IS NOT NULL THEN
        EXECUTE 'DROP TRIGGER IF EXISTS lieu_inclusion_sync_registre_tg ON coop.lieu_inclusion';
    END IF;
    DROP FUNCTION IF EXISTS main.sync_registre_lieu_coop();

    -- ------------------------------------------------------------------
    -- 1) Grants du rôle coop (conditionnels, pattern V155/V156)
    -- ------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coop') THEN
        EXECUTE $g$
        GRANT INSERT (structure_coop_id, nom, nom_usage, complement_adresse,
                      adresse_id, source, edited_by, updated_at_coop, created_at,
                      deleted_at, structure_cartographie_nationale_id,
                      visible_pour_cartographie_nationale, fiche_acces_libre,
                      prise_rdv, horaires, presentation_resume,
                      presentation_detail, siret_a_l_enrichissement, typologies,
                      services, publics_specifiquement_adresses,
                      prise_en_charge_specifique, modalites_acces,
                      frais_a_charge, itinerance, formations_labels,
                      modalites_accompagnement, contact),
              UPDATE (structure_coop_id, nom, nom_usage, complement_adresse,
                      adresse_id, source, edited_by, updated_at_coop,
                      deleted_at, structure_cartographie_nationale_id,
                      visible_pour_cartographie_nationale, fiche_acces_libre,
                      prise_rdv, horaires, presentation_resume,
                      presentation_detail, siret_a_l_enrichissement, typologies,
                      services, publics_specifiquement_adresses,
                      prise_en_charge_specifique, modalites_acces,
                      frais_a_charge, itinerance, formations_labels,
                      modalites_accompagnement, contact)
        ON main.lieu_inclusion_registre TO coop
        $g$;
        EXECUTE 'GRANT EXECUTE ON FUNCTION main.trouver_ou_creer_adresse_lieu(text, text, text, text, double precision, double precision, text) TO coop';
    END IF;

    -- ------------------------------------------------------------------
    -- 2) Re-matérialisation initiale du stock.
    --    updated_at_coop en GREATEST (jamais de retour en arrière de
    --    fraîcheur ; updated_at est une colonne GÉNÉRÉE, jamais écrite),
    --    deleted_at préservé sauf suppression coop à refléter (COALESCE),
    --    edited_by PRÉSERVÉ (signature du dernier écrivain réel),
    --    adresse_id non touché (déjà résolu par le filet),
    --    contact COMBINÉ : la coop gagne clé par clé, l'archive comble.
    -- ------------------------------------------------------------------
    IF to_regclass('coop.lieu_inclusion') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : re-matérialisation ignorée.';
        RETURN;
    END IF;

    EXECUTE $bf$
    UPDATE main.lieu_inclusion_registre r SET
        nom              = cl.nom,
        updated_at_coop  = GREATEST(r.updated_at_coop, cl.modification),
        deleted_at       = COALESCE(cl.suppression, r.deleted_at),
        fiche_acces_libre               = NULLIF(cl.fiche_acces_libre, ''),
        presentation_resume             = NULLIF(cl.presentation_resume, ''),
        presentation_detail             = NULLIF(cl.presentation_detail, ''),
        horaires                        = NULLIF(cl.horaires, ''),
        prise_rdv                       = NULLIF(cl.prise_rdv, ''),
        itinerance                      = NULLIF(cl.itinerance::text[], '{}')::main.itinerance[],
        services                        = NULLIF(cl.services::text[], '{}')::main.service[],
        modalites_acces                 = NULLIF(cl.modalites_acces::text[], '{}')::main.modalite_acces[],
        modalites_accompagnement        = NULLIF(cl.modalites_accompagnement::text[], '{}')::main.modalite_accompagnement[],
        publics_specifiquement_adresses = NULLIF(cl.publics_specifiquement_adresses::text[], '{}')::main.public_specifiquement_adresse[],
        prise_en_charge_specifique      = NULLIF(cl.prise_en_charge_specifique::text[], '{}')::main.prise_en_charge_specifique[],
        frais_a_charge                  = NULLIF(cl.frais_a_charge::text[], '{}')::main.frais_a_charge[],
        formations_labels               = NULLIF(cl.formations_labels::text[], '{}')::main.formation_label[],
        autres_formations_labels        = NULLIF(cl.autres_formations_labels, '{}'),
        dispositif_programmes_nationaux = NULLIF(cl.dispositif_programmes_nationaux::text[], '{}')::main.dispositif_programme_national[],
        typologies                      = NULLIF(cl.typologies::text[], '{}')::main.typologie[],
        contact = (CASE WHEN jsonb_typeof(r.contact) = 'object'
                        THEN r.contact ELSE '{}'::jsonb END)
                  || jsonb_strip_nulls(jsonb_build_object(
                        'telephone', NULLIF(cl.telephone, ''),
                        'courriels',
                            CASE WHEN cl.courriels IS NOT NULL AND array_length(cl.courriels, 1) > 0
                                 THEN jsonb_build_object('email', array_to_string(cl.courriels, '|'))
                                 ELSE NULL::jsonb END,
                        'site_web', NULLIF(cl.site_web, ''))),
        emplois = NULL
    FROM coop.lieu_inclusion cl
    WHERE cl.id = r.structure_coop_id
    $bf$;
END $mig$;
