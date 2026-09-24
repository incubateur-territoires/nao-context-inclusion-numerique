-- ============================================================
-- V169 – Le fichier national ne porte plus `pivot` sur 85 % des lieux :
--   staging.carto__structures.pivot passe NULLABLE.
-- ============================================================
-- Depuis le millésime du 2026-09-16, la cartographie nationale a cessé de
-- publier le champ `pivot` (SIRET ou RNA du lieu) sur la grande majorité des
-- lignes. Constaté sur le fichier du 2026-09-22 : 16 010 lieux sans pivot sur
-- 18 756 (85 %), contre 18 812/18 812 renseignés au run du 2026-09-15. La
-- comparaison par id entre les deux millésimes confirme une perte sèche amont
-- (15 637 ids communs qui portaient un pivot le 15/09 ne le portent plus), et
-- non une dérive de volume : le fichier n'a pas été tronqué (18 756 lieux).
--
-- Conséquence : `load_carto_national_file` échoue depuis le 2026-09-16 sur
--   NotNullViolation: null value in column "pivot" of relation "carto__structures"
-- → le silver n'est plus alimenté, et tout le carto-dag est à l'arrêt.
--
-- Pourquoi relâcher la contrainte plutôt que rejeter les lignes :
--   - `pivot` n'a AUCUN consommateur métier dans le dataspace. Le lien
--     lieu ↔ structure_administrative est supprimé depuis #1711 : api.carto
--     et api.get_carto_mediateur exposent `pivot` en constante
--     '00000000000000' (V123, V147, V154, V165). Le seul lecteur de la
--     colonne est scripts/rapport_carto_integration.py (détection de
--     doublons par (pivot, nom)), déjà NULL-safe.
--   - Rejeter les lignes sans pivot écarterait 85 % du fichier : la garde
--     volumétrique (seuil 0.8, SEPT #1724) refuserait le run, et le carto-dag
--     resterait à l'arrêt pour un champ que personne ne lit.
--
-- La colonne est conservée (renseignée sur les ~2 700 lieux qui la portent
-- encore) : si l'amont republie le champ, rien à défaire.
-- ------------------------------------------------------------

ALTER TABLE staging.carto__structures ALTER COLUMN pivot DROP NOT NULL;

COMMENT ON COLUMN staging.carto__structures.pivot IS
  'SIRET ou RNA déclaré par la source. NULLABLE depuis V169 : la cartographie '
  'nationale ne publie plus ce champ sur ~85 % des lieux (millésime 2026-09-16). '
  'Aucun consommateur métier — `pivot` est une constante dans api.carto depuis #1711.';
