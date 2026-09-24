-- Bascule #1707 : la fusion de structures MIN repointe les FK coop qui visent
-- main.structure_administrative (colonnes de l'ADR-002 coop, mergé 2026-08 :
-- coop.activites.structure_employeuse_main_id, ON DELETE SET NULL, et
-- coop.employes_structures.structure_main_id — cette dernière table sera
-- droppée par la coop à l'échange final, le GRANT disparaîtra avec elle).
-- min_scalingo (rôle applicatif MIN) a besoin de SELECT (détection des
-- colonnes + comptage) et UPDATE sur ces tables du schéma coop.
-- Bloc défensif : le schéma coop appartient à la coop (Prisma), les tables
-- peuvent ne pas exister sur un environnement (CI, base neuve).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'coop') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA coop TO min_scalingo';
  END IF;
  IF to_regclass('coop.activites') IS NOT NULL THEN
    EXECUTE 'GRANT SELECT, UPDATE ON TABLE coop.activites TO min_scalingo';
  END IF;
  IF to_regclass('coop.employes_structures') IS NOT NULL THEN
    EXECUTE 'GRANT SELECT, UPDATE ON TABLE coop.employes_structures TO min_scalingo';
  END IF;
END
$$;
