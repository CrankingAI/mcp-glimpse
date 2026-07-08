"""Durable feedback sink — never a no-op.

The public, anonymous, writable endpoint is bounded: an empty summary is rejected, and each
field is capped so a caller can't grow the store without limit. Two backends:

* ``AzureTableFeedbackStore`` — ``azure-data-tables`` with ``DefaultAzureCredential`` when a
  table service URI is configured (``GLIMPSE_TABLE_URI`` or ``AzureWebJobsStorage__tableServiceUri``).
* ``LocalFeedbackStore`` — appends JSONL to a file and keeps an in-memory list, so local runs
  and tests work without Azure.

``create_feedback_store()`` picks the backend from the environment.
"""

from __future__ import annotations

import json
import os
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Bounds on a public, anonymous, writable endpoint.
MAX_SUMMARY = 300
MAX_DETAIL = 4000
MAX_CONTEXT = 2000

_VALID_KINDS = {"feedback", "feature-request", "bug", "praise"}


def _cap(value: str | None, maximum: int) -> str:
    """Trim to a max length, appending a visible marker so truncation is obvious."""
    text = value or ""
    return text if len(text) <= maximum else text[:maximum] + "…[truncated]"


def _sanitize_kind(kind: str | None) -> str:
    normalized = (kind or "feedback").strip().lower()
    return normalized if normalized in _VALID_KINDS else "feedback"


class FeedbackStore(ABC):
    """Enforces the guard + caps, then delegates persistence to a backend."""

    def record(
        self,
        kind: str,
        summary: str,
        detail: str | None = None,
        context: str | None = None,
    ) -> dict[str, str]:
        if summary is None or not summary.strip():
            return {"id": "", "status": "rejected: summary is required"}

        record_id = uuid.uuid4().hex
        entity = {
            "kind": _sanitize_kind(kind),
            "id": record_id,
            "summary": _cap(summary, MAX_SUMMARY),
            "detail": _cap(detail, MAX_DETAIL),
            "context": _cap(context, MAX_CONTEXT),
            "receivedUtc": datetime.now(timezone.utc).isoformat(),
        }
        self._persist(entity)
        return {"id": record_id, "status": "recorded"}

    @abstractmethod
    def _persist(self, entity: dict[str, Any]) -> None: ...


class LocalFeedbackStore(FeedbackStore):
    """File-backed (JSONL) + in-memory fallback for local dev and tests."""

    def __init__(self, path: str | os.PathLike[str] | None = None) -> None:
        self.records: list[dict[str, Any]] = []
        self.path = Path(path) if path is not None else None

    def _persist(self, entity: dict[str, Any]) -> None:
        self.records.append(entity)
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entity) + "\n")


class AzureTableFeedbackStore(FeedbackStore):
    """Azure Table Storage via managed identity (no shared key). Imports Azure lazily."""

    TABLE_NAME = "feedback"

    def __init__(self, table_service_uri: str, client_id: str | None = None) -> None:
        from azure.data.tables import TableServiceClient  # lazy: optional dependency
        from azure.identity import DefaultAzureCredential

        credential = (
            DefaultAzureCredential(managed_identity_client_id=client_id)
            if client_id
            else DefaultAzureCredential()
        )
        self._service = TableServiceClient(endpoint=table_service_uri, credential=credential)

    def _persist(self, entity: dict[str, Any]) -> None:
        table = self._service.create_table_if_not_exists(self.TABLE_NAME)
        table.create_entity(
            {
                "PartitionKey": entity["kind"],
                "RowKey": entity["id"],
                "Kind": entity["kind"],
                "Summary": entity["summary"],
                "Detail": entity["detail"],
                "Context": entity["context"],
                "ReceivedUtc": entity["receivedUtc"],
            }
        )


def create_feedback_store() -> FeedbackStore:
    """Pick a backend from the environment; default to the local file store."""
    table_uri = os.environ.get("GLIMPSE_TABLE_URI") or os.environ.get(
        "AzureWebJobsStorage__tableServiceUri"
    )
    if table_uri:
        try:
            client_id = os.environ.get("AzureWebJobsStorage__clientId") or os.environ.get(
                "GLIMPSE_MANAGED_IDENTITY_CLIENT_ID"
            )
            return AzureTableFeedbackStore(table_uri, client_id)
        except Exception:
            # Fall back rather than crash the server; never a silent no-op.
            pass
    feedback_file = os.environ.get("GLIMPSE_FEEDBACK_FILE")
    return LocalFeedbackStore(feedback_file)
