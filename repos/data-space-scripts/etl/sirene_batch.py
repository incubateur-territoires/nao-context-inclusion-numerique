#!/usr/bin/env python3
"""
Module d'enrichissement SIRENE en batch via l'API INSEE.

Utilise l'endpoint /siret avec le paramètre q pour rechercher plusieurs SIRET en une requête.
Documentation : https://api.insee.fr/catalogue/site/themes/wso2/subthemes/insee/pages/item-info.jag?name=Sirene&version=3.11

Limites de l'API :
- 30 requêtes/minute
- 100 SIRET max par requête batch

Usage:
    from etl.sirene_batch import SireneBatch

    sirene = SireneBatch(api_key='votre_cle_api')
    resultats = sirene.enrichir_dataframe(df, colonne_id='id', colonne_siret='siret')
"""

import logging
import os
import time
from dataclasses import dataclass

import pandas as pd
import requests

from etl.core.enrichissement import normaliser_siret

logger = logging.getLogger(__name__)

# Configuration
SIRENE_API_URL = os.environ.get(
    "SIRENE_API_URL", "https://api.insee.fr/api-sirene/3.11/siret"
)
SIRENE_BATCH_SIZE = 1000  # Taille de batch (API limite à 1000 résultats max)
SIRENE_RATE_LIMIT_DELAY = 2.0  # Délai entre les batches (30 req/min = 2s entre chaque)


@dataclass
class EtablissementSirene:
    """Résultat de l'enrichissement SIRENE d'un établissement."""

    id_source: str
    siret: str
    etat_administratif: str | None
    code_activite_principale: str | None
    categorie_juridique: str | None
    denomination_sirene: str | None
    adresse_sirene: str | None
    code_insee_sirene: str | None
    code_postal_sirene: str | None
    date_creation: str | None
    tranche_effectifs: str | None

    @property
    def est_actif(self) -> bool:
        """Vérifie si l'établissement est actif."""
        return (
            self.etat_administratif is not None
            and "actif" in self.etat_administratif.lower()
        )


