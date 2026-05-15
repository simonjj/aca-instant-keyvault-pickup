"""
Minimal Flask app that demonstrates near-instant Key Vault secret pickup
on Azure Container Apps by reading directly from AKV using a managed
identity and caching the value in-process with a short TTL.

Environment variables:
  KEY_VAULT_NAME      Name of the Azure Key Vault (without the .vault.azure.net suffix).
  SECRET_NAME         Name of the secret to read. Defaults to "demo-secret".
  SECRET_TTL_SECONDS  How long to cache the secret in memory. Defaults to 30.
  AZURE_CLIENT_ID     Optional. Client id of the user-assigned managed identity.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from dataclasses import dataclass
from typing import Optional

from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("akv-pickup")

KEY_VAULT_NAME = os.environ.get("KEY_VAULT_NAME", "")
SECRET_NAME = os.environ.get("SECRET_NAME", "demo-secret")
SECRET_TTL_SECONDS = int(os.environ.get("SECRET_TTL_SECONDS", "30"))
MANAGED_IDENTITY_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID")

if not KEY_VAULT_NAME:
    log.warning("KEY_VAULT_NAME is not set. The app will start but secret reads will fail.")

VAULT_URL = f"https://{KEY_VAULT_NAME}.vault.azure.net" if KEY_VAULT_NAME else ""


def _build_credential():
    if MANAGED_IDENTITY_CLIENT_ID:
        log.info("Using ManagedIdentityCredential with client id %s", MANAGED_IDENTITY_CLIENT_ID)
        return ManagedIdentityCredential(client_id=MANAGED_IDENTITY_CLIENT_ID)
    log.info("Using DefaultAzureCredential")
    return DefaultAzureCredential()


@dataclass
class CachedSecret:
    value: str
    version: Optional[str]
    fetched_at: float


class SecretCache:
    """Thread-safe in-memory cache with a fixed TTL."""

    def __init__(self, vault_url: str, secret_name: str, ttl_seconds: int):
        self._vault_url = vault_url
        self._secret_name = secret_name
        self._ttl = ttl_seconds
        self._lock = threading.Lock()
        self._cached: Optional[CachedSecret] = None
        self._client: Optional[SecretClient] = None

    def _client_or_create(self) -> SecretClient:
        if self._client is None:
            if not self._vault_url:
                raise RuntimeError("KEY_VAULT_NAME is not configured")
            self._client = SecretClient(vault_url=self._vault_url, credential=_build_credential())
        return self._client

    def _is_stale(self, entry: CachedSecret) -> bool:
        return (time.time() - entry.fetched_at) >= self._ttl

    def _fetch(self) -> CachedSecret:
        client = self._client_or_create()
        log.info("Fetching secret '%s' from %s", self._secret_name, self._vault_url)
        secret = client.get_secret(self._secret_name)
        version = None
        if secret.properties and secret.properties.version:
            version = secret.properties.version
        return CachedSecret(value=secret.value or "", version=version, fetched_at=time.time())

    def get(self, force_refresh: bool = False) -> CachedSecret:
        with self._lock:
            if force_refresh or self._cached is None or self._is_stale(self._cached):
                self._cached = self._fetch()
            return self._cached

    def snapshot(self):
        with self._lock:
            return self._cached, self._ttl


cache = SecretCache(VAULT_URL, SECRET_NAME, SECRET_TTL_SECONDS)


app = Flask(__name__)


def _describe(entry: CachedSecret, ttl: int) -> dict:
    age = round(time.time() - entry.fetched_at, 2)
    return {
        "secret_name": SECRET_NAME,
        "secret_value": entry.value,
        "secret_version": entry.version,
        "fetched_at_epoch": round(entry.fetched_at, 2),
        "age_seconds": age,
        "ttl_seconds": ttl,
        "seconds_until_refresh": max(0, round(ttl - age, 2)),
        "vault_url": VAULT_URL,
    }


@app.route("/")
def index():
    try:
        entry = cache.get()
        _, ttl = cache.snapshot()
        return jsonify({"status": "ok", **_describe(entry, ttl)})
    except Exception as exc:  # noqa: BLE001
        log.exception("Failed to read secret")
        return jsonify({"status": "error", "error": str(exc)}), 500


@app.route("/refresh", methods=["GET", "POST"])
def refresh():
    try:
        entry = cache.get(force_refresh=True)
        _, ttl = cache.snapshot()
        return jsonify({"status": "refreshed", **_describe(entry, ttl)})
    except Exception as exc:  # noqa: BLE001
        log.exception("Forced refresh failed")
        return jsonify({"status": "error", "error": str(exc)}), 500


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
