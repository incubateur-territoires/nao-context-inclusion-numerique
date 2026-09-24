-- V171 — CORRECTIF URGENT de V170 : `deleted_at` sur main.personne n'est pas un
-- signal de fin d'activité, il ne doit pas conditionner la publication carto.
--
-- V170 (mergée et appliquée en prod le 2026-09-22) avait ajouté le critère
-- `personne_active` = `main.personne.deleted_at IS NULL` à `expose`, par
-- analogie avec la doctrine V167 sur les lieux. L'analogie ne tient pas.
--
-- Ce qu'on croyait : `deleted_at` est une décision de gestion, écrite par MIN
-- (c'est ce qu'affirme docs/cycle-de-vie-lieux-personnes.md §1.5 — assertion
-- inexacte, corrigée dans la même MR).
--
-- Ce qui est vrai : `deleted_at` est aussi écrit par le flux Aidants Connect
-- quand une habilitation est retirée, et il n'est JAMAIS effacé quand une autre
-- source continue à faire vivre la personne. C'est un marqueur par source posé
-- sur un pivot partagé, pas un état de la personne.
--
-- Mesure au 2026-09-22 sur les 154 personnes que V170 retirait de la carte :
--
--   ont un emploi actif hors aidants-connect ........ 154 / 154
--   ont un contrat CoNum non rompu .................. 129 / 154
--   ont été mises à jour par la coop APRÈS deleted_at  154 / 154
--   deleted_by = {aidants-connect} seul ............. 144 / 154
--
-- Aucune exception : les 154 sont des professionnels en poste. Cas témoin,
-- personne 1549 — `deleted_at` 2022-10-27 par aidants-connect, affectations
-- coop ET idposte actives, compte coop vivant et visible, contrat CoNum
-- 2023-09-26 → 2026-09-25 sans rupture. V170 la retirait de la carte, ainsi que
-- 545 lieux dont 408 perdaient leur seul médiateur.
--
-- Ce que V171 fait :
--   - `expose` revient aux quatre critères de V165 ;
--   - le motif `personne_supprimee` disparaît du CASE : il n'exclut plus rien,
--     le laisser afficherait un motif sur des lignes exposées ;
--   - la colonne `personne_active` est CONSERVÉE, à titre informatif — on ne
--     peut pas retirer une colonne par CREATE OR REPLACE VIEW, et api.carto
--     dépend de la vue. Son commentaire dit explicitement qu'elle ne conditionne
--     rien.
--
-- Ce que V171 NE défait PAS : l'adresse publiée reste construite sur les seuls
-- champs professionnels, `COALESCE(coop.users.email, mail_pro)`. Cette moitié de
-- V170 est saine et sans effet de bord mesuré.
--
-- Périmètre publié attendu, base dev (réplique du 2026-09-16) :
--   personnes publiées sur api.carto    2 059 → 2 213
--   lignes (personne, lieu) publiées    7 245 → 7 819
--   lieux portant ≥ 1 médiateur         6 078 → 6 486
-- Contrôle : scripts/rapport_exposition_carto.sql
--
-- La question de fond — faut-il exclure les personnes réellement parties, et à
-- quel signal le reconnaître — reste ouverte : elle demande un signal fiable
-- (absence d'emploi actif, toutes sources confondues) et un arbitrage métier,
-- pas un `deleted_at` par source. Suivi dans l'issue SEPT dédiée.
--
-- Bloc défensif (doctrine V151/V164/V165) : sans schéma coop, rien n'est fait.

DO $mig$
BEGIN
    IF to_regclass('coop.users') IS NULL OR to_regclass('coop.mediateurs') IS NULL THEN
        RAISE NOTICE 'Schéma coop absent (CI/base neuve) : V171 ignorée.';
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

    EXECUTE $c0$ COMMENT ON VIEW main.personne_visibilite_carto IS $t0$ Règle de visibilité d'une personne sur la cartographie nationale (V165 ; V170 annulée sur ce point par V171), une ligne par (personne, lieu) de main.personne_affectations_lieu. `expose` = lieu_actif ET compte_coop_actif ET visible_coop ET emploi_autorise ; `motif_exclusion` = premier critère en défaut. Les critères côté lieu restent dans api.carto. Le courriel publié est l'adresse Coop ou le mail_pro, jamais mail_perso (V170). Spécification exécutable : tests/carto/cas_visibilite.yml. $t0$ $c0$;
    EXECUTE $c1$ COMMENT ON COLUMN main.personne_visibilite_carto.personne_active IS 'INFORMATIF UNIQUEMENT — ne conditionne PAS expose (V171). main.personne.deleted_at est un marqueur posé par une source (aidants-connect notamment) et jamais effacé quand une autre source fait vivre la personne : il ne vaut pas fin d''activité. Colonne conservée faute de pouvoir la retirer par CREATE OR REPLACE.' $c1$;
END
$mig$;
