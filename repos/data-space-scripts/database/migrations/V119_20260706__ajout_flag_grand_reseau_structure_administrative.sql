-- Flag « grand réseau » sur les structures administratives (#1681).
-- Un grand réseau = une organisation nationale/régionale (1 SIREN) présente dans
-- plusieurs départements via délégations/antennes (Croix-Rouge, La Poste, Reconnect…).
-- Le flag permet de NE PAS écraser les délégations sur une structure unique lors
-- des rapprochements/canonisations, et d'identifier ces réseaux côté produit.
-- Idempotente (IF NOT EXISTS) : peut être appliquée manuellement avant le merge.
ALTER TABLE main.structure_administrative
  ADD COLUMN IF NOT EXISTS est_grand_reseau boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN main.structure_administrative.est_grand_reseau IS
  'Structure appartenant à un grand réseau (SIREN multi-départements, hors collectivités) — délégations territoriales à ne pas fusionner (#1681)';
