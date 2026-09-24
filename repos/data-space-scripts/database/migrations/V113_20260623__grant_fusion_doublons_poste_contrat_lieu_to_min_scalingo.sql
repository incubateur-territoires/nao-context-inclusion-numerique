-- Grants complémentaires pour min_scalingo : flux "structures-doublons" (fusion /
-- transfert de notions) de l'app MIN. Complète V111 (qui a couvert le DELETE sur
-- main.personne_affectations_emploi).
--
-- deplacerNotionsDansTransaction() (src/gateways/shared/deplacerNotions.ts) repointe
-- (UPDATE collision-aware) les rattachements de la structure absorbée vers la survivante.
-- Droits manquants pour min_scalingo (n'avaient que SELECT, REFERENCES via V008) :
--   - main.poste   : UPDATE  (repointage de poste.structure_id ; transfererIdposte)
--   - main.contrat : UPDATE  (repointage de contrat.structure_id ; transfererIdposte)
--
-- main.poste : on accorde UPDATE *uniquement*, PAS DELETE. Le code MIN ne doit plus
-- supprimer dans main.poste (table alimentée par l'ETL id-poste — un DELETE côté MIN
-- détruirait une ligne ETL, recréée/désynchronisée au run suivant). Les doublons exacts
-- non repointables restent sur la structure absorbée (ensuite soft-deletée) et sont
-- réconciliés par l'ETL. Cf. MR MIN retirant le `DELETE FROM main.poste`.
--
-- main.lieu_inclusion_structure_administrative : DELETE des liens résiduels (lien pur
-- SA<->lieu, suppression de doublon bénigne, comme contact / personne_affectations_emploi).
--
-- Sans ces droits : ERROR 42501 "permission denied for table <poste|contrat|...>" au
-- déclenchement d'une fusion en prod (utilisateur min_scalingo).

GRANT UPDATE ON TABLE main.poste                                   TO min_scalingo;
GRANT UPDATE ON TABLE main.contrat                                 TO min_scalingo;
GRANT DELETE ON TABLE main.lieu_inclusion_structure_administrative TO min_scalingo;
