"""Logique métier d'ingestion Aidants Connect — indépendante d'Airflow.

Chaque fonction prend une connexion psycopg2 et des données en entrée.
Les wrappers Airflow dans aidants-connect-dag.py se chargent du câblage
(xcom_pull, PostgresHook, Variable.get, etc.).
"""

import io
import logging

import pandas as pd

from etl.core.rejets import Rejet


# ── Utilisateurs (personnes) ────────────────────────────────────────────

STAGING_COLS_PERSONNES = [
    "aidant_connect_id",
    "nom",
    "prenom",
    "formation_fne_ac",
    "profession_ac",
    "nb_accompagnements_ac",
    "is_referent_ac",
    "updated_at_ac",
]


def ingest_utilisateurs(conn, aidants: list[dict]) -> dict:
    """Staging → dedup → upsert des personnes AC.

    Returns dict avec les compteurs (updated, inserted).
    """
    if not aidants:
        return {"updated": 0, "inserted": 0}

    df = pd.DataFrame(aidants)

    for col in STAGING_COLS_PERSONNES:
        if col not in df.columns:
            df[col] = None

    cursor = conn.cursor()

    cursor.execute("""
        DROP TABLE IF EXISTS staging_utilisateurs_ac;
        CREATE TEMPORARY TABLE staging_utilisateurs_ac (
            row_id  SERIAL PRIMARY KEY,
            aidant_connect_id INTEGER,
            nom     VARCHAR(50),
            prenom  VARCHAR(50),
            formation_fne_ac BOOLEAN,
            profession_ac TEXT,
            nb_accompagnements_ac INTEGER,
            is_referent_ac BOOLEAN,
            updated_at_ac TIMESTAMP WITHOUT TIME ZONE,
            matched BOOLEAN DEFAULT FALSE
        );
    """)

    buf = io.StringIO()
    for _, row in df[STAGING_COLS_PERSONNES].iterrows():
        fields = []
        for val in row:
            if val is None or (isinstance(val, float) and pd.isna(val)):
                fields.append("\\N")
            else:
                s = str(val)
                s = (
                    s.replace("\\", "/")
                    .replace("\t", " ")
                    .replace("\n", " ")
                    .replace("\r", "")
                )
                if s in ("None", "nan", "NaN", ""):
                    fields.append("\\N")
                else:
                    fields.append(s)
        buf.write("\t".join(fields) + "\n")
    buf.seek(0)
    cursor.copy_expert(
        f"COPY staging_utilisateurs_ac ({', '.join(STAGING_COLS_PERSONNES)}) "
        "FROM STDIN WITH (FORMAT text)",
        buf,
    )
    copied = cursor.rowcount
    logging.info("%s utilisateurs copiés dans le staging.", copied)

    # Dédupliquer par aidant_connect_id (garder la dernière ligne)
    cursor.execute("""
        DELETE FROM staging_utilisateurs_ac s
        USING staging_utilisateurs_ac s2
        WHERE s.aidant_connect_id IS NOT NULL
          AND s.aidant_connect_id = s2.aidant_connect_id
          AND s.row_id < s2.row_id;
        CREATE INDEX ON staging_utilisateurs_ac (aidant_connect_id)
            WHERE aidant_connect_id IS NOT NULL AND matched = FALSE;
    """)

    # UPDATE par aidant_connect_id (données plus récentes)
    cursor.execute("""
        WITH updated AS (
            UPDATE main.personne p
            SET
                nom = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN s.nom ELSE p.nom
                END,
                prenom = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN s.prenom ELSE p.prenom
                END,
                formation_fne_ac = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN s.formation_fne_ac ELSE p.formation_fne_ac
                END,
                profession_ac = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN s.profession_ac ELSE p.profession_ac
                END,
                nb_accompagnements_ac = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN s.nb_accompagnements_ac ELSE p.nb_accompagnements_ac
                END,
                is_referent_ac = CASE
                    WHEN s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
                    THEN COALESCE(s.is_referent_ac, FALSE) ELSE p.is_referent_ac
                END,
                updated_at_ac = GREATEST(s.updated_at_ac, p.updated_at_ac),
                edited_by = 'aidants-connect'
            FROM staging_utilisateurs_ac s
            WHERE s.aidant_connect_id IS NOT NULL
              AND p.aidant_connect_id = s.aidant_connect_id
              AND s.matched = FALSE
              AND s.updated_at_ac > COALESCE(p.updated_at_ac, '1970-01-01'::timestamp)
            RETURNING s.row_id AS matched_row_id
        )
        UPDATE staging_utilisateurs_ac stg
        SET matched = TRUE
        FROM updated u WHERE stg.row_id = u.matched_row_id;
    """)
    updated = cursor.rowcount
    logging.info("UPDATE par aidant_connect_id : %s lignes.", updated)

    # INSERT les non-matchés
    cursor.execute("""
        INSERT INTO main.personne (
            aidant_connect_id, nom, prenom,
            formation_fne_ac, profession_ac,
            nb_accompagnements_ac, is_referent_ac, updated_at_ac, edited_by
        )
        SELECT
            s.aidant_connect_id, s.nom, s.prenom,
            s.formation_fne_ac, s.profession_ac,
            s.nb_accompagnements_ac, COALESCE(s.is_referent_ac, FALSE),
            s.updated_at_ac, 'aidants-connect'
        FROM staging_utilisateurs_ac s
        WHERE s.matched = FALSE
        ON CONFLICT (aidant_connect_id) DO NOTHING;
    """)
    inserted = cursor.rowcount
    logging.info("INSERT nouvelles personnes : %s lignes.", inserted)

    return {"copied": copied, "updated": updated, "inserted": inserted}


