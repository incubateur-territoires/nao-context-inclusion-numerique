import re

import pandas as pd

"""
    Fonctions utilitaires pour la normalisation des données
    Le schema de données utilsé est le suivant :
    https://schema.data.gouv.fr/LaMednum/standard-mediation-num/1.0.1/documentation.html
"""


VALID_PREFIXES = {
    "+33",
    "+590",
    "+594",
    "+262",
    "+596",
    "+269",
    "+687",
    "+689",
    "+508",
    "+681",
}


def format_and_validate_phone(raw_number: str) -> str | None:
    """
    Formatte et valide un numéro de téléphone vers le format international valide FR/DROM.

    Args:
        raw_number (str): Le numéro brut (peut contenir espaces, tirets, 00, etc.)

    Returns:
        str | None: Numéro formaté (ex: +33612345678), ou None si invalide.
    """
    if not raw_number or pd.isna(raw_number):
        return None

    # Supprimer les caractères parasites
    cleaned = re.sub(r"[ \-\.\(\)]", "", raw_number)

    # 00 → +
    if cleaned.startswith("00"):
        cleaned = "+" + cleaned[2:]

    # Corriger les (0) dans +33
    cleaned = re.sub(r"^\+33(?:0)?", "+33", cleaned)

    # Numéros locaux français
    if cleaned.startswith("0") and len(cleaned) in (9, 10):
        cleaned = "+33" + cleaned[1:]

    # Validation finale
    for prefix in sorted(VALID_PREFIXES, key=len, reverse=True):
        if cleaned.startswith(prefix):
            suffix = cleaned[len(prefix) :]
            if suffix.isdigit() and 6 <= len(suffix) <= 9:
                return prefix + suffix
            break

    return None


def validate_code_insee(raw_code: str) -> str | None:
    """
    Valide un code INSEE (5 caractères alphanumériques, y compris 2A/2B pour la Corse).
    Exemples valides : 01053, 2A123, 97123

    Args:
        raw_code (str): Code brut à valider.

    Returns:
        str | None: Code INSEE valide ou None si invalide.
    """
    if not raw_code or str(raw_code).strip().lower() in {"", "nan", "none"}:
        return None

    code = str(raw_code).strip().upper()

    # Si le code est purement numérique, ajouter des zéros à gauche
    if code.isdigit() and len(code) < 5:
        code = code.zfill(5)

    # INSEE : 2 lettres ou chiffres (département) + 3 chiffres (commune)
    regex = r"^(0[1-9]|[1-8][0-9]|9[0-6]|2A|2B|97[1-6]|98[4,6-9])[0-9]{3}$"

    return code if re.match(regex, code) else None


def validate_pivot(raw_pivot: str) -> str | None:
    """
    Valide une chaîne pivot alphanumérique de 9 à 14 caractères.

    Args:
        raw_pivot (str): Pivot brut à valider.

    Returns:
        str | None: Pivot formaté ou None si invalide.
    """

    if not raw_pivot or pd.isna(raw_pivot) or str(raw_pivot) in {"nan", "NaN"}:
        return None

    cleaned = str(raw_pivot).strip().replace(".", "")

    if re.fullmatch(r"W\d{9}", cleaned):
        return cleaned
    if re.fullmatch(r"\d{14}", cleaned):
        return cleaned
    if re.fullmatch(r"\d{9}", cleaned):
        return cleaned + "00000"

    return None


def normalize_nom(raw_nom: str) -> str | None:
    """
    Normalise un nom de famille :
    - Supprime les espaces/tabs en début ou fin.
    - Renvoie le nom en lettres capitales (uppercase plein).
    - Retourne None si vide ou NaN.

    Args:
        raw_nom (str): Nom brut.

    Returns:
        str | None: Nom normalisé ou None si invalide.
    """
    if not raw_nom or pd.isna(raw_nom):
        return None
    cleaned = str(raw_nom).strip()
    return cleaned.upper() if cleaned else None


