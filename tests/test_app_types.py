"""Drift gate: app/src/types.generated.ts must match the current Pydantic wire models."""
import importlib.util
from pathlib import Path

_GEN = Path(__file__).resolve().parents[1] / "scripts" / "gen_app_types.py"
_spec = importlib.util.spec_from_file_location("gen_app_types", _GEN)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)


def test_generated_types_exist():
    assert gen.OUT.exists(), "run: uv run python scripts/gen_app_types.py"


def test_generated_types_are_current():
    assert gen.OUT.read_text(encoding="utf-8") == gen.generate(), (
        "app/src/types.generated.ts is stale — regenerate with "
        "`uv run python scripts/gen_app_types.py` (never hand-edit it)."
    )
