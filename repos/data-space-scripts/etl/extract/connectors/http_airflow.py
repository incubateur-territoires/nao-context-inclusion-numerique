import logging
import time
from urllib.parse import urlparse

import requests
from airflow.models.baseoperator import BaseOperator
from airflow.providers.http.hooks.http import HttpHook
from airflow.providers.postgres.hooks.postgres import PostgresHook

from etl.core.ac import transformer_aidants
from etl.core.ac import transformer_structures
from etl.source_capture import make_source_sink


class APIClientOperator(BaseOperator):
    template_fields = ("endpoint", "source_db_conn_id")

    def __init__(
        self,
        conn_id,
        endpoint,
        method="GET",
        data=None,
        data_type=None,
        headers=None,
        do_xcom_push=False,
        max_retries=3,
        backoff_seconds=2,
        backoff_factor=2,
        retry_for_statuses=None,
        request_timeout=30,
        page_delay_seconds=0.5,
        source_table=None,
        source_db_conn_id=None,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.conn_id = conn_id
        self.endpoint = endpoint
        self.method = method
        self.data_type = data_type
        self.data = data
        self.headers = headers
        self.do_xcom_push = do_xcom_push
        self.max_retries = max_retries
        self.backoff_seconds = backoff_seconds
        self.backoff_factor = backoff_factor
        self.retry_for_statuses = (
            retry_for_statuses
            if retry_for_statuses is not None
            else (429, 500, 502, 503, 504)
        )
        self.request_timeout = request_timeout
        self.page_delay_seconds = page_delay_seconds
        self.source_table = source_table
        self.source_db_conn_id = source_db_conn_id

    def _init_source_capture(self, context):
        """Prépare le sink de capture brute (couche source), ou None si non configuré.

        La capture est faite page par page, dès réception (voir
        _capture_page_to_source) : persistance au fil de l'eau, rien n'est
        perdu si la task crash en cours de pagination. Dead-end tolérant aux
        erreurs : un échec n'interrompt jamais le fetch.
        """
        self._source_sink = None
        if not (self.source_table and self.source_db_conn_id):
            return
        try:
            conn = PostgresHook(postgres_conn_id=self.source_db_conn_id).get_conn()
            # endpoint journalisé dans capture_run.parametres : porte le
            # curseur des flux incrémentaux (ex. updated_at__gte des aidants).
            self._source_sink = make_source_sink(
                conn,
                context["run_id"],
                self.source_table,
                parametres={"endpoint": self.endpoint},
            )
        except Exception:
            logging.error(
                "[source] connexion impossible pour la capture brute vers %s — capture désactivée",
                self.source_table,
                exc_info=True,
            )

    def _capture_page_to_source(self, page_json):
        """Capture brute d'une page JSON telle que reçue de l'API (avant toute transformation).

        Les objets des clefs `results`/`data` sont stockés tels quels en JSONB,
        une ligne par objet.
        """
        if getattr(self, "_source_sink", None) is None:
            return
        try:
            records = page_json.get("results") or page_json.get("data") or []
            if records:
                self._source_sink(records, self.endpoint)
        except Exception:
            logging.error(
                "[source] échec capture brute d'une page vers %s — page ignorée",
                self.source_table,
                exc_info=True,
            )

    def _do_http_call(self, hook, endpoint):
        """
        Performs a single HTTP call using either the Airflow HttpHook or direct requests,
        depending on whether `endpoint` is absolute or relative.
        Returns a `requests.Response`-like object.
        """
        if endpoint.startswith("http"):
            return requests.get(
                endpoint,
                headers=self.headers,
                json=self.data,
                timeout=self.request_timeout,
            )
        else:
            # Airflow's HttpHook.run returns a requests.Response
            return hook.run(endpoint=endpoint, data=self.data, headers=self.headers)

    def _request_with_retry(self, hook, endpoint):
        attempts = 0
        backoff = self.backoff_seconds
        retry_statuses = set(self.retry_for_statuses or ())
        while True:
            attempts += 1
            try:
                response = self._do_http_call(hook, endpoint)
            except Exception as err:
                if attempts <= self.max_retries:
                    logging.warning(
                        "Appel HTTP échoué (exception) tentative %d/%d vers %s : %s — nouvelle tentative après %ss",
                        attempts,
                        self.max_retries,
                        endpoint,
                        err,
                        backoff,
                    )
                    time.sleep(backoff)
                    backoff *= max(1, self.backoff_factor)
                    continue
                raise

            # If status code is OK, return immediately
            status = getattr(response, "status_code", None)
            if status is not None and 200 <= status < 300:
                return response

            # Non-2xx status: decide to retry or raise
            body_preview = getattr(response, "text", "")[:500]
            if status in retry_statuses and attempts <= self.max_retries:
                logging.warning(
                    "Erreur HTTP %s tentative %d/%d vers %s — nouvelle tentative après %ss. Corps: %s",
                    status,
                    attempts,
                    self.max_retries,
                    endpoint,
                    backoff,
                    body_preview,
                )
                time.sleep(backoff)
                backoff *= max(1, self.backoff_factor)
                continue

            # Final failure
            error_msg = f"Erreur HTTP {status}: {body_preview}"
            logging.error(error_msg)
            raise ConnectionError(error_msg)

    def execute(self, context):
        hook = HttpHook(http_conn_id=self.conn_id, method=self.method)

        # Capture brute (couche source) au fil de l'eau, page par page.
        self._init_source_capture(context)

        if self.data_type == "coop_activity":
            all_data = None
            logging.info(
                "Mode streaming activé pour coop_activity (pas de chargement global en mémoire)."
            )
            self.log.info(
                "Début du streaming coop_activity depuis l'endpoint initial: %s",
                self.endpoint,
            )
        else:
            # Récupération de toutes les pages de données
            self.log.info(
                "Début du fetch all depuis l'endpoint initial: %s", self.endpoint
            )
            all_data = self._fetch_all_pages(hook)
            logging.info(
                "Toutes les pages ont été récupérées, total = %d", len(all_data)
            )

        if self.data_type in (
            "aidants-personnes",
            "aidants-structures",
            "aidants-accompagnements",
        ):
            # Sans XCom à produire, la transformation n'a aucun consommateur :
            # le fetch se limite à la collecte + capture brute (couche source).
            if not self.do_xcom_push:
                logging.info(
                    "do_xcom_push=False : transformation ignorée (fetch + capture brute uniquement)."
                )
                return

            # Transformation portée par le core (etl/core/ac.py) depuis la
            # bascule (MR 3 boucle AC quotidien, approche-data/17).
            # aidants-accompagnements n'a pas de transformation avec XCom :
            # son seul usage est en do_xcom_push=False (fetch + capture brute).
            if self.data_type == "aidants-accompagnements":
                raise ValueError(
                    "aidants-accompagnements : pas de transformation XCom, "
                    "utiliser do_xcom_push=False."
                )

            all_aidants = []
            all_structures = []

            for page_index, page_json in enumerate(all_data, start=1):
                self.log.info(f"Transformation de la page {page_index}")
                results = page_json.get("results", [])
                if self.data_type == "aidants-personnes":
                    all_aidants.extend(transformer_aidants(results))
                else:
                    all_structures.extend(transformer_structures(results))

            result = {}
            if all_aidants:
                result["aidants"] = all_aidants
            if all_structures:
                result["structures"] = all_structures

            return result

        elif self.data_type in (
            "coop_activity",
            "coop_utilisateurs",
            "coop_structures",
        ):
            # Depuis la bascule (MR 3 boucle coop, approche-data/17), le fetch
            # se limite à la collecte + capture brute (couche source) — la
            # transformation est portée par le core (etl/core/coop.py) dans les
            # tâches transform_* du DAG, qui relisent source.coop__*.
            if self.data_type == "coop_activity":
                for page_index, _ in enumerate(self._stream_pages(hook), start=1):
                    self.log.info(f"Capture brute de la page {page_index}")
            logging.info(
                "Fetch coop : collecte + capture brute uniquement (transformation portée par etl/core/coop.py)."
            )
            return
        else:
            raise ValueError(
                "Type de données inconnu. Utiliser 'aidants', 'coop_activity', 'coop_utilisateurs', ou 'coop_structures'."
            )

    def _resolve_next_endpoint(self, next_link):
        if not next_link:
            return None
        if next_link.startswith("http"):
            return next_link
        parsed = urlparse(next_link)
        return parsed.path + "?" + parsed.query if parsed.query else parsed.path

    def _stream_pages(self, hook):
        """
        Generator version of pagination to avoid loading all pages into memory.
        Yields each page's JSON response one by one.
        """
        current_endpoint = self.endpoint
        page_num = 1
        while True:
            response = self._request_with_retry(hook, current_endpoint)

            json_data = response.json()
            try:
                len(json_data.get("data", []))
            except Exception:
                pass
            self._capture_page_to_source(json_data)
            yield json_data

            # Determine "next" link shape according to data_type
            if self.data_type in (
                "coop_activity",
                "coop_utilisateurs",
                "coop_structures",
            ):
                next_link = json_data.get("links", {}).get("next", {}).get("href")
            else:
                next_link = json_data.get("next")
            if next_link:
                logging.info("Page suivante détectée : %s", next_link)
                current_endpoint = self._resolve_next_endpoint(next_link)
                page_num += 1
                if self.page_delay_seconds:
                    time.sleep(self.page_delay_seconds)
            else:
                logging.info("Aucune page suivante détectée.")
                break

    def _fetch_all_pages(self, hook):
        """
        NOTE: For memory-sensitive paths (e.g., 'coop_activity'), prefer _stream_pages().
        Méthode interne pour récupérer toutes les pages à partir d'une API paginée
        qui fournit un lien "next" -> {"href": "..."} si d'autres pages existent.

        Retourne une liste de réponses JSON complètes.
        """
        all_responses = []
        current_endpoint = self.endpoint
        page_num = 1

        while True:
            response = self._request_with_retry(hook, current_endpoint)

            json_data = response.json()
            try:
                if isinstance(json_data.get("data"), list):
                    len(json_data.get("data", []))
                elif isinstance(json_data.get("results"), list):
                    len(json_data.get("results", []))
                else:
                    pass
            except Exception:
                pass
            if json_data.get("data") or json_data.get("results"):
                all_responses.append(json_data)
                # Persistance immédiate du brut : rien n'est perdu en cas de
                # crash avant la fin de la pagination.
                self._capture_page_to_source(json_data)
            else:
                logging.info("Page vide ignorée : %s", current_endpoint)

            # On teste la présence de "next" -> "href" dans la réponse JSON
            if self.data_type in (
                "coop_activity",
                "coop_utilisateurs",
                "coop_structures",
            ):
                next_link = json_data.get("links", {}).get("next", {}).get("href")
            else:
                next_link = json_data.get("next")
            if next_link:
                logging.info("Page suivante détectée : %s", next_link)
                current_endpoint = self._resolve_next_endpoint(next_link)
                page_num += 1
                if self.page_delay_seconds:
                    time.sleep(self.page_delay_seconds)
            else:
                logging.info("Aucune page suivante détectée.")
                break

        return all_responses
