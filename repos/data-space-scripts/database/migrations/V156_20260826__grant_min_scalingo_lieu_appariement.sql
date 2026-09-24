-- Grants min_scalingo pour l'interface de revue des appariements de lieux
-- (SEPT #1845, PR MIN #1853). MIN liste la file (statut 'a_valider') et
-- enregistre les décisions humaines.
--
-- Droits accordés :
--   - SELECT sur main.lieu_appariement (listing + jointures vers
--     main.lieu_inclusion / main.adresse, déjà couvertes par V008) ;
--   - UPDATE LIMITÉ AUX COLONNES DE DÉCISION (statut, decide_par, decide_le) :
--     le gel du reste de la table (scores, segments, détections — alimentés par
--     le DAG lieu-appariement) est appliqué par PostgreSQL, pas par le code MIN.
--
-- Pas d'INSERT ni DELETE : la table est alimentée et purgée exclusivement par
-- le DAG (V152) ; le DAG préserve les statuts 'valide'/'rejete' à chaque run.
--
-- Grant conditionnel (pattern V152) : le rôle n'existe pas sur l'instance
-- fraîche du job CI test_migration.
--
-- Pas d'undo (cohérent avec les migrations de grants V053/V107/V111/V113).

DO $grants$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'min_scalingo') THEN
        GRANT SELECT ON main.lieu_appariement TO min_scalingo;
        GRANT UPDATE (statut, decide_par, decide_le) ON main.lieu_appariement TO min_scalingo;
    END IF;
END
$grants$;