# ── Structures ───────────────────────────────────────────────────────────

SIRENE_UPDATE_FIELDS = (
    "etat_administratif",
    "code_activite_principale",
    "categorie_juridique",
    "denomination_sirene",
)


def build_sirene_update_row(rec, now_ts):
    """Construit la ligne (etat, ape, cj, denom, ts, ac_id) pour le batch UPDATE SIRENE.

    Retourne `None` si la ligne ne doit pas être updatée (pas d'ac_id, ou aucune
    valeur SIRENE exploitable). Normalise les NaN pandas en None : sans cela, NaN
    bypasse le filtre `is None` et PostgreSQL infère le type du `VALUES` comme
    `double precision` à partir de la 1ʳᵉ ligne, ce qui fait planter les lignes
    suivantes contenant du texte.
    """
    ac_id = rec.get("structure_ac_id")
    if not ac_id:
        return None
    fields = [
        None if pd.isna(v) else v for v in (rec.get(f) for f in SIRENE_UPDATE_FIELDS)
    ]
    if all(v is None for v in fields):
        return None
    return (*fields, now_ts, ac_id)


def _query(cursor, sql, params=None):
    """Execute SQL and return all rows."""
    cursor.execute(sql, params)
    return cursor.fetchall()


def _batch_query(cursor, sql_template, ids, batch_size=500):
    """Execute a query in batches over a list of IDs.

    sql_template must contain {placeholders} where the IN clause goes.
    """
    results = []
    for start in range(0, len(ids), batch_size):
        batch = ids[start : start + batch_size]
        placeholders = ", ".join(["%s"] * len(batch))
        sql = sql_template.format(placeholders=placeholders)
        cursor.execute(sql, batch)
        results.extend(cursor.fetchall())
    return results


def _batch_execute(cursor, sql_template, flat_params_chunks):
    """Execute batched INSERT/UPDATE with flat params."""
    for sql, params in flat_params_chunks:
        cursor.execute(sql, params)


