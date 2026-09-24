#!/usr/bin/env python3
"""
Module de géocodage en batch via l'API Géoplateforme IGN.

Utilise l'endpoint /search/csv pour géocoder des adresses en lot.
Documentation : https://geoservices.ign.fr/documentation/services/services-geoplateforme/geocodage

Limites de l'API :
- 50 requêtes/seconde par IP
- 50 Mo ou 200 000 lignes max par requête synchrone

Usage:
    from etl.geocoding_batch import GeocodeurBatch

    geocodeur = GeocodeurBatch()
    resultats = geocodeur.geocoder_adresses(df_adresses)
"""

import io
import logging
import os
import time
from typing import Iterator

import pandas as pd
import requests

from etl.core.ban import ligne_vide
from etl.core.ban import transformer_reponses

logger = logging.getLogger(__name__)

# Configuration
API_GEO_ENDPOINT = os.environ.get("API_GEO_ENDPOINT", "https://data.geopf.fr/geocodage")
API_GEO_MINIMUM_SCORE = float(os.environ.get("API_GEO_MINIMUM_SCORE", "0.5"))
BATCH_SIZE = int(os.environ.get("GEOCODING_BATCH_SIZE", "10000"))
RATE_LIMIT_DELAY = 0.1  # Délai entre les batches pour respecter la limite de 50 req/s


