-- L'app MIN (rôle min_scalingo) lit ET écrit le journal de fusion/transfert de
-- structures dans audit.structure_merge_log :
--   * lecture  : page admin « doublons de structures » (badge déjà-fusionnée),
--   * écriture : journalisation des fusions/transferts (dag_id 'min-ui' / 'min-ui-transfert').
-- Le schéma audit (créé en V037) n'avait jamais été ouvert à min_scalingo, contrairement
-- à main/reference/admin/min (V008). En prod la page et la fusion échouaient donc par
-- « permission denied for schema audit ». On accorde le strict nécessaire (least privilege).
GRANT USAGE ON SCHEMA audit TO min_scalingo;
GRANT SELECT, INSERT ON TABLE audit.structure_merge_log TO min_scalingo;
GRANT USAGE ON SEQUENCE audit.structure_merge_log_id_seq TO min_scalingo;