def normalize_prenom(raw_prenom: str) -> str | None:
    """
    Normalise un prénom :
    - Supprime les espaces/tabs en début ou fin.
    - Met une majuscule initiale à chaque segment séparé par un espace ou un tiret,
      les autres lettres en minuscules (ex : "jean-luc" -> "Jean-Luc").
    - Retourne None si vide ou NaN.

    Args:
        raw_prenom (str): Prénom brut.

    Returns:
        str | None: Prénom normalisé ou None si invalide.
    """
    if not raw_prenom or pd.isna(raw_prenom):
        return None

    cleaned = str(raw_prenom).strip()

    if not cleaned:
        return None

    # Gestion des prénoms composés avec espaces et/ou tirets
    def capitalize_segment(segment: str) -> str:
        return segment[:1].upper() + segment[1:].lower() if segment else ""

    parts = []
    for word in cleaned.split(" "):
        sub_parts = word.split("-")
        capitalized = "-".join(capitalize_segment(s) for s in sub_parts)
        parts.append(capitalized)

    return " ".join(parts) if parts else None


# Dictionnaire d’abréviations rencontrées dans les logs et conventions courantes
RUE_ABBREVIATIONS = {
    "avn": "avenue",
    "av": "avenue",
    "av.": "avenue",
    "ave": "avenue",
    "ave.": "avenue",
    "bd": "boulevard",
    "bvd": "boulevard",
    "bvd.": "boulevard",
    "blv": "boulevard",
    "blv.": "boulevard",
    "bd.": "boulevard",
    "plc": "place",
    "pl": "place",
    "pl.": "place",
    "imp": "impasse",
    "all": "allée",
    "sq": "square",
    "sq.": "square",
    "ch": "chemin",
    "chem": "chemin",
    "crs": "cours",
    "rdc": "rez-de-chaussée",
    "egl": "église",
    "rte": "route",
    "rte.": "route",
    "rt": "route",
    "cte": "côte",
    "ste": "sainte",
    "st": "saint",
    "st.": "saint",
    "fbg": "faubourg",
    "fg": "faubourg",
}


def normalize_rue_abbreviations(raw_address: str) -> str:
    """
    Remplace les abréviations de type de voie par leur forme longue.

    Args:
        raw_address (str): Adresse brute ou fragment de voie.

    Returns:
        str: Adresse avec abréviations normalisées.
    """
    if not raw_address:
        return raw_address

    parts = raw_address.split()
    out = []
    for part in parts:
        key = part.lower().rstrip(".")
        out.append(RUE_ABBREVIATIONS.get(key, part))
    return " ".join(out)


def normalize_address(raw_address: str) -> str | None:
    """
    Nettoie et normalise une adresse :
    - supprime placeholders ('null', '[Non-Diffusible]', '-')
    - normalise les abréviations (avn → avenue, plc → place, etc.)
    - retire espaces multiples

    Args:
        raw_address (str): Adresse brute.

    Returns:
        str | None: Adresse nettoyée, ou None si invalide/absente.
    """
    if raw_address is None or pd.isna(raw_address):
        return None

    cleaned = str(raw_address).strip()

    # Placeholders rencontrés dans les logs
    if cleaned in {"", "-", "null", "NULL", "[Non-Diffusible]"}:
        return None

    cleaned = re.sub(r"\bnull\b", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\[Non-Diffusible\]", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\bC/O\b[^,]*,?", "", cleaned, flags=re.IGNORECASE)
    # Conserver uniquement la portion d'adresse à partir
    # - d'un numéro de voie (ex : "149 avenue …")
    # - ou d'un type de voie reconnu (rue, avenue, bd, route…)
    main_match = re.search(
        r"(?:\d+\s+[^,]+|\b(?:rue|avenue|av|bd|boulevard|route|chemin|rte|place|impasse|square|sq|cours)\b[^,]*)",
        cleaned,
        flags=re.IGNORECASE,
    )
    if main_match:
        cleaned = main_match.group(0).strip()

    cleaned = re.sub(r"\([^)]*\)", "", cleaned)

    # Remplacer les tirets en séparateurs par une virgule
    cleaned = re.sub(r"\s*-\s*", ", ", cleaned)
    # Nettoyer virgules doublons ou espaces avant virgule
    cleaned = re.sub(r"\s*,\s*", ", ", cleaned)
    cleaned = re.sub(r",\s*,", ",", cleaned)
    cleaned = cleaned.strip(" ,")

    # Normalisation des abréviations
    cleaned = normalize_rue_abbreviations(cleaned)

    # Compacter les espaces
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()

    return cleaned if cleaned else None
