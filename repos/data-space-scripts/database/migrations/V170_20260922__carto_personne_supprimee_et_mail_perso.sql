-- V170 — main.personne_visibilite_carto : affiner les critères de publication.
--
-- Deux ajustements du filtre, dans la continuité de V165 (formalisation de la
-- règle) et de V167 (suppression respectée côté lieu) :
--
--   1. Nouveau critère `personne_active` = main.personne.deleted_at IS NULL.
--      La vue ne testait jusqu'ici que `compte_coop_actif`
--      (coop.users.deleted IS NULL), qui porte sur le compte Coop et non sur
--      la suppression logique côté dataspace. Les deux notions sont
--      distinctes ; la publication s'aligne désormais sur les deux.
--
--      C'est la doctrine de V167 pour les lieux — « la suppression est une
--      décision de gestion, la carte la respecte »
--      (docs/cycle-de-vie-lieux-personnes.md §1.3) — étendue aux personnes.
--
--   2. L'adresse publiée est construite sur les seuls champs professionnels :
--      COALESCE(coop.users.email, contact->'idposte'->>'mail_pro'). Le repli
--      sur contact->'idposte'->>'mail_perso' est retiré. Même règle que MIN
--      #1964 pour la fiche aidant. Garde défensive : sur la base de référence
--      ce repli n'est atteint par aucune des 7 245 lignes publiées (une
--      personne publiée a par construction un compte Coop dont l'adresse est
--      renseignée).
--
-- Change la règle P-02 du manifeste docs/cycle-de-vie.gardes.yml :
--   avant : expose = lieu_actif ∧ compte_coop_actif ∧ visible_coop ∧ emploi_autorise
--   après : expose = personne_active ∧ (idem)
-- Documents amendés dans la même MR (docs/cycle-de-vie-lieux-personnes.md,
-- -support.md, -preuves.md) et cas ajoutés à tests/carto/cas_visibilite.yml.
--
-- Périmètre publié, base dev (réplique du 2026-09-16), avant → après :
--   personnes publiées sur api.carto      2 213 → 2 059
--   lignes (personne, lieu) publiées      7 819 → 7 245
-- Le motif_exclusion `personne_supprimee` étant évalué en premier, il absorbe
-- des lignes auparavant classées sous les autres motifs : leur répartition
-- change sans que la population exclue par ces motifs diminue.
-- Rapport de contrôle : scripts/rapport_exposition_carto.sql
--
-- api.carto n'est pas redéfinie : elle se contente d'agréger les lignes
-- expose = true de la vue. Pas de NOTIFY pgrst (aucun objet du schéma api
-- modifié).
--
-- La nouvelle colonne personne_active est ajoutée EN FIN de liste : c'est la
-- seule façon d'enrichir une vue avec CREATE OR REPLACE sans la détruire, et
-- api.carto en dépend.
--
-- Bloc défensif (doctrine V151/V164/V165) : sans schéma coop (CI/base neuve),
-- rien n'est fait.

DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V170 ignorée.';
        RETURN;
    END IF;

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
           (s.personne_active AND s.lieu_actif AND s.compte_coop_actif
            AND s.visible_coop AND s.emploi_autorise) AS expose,
           CASE
               WHEN NOT s.personne_active   THEN 'personne_supprimee'
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
           s.telephone,
           s.personne_active
    FROM ( SELECT pal.personne_id,
                  pal.lieu_id,
                  p.prenom,
                  p.nom,
                  (p.deleted_at IS NULL) AS personne_active,
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
                           (p.contact -> 'idposte'::text) ->> 'mail_pro'::text) AS email,
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

    EXECUTE $c0$ COMMENT ON VIEW main.personne_visibilite_carto IS $t0$ Règle de visibilité d'une personne sur la cartographie nationale (V165, étendue V170), une ligne par (personne, lieu) de main.personne_affectations_lieu. `expose` = tous les critères personne réunis ; `motif_exclusion` = premier critère en défaut (personne_supprimee, lieu_inactif, compte_coop_supprime, masque_coop, cn_sans_emploi_actif). Les critères côté lieu restent dans api.carto. Le courriel publié est l'adresse Coop ou le mail_pro (V170). Spécification exécutable : tests/carto/cas_visibilite.yml. $t0$ $c0$;
    EXECUTE $c1$ COMMENT ON COLUMN main.personne_visibilite_carto.personne_active IS 'main.personne.deleted_at IS NULL — suppression logique côté dataspace, distincte de compte_coop_actif (coop.users.deleted). Ajouté V170.' $c1$;
    EXECUTE $c2$ COMMENT ON COLUMN main.personne_visibilite_carto.email IS 'Adresse publiée : COALESCE(coop.users.email, contact->idposte->>mail_pro). Champs professionnels uniquement depuis V170.' $c2$;
END
$mig$;