def ingest_structures(conn, structures: list[dict]) -> dict:
    """Ingère les nouvelles structures (lignes silver ⋈ caches, lot 2 caches).

    Returns dict avec les compteurs, plus `rejets` : les ``Rejet`` des lignes
    écartées, à écrire en quarantaine par le shell (cf ``etl/quarantaine.py``).
    """
    if not structures:
        logging.info("Aucune structure à ingérer.")
        return {"inserted": 0, "ecartes": 0, "rejets": []}

    # main.adresse.code_postal / code_insee sont des VARCHAR(5). L'API AC
    # renvoie parfois des codes mal formés (espaces, codes étrangers, valeurs
    # > 5 caractères) qui font échouer le COPY (StringDataRightTruncation).
    # On normalise à 5 caractères max ; vide → None.
    nb_tronques = 0
    for s in structures:
        for col in ("code_postal", "code_insee"):
            val = s.get(col)
            if val is None:
                continue
            clean = str(val).strip()[:5] or None
            if clean != val:
                nb_tronques += 1
            s[col] = clean
    if nb_tronques:
        logging.warning(
            "%s valeurs code_postal/code_insee normalisées à 5 caractères.",
            nb_tronques,
        )

    logging.info(f"{len(structures)} structures à insérer.")

    BATCH_SIZE = 500
    cursor = conn.cursor()

    # --- Batch address lookup ---
    all_clef_interops = set()
    all_code_bans = set()
    for s in structures:
        ci = str(s.get("clef_interop")) if s.get("clef_interop") else None
        cb = str(s.get("code_ban")) if s.get("code_ban") else None
        if ci:
            all_clef_interops.add(ci)
        if cb:
            all_code_bans.add(cb)

    adresse_by_clef = {}
    adresse_by_code_ban = {}

    try:
        ci_list = list(all_clef_interops)
        cb_list = list(all_code_bans)
        for start in range(0, max(len(ci_list), len(cb_list), 1), BATCH_SIZE):
            ci_chunk = ci_list[start : start + BATCH_SIZE]
            cb_chunk = cb_list[start : start + BATCH_SIZE]
            conditions = []
            params = []
            if ci_chunk:
                conditions.append(
                    f"clef_interop IN ({','.join(['%s'] * len(ci_chunk))})"
                )
                params.extend(ci_chunk)
            if cb_chunk:
                conditions.append(f"code_ban IN ({','.join(['%s'] * len(cb_chunk))})")
                params.extend(cb_chunk)
            if not conditions:
                continue
            cursor.execute(
                f"SELECT id, clef_interop, code_ban FROM main.adresse WHERE {' OR '.join(conditions)}",
                tuple(params),
            )
            for row in cursor.fetchall():
                aid, ci, cb = row[0], row[1], row[2]
                if ci:
                    adresse_by_clef[ci] = aid
                if cb:
                    adresse_by_code_ban[cb] = aid
    except Exception as e:
        if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
            logging.warning(
                "Table main.adresse absente, toutes les adresses seront insérées."
            )
        else:
            raise

    logging.info(
        "Batch adresse lookup : %s par clef_interop, %s par code_ban.",
        len(adresse_by_clef),
        len(adresse_by_code_ban),
    )

    # --- Batch address insert ---
    adresses_to_insert = {}
    for i, s in enumerate(structures):
        ci = str(s.get("clef_interop")) if s.get("clef_interop") else None
        cb = str(s.get("code_ban")) if s.get("code_ban") else None
        existing_id = adresse_by_clef.get(ci) or adresse_by_code_ban.get(cb)
        if existing_id:
            continue
        if not (s.get("code_postal") and s.get("nom_commune") and s.get("code_insee")):
            continue

        # Path nominal : BAN a résolu une adresse complète (nom_voie + numero_voie + geom).
        nom_voie = s.get("nom_voie")
        numero_voie = (
            int(s["numero_voie"])
            if s.get("numero_voie") and str(s["numero_voie"]).isdigit()
            else None
        )
        geom = s.get("geom")
        clef_interop_ins = ci
        code_ban_ins = cb

        # Path dégradé : BAN a échoué ou été rejeté → on insère depuis l'adresse source
        # brute pour préserver le lien structure ↔ adresse, sans géolocalisation.
        if not nom_voie:
            adresse_brute = s.get("adresse")
            if not adresse_brute:
                continue
            nom_voie = str(adresse_brute).strip()[:255]
            numero_voie = None
            geom = None
            clef_interop_ins = None
            code_ban_ins = None

        conflict_key = (
            s.get("code_postal"),
            s.get("nom_commune"),
            nom_voie,
            numero_voie if numero_voie else 0,
            s.get("repetition") or "",
        )
        row_tuple = (
            clef_interop_ins,
            s.get("code_postal"),
            s.get("nom_commune"),
            nom_voie,
            numero_voie,
            geom,
            s.get("code_insee"),
            s.get("repetition"),
            code_ban_ins,
        )
        if conflict_key not in adresses_to_insert:
            adresses_to_insert[conflict_key] = (row_tuple, [i])
        else:
            adresses_to_insert[conflict_key][1].append(i)

    unique_adresses = list(adresses_to_insert.values())
    inserted_adresse_ids = {}
    try:
        cursor.execute("SAVEPOINT adresse_insert")
        for start in range(0, len(unique_adresses), BATCH_SIZE):
            chunk = unique_adresses[start : start + BATCH_SIZE]
            values_parts = []
            flat_params = []
            for row_tuple, _ in chunk:
                values_parts.append(
                    "(%s, %s, %s, %s, %s, ST_GeomFromText(%s, 4326), %s, %s, %s)"
                )
                flat_params.extend(row_tuple)
            cursor.execute(
                f"""
                INSERT INTO main.adresse (
                    clef_interop, code_postal, nom_commune,
                    nom_voie, numero_voie, geom, code_insee, repetition, code_ban
                ) VALUES {",".join(values_parts)}
                ON CONFLICT (code_postal, nom_commune, nom_voie, COALESCE(numero_voie, 0), COALESCE(repetition, ''))
                DO UPDATE SET
                    code_insee = COALESCE(EXCLUDED.code_insee, main.adresse.code_insee)
                RETURNING id
                """,
                tuple(flat_params),
            )
            for j, row in enumerate(cursor.fetchall()):
                _, struct_indices = chunk[j]
                for idx in struct_indices:
                    inserted_adresse_ids[idx] = row[0]
        cursor.execute("RELEASE SAVEPOINT adresse_insert")
    except Exception as e:
        cursor.execute("ROLLBACK TO SAVEPOINT adresse_insert")
        if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
            logging.warning("Table main.adresse absente, insertion d'adresses ignorée.")
        else:
            raise

    logging.info(
        "Batch adresse insert : %s adresses uniques insérées/mises à jour pour %s structures.",
        len(unique_adresses),
        len(inserted_adresse_ids),
    )

    # --- Pré-résoudre adresse_id ---
    resolved_adresse_ids = {}
    for i, s in enumerate(structures):
        ci = str(s.get("clef_interop")) if s.get("clef_interop") else None
        cb = str(s.get("code_ban")) if s.get("code_ban") else None
        resolved_adresse_ids[i] = (
            adresse_by_clef.get(ci)
            or adresse_by_code_ban.get(cb)
            or inserted_adresse_ids.get(i)
        )

    # --- Normaliser dispositif_programmes_nationaux ---
    for s in structures:
        dpn = s.get("dispositif_programmes_nationaux")
        if dpn is None or isinstance(dpn, list):
            continue
        raw = str(dpn).strip()
        if not raw or raw in ("None", "nan", "NaN", "[]", "{}"):
            s["dispositif_programmes_nationaux"] = None
        else:
            import json as _json

            try:
                parsed = _json.loads(raw.replace("'", '"'))
                s["dispositif_programmes_nationaux"] = (
                    parsed if isinstance(parsed, list) else [raw]
                )
            except Exception:
                s["dispositif_programmes_nationaux"] = [raw]

    # --- Filtrer sans nom ---
    before_count = len(structures)
    valid_structures = [(i, s) for i, s in enumerate(structures) if s.get("nom")]
    if len(valid_structures) < before_count:
        logging.warning(
            "%s structures ignorées (nom manquant).",
            before_count - len(valid_structures),
        )

    # --- Refonte phase 4a : écriture main.structure_administrative ---
    # AC ne crée jamais de lieu_inclusion (les affectations AC sont toutes
    # type='structure_emploi' — cf ingest_personne_affectations plus bas).
    # Les champs LI-only (nom, dispositif_programmes_nationaux) ne sont pas
    # écrits ici ; le LI sera créé par le DAG carto si la structure est
    # France Services et apparaît sur la carto nationale.
    #
    # UPSERT antenne-aware : un SIRET pouvant porter plusieurs antennes
    # (denomination_antenne, cf décision 2026-05-25), on identifie la SA par
    # (siret, denomination_antenne) — et non par SIRET seul, qui matcherait
    # plusieurs lignes et provoquerait une collision sur structure_ac_id.

    # --- Préparation antenne-aware (décision 2026-05-29 : AC = sa propre antenne) ---
    # denomination_antenne = nom AC : l'identité d'une structure AC au sein d'un
    # SIRET est son nom. Un même SIRET peut porter plusieurs antennes (créées par
    # coop / idposte) ; l'UPSERT sur la contrainte (siret, denomination_antenne)
    # attache l'ac_id à l'antenne de même nom si elle existe, sinon crée une
    # nouvelle antenne AC. Les structures sans SIRET sont identifiées par ac_id.
    for _, s in valid_structures:
        s["denomination_antenne"] = s.get("nom")

    # --- Correctif casse (#1743) : réutiliser l'antenne existante -------------
    # Le ON CONFLICT (siret, denomination_antenne) est sensible à la casse : un nom
    # de casse/espacement différent ("Cidff 07" vs "CIDFF 07") ne matche pas la SA
    # existante et crée une antenne doublon. On réaligne donc denomination_antenne
    # sur la valeur EXACTE déjà en base quand un équivalent normalisé (lower/strip)
    # existe. Lookup filtré sur deleted_at IS NULL : on ne réutilise jamais une SA
    # soft-deletée (évite de faire recouler AC vers une perdante de fusion #1468).
    def _match_key(name):
        return (name or "").strip().lower()

    sirets_in = {s["siret"] for _, s in valid_structures if s.get("siret")}
    existing_antennes = {}
    canonical_rows = {}
    if sirets_in:
        cursor.execute(
            "SELECT siret, denomination_antenne, structure_ac_id, denomination_sirene "
            "FROM main.structure_administrative "
            "WHERE deleted_at IS NULL AND siret = ANY(%s)",
            (list(sirets_in),),
        )
        for row_siret, row_antenne, row_acid, row_denom in cursor.fetchall():
            if row_antenne is None:
                # SA canonique (#1681) : antenne NULL, nom = denomination_sirene.
                canonical_rows.setdefault(row_siret, (row_denom, row_acid))
                continue
            key = (row_siret, _match_key(row_antenne))
            # Préférer une antenne non ancrée AC (ac_id NULL, réutilisable par
            # n'importe quel ac_id) à une antenne déjà ancrée.
            prev = existing_antennes.get(key)
            if prev is None or (prev[1] is not None and row_acid is None):
                existing_antennes[key] = (row_antenne, row_acid)

    for _, s in valid_structures:
        if s.get("siret"):
            match = existing_antennes.get(
                (s["siret"], _match_key(s.get("denomination_antenne")))
            )
            if match is not None:
                canon_antenne, canon_acid = match
                # Ne réaligner QUE si l'antenne existante n'est pas déjà ancrée à un
                # AUTRE ac_id : sinon l'UPSERT (siret, denomination_antenne) tomberait
                # dessus et le COALESCE jetterait l'ac_id entrant → on perdrait
                # l'identité d'une structure AC distincte (fait 2026-05-25 : antenne =
                # identité source). Dans ce cas on laisse le comportement d'origine.
                if canon_acid is None or canon_acid == s.get("structure_ac_id"):
                    s["denomination_antenne"] = canon_antenne
                continue
            # --- Respect de la canonisation (#1681) --------------------------
            # SA canonique = (siret, antenne NULL), nom porté par denomination_sirene.
            # Si le nom AC n'est qu'une redite du nom du canonique (égalité
            # normalisée), on pose antenne = NULL : l'UPSERT matche le canonique
            # (contrainte NULLS NOT DISTINCT) et y attache l'ac_id, au lieu de
            # recréer une antenne doublon au nom redondant. Un nom distinct
            # (France Services X…) garde son antenne : vrai lieu/service à part.
            # Même garde ac_id que ci-dessus : ne pas voler le canonique d'un
            # autre ac_id.
            canonical = canonical_rows.get(s["siret"])
            if canonical is not None:
                canon_denom, canon_acid = canonical
                if _match_key(s.get("denomination_antenne")) == _match_key(
                    canon_denom
                ) and (canon_acid is None or canon_acid == s.get("structure_ac_id")):
                    s["denomination_antenne"] = None

    # --- Dédupe sur TOUTES les clés uniques avant batch (règle CLAUDE.md) -----
    # main.structure_administrative porte deux contraintes uniques que cette
    # ingestion peut violer : structure_ac_id_ukey et siret_antenne_ukey
    # (NULLS NOT DISTINCT). Un ON CONFLICT n'en cible qu'une : toute ligne qui
    # violerait l'autre fait lever UniqueViolation et échouer TOUT le run.
    # Vécu : (null, "HABITAT JEUNES CANTAL") le 2026-07-31, puis
    # (null, "CHATEAU RENARD") à partir du 2026-09-17 — AC avait renommé
    # f67f296e… en « France services La Poste de Château-Renard » et créé une
    # nouvelle structure au nom libéré, que la SA de f67f296e porte toujours
    # (#1743 : le nom appartient à la structure, pas à la source).
    # On écarte donc ces collisions en amont, vers staging.rejets : ce sont des
    # collisions d'identité côté source, qui demandent un arbitrage métier
    # (fusion / renommage dans MIN), pas un rattachement deviné sur l'homonymie.
    rejets = []

    def _rejeter(motif, s, **extra):
        rejets.append(
            Rejet(
                motif=motif,
                source_key=str(s.get("structure_ac_id") or ""),
                payload={
                    "structure_ac_id": str(s.get("structure_ac_id") or "") or None,
                    "siret": s.get("siret"),
                    "denomination_antenne": s.get("denomination_antenne"),
                    **extra,
                },
            )
        )

    # 1) structure_ac_id_ukey, intra-batch : un même ac_id ne peut donner qu'une
    #    SA (deux lignes source homonymes d'id identique = doublon source).
    dedup_ac = []
    ac_ids_vus = {}
    for orig_idx, s in valid_structures:
        ac_id = s.get("structure_ac_id")
        if ac_id is not None:
            if ac_id in ac_ids_vus:
                _rejeter(
                    "structure_ac_id_doublon_intra_batch",
                    s,
                    denomination_antenne_retenue=ac_ids_vus[ac_id],
                )
                continue
            ac_ids_vus[ac_id] = s.get("denomination_antenne")
        dedup_ac.append((orig_idx, s))

    # 2) siret_antenne_ukey, intra-batch. On sépare avec / sans SIRET : la clé de
    #    conflit ciblée n'est pas la même (cf ON CONFLICT plus bas). Le lower()
    #    est plus strict que la contrainte (sensible à la casse) : deux variantes
    #    de casse sont fusionnées ici, aucune ne peut donc collisionner.
    with_siret = {}
    no_siret = {}
    for orig_idx, s in dedup_ac:
        if s.get("siret"):
            cle = (s["siret"], (s.get("denomination_antenne") or "").lower())
            if cle in with_siret:
                _rejeter("siret_antenne_doublon_intra_batch", s)
                continue
            with_siret[cle] = (orig_idx, s)
        elif s.get("structure_ac_id"):
            no_siret[s["structure_ac_id"]] = (orig_idx, s)

    # 3) siret_antenne_ukey côté base, pour le batch SANS SIRET : son ON CONFLICT
    #    cible structure_ac_id et ne couvre donc pas (NULL, denomination_antenne).
    #    ⚠️ Le lookup ne filtre PAS deleted_at : une SA soft-deletée occupe quand
    #    même la clé unique.
    if no_siret:
        noms_batch = {s.get("denomination_antenne") for _, s in no_siret.values()}
        noms = sorted(n for n in noms_batch if n is not None)
        sql_occupants = (
            "SELECT id, denomination_antenne, structure_ac_id "
            "FROM main.structure_administrative "
            "WHERE siret IS NULL AND (denomination_antenne = ANY(%s)"
        )
        if None in noms_batch:
            sql_occupants += " OR denomination_antenne IS NULL"
        sql_occupants += ")"
        cursor.execute(sql_occupants, (noms,))
        occupants = {
            row_antenne: (row_id, str(row_acid) if row_acid else None)
            for row_id, row_antenne, row_acid in cursor.fetchall()
        }
        retenus = {}
        noms_vus = {}
        for ac_id, (orig_idx, s) in no_siret.items():
            nom_antenne = s.get("denomination_antenne")
            occupant = occupants.get(nom_antenne)
            if occupant is not None and occupant[1] != str(ac_id):
                _rejeter(
                    "antenne_sans_siret_deja_en_base",
                    s,
                    sa_occupante_id=occupant[0],
                    sa_occupante_structure_ac_id=occupant[1],
                )
                continue
            # Intra-batch : no_siret est indexé par ac_id, deux ac_id homonymes
            # y cohabitent — la 2e violerait la contrainte à l'INSERT.
            if nom_antenne in noms_vus:
                _rejeter(
                    "antenne_sans_siret_doublon_intra_batch",
                    s,
                    structure_ac_id_retenu=noms_vus[nom_antenne],
                )
                continue
            noms_vus[nom_antenne] = str(ac_id)
            retenus[ac_id] = (orig_idx, s)
        no_siret = retenus

    # 4) structure_ac_id_ukey côté base, pour le batch AVEC SIRET : son ON CONFLICT
    #    cible (siret, denomination_antenne). Si l'ac_id entrant est déjà posé sur
    #    une SA d'une AUTRE clé (siret ou antenne différents), l'INSERT créerait un
    #    2e porteur du même ac_id. Filet : en usage DAG, structures_ingest_dag ne
    #    passe que des structures dont l'ac_id est absent de SA.
    if with_siret:
        ac_ids = sorted(
            {
                str(s["structure_ac_id"])
                for _, s in with_siret.values()
                if s.get("structure_ac_id")
            }
        )
        porteurs = {}
        if ac_ids:
            cursor.execute(
                "SELECT structure_ac_id, id, siret, denomination_antenne "
                "FROM main.structure_administrative "
                "WHERE structure_ac_id = ANY(%s::uuid[])",
                (ac_ids,),
            )
            porteurs = {
                str(row_acid): (row_id, row_siret, row_antenne)
                for row_acid, row_id, row_siret, row_antenne in cursor.fetchall()
            }
        retenus = {}
        for cle, (orig_idx, s) in with_siret.items():
            porteur = porteurs.get(str(s.get("structure_ac_id") or ""))
            if porteur is not None and (porteur[1], porteur[2]) != (
                s.get("siret"),
                s.get("denomination_antenne"),
            ):
                _rejeter(
                    "structure_ac_id_deja_sur_autre_sa",
                    s,
                    sa_porteuse_id=porteur[0],
                    sa_porteuse_siret=porteur[1],
                    sa_porteuse_denomination_antenne=porteur[2],
                )
                continue
            retenus[cle] = (orig_idx, s)
        with_siret = retenus

    if rejets:
        motifs = {}
        for r in rejets:
            motifs[r.motif] = motifs.get(r.motif, 0) + 1
        logging.warning(
            "%s structures AC écartées (collision de clé unique) : %s",
            len(rejets),
            ", ".join(f"{m}={n}" for m, n in sorted(motifs.items())),
        )

    # --- UPSERT SA en 2 batchs (par clé de conflit) ---
    sa_cols = (
        "structure_ac_id, siret, denomination_antenne, adresse_id, "
        "etat_administratif, code_activite_principale, categorie_juridique, "
        "denomination_sirene, nb_mandats_ac, deleted_at, deleted_by, "
        "edited_by, updated_at_ac"
    )
    sa_value_tmpl = (
        "(%s::uuid, %s, %s, %s::integer, %s, %s, %s, %s, %s::integer, "
        "CASE WHEN %s::boolean = FALSE THEN %s::timestamp ELSE NULL END, "
        "CASE WHEN %s::boolean = FALSE THEN ARRAY['aidants-connect'] ELSE NULL END, "
        "'aidants-connect', %s::timestamp)"
    )

    def sa_params(orig_idx, s):
        is_active = s.get("is_active_ac")
        return [
            s.get("structure_ac_id"),
            s.get("siret"),
            s.get("denomination_antenne"),
            resolved_adresse_ids[orig_idx],
            s.get("etat_administratif"),
            s.get("code_activite_principale"),
            s.get("categorie_juridique"),
            s.get("denomination_sirene"),
            s.get("nb_mandats_ac"),
            is_active,
            s.get("updated_at_ac"),
            is_active,
            s.get("updated_at_ac"),
        ]

    # Champs enrichis communs aux 2 clauses DO UPDATE.
    common_set = """
                adresse_id = COALESCE(EXCLUDED.adresse_id, main.structure_administrative.adresse_id),
                etat_administratif = COALESCE(EXCLUDED.etat_administratif, main.structure_administrative.etat_administratif),
                code_activite_principale = COALESCE(EXCLUDED.code_activite_principale, main.structure_administrative.code_activite_principale),
                categorie_juridique = COALESCE(EXCLUDED.categorie_juridique, main.structure_administrative.categorie_juridique),
                denomination_sirene = COALESCE(EXCLUDED.denomination_sirene, main.structure_administrative.denomination_sirene),
                nb_mandats_ac = COALESCE(EXCLUDED.nb_mandats_ac, main.structure_administrative.nb_mandats_ac),
                deleted_at = CASE
                    WHEN EXCLUDED.deleted_at IS NOT NULL
                         AND EXCLUDED.deleted_at >= COALESCE(main.structure_administrative.deleted_at, EXCLUDED.deleted_at)
                    THEN EXCLUDED.deleted_at
                    ELSE main.structure_administrative.deleted_at
                END,
                deleted_by = CASE
                    WHEN EXCLUDED.deleted_by IS NOT NULL THEN
                        CASE
                            WHEN main.structure_administrative.deleted_by IS NOT NULL
                                 AND 'aidants-connect' = ANY(main.structure_administrative.deleted_by)
                            THEN main.structure_administrative.deleted_by
                            ELSE array_append(
                                COALESCE(main.structure_administrative.deleted_by, '{}'),
                                'aidants-connect'
                            )
                        END
                    ELSE main.structure_administrative.deleted_by
                END,
                edited_by = 'aidants-connect',
                updated_at_ac = EXCLUDED.updated_at_ac"""

    # Avec SIRET : conflit sur (siret, denomination_antenne) → attache l'ac_id à
    # l'antenne de même nom si elle existe (sans écraser un ac_id déjà posé),
    # sinon crée une nouvelle antenne AC.
    conflict_siret = (
        "ON CONFLICT ON CONSTRAINT structure_administrative_siret_antenne_ukey "
        "DO UPDATE SET\n"
        "                structure_ac_id = COALESCE("
        "main.structure_administrative.structure_ac_id, EXCLUDED.structure_ac_id),"
        + common_set
    )
    # Sans SIRET : conflit sur structure_ac_id (UPSERT idempotent).
    # ⚠️ Cet ON CONFLICT ne couvre pas structure_administrative_siret_antenne_ukey
    # (NULLS NOT DISTINCT) : les homonymes sans SIRET sont écartés en amont par la
    # garde collision ci-dessus (rejets → staging.rejets). Historique du bug :
    # (null, "HABITAT JEUNES CANTAL") au premier run post-fusion (2026-07-31),
    # (null, "CHATEAU RENARD") à partir du 2026-09-17.
    # ⚠️ On ne met JAMAIS à jour denomination_antenne sur une structure existante
    # (#1743) : le nom appartient à la structure une fois créée, pas à la source. MIN
    # autorise la fusion de structures et la migration des ac_id, et une structure peut
    # être rendue canonique (denomination_antenne = NULL après fusion / sync SIRENE) ;
    # aucun DAG ne doit pouvoir réécrire ce nom (un COALESCE écraserait même le NULL
    # canonique avec le nom AC entrant). denomination_antenne n'est donc posé qu'à la
    # création (INSERT), jamais en DO UPDATE — idem chemin avec-SIRET (common_set).
    conflict_acid = (
        "ON CONFLICT (structure_ac_id) DO UPDATE SET\n"
        "                siret = COALESCE(EXCLUDED.siret, main.structure_administrative.siret),"
        + common_set
    )

    def run_sa_batch(items, conflict_sql):
        items = list(items)
        total = 0
        for start in range(0, len(items), BATCH_SIZE):
            chunk = items[start : start + BATCH_SIZE]
            values_parts = [sa_value_tmpl] * len(chunk)
            flat_params = []
            for orig_idx, s in chunk:
                flat_params.extend(sa_params(orig_idx, s))
            cursor.execute(
                f"INSERT INTO main.structure_administrative ({sa_cols}) "
                f"VALUES {', '.join(values_parts)} {conflict_sql}",
                flat_params,
            )
            total += len(chunk)
        return total

    total_upserted = run_sa_batch(with_siret.values(), conflict_siret) + run_sa_batch(
        no_siret.values(), conflict_acid
    )
    logging.info(
        "Insertion structures terminée : %s upserts SA (%s avec SIRET, %s sans, "
        "%s écartées sur collision de clé unique).",
        total_upserted,
        len(with_siret),
        len(no_siret),
        len(rejets),
    )
    return {
        "inserted": total_upserted,
        "total": len(valid_structures),
        "ecartes": len(rejets),
        "rejets": rejets,
    }


