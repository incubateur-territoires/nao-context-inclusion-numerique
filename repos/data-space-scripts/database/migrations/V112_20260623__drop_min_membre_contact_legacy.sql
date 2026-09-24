-- Suppression des colonnes legacy min.membre.contact / min.membre.contact_technique.
--
-- Contexte : ces deux colonnes (anciennes FK vers min.contact_membre_gouvernance)
-- portaient l'ancien modèle de contact des membres. Depuis V047 (2026-02-26) les
-- contacts vivent dans main.contact + main.contact_structure_administrative ; les
-- FK membre_contact_fkey / membre_contact_technique_fkey ont été supprimées et les
-- colonnes rendues nullable. Plus aucun code applicatif ne les écrit (le gateway
-- min PrismaMembreRepository écrit dans main.contact) et les vues LLM (V102) les
-- excluent déjà. On les supprime définitivement.
--
-- ⚠️ Déploiement : doit passer APRÈS la mise en prod du retrait de `nb_contacts_membre`
--    côté min (seul lecteur résiduel : PrismaStructuresComparaisonLoader).

ALTER TABLE "min"."membre" DROP COLUMN IF EXISTS "contact";
ALTER TABLE "min"."membre" DROP COLUMN IF EXISTS "contact_technique";
