import json
import logging
import re

import pandas as pd

from etl.transform.normalizer_utils import format_and_validate_phone
from etl.transform.normalizer_utils import normalize_nom
from etl.transform.normalizer_utils import normalize_prenom
from etl.transform.normalizer_utils import validate_code_insee
from etl.transform.normalizer_utils import validate_pivot


def dedup_rows_by_structure_tp_id(rows):
    """Itère `rows` en ne gardant que la première occurrence par `structure_tp_id`.

    Le CSV id-poste est tabulaire multidim : N lignes peuvent porter le même
    `structure_tp_id` avec des attributs structure identiques.
    `main.structure_administrative` impose `UNIQUE(structure_tp_id)`.
    Voir `docs/id-poste-regles.md`.

    Args:
        rows: itérable de mappings (dict ou pandas Series) exposant `.get(key)`.

    Yields:
        Les lignes conservées (None / NaN sur `structure_tp_id` sont sautées).
    """
    seen = set()
    for row in rows:
        tp_id = row.get("structure_tp_id")
        if tp_id is None or pd.isna(tp_id):
            continue
        if tp_id in seen:
            continue
        seen.add(tp_id)
        yield row


COLUMN_MAPPING = {
    "poste": {
        "id_poste": "poste_conum_id",
        "id_structure": "structure_tp_id",
        "etat": "etat",
        "etat_de_l'instruction_v1": "etat_instruction_v1",
        "etat_de_l'instruction_v2": "etat_instruction_v2",
        "id_cn": "cn_pg_id",
        "date_attribution": "date_attribution",
        "date_rendu_de_poste": "date_rendu_poste",
        "typologie": "typologie",
        "origine_transfert": "origine_transfert",
        "poste_renouvelé": "poste_renouvele",
        "action_coselec": "action_coselec",
    },
    "structure": {
        "id_structure": "structure_tp_id",
        "nom_structure": "nom",
        "siret": "siret",
        "publique/privée": "publique",
        "adresse_structure": "adresse",
        "code_insee": "code_insee",
        "code_postal": "code_postal",
        "nom_référent_tp": "nom_referent_tp",
        "prénom_référent_tp": "prenom_referent_tp",
        "telephone": "telephone",
        "mail_gestionnaire": "mail_gestionnaire",
        "mail_2": "mail_2",
        "référent_hiérarchique": "referent_hierarchique",
    },
    "formation": {
        "id_cn": "personne_id_pg",
        "lot": "lot",
        "marché_de_formation": "marche_formation",
        "formation": "label",
        "date_de_départ": "date_debut",
        "date_de_fin": "date_fin",
        "lieu": "lieu",
        "parcours": "parcours",
        "pix": "pix",
        "remn": "remn",
        "statut_formation_conum": "observations",
    },
    "subvention": {
        "id_poste": "poste_id",
        "territoire_prioritaire": "is_territoire_prioritaire",
    },
    "personne": {
        "id_cn": "cn_pg_id",
        "id_structure": "structure_tp_id",
        "nom": "nom",
        "prénom": "prenom",
        "mail_pro": "mail_pro",
        "mail_perso": "mail_perso",
    },
    "contrat": {
        "id_cn": "cn_pg_id",
        "id_structure": "structure_tp_id",
        "date_debut_contrat": "date_debut",
        "date_fin_contrat": "date_fin",
        "date_rupture": "date_rupture",
        "type_ct": "type",
    },
}


def transform_data(data, column_map):
    mapped_data = data[list(column_map.keys())].rename(columns=column_map)
    mapped_data = mapped_data.where(pd.notna(mapped_data), None)
    return mapped_data


def create_emails_column_personne(row):
    idposte = {
        key: value
        for key, value in {
            "mail_pro": row.get("mail_pro"),
            "mail_perso": row.get("mail_perso"),
        }.items()
        if value and value.lower() != "absent"
    }

    if idposte:
        return json.dumps({"idposte": idposte}, ensure_ascii=False)
    return None