# ── Affectations personne-structure ──────────────────────────────────────


def ingest_personne_affectations(conn, aidants: list[dict]) -> dict:
    """Ingère les affectations personne-structure via batch lookups + upsert.

    Returns dict avec les compteurs.
    """
    if not aidants:
        return {"upserted": 0, "skipped": 0}

    BATCH_SIZE = 500
    cursor = conn.cursor()

    # --- 1) Batch lookup : structure_ac_id -> structure_administrative.id ---
    # Refonte phase 4a : AC ne produit que des affectations type='structure_emploi'
    # (cf in dur ci-dessous). On lookup donc uniquement la SA, pas de LI.
    all_ac_ids = list(
        {u.get("structure_ac_id") for u in aidants if u.get("structure_ac_id")}
    )
    sa_map = {}
    try:
        for row in _batch_query(
            cursor,
            "SELECT structure_ac_id, id FROM main.structure_administrative WHERE structure_ac_id IN ({placeholders})",
            all_ac_ids,
        ):
            sa_map[row[0]] = row[1]
    except Exception as e:
        if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
            logging.warning(
                "Table main.structure_administrative absente, aucune affectation ne sera créée."
            )
        else:
            raise

    # --- 2) Batch lookup : aidant_connect_id -> personne_id ---
    all_aidant_ids = list(
        {u.get("aidant_connect_id") for u in aidants if u.get("aidant_connect_id")}
    )
    personne_map = {}
    try:
        for row in _batch_query(
            cursor,
            "SELECT aidant_connect_id, id FROM main.personne WHERE aidant_connect_id IN ({placeholders})",
            all_aidant_ids,
        ):
            personne_map[row[0]] = row[1]
    except Exception as e:
        if "UndefinedTable" in type(e).__name__ or "relation" in str(e).lower():
            logging.warning(
                "Table main.personne absente, aucune affectation ne sera créée."
            )
        else:
            raise

    logging.info(
        "Batch lookups : %s structures (SA), %s personnes trouvées.",
        len(sa_map),
        len(personne_map),
    )

    # --- 3) Construire les rows ---
    # Refonte phase 4a : INSERT INTO main.personne_affectations_emploi.
    # source = 'aidants-connect' (le type='structure_emploi' est implicite
    # car la table dédiée ne stocke que les affectations d'emploi).
    insert_rows = []
    skipped = 0
    for u in aidants:
        sa_id = sa_map.get(u.get("structure_ac_id"))
        personne_id = personne_map.get(u.get("aidant_connect_id"))

        if not sa_id or not personne_id:
            skipped += 1
            continue

        is_active = u.get("is_active_ac", True)
        insert_rows.append((personne_id, sa_id, "aidants-connect", is_active))

    # --- 4) Dédupliquer ---
    # Clé unique métier : (personne_id, structure_administrative_id, source)
    seen = {}
    deduped_rows = []
    for row in insert_rows:
        key = (row[0], row[1], row[2])
        if key not in seen:
            seen[key] = len(deduped_rows)
            deduped_rows.append(row)
        else:
            deduped_rows[seen[key]] = row

    logging.info(
        f"{len(deduped_rows)} affectations uniques à insérer ({skipped} ignorées sans SA / personne)."
    )

    # --- 5) Batch upsert ---
    total_upserted = 0
    for start in range(0, len(deduped_rows), BATCH_SIZE):
        chunk = deduped_rows[start : start + BATCH_SIZE]
        values_ph = ", ".join(["(%s, %s, %s, %s)"] * len(chunk))
        flat_params = [p for r in chunk for p in r]
        cursor.execute(
            f"""
            INSERT INTO main.personne_affectations_emploi
                (personne_id, structure_administrative_id, source, est_active)
            VALUES {values_ph}
            ON CONFLICT (personne_id, structure_administrative_id, source)
            DO UPDATE SET est_active = EXCLUDED.est_active
            """,
            flat_params,
        )
        total_upserted += len(chunk)

    logging.info(f"Insertion affectations terminée : {total_upserted} upserts emploi.")
    return {"upserted": total_upserted, "skipped": skipped}
