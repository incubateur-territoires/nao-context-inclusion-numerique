-- Flag « hub » sur les structures administratives (#1681).
-- Hub = tête de réseau régionale de la médiation numérique (référentiel métier
-- Hubs_SIRET.csv) : 1 entité juridique (ou porteur de consortium) dont la gouvernance
-- couvre plusieurs départements. Distinct de est_grand_reseau (délégations physiques
-- multi-départements) : un hub est mono-implantation mais multi-gouvernance.
-- Sert à exclure ces structures des fusions/consolidations automatiques.
-- Idempotente (IF NOT EXISTS) : applicable manuellement avant le merge.
ALTER TABLE main.structure_administrative
  ADD COLUMN IF NOT EXISTS est_hub boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN main.structure_administrative.est_hub IS
  'Tête de réseau régionale médiation numérique (hub ou porteur de consortium) — exclue des fusions automatiques (#1681, référentiel Hubs_SIRET)';
