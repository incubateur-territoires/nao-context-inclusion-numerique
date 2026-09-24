-- Active l'extension pgvector dans la base dataspace.
--
-- Contexte : pgvector fournit le type `vector` et les opérateurs de distance
-- (`<->`, `<=>`, `<#>`) nécessaires au stockage et à la recherche d'embeddings
-- (cas d'usage LLM, cf. schéma `llm` introduit en V102/V103). L'extension a déjà
-- été activée sur le Postgres local côté min (commit 361a2d77) ; cette migration
-- la rend disponible dans la vraie base gérée par Flyway.
--
-- Installée dans `public` (comme postgis / pg_trgm) pour que le type `vector`
-- soit accessible sans qualification de schéma par tous les schémas applicatifs.
--
-- Prérequis : le paquet pgvector doit être présent dans l'image Postgres (déjà
-- le cas en local via Dockerfile.postgres ; à vérifier sur les instances managées).

CREATE EXTENSION IF NOT EXISTS vector;
