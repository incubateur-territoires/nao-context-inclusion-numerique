-- ============================================================
-- V157 – SEPT #1707 (phase 5, décommissionnement) :
--   suppression de main.coordination_mediation et de api.get_mediateur.
-- ============================================================
-- main.coordination_mediation était la RÉPLIQUE (coop-dag, tâche
-- insert_coordination_mediation) des liens coordinateur → médiateurs de
-- coop.mediateurs_coordonnes. Depuis la bascule Prisma, la source vit dans le
-- même cluster ; la réplique divergeait déjà (3 655 liens actifs côté main vs
-- 3 391 côté coop au 2026-08-11 : suppressions jamais propagées, même
-- symptôme que activites_coop V144 / personne_affectations_lieu V151).
--
-- Son unique consommateur était api.get_mediateur(email) — RPC PostgREST du
-- rôle postgrest_coop (clé `conseillers_numerique_coordonnes`), dont le seul
-- client était l'application coop (dataspaceApiClient.ts). La coop a supprimé
-- ce client le 2026-08-20 (commit coop 924ff99e « supprimer l'API Dataspace
-- et la synchro qui la consommait ») : elle lit désormais main directement et
-- est de toute façon la source de ces liens. Plus aucun appelant → on
-- supprime l'endpoint plutôt que de maintenir une vue de compatibilité.
--
-- Le rôle postgrest_coop est conservé (auth.check_token / auth.token,
-- V015) : il ne donne plus accès à aucun objet du schéma api.
--
-- Le silver staging.coop__utilisateurs.coordination_mediation (V131) perd
-- son seul lecteur : colonne droppée, le core (etl/core/coop.py) ne la
-- produit plus (même MR).
--
-- Ordre : fonction d'abord (elle lit la table), puis la table.
-- ------------------------------------------------------------

DROP FUNCTION IF EXISTS api.get_mediateur(text);

-- CASCADE : triggers updated_at / updated_at_insert (V059), index
-- coordination_mediation_ukey (V026), séquence identity, FK vers main.personne.
DROP TABLE IF EXISTS main.coordination_mediation CASCADE;

ALTER TABLE staging.coop__utilisateurs DROP COLUMN IF EXISTS coordination_mediation;

NOTIFY pgrst, 'reload schema';