class SireneBatch:
    """
    Enrichisseur SIRENE en batch utilisant l'API INSEE.

    Exemple d'utilisation :

        sirene = SireneBatch(api_key='votre_cle_api')

        # Depuis un DataFrame
        df = pd.DataFrame({
            'id': ['1', '2'],
            'siret': ['12345678901234', '98765432109876'],
        })
        resultats = sirene.enrichir_dataframe(
            df,
            colonne_id='id',
            colonne_siret='siret'
        )
    """

    def __init__(
        self, api_key: str | None = None, endpoint: str | None = None, source_sink=None
    ):
        """
        Initialise l'enrichisseur SIRENE.

        Args:
            api_key: Clé API INSEE (défaut: variable d'env SIRENE_API_KEY)
            endpoint: URL de l'API (défaut: SIRENE_API_URL)
            source_sink: callable optionnel sink(records, source_key) pour la
                capture brute (couche source). None → comportement inchangé.
        """
        self.api_key = api_key or os.environ.get("SIRENE_API_KEY")
        if not self.api_key:
            raise ValueError(
                "Clé API SIRENE requise (paramètre api_key ou variable d'env SIRENE_API_KEY)"
            )

        self.endpoint = endpoint or SIRENE_API_URL
        self.source_sink = source_sink
        self.session = requests.Session()
        self.session.headers.update(
            {
                "X-INSEE-Api-Key-Integration": self.api_key,
                "Accept": "application/json",
            }
        )

    def _normalize_siret(self, siret) -> str:
        """Normalise un SIRET en chaîne de 14 caractères.

        Délègue au core pur (etl/core/enrichissement.py) : même normalisation
        pour la clé du cache d'enrichissement et ses lecteurs (lot 2)."""
        if pd.isna(siret):
            return ""
        return normaliser_siret(siret)

    def enrichir_dataframe(
        self,
        df: pd.DataFrame,
        colonne_id: str,
        colonne_siret: str,
        batch_size: int = SIRENE_BATCH_SIZE,
    ) -> pd.DataFrame:
        """
        Enrichit un DataFrame avec les données SIRENE.

        Args:
            df: DataFrame contenant les SIRET
            colonne_id: Nom de la colonne identifiant unique
            colonne_siret: Nom de la colonne contenant les SIRET
            batch_size: Taille des lots (max 100)

        Returns:
            DataFrame avec les résultats d'enrichissement SIRENE
        """
        if batch_size > SIRENE_BATCH_SIZE:
            logger.warning(
                f"batch_size ({batch_size}) dépasse la limite API ({SIRENE_BATCH_SIZE}), utilisation de {SIRENE_BATCH_SIZE}"
            )
            batch_size = SIRENE_BATCH_SIZE

        # Préparer les données
        df_requete = pd.DataFrame(
            {
                "id_source": df[colonne_id].astype(str),
                "siret": df[colonne_siret].apply(self._normalize_siret),
            }
        )

        # Filtrer les lignes avec SIRET valide
        df_requete = df_requete[
            (df_requete["siret"].str.len() == 14)
            & (df_requete["siret"] != "00000000000000")
        ]

        logger.info(
            f"Enrichissement SIRENE de {len(df_requete)} établissements en batches de {batch_size}"
        )

        # Traiter par batch
        resultats = []
        sirets_traites = set()

        for i in range(0, len(df_requete), batch_size):
            batch_df = df_requete.iloc[i : i + batch_size]

            # Dédupliquer les SIRET dans le batch pour l'appel API
            sirets_uniques = [
                s for s in batch_df["siret"].unique() if s not in sirets_traites
            ]

            if not sirets_uniques:
                continue

            try:
                batch_data = self._fetch_batch(sirets_uniques)
                sirets_traites.update(sirets_uniques)

                # Associer les résultats aux id_source
                for _, row in batch_df.iterrows():
                    siret = row["siret"]
                    if siret in batch_data:
                        etab = batch_data[siret]
                        etab_result = EtablissementSirene(
                            id_source=row["id_source"],
                            siret=siret,
                            etat_administratif=etab.get("etat_administratif"),
                            code_activite_principale=etab.get(
                                "code_activite_principale"
                            ),
                            categorie_juridique=etab.get("categorie_juridique"),
                            denomination_sirene=etab.get("denomination_sirene"),
                            adresse_sirene=etab.get("adresse_sirene"),
                            code_insee_sirene=etab.get("code_insee_sirene"),
                            code_postal_sirene=etab.get("code_postal_sirene"),
                            date_creation=etab.get("date_creation"),
                            tranche_effectifs=etab.get("tranche_effectifs"),
                        )
                        resultats.append(etab_result)
                    else:
                        # SIRET non trouvé
                        resultats.append(
                            EtablissementSirene(
                                id_source=row["id_source"],
                                siret=siret,
                                etat_administratif=None,
                                code_activite_principale=None,
                                categorie_juridique=None,
                                denomination_sirene=None,
                                adresse_sirene=None,
                                code_insee_sirene=None,
                                code_postal_sirene=None,
                                date_creation=None,
                                tranche_effectifs=None,
                            )
                        )

                logger.info(f"Batch traité : {len(sirets_uniques)} SIRET interrogés")

            except Exception as e:
                logger.error(f"Erreur lors de l'enrichissement du batch : {e}")
                # Ajouter des résultats vides pour ce batch
                for _, row in batch_df.iterrows():
                    resultats.append(
                        EtablissementSirene(
                            id_source=row["id_source"],
                            siret=row["siret"],
                            etat_administratif=None,
                            code_activite_principale=None,
                            categorie_juridique=None,
                            denomination_sirene=None,
                            adresse_sirene=None,
                            code_insee_sirene=None,
                            code_postal_sirene=None,
                            date_creation=None,
                            tranche_effectifs=None,
                        )
                    )

            # Respecter la limite de taux
            time.sleep(SIRENE_RATE_LIMIT_DELAY)

        # Convertir en DataFrame
        df_resultats = pd.DataFrame(
            [
                {
                    "id_source": r.id_source,
                    "siret_sirene": r.siret,
                    "etat_administratif": r.etat_administratif,
                    "code_activite_principale": r.code_activite_principale,
                    "categorie_juridique": r.categorie_juridique,
                    "denomination_sirene": r.denomination_sirene,
                    "adresse_sirene": r.adresse_sirene,
                    "code_insee_sirene": r.code_insee_sirene,
                    "code_postal_sirene": r.code_postal_sirene,
                    "date_creation_sirene": r.date_creation,
                    "tranche_effectifs_sirene": r.tranche_effectifs,
                    "sirene_trouve": r.etat_administratif is not None,
                }
                for r in resultats
            ]
        )

        nb_trouves = df_resultats["sirene_trouve"].sum()
        logger.info(
            f"Enrichissement terminé : {len(df_resultats)} résultats, {nb_trouves} établissements trouvés"
        )

        return df_resultats

    def _fetch_batch(self, sirets: list[str], max_retries: int = 3) -> dict:
        """
        Interroge l'API SIRENE pour un lot de SIRET via POST.

        Args:
            sirets: Liste des SIRET à rechercher
            max_retries: Nombre maximum de tentatives

        Returns:
            Dictionnaire {siret: données} des établissements trouvés
        """
        if not sirets:
            return {}

        # Construire la requête : siret:"12345" OR siret:"67890"
        query_parts = [f'siret:"{siret}"' for siret in sirets]
        query = " OR ".join(query_parts)

        # Body pour POST (pas de limite d'URL)
        # nombre: nombre max de résultats (défaut 20, on demande le max)
        body = {
            "q": query,
            "nombre": len(sirets),  # Demander autant de résultats que de SIRET
        }

        attempt = 0
        base_wait_time = 2

        while attempt < max_retries:
            try:
                response = self.session.post(self.endpoint, data=body, timeout=30)

                if response.status_code == 200:
                    data = response.json()
                    # Capture brute (couche source) avant tout parsing.
                    if self.source_sink:
                        try:
                            self.source_sink(
                                data.get("etablissements", []), self.endpoint
                            )
                        except Exception:
                            logger.error("[source] échec capture SIRENE", exc_info=True)
                    return self._parse_response(data)

                elif response.status_code == 404:
                    # Aucun résultat trouvé
                    logger.info("Aucun établissement trouvé pour ce batch")
                    return {}

                elif response.status_code == 429:
                    wait_time = min(base_wait_time * (2**attempt), 60)
                    logger.warning(f"HTTP 429: Trop d'appels. Pause de {wait_time}s...")
                    time.sleep(wait_time)

                elif response.status_code == 401:
                    logger.error("Erreur 401: Clé API invalide ou expirée")
                    raise ValueError("Clé API SIRENE invalide ou expirée")

                else:
                    logger.error(
                        f"Erreur API SIRENE ({response.status_code}): {response.text[:500]}"
                    )

            except requests.exceptions.RequestException as e:
                logger.error(f"Erreur réseau lors de l'appel API SIRENE : {e}")

            attempt += 1

        logger.error(f"Échec après {max_retries} tentatives pour le batch")
        return {}

    def _parse_response(self, data: dict) -> dict:
        """
        Parse la réponse JSON de l'API SIRENE.

        Args:
            data: Réponse JSON de l'API

        Returns:
            Dictionnaire {siret: données} des établissements
        """
        resultats = {}

        etablissements = data.get("etablissements", [])

        for etab in etablissements:
            siret = etab.get("siret")
            if not siret:
                continue

            adresse_etab = etab.get("adresseEtablissement", {})
            unite_legale = etab.get("uniteLegale", {})

            # Déterminer l'état administratif
            etat_etab = "Inconnu"
            for periode in etab.get("periodesEtablissement", []):
                if periode.get("dateFin") is None:
                    if periode.get("etatAdministratifEtablissement") == "F":
                        etat_etab = "Etablissement fermé"
                    else:
                        etat_etab = "Etablissement actif"
                    break

            etat_unite = unite_legale.get("etatAdministratifUniteLegale")
            if etat_unite == "C":
                etat_administratif = "Entreprise cessée"
            else:
                etat_administratif = f"Entreprise active / {etat_etab}"

            # Construire l'adresse
            numero = adresse_etab.get("numeroVoieEtablissement", "") or ""
            indice_rep = adresse_etab.get("indiceRepetitionEtablissement", "") or ""
            type_voie = adresse_etab.get("typeVoieEtablissement", "") or ""
            libelle_voie = adresse_etab.get("libelleVoieEtablissement", "") or ""
            adresse_sirene = f"{numero} {indice_rep} {type_voie} {libelle_voie}".strip()
            adresse_sirene = " ".join(adresse_sirene.split())  # Normaliser les espaces

            resultats[siret] = {
                "etat_administratif": etat_administratif,
                "code_activite_principale": unite_legale.get(
                    "activitePrincipaleUniteLegale"
                ),
                "categorie_juridique": unite_legale.get(
                    "categorieJuridiqueUniteLegale"
                ),
                "denomination_sirene": unite_legale.get("denominationUniteLegale"),
                "adresse_sirene": adresse_sirene if adresse_sirene else None,
                "code_insee_sirene": adresse_etab.get("codeCommuneEtablissement"),
                "code_postal_sirene": adresse_etab.get("codePostalEtablissement"),
                "date_creation": etab.get("dateCreationEtablissement"),
                "tranche_effectifs": etab.get("trancheEffectifsEtablissement"),
            }

        return resultats


