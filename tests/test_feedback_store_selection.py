"""Phase 6: create_feedback_store() picks a backend from the environment and never crashes.

The Azure Table backend + managed identity + RBAC are provisioned and validated at deploy
(Phase 8); here we prove the selection logic and the graceful fallback (never a silent no-op,
never a crash) — the `azure` extra is intentionally not installed in dev, so the Azure import
fails and we fall back to the durable local store.
"""
from mcp_glimpse.feedback import FeedbackStore, LocalFeedbackStore, create_feedback_store


def test_defaults_to_local_when_no_table_configured(monkeypatch):
    monkeypatch.delenv("GLIMPSE_TABLE_URI", raising=False)
    monkeypatch.delenv("AzureWebJobsStorage__tableServiceUri", raising=False)
    store = create_feedback_store()
    assert isinstance(store, LocalFeedbackStore)


def test_falls_back_to_local_when_azure_backend_unavailable(monkeypatch):
    # A table URI is configured, but the azure extra isn't installed in dev, so the Azure
    # backend construction fails and we fall back — a FeedbackStore, never an exception.
    monkeypatch.setenv("GLIMPSE_TABLE_URI", "https://example.table.core.windows.net")
    monkeypatch.delenv("AzureWebJobsStorage__tableServiceUri", raising=False)
    store = create_feedback_store()
    assert isinstance(store, FeedbackStore)
    assert isinstance(store, LocalFeedbackStore)