class GeocodeurBatch:
    """
    Géocodeur en batch utilisant l'API Géoplateforme IGN.

    Exemple d'utilisation :

        geocodeur = GeocodeurBatch()

        # Depuis un DataFrame
        df = pd.DataFrame({
            'id': ['1', '2'],
            'adresse': ['15 rue de la Paix', '1 place de la République'],
            'code_postal': ['75002', '75003'],
            'code_insee': ['75102', '75103'],
        })
        resultats = geocodeur.geocoder_dataframe(
            df,
            colonne_id='id',
            colonne_adresse='adresse',
            colonne_code_postal='code_postal',
            colonne_code_insee='code_insee'
        )
    """

    # Colonnes envoyées à l'API
    COLONNES_REQUETE = ["id_source", "query", "code_insee", "code_postal"]

    def __init__(
        self,
        endpoint: str | None = None,
        score_minimum: float | None = None,
        source_sink=None,
    ):
        """
        Initialise le géocodeur.

        Args:
            endpoint: URL de l'API (défaut: API_GEO_ENDPOINT)
            score_minimum: Score minimum pour considérer un résultat valide (défaut: 0.5)
            source_sink: callable optionnel sink(records, source_key) pour la
                capture brute (couche source). None → comportement inchangé.
        """
        self.endpoint = endpoint or API_GEO_ENDPOINT
        self.score_minimum = score_minimum or API_GEO_MINIMUM_SCORE
        self.source_sink = source_sink
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": "dataspace-etl/1.0",
            }
        )

    def geocoder_dataframe(
        self,
        df: pd.DataFrame,
        colonne_id: str,
        colonne_adresse: str,
        colonne_code_postal: str | None = None,
        colonne_code_insee: str | None = None,
        batch_size: int = BATCH_SIZE,
    ) -> pd.DataFrame:
        """
        Géocode un DataFrame d'adresses.

        Args:
            df: DataFrame contenant les adresses
            colonne_id: Nom de la colonne identifiant unique
            colonne_adresse: Nom de la colonne contenant l'adresse à géocoder
            colonne_code_postal: Nom de la colonne code postal (optionnel, améliore la précision)
            colonne_code_insee: Nom de la colonne code INSEE (optionnel, améliore la précision)
            batch_size: Taille des lots pour l'envoi à l'API

        Returns:
            DataFrame avec les résultats de géocodage
        """

        # Préparer le DataFrame de requête
        # Nettoyer les codes postaux/INSEE qui peuvent être en float (ex: 13013.0 -> 13013)
        def clean_code(val):
            if pd.isna(val) or val == "":
                return ""
            s = str(val).strip()
            # Supprimer le .0 des floats convertis en string
            if s.endswith(".0"):
                s = s[:-2]
            return s

        df_requete = pd.DataFrame(
            {
                "id_source": df[colonne_id].astype(str),
                "query": df[colonne_adresse].fillna(""),
                "code_insee": df[colonne_code_insee].apply(clean_code)
                if colonne_code_insee
                else "",
                "code_postal": df[colonne_code_postal].apply(clean_code)
                if colonne_code_postal
                else "",
            }
        )

        # Filtrer les lignes sans adresse
        df_requete = df_requete[df_requete["query"].str.strip() != ""]

        logger.info(
            f"Géocodage de {len(df_requete)} adresses en batches de {batch_size}"
        )

        # Traiter par batch
        resultats = []
        for batch_df in self._iter_batches(df_requete, batch_size):
            try:
                batch_resultats = self._geocoder_batch(batch_df)
                resultats.extend(batch_resultats)
                logger.info(f"Batch traité : {len(batch_resultats)} résultats")
            except Exception as e:
                logger.error(f"Erreur lors du géocodage du batch : {e}")
                # Ajouter des résultats vides pour ce batch
                for _, row in batch_df.iterrows():
                    resultats.append(ligne_vide(row["id_source"]))

            # Respecter la limite de taux
            time.sleep(RATE_LIMIT_DELAY)

        # Convertir en DataFrame (les lignes sortent du core aux colonnes finales)
        df_resultats = pd.DataFrame(resultats)

        logger.info(
            f"Géocodage terminé : {len(df_resultats)} résultats, "
            f"{df_resultats['geocodage_valide'].sum()} valides"
        )

        return df_resultats

    def _iter_batches(
        self, df: pd.DataFrame, batch_size: int
    ) -> Iterator[pd.DataFrame]:
        """Itère sur le DataFrame par lots."""
        for i in range(0, len(df), batch_size):
            yield df.iloc[i : i + batch_size]

    def _geocoder_batch(self, df_batch: pd.DataFrame) -> list[dict]:
        """
        Envoie un batch à l'API et parse les résultats.

        Args:
            df_batch: DataFrame contenant les adresses à géocoder

        Returns:
            Liste des résultats de géocodage
        """
        url = f"{self.endpoint}/search/csv"

        # Convertir en CSV
        csv_buffer = io.StringIO()
        df_batch.to_csv(csv_buffer, index=False, encoding="utf-8")
        csv_content = csv_buffer.getvalue().encode("utf-8")

        # Préparer la requête multipart
        files = {
            "data": ("adresses.csv", csv_content, "text/csv"),
        }

        # Construire les données du formulaire multipart
        # Format: liste de tuples pour permettre les clés multiples (result_columns)
        data = [
            ("columns", "query"),
            ("citycode", "code_insee"),
            ("postcode", "code_postal"),
        ]

        # Envoyer la requête
        logger.info(f"Envoi requête à {url} avec {len(df_batch)} adresses")
        response = self.session.post(
            url,
            files=files,
            data=data,
        )

        logger.info(
            f"Réponse API : status={response.status_code}, taille={len(response.text)} chars"
        )

        if not response.ok:
            logger.error(f"Erreur API ({response.status_code}): {response.text[:500]}")
            raise Exception(f"Erreur API ({response.status_code}): {response.text}")

        # Parser le CSV de réponse
        csv_brut = response.text
        logger.info(f"Premières lignes réponse:\n{csv_brut[:1000]}")
        df_resultat = pd.read_csv(io.StringIO(csv_brut), dtype=str)
        logger.info(f"Colonnes reçues: {list(df_resultat.columns)}")

        # Forme source : NaN pandas (cellules vides du CSV) -> None — sinon
        # json.dumps émet un littéral NaN invalide pour le JSONB Postgres, et
        # le core attend des valeurs str | None.
        records = (
            df_resultat.astype(object)
            .where(df_resultat.notna(), None)
            .to_dict("records")
        )

        # Capture brute (couche source) avant le filtre INSEE/score.
        if self.source_sink:
            try:
                self.source_sink(records, url)
            except Exception:
                logger.error("[source] échec capture BAN", exc_info=True)

        # Transformation portée par le core pur (etl/core/ban.py) depuis la
        # bascule (MR 3 boucle BAN, approche-data/17).
        resultats = transformer_reponses(records, score_minimum=self.score_minimum)

        nb_valides = sum(1 for r in resultats if r["geocodage_valide"])
        logger.info(f"Batch stats: {len(resultats)} total, {nb_valides} valides")

        return resultats

    def geocoder_fichier_csv(
        self,
        fichier_entree: str,
        fichier_sortie: str,
        colonne_id: str,
        colonne_adresse: str,
        colonne_code_postal: str | None = None,
        colonne_code_insee: str | None = None,
        separateur: str = ";",
    ) -> None:
        """
        Géocode un fichier CSV et écrit les résultats.

        Args:
            fichier_entree: Chemin du fichier CSV d'entrée
            fichier_sortie: Chemin du fichier CSV de sortie
            colonne_id: Nom de la colonne identifiant unique
            colonne_adresse: Nom de la colonne contenant l'adresse
            colonne_code_postal: Nom de la colonne code postal (optionnel)
            colonne_code_insee: Nom de la colonne code INSEE (optionnel)
            separateur: Séparateur CSV (défaut: ';')
        """
        logger.info(f"Lecture de {fichier_entree}")
        df = pd.read_csv(fichier_entree, sep=separateur, dtype=str)

        df_resultats = self.geocoder_dataframe(
            df,
            colonne_id=colonne_id,
            colonne_adresse=colonne_adresse,
            colonne_code_postal=colonne_code_postal,
            colonne_code_insee=colonne_code_insee,
        )

        # Joindre les résultats au DataFrame d'origine
        df_enrichi = df.merge(
            df_resultats,
            left_on=colonne_id,
            right_on="id_source",
            how="left",
        )

        # Sauvegarder
        df_enrichi.to_csv(fichier_sortie, sep=separateur, index=False)
        logger.info(f"Résultats écrits dans {fichier_sortie}")


def main():
    """Point d'entrée CLI pour le géocodage batch."""
    import argparse

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    parser = argparse.ArgumentParser(description="Géocodage batch via API IGN")
    parser.add_argument("--input", "-i", required=True, help="Fichier CSV d'entrée")
    parser.add_argument("--output", "-o", required=True, help="Fichier CSV de sortie")
    parser.add_argument("--id", required=True, help="Colonne identifiant")
    parser.add_argument("--adresse", required=True, help="Colonne adresse")
    parser.add_argument("--code-postal", help="Colonne code postal")
    parser.add_argument("--code-insee", help="Colonne code INSEE")
    parser.add_argument("--sep", default=";", help="Séparateur CSV (défaut: ;)")

    args = parser.parse_args()

    geocodeur = GeocodeurBatch()
    geocodeur.geocoder_fichier_csv(
        fichier_entree=args.input,
        fichier_sortie=args.output,
        colonne_id=args.id,
        colonne_adresse=args.adresse,
        colonne_code_postal=args.code_postal,
        colonne_code_insee=args.code_insee,
        separateur=args.sep,
    )


if __name__ == "__main__":
    main()