def main():
    """Point d'entrée CLI pour l'enrichissement SIRENE batch."""
    import argparse

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    parser = argparse.ArgumentParser(
        description="Enrichissement SIRENE batch via API INSEE"
    )
    parser.add_argument("--input", "-i", required=True, help="Fichier CSV d'entrée")
    parser.add_argument("--output", "-o", required=True, help="Fichier CSV de sortie")
    parser.add_argument("--id", required=True, help="Colonne identifiant")
    parser.add_argument("--siret", required=True, help="Colonne SIRET")
    parser.add_argument(
        "--api-key", default=os.environ.get("SIRENE_API_KEY"), help="Clé API INSEE"
    )
    parser.add_argument("--sep", default=";", help="Séparateur CSV (défaut: ;)")

    args = parser.parse_args()

    if not args.api_key:
        parser.error("Clé API requise (--api-key ou variable SIRENE_API_KEY)")

    sirene = SireneBatch(api_key=args.api_key)

    # Lire le fichier
    logger.info(f"Lecture de {args.input}")
    df = pd.read_csv(args.input, sep=args.sep, dtype=str)

    # Enrichir
    df_resultats = sirene.enrichir_dataframe(
        df,
        colonne_id=args.id,
        colonne_siret=args.siret,
    )

    # Joindre et sauvegarder
    df_enrichi = df.merge(
        df_resultats,
        left_on=args.id,
        right_on="id_source",
        how="left",
    )

    df_enrichi.to_csv(args.output, sep=args.sep, index=False)
    logger.info(f"Résultats écrits dans {args.output}")


if __name__ == "__main__":
    main()