def normalize_lieu_formation(value):
    if not isinstance(value, str):
        return value
    value = value.strip()

    # Supprimer les annotations "Session X"
    value = re.sub(r"\s+Session\s+\d+", "", value, flags=re.IGNORECASE)

    # Nettoyage personnalisé des noms
    corrections = {
        "Clermont Ferrand": "Clermont-Ferrand",
        "Ales": "Alès",
        "Clermant Ferrand": "Clermont-Ferrand",
        "St Clotilde": "Sainte-Clotilde",
        "Ste Clotilde": "Sainte-Clotilde",
        "Villeuneuve": "Villeneuve",
        "Kremlin-Bicetre": "Le Kremlin-Bicêtre",
        "Kremlin-Bicêtre": "Le Kremlin-Bicêtre",
        "St Gilles": "Saint-Gilles",
        "St Lô": "Saint-Lô",
        "St Omer": "Saint-Omer",
        "St Quentin": "Saint-Quentin",
        "Saint Etienne": "Saint-Étienne",
        "Saint Brieuc": "Saint-Brieuc",
        "Villeneuve La Garenne": "Villeneuve-la-Garenne",
        "Aix En Provence": "Aix-en-Provence",
        "Bourg En Bresse": "Bourg-en-Bresse",
        "Charleville Mézières": "Charleville-Mézières",
        "La Roche Sur Yon": "La Roche-sur-Yon",
        "Distanciel -": "Distanciel",
        "Dispensé": "Distanciel",
        "Montmoreau St Cybard": "Montmoreau-Saint-Cybard",
        "Montmoreau-St-Cybard": "Montmoreau-Saint-Cybard",
        "Montceau": "Montceau-les-Mines",
        "Paris 13": "Paris 13ème",
        "Paris 20": "Paris 20ème",
        "Paris 11": "Paris 11ème",
        "Saint Jean De Védas": "Saint-Jean-de-Védas",
        "Saint Paul": "Saint-Paul",
        "Saint Léonard De Noblat": "Saint-Léonard-de-Noblat",
        "Brive La Gaillarde": "Brive-la-Gaillarde",
        "Brive": "Brive-la-Gaillarde",
    }

    value = corrections.get(value, value)

    # Appliquer le title sur les valeurs restantes
    return value.title()


def create_contact_column(row):
    contact = {
        key: value
        for key, value in {
            "nom": normalize_nom(row.get("nom_referent_tp")),
            "prenom": normalize_prenom(row.get("prenom_referent_tp")),
            "telephone": format_and_validate_phone(row.get("telephone")),
        }.items()
        if value
    }

    emails = {
        key: value
        for key, value in {
            "mail_gestionnaire": row.get("mail_gestionnaire"),
            "mail_2": row.get("mail_2"),
            "referent_hierarchique": row.get("referent_hierarchique"),
        }.items()
        if value and value.lower() != "absent"
    }

    if emails:
        contact["courriels"] = emails

    return json.dumps(contact, ensure_ascii=False) if contact else None


def any_of(options):
    return r"(?:%s)" % "|".join(re.escape(opt) for opt in options)


# ---------------- Subvention helpers ----------------


def _parse_date(value):
    if pd.isna(value):
        return None
    s = str(value).strip()
    if not s or s.lower() in {"none", "null", "nan"}:
        return None
    # normalize separators
    s = s.replace(".", "/").replace(" ", "")
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y", "%Y/%m/%d"):
        try:
            return pd.to_datetime(s, format=fmt, errors="raise").date()
        except Exception:
            continue
    # compact dates like YYYYMMDD or DDMMYYYY
    if re.fullmatch(r"\d{8}", s):
        mm = int(s[4:6])
        try:
            if 1 <= mm <= 12:
                return pd.to_datetime(s, format="%Y%m%d").date()
            return pd.to_datetime(s, format="%d%m%Y").date()
        except Exception:
            return None
    # last resort
    try:
        return pd.to_datetime(s, errors="coerce").date()
    except Exception:
        return None


def _parse_int(value):
    """
    Convert a scalar to a nullable pandas Int64 integer.
    Returns pd.NA for non-numeric or empty values; ensures no 24.0 artifacts.
    """
    if pd.isna(value):
        return pd.NA
    s = str(value).strip()
    if not s or s.lower() in {"none", "null", "nan"}:
        return pd.NA
    s = s.replace("€", "").replace("\u00a0", "").replace(" ", "").replace(",", ".")
    # Use pandas to coerce, then cast to Int64 and return the scalar
    ser = pd.to_numeric(pd.Series([s]), errors="coerce").astype("Int64")
    val = ser.iloc[0]
    if pd.notna(val) and val == 0:
        return pd.NA
    return val


def _parse_bool(value):
    if pd.isna(value):
        return None
    s = str(value).strip().lower()
    return s in {"oui", "true", "vrai", "1", "yes"}


def _any_values(row, keys):
    for k in keys:
        if k not in row:
            continue
        v = row[k]
        if pd.isna(v):
            continue
        if isinstance(v, (int, float)) and v == 0:
            continue
        s = str(v).strip()
        if not s or s.lower() in {"0", "-", "none", "null", "nan"}:
            continue
        return True
    return False


def main(data):
    """Éclate le CSV id-poste en 6 DataFrames transformés.

    Retourne {table_name: DataFrame} (structure, poste, personne, formation,
    subvention, contrat) — le DAG les écrit dans le silver staging.idposte__*.
    """
    tables = {}
    for table_name, columns_map in COLUMN_MAPPING.items():
        data.columns = data.columns.str.strip()
        available_columns = [col for col in columns_map.keys() if col in data.columns]
        if not available_columns:
            logging.info(
                f"Aucune colonne disponible pour la table '{table_name}' dans le CSV."
            )
            continue

        if table_name == "subvention":
            logging.info(
                "[DEBUG] 🎯 VERSION CODE: Subvention OPTION A - Total V2 contient déjà bonifications (2026-03-04)"
            )
            # IMPORTANT : Grouper par id_poste et SOMMER les montants car le CSV contient plusieurs lignes par poste
            # (une ligne par conseiller numérique avec montants répartis)
            # Les colonnes de dates/conventions sont prises via aggregation (first/max)
            # OPTION A : montant_subventions_total_(=ae_total) contient DÉJÀ les bonifications

            # Colonnes à sommer
            sum_cols = [
                "montant_subventions_total_(=ae_total)_v1",
                "montant_versement_dgcl",
                "avoir_v1",
                "montant_subventions_total_(=ae_total)",  # V2 - contient déjà bonifications
                "bonifications_découlant_du_lieu_de_permanence",  # Pour comptage structures bonif
                "avoir_v2",
                "montant_versement_1e_tranche",
                "montant_versement_2e_tranche",
                "montant_versement_3e_tranche",
            ]

            # Colonnes à prendre (first)
            first_cols = [
                "date_début/signature_convention_v1",
                "date_fin_convention_v1",
                "date_début_financement_dgcl",
                "date_de_fin_financement_dgcl",
                "mois_consommés_sur_la_période_de_financement_dgcl",
                "date_début/signature_convention_v2",
                "date_fin_convention_v2",
                "date_début_financement_ditp",
                "date_de_fin_financement_ditp",
                "mois_consommés_sur_la_période_de_financement_ditp",
                "date_début_financement_dge",
                "date_de_fin_financement_dge",
                "mois_consommés_sur_la_période_de_financement_dge",
                "date_versement_1e_tranche",
                "date_versement_2e_tranche",
                "date_versement_3e_tranche",
            ]

            # Debug: afficher les colonnes montant_subventions_total
            logging.info("[DEBUG] 🔎 Colonnes contenant 'montant_subventions_total':")
            for col in data.columns:
                if "montant_subventions_total" in col.lower():
                    logging.info(f"[DEBUG]   - '{col}' (longueur: {len(col)})")

            # Debug: vérifier si les colonnes V2 existent
            col_v2_wanted = "montant_subventions_total_(=ae_total)"
            col_bonif_wanted = "bonifications_découlant_du_lieu_de_permanence"
            logging.info(
                f"[DEBUG] Colonne V2 recherchée: '{col_v2_wanted}' -> {'✅ TROUVÉE' if col_v2_wanted in data.columns else '❌ NON TROUVÉE'}"
            )
            logging.info(
                f"[DEBUG] Colonne bonif recherchée: '{col_bonif_wanted}' -> {'✅ TROUVÉE' if col_bonif_wanted in data.columns else '❌ NON TROUVÉE'}"
            )

            # Debug: lister toutes les colonnes contenant 'bonif'
            logging.info("[DEBUG] 🔎 Colonnes contenant 'bonif':")
            for col in data.columns:
                if "bonif" in col.lower():
                    logging.info(f"[DEBUG]   - '{col}' (longueur: {len(col)})")
                    # Afficher quelques valeurs uniques non-nulles
                    unique_vals = data[col].dropna().unique()[:5]
                    logging.info(f"[DEBUG]     Valeurs uniques (sample): {unique_vals}")

            # Créer dictionnaire d'agrégation
            agg_dict = {col: "sum" for col in sum_cols if col in data.columns}
            agg_dict.update({col: "first" for col in first_cols if col in data.columns})

            # IMPORTANT: Les bonifications doivent être MAX et non SUM
            # (même poste = même bonification, mais plusieurs lignes dans le CSV)
            if "bonifications_découlant_du_lieu_de_permanence" in agg_dict:
                agg_dict["bonifications_découlant_du_lieu_de_permanence"] = "max"
                logging.info(
                    "[DEBUG] ⚠️  Bonifications: agrégation changée de SUM à MAX"
                )

            logging.info(
                f"[DEBUG] 📋 Colonnes dans agg_dict pour SUM: {[k for k, v in agg_dict.items() if v == 'sum']}"
            )

            # Grouper et agréger
            data_grouped = data.groupby("id_poste", as_index=False).agg(agg_dict)
            logging.info(
                f"[DEBUG] 📊 Subventions: {len(data)} lignes CSV -> {len(data_grouped)} postes uniques après agrégation"
            )

            # Stats sur les colonnes V2
            col_total = " montant_subventions_total_(=ae_total) "
            if col_total in data_grouped.columns:
                non_null_v2 = data_grouped[col_total].notna().sum()
                logging.info(
                    f"[DEBUG] 📈 Postes avec V2 non-null: {non_null_v2}/{len(data_grouped)}"
                )
            else:
                logging.warning(f"[DEBUG] ⚠️  Colonne '{col_total}' NON TROUVÉE !")

            logging.info(
                f"Subventions: {len(data)} lignes CSV -> {len(data_grouped)} postes uniques après agrégation"
            )

            # Debug: statistiques sur les bonifications AVANT et APRÈS agrégation
            if "bonifications_découlant_du_lieu_de_permanence" in data.columns:
                bonif_avant = data["bonifications_découlant_du_lieu_de_permanence"]
                nb_lignes_7500 = (bonif_avant == 7500).sum()
                nb_lignes_10125 = (bonif_avant == 10125).sum()

                # Compter les POSTES DISTINCTS (pas les lignes)
                postes_distincts_avec_7500 = data[bonif_avant == 7500][
                    "id_poste"
                ].nunique()
                postes_distincts_avec_10125 = data[bonif_avant == 10125][
                    "id_poste"
                ].nunique()

                # Analyser les postes avec bonifications mixtes
                bonif_par_poste = data.groupby("id_poste")[
                    "bonifications_découlant_du_lieu_de_permanence"
                ].agg(["min", "max", "nunique"])
                postes_mixtes = bonif_par_poste[
                    (bonif_par_poste["min"] != bonif_par_poste["max"])
                    & (bonif_par_poste["nunique"] > 1)
                ]
                postes_avec_7500_et_10125 = bonif_par_poste[
                    (bonif_par_poste["min"].isin([0, 7500]))
                    & (bonif_par_poste["max"] == 10125)
                ]

                logging.info("[DEBUG] 📊 Bonifications AVANT agrégation (CSV source):")
                logging.info(f"[DEBUG]   - Lignes avec 7500€: {nb_lignes_7500}")
                logging.info(f"[DEBUG]   - Lignes avec 10125€: {nb_lignes_10125}")
                logging.info(
                    f"[DEBUG]   - POSTES DISTINCTS avec 7500€: {postes_distincts_avec_7500}"
                )
                logging.info(
                    f"[DEBUG]   - POSTES DISTINCTS avec 10125€: {postes_distincts_avec_10125}"
                )
                logging.info(
                    f"[DEBUG]   - Postes avec bonifications MIXTES: {len(postes_mixtes)}"
                )
                logging.info(
                    f"[DEBUG]   - Postes avec 7500 ET 10125: {len(postes_avec_7500_et_10125)}"
                )

            if "bonifications_découlant_du_lieu_de_permanence" in data_grouped.columns:
                bonif_col = data_grouped[
                    "bonifications_découlant_du_lieu_de_permanence"
                ]
                nb_bonif_7500 = (bonif_col == 7500).sum()
                nb_bonif_10125 = (bonif_col == 10125).sum()
                nb_bonif_0 = (bonif_col == 0).sum()
                nb_bonif_null = bonif_col.isna().sum()
                nb_bonif_other = (
                    len(bonif_col)
                    - nb_bonif_7500
                    - nb_bonif_10125
                    - nb_bonif_0
                    - nb_bonif_null
                )

                # Afficher les valeurs uniques "autres"
                valeurs_autres = bonif_col[
                    ~bonif_col.isin([7500, 10125, 0]) & bonif_col.notna()
                ].unique()

                logging.info("[DEBUG] 📊 Bonifications APRÈS agrégation (max):")
                logging.info(f"[DEBUG]   - 7500€: {nb_bonif_7500} postes")
                logging.info(f"[DEBUG]   - 10125€: {nb_bonif_10125} postes")
                logging.info(f"[DEBUG]   - 0€: {nb_bonif_0} postes")
                logging.info(f"[DEBUG]   - NULL: {nb_bonif_null} postes")
                logging.info(f"[DEBUG]   - Autres: {nb_bonif_other} postes")
                if len(valeurs_autres) > 0:
                    logging.info(f"[DEBUG]   - Valeurs 'autres': {valeurs_autres[:10]}")

            out_rows = []
            # Créer une seule ligne par poste avec toutes les colonnes consolidées
            for _, r in data_grouped.iterrows():
                poste_id = _parse_int(r.get("id_poste"))
                if poste_id is None:
                    continue

                # OPTION A : montant_subventions_total_(=ae_total) contient DÉJÀ les bonifications
                # On met directement ce montant total dans montant_subvention_v2
                # MAIS on stocke aussi les bonifications séparément pour les comptages
                montant_total_v2 = r.get("montant_subventions_total_(=ae_total)")
                montant_bonif_v2 = r.get(
                    "bonifications_découlant_du_lieu_de_permanence"
                )

                montant_total_v2_val = _parse_int(montant_total_v2)
                montant_bonif_v2_val = _parse_int(montant_bonif_v2)

                # Le montant total V2 va directement dans montant_subvention_v2 (bonifications incluses)
                montant_subv_v2_val = montant_total_v2_val

                # On stocke aussi les bonifications séparément (pour comptages structures bonif 7500/10125)

                # Log pour les postes de test de l'Allier
                if poste_id in [186, 187, 4496]:
                    logging.info(
                        f"[DEBUG] 🔍 Poste {poste_id}: total_v2={montant_total_v2_val}, subv_v2={montant_subv_v2_val}"
                    )

                row = {
                    "poste_id": poste_id,
                    # Dates et mois DGCL (V1)
                    "date_debut_convention_dgcl": _parse_date(
                        r.get("date_début/signature_convention_v1")
                    ),
                    "date_debut_financement_dgcl": _parse_date(
                        r.get("date_début_financement_dgcl")
                    ),
                    "date_fin_convention_dgcl": _parse_date(
                        r.get("date_fin_convention_v1")
                    ),
                    "date_fin_financement_dgcl": _parse_date(
                        r.get("date_de_fin_financement_dgcl")
                    ),
                    "mois_utilises_periode_financement_dgcl": _parse_int(
                        r.get("mois_consommés_sur_la_période_de_financement_dgcl")
                    ),
                    # Dates et mois DITP (V2)
                    "date_debut_convention_ditp": _parse_date(
                        r.get("date_début/signature_convention_v2")
                    ),
                    "date_debut_financement_ditp": _parse_date(
                        r.get("date_début_financement_ditp")
                    ),
                    "date_fin_convention_ditp": _parse_date(
                        r.get("date_fin_convention_v2")
                    ),
                    "date_fin_financement_ditp": _parse_date(
                        r.get("date_de_fin_financement_ditp")
                    ),
                    "mois_utilises_periode_financement_ditp": _parse_int(
                        r.get("mois_consommés_sur_la_période_de_financement_ditp")
                    ),
                    # Dates et mois DGE (V2)
                    "date_debut_convention_dge": _parse_date(
                        r.get("date_début/signature_convention_v2")
                    ),
                    "date_debut_financement_dge": _parse_date(
                        r.get("date_début_financement_dge")
                    ),
                    "date_fin_convention_dge": _parse_date(
                        r.get("date_fin_convention_v2")
                    ),
                    "date_fin_financement_dge": _parse_date(
                        r.get("date_de_fin_financement_dge")
                    ),
                    "mois_utilises_periode_financement_dge": _parse_int(
                        r.get("mois_consommés_sur_la_période_de_financement_dge")
                    ),
                    # Montants V1
                    "montant_subvention_v1": _parse_int(
                        r.get("montant_subventions_total_(=ae_total)_v1")
                    ),
                    "montant_versement_v1": _parse_int(r.get("montant_versement_dgcl")),
                    "montant_avoir_v1": _parse_int(r.get("avoir_v1")),
                    # Montants V2
                    "montant_bonification_v2": montant_bonif_v2_val,
                    "montant_subvention_v2": montant_subv_v2_val,
                    "montant_avoir_v2": _parse_int(r.get("avoir_v2")),
                    # Versements V2
                    "versement_1_v2": _parse_int(r.get("montant_versement_1e_tranche")),
                    "versement_2_v2": _parse_int(r.get("montant_versement_2e_tranche")),
                    "versement_3_v2": _parse_int(r.get("montant_versement_3e_tranche")),
                    "date_versement_1_v2": _parse_date(
                        r.get("date_versement_1e_tranche")
                    ),
                    "date_versement_2_v2": _parse_date(
                        r.get("date_versement_2e_tranche")
                    ),
                    "date_versement_3_v2": _parse_date(
                        r.get("date_versement_3e_tranche")
                    ),
                }

                out_rows.append(row)

            # Définir les colonnes dans l'ordre
            subvention_cols = [
                "poste_id",
                # Dates DGCL
                "date_debut_convention_dgcl",
                "date_debut_financement_dgcl",
                "date_fin_convention_dgcl",
                "date_fin_financement_dgcl",
                "mois_utilises_periode_financement_dgcl",
                # Dates DITP
                "date_debut_convention_ditp",
                "date_debut_financement_ditp",
                "date_fin_convention_ditp",
                "date_fin_financement_ditp",
                "mois_utilises_periode_financement_ditp",
                # Dates DGE
                "date_debut_convention_dge",
                "date_debut_financement_dge",
                "date_fin_convention_dge",
                "date_fin_financement_dge",
                "mois_utilises_periode_financement_dge",
                # Montants V1
                "montant_subvention_v1",
                "montant_versement_v1",
                "montant_avoir_v1",
                # Montants V2
                "montant_bonification_v2",
                "montant_subvention_v2",
                "montant_avoir_v2",
                # Versements V2
                "versement_1_v2",
                "versement_2_v2",
                "versement_3_v2",
                "date_versement_1_v2",
                "date_versement_2_v2",
                "date_versement_3_v2",
            ]

            table_data = pd.DataFrame(out_rows, columns=subvention_cols)

            # Force integer columns to nullable Int64
            int_cols = [
                "poste_id",
                "mois_utilises_periode_financement_dgcl",
                "mois_utilises_periode_financement_ditp",
                "mois_utilises_periode_financement_dge",
                "montant_subvention_v1",
                "montant_versement_v1",
                "montant_avoir_v1",
                "montant_bonification_v2",
                "montant_subvention_v2",
                "montant_avoir_v2",
                "versement_1_v2",
                "versement_2_v2",
                "versement_3_v2",
            ]

            for c in int_cols:
                if c in table_data.columns:
                    table_data[c] = pd.to_numeric(
                        table_data[c], errors="coerce"
                    ).astype("Int64")
                    table_data[c] = table_data[c].mask(table_data[c] == 0, pd.NA)

            tables[table_name] = table_data
            logging.info(
                "Table %s transformée : %s lignes.", table_name, len(table_data)
            )
            continue

        table_data = transform_data(data, columns_map)
        if table_name == "structure":
            table_data = table_data.drop_duplicates(
                subset=["structure_tp_id"], keep="first"
            )

            if "nom_referent_tp" in table_data.columns:
                table_data["structure_tp_id"] = (
                    table_data["structure_tp_id"]
                    .apply(lambda x: int(x) if pd.notna(x) else None)
                    .astype("Int64")
                )
                table_data["contact"] = table_data.apply(create_contact_column, axis=1)
                table_data["siret"] = table_data["siret"].apply(
                    lambda x: validate_pivot(
                        str(int(x)) if pd.notna(x) and not isinstance(x, str) else x
                    )
                )
                table_data["code_insee"] = table_data["code_insee"].apply(
                    lambda x: validate_code_insee(
                        str(int(x)) if pd.notna(x) and not isinstance(x, str) else x
                    )
                )
                table_data["publique"] = table_data["publique"].apply(
                    lambda x: x.lower() == "publique" if isinstance(x, str) else False
                )
                table_data["nom"] = table_data["nom"].apply(
                    lambda x: x.title() if pd.notna(x) else None
                )
                table_data = table_data.drop(
                    columns=[
                        "nom_referent_tp",
                        "prenom_referent_tp",
                        "telephone",
                        "mail_gestionnaire",
                        "mail_2",
                        "referent_hierarchique",
                    ],
                    errors="ignore",
                )
        if table_name == "poste":
            table_data = table_data.drop_duplicates(
                subset=["poste_conum_id", "structure_tp_id", "cn_pg_id"], keep="first"
            )
            table_data["poste_conum_id"] = pd.to_numeric(
                table_data["poste_conum_id"], errors="coerce"
            ).astype("Int64")
            table_data["poste_conum_id"] = table_data["poste_conum_id"].mask(
                table_data["poste_conum_id"] == 0, pd.NA
            )
            table_data["structure_tp_id"] = pd.to_numeric(
                table_data["structure_tp_id"], errors="coerce"
            ).astype("Int64")
            table_data["structure_tp_id"] = table_data["structure_tp_id"].mask(
                table_data["structure_tp_id"] == 0, pd.NA
            )
            table_data["cn_pg_id"] = pd.to_numeric(
                table_data["cn_pg_id"], errors="coerce"
            ).astype("Int64")
            table_data["cn_pg_id"] = table_data["cn_pg_id"].mask(
                table_data["cn_pg_id"] == 0, pd.NA
            )
            table_data["etat_instruction_v1"] = table_data["etat_instruction_v1"].apply(
                lambda x: (
                    "refusée"
                    if isinstance(x, str)
                    and x.strip().lower() == 'convention "refusée"'
                    else (
                        "bloquée"
                        if isinstance(x, str)
                        and x.strip().lower() == "convention bloquée"
                        else x.lower().strip()
                        if pd.notna(x)
                        else None
                    )
                )
            )
            table_data["etat_instruction_v2"] = table_data["etat_instruction_v2"].apply(
                lambda x: (
                    "refusée"
                    if isinstance(x, str)
                    and x.strip().lower() == 'convention "refusée"'
                    else (
                        "bloquée"
                        if isinstance(x, str)
                        and x.strip().lower() == "convention bloquée"
                        else x.lower().strip()
                        if pd.notna(x)
                        else None
                    )
                )
            )
            # Parse date attribution, date rendu poste en format date or None
            table_data["date_attribution"] = table_data["date_attribution"].apply(
                lambda x: _parse_date(x)
            )
            table_data["date_rendu_poste"] = table_data["date_rendu_poste"].apply(
                lambda x: _parse_date(x)
            )
            table_data["origine_transfert"] = (
                table_data["origine_transfert"]
                .apply(lambda x: int(x) if pd.notna(x) else None)
                .astype("Int64")
            )
            table_data["typologie"] = table_data["typologie"].apply(
                lambda x: (
                    x.lower()
                    if pd.notna(x) and x.lower() in {"conum", "coordo", "dns"}
                    else None
                )
            )
            table_data["etat"] = table_data.apply(
                lambda x: (
                    x["etat"].lower().strip().replace("occupé", "occupe")
                    if pd.notna(x["etat"])
                    else None
                ),
                axis=1,
            )
            table_data["poste_renouvele"] = table_data["poste_renouvele"].apply(
                lambda x: x.lower() == "oui" if pd.notna(x) else False
            )
            table_data["action_coselec"] = table_data["action_coselec"].apply(
                lambda x: x.lower() if pd.notna(x) else None
            )

            # drop null poste_conum_id rows
            table_data = table_data[pd.notna(table_data["poste_conum_id"])]
        if table_name == "personne":
            table_data = table_data.drop_duplicates(subset=["cn_pg_id"], keep="first")
            table_data = table_data[
                pd.notna(table_data["cn_pg_id"]) & (table_data["cn_pg_id"] != 0)
            ]

            table_data["nom"] = table_data["nom"].apply(
                lambda x: normalize_nom(x) if pd.notna(x) else None
            )
            table_data["prenom"] = table_data["prenom"].apply(
                lambda x: normalize_prenom(x) if pd.notna(x) else None
            )
            table_data["cn_pg_id"] = table_data["cn_pg_id"].apply(
                lambda x: int(x) if pd.notna(x) else None
            )
            table_data["structure_tp_id"] = table_data["structure_tp_id"].apply(
                lambda x: int(x) if pd.notna(x) else None
            )
            table_data["contact"] = table_data.apply(
                lambda row: create_emails_column_personne(row), axis=1
            )

            if (
                "structure_tp_id" not in table_data.columns
                and "structure_tp_id" in data.columns
            ):
                table_data["structure_tp_id"] = data["structure_tp_id"]
            table_data = table_data.drop(
                columns=["mail_pro", "mail_perso"], errors="ignore"
            )
        if table_name == "formation":
            table_data = table_data.drop_duplicates(
                subset=["personne_id_pg"], keep="first"
            )
            table_data = table_data[
                pd.notna(table_data["personne_id_pg"])
                & (table_data["personne_id_pg"] != 0)
            ]
            table_data["personne_id_pg"] = table_data["personne_id_pg"].apply(
                lambda x: int(x) if pd.notna(x) else None
            )
            table_data["lieu"] = table_data["lieu"].apply(normalize_lieu_formation)
            table_data["remn"] = table_data["remn"].astype(str).str.lower().eq("oui")
            table_data["pix"] = table_data["pix"].astype(str).str.lower().eq("oui")
            table_data["parcours"] = table_data["parcours"].apply(
                lambda x: x.strip().lower() if pd.notna(x) else None
            )
            table_data["label"] = table_data["label"].apply(
                lambda x: x.strip() if pd.notna(x) and x != "0" else None
            )
            table_data["observations"] = table_data["observations"].apply(
                lambda x: x.lower().strip() if pd.notna(x) else None
            )
            table_data["marche_formation"] = table_data["marche_formation"].apply(
                lambda x: x.strip().lower() if pd.notna(x) else None
            )
            table_data["lot"] = (
                table_data["lot"]
                .apply(lambda x: int(float(x)) if pd.notna(x) else pd.NA)
                .astype("Int64")
            )
            table_data["date_debut"] = table_data["date_debut"].apply(
                lambda x: _parse_date(x)
            )
            table_data["date_fin"] = table_data["date_fin"].apply(
                lambda x: _parse_date(x)
            )
        if table_name == "contrat":
            table_data = table_data[
                pd.notna(table_data["cn_pg_id"]) & (table_data["cn_pg_id"] != 0)
            ]
            table_data["cn_pg_id"] = table_data["cn_pg_id"].apply(
                lambda x: int(x) if pd.notna(x) else None
            )
            table_data["structure_tp_id"] = (
                table_data["structure_tp_id"]
                .apply(lambda x: int(x) if pd.notna(x) else None)
                .astype("Int64")
            )
            table_data["date_debut"] = table_data["date_debut"].apply(
                lambda x: (
                    None
                    if isinstance(x, str) and x.strip().lower() == "non renseignée"
                    else _parse_date(x)
                )
            )
            table_data["date_fin"] = table_data["date_fin"].apply(
                lambda x: (
                    None
                    if isinstance(x, str) and x.strip().lower() == "non renseignée"
                    else _parse_date(x)
                )
            )
            table_data["date_rupture"] = table_data["date_rupture"].apply(
                lambda x: None if x == "1900-01-00" else _parse_date(x)
            )

            s = table_data["type"].astype(str).str.strip().str.upper()
            variants = {
                "CDP": [
                    "CONTRAT_DE_PROJET_PUBLIC",
                    "CONTRAT DE PROJET 24 MOIS",
                    "CDP",
                    "CONTRAT DE PROJET",
                ],
                "CDD": [
                    "CDD",
                    "CDD 18 MOIS",
                    "CDD 24 MOIS",
                    "CDD PUBLIQUE 1+1",
                ],
                "CDI": [
                    "CONTRAT A DUREE INDETERMINEE",
                    "CONTRAT À DURÉE INDÉTERMINÉE",
                    "CDI",
                ],
                "PEC": ["PEC 18 MOIS", "PEC 24 MOIS", "PEC"],
            }

            # Exact match mapping (no regex): build a flat map variant -> code
            flat_map = {}
            for code, opts in variants.items():
                for v in opts:
                    flat_map[v.upper()] = code

            # Map exact values from the uppercased series; unmatched become None
            res = s.map(flat_map)

            # Ensure Python None for unmatched values
            table_data["type"] = res.where(res.notna(), None).astype(object)

        tables[table_name] = table_data
        logging.info("Table %s transformée : %s lignes.", table_name, len(table_data))

    return tables


