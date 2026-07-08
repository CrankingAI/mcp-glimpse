"""Share card — the viral 'Agent Facts' asset.

Data minimization is the feature: a card persists ONLY aggregate counts, never tool names or
descriptions. `share_context_card` is elicitation-confirmed before anything is written. The card
page (/c/{id}, on www) carries an OG image rendered here server-side with Pillow (no headless
browser) so it unfurls beautifully on social. Aesthetic follows Paper & Proof — warm paper, exact
ink, machine facts in monospace, one rationed gate-green.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel

from . import manifest
from .model import Analysis, GlimpseSnapshot

_FONT_DIR = manifest.RESOURCES_DIR / "fonts"

# Paper & Proof palette (light "Paper").
_PAPER = (246, 244, 238)
_INK = (28, 26, 22)
_MUTED = (107, 102, 91)
_GREEN = (22, 105, 75)
_HAIR = (228, 224, 213)


class Card(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="ignore")

    id: str
    servers: int = 0
    tools: int = 0
    destructive: int = 0
    annotation_coverage_pct: int = 0
    unannotated: int = 0
    sampling: bool = False
    elicitation: bool = False
    roots: bool = False
    cost_low: int | None = None
    cost_high: int | None = None
    window: int | None = None
    created_utc: str = ""


def aggregate(analysis: Analysis, snapshot: GlimpseSnapshot | None) -> dict[str, Any]:
    """Derive the aggregate-only card fields from an analysis + snapshot. Never includes tool
    names or descriptions — data minimization is enforced here, server-side."""
    total = analysis.total_tools or 0
    coverage = int(round(100 * analysis.annotated_tool_count / total)) if total else 0
    caps = snapshot.client_capabilities if snapshot else None
    cost = analysis.context_cost
    return {
        "servers": analysis.total_servers,
        "tools": total,
        "destructive": analysis.dangerous_tool_count,
        "annotation_coverage_pct": coverage,
        "unannotated": analysis.unannotated_tool_count,
        "sampling": bool(caps and caps.sampling),
        "elicitation": bool(caps and caps.elicitation),
        "roots": bool(caps and caps.roots),
        "cost_low": cost.estimated_tokens_low if cost else None,
        "cost_high": cost.estimated_tokens_high if cost else None,
        "window": cost.window_total_tokens if cost else None,
    }


# --- persistence ----------------------------------------------------------------------------

class CardStore(ABC):
    def put(self, aggregates: dict[str, Any]) -> Card:
        card = Card(
            id=uuid.uuid4().hex[:12],
            created_utc=datetime.now(timezone.utc).isoformat(),
            **aggregates,
        )
        self._persist(card)
        return card

    @abstractmethod
    def _persist(self, card: Card) -> None: ...

    @abstractmethod
    def get(self, card_id: str) -> Card | None: ...


class LocalCardStore(CardStore):
    def __init__(self, path: str | os.PathLike[str] | None = None) -> None:
        self.cards: dict[str, Card] = {}
        self.path = Path(path) if path is not None else None
        if self.path is not None and self.path.exists():
            for line in self.path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    card = Card.model_validate_json(line)
                except Exception:
                    continue  # skip corrupt/legacy lines rather than crash server startup
                self.cards[card.id] = card

    def _persist(self, card: Card) -> None:
        self.cards[card.id] = card
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(card.model_dump_json() + "\n")

    def get(self, card_id: str) -> Card | None:
        return self.cards.get(card_id)


class AzureTableCardStore(CardStore):
    TABLE_NAME = "cards"

    def __init__(self, table_service_uri: str, client_id: str | None = None) -> None:
        from azure.data.tables import TableServiceClient
        from azure.identity import DefaultAzureCredential

        credential = (
            DefaultAzureCredential(managed_identity_client_id=client_id)
            if client_id
            else DefaultAzureCredential()
        )
        self._service = TableServiceClient(endpoint=table_service_uri, credential=credential)

    def _persist(self, card: Card) -> None:
        table = self._service.create_table_if_not_exists(self.TABLE_NAME)
        entity = {"PartitionKey": "card", "RowKey": card.id}
        entity.update({k: v for k, v in card.model_dump().items() if k != "id" and v is not None})
        table.upsert_entity(entity)

    def get(self, card_id: str) -> Card | None:
        try:
            table = self._service.get_table_client(self.TABLE_NAME)
            entity = table.get_entity("card", card_id)
            fields = {k: v for k, v in entity.items() if k not in ("PartitionKey", "RowKey")}
            return Card(id=card_id, **fields)
        except Exception:
            return None


def create_card_store() -> CardStore:
    table_uri = os.environ.get("GLIMPSE_TABLE_URI") or os.environ.get(
        "AzureWebJobsStorage__tableServiceUri"
    )
    if table_uri:
        try:
            client_id = os.environ.get("AzureWebJobsStorage__clientId") or os.environ.get(
                "GLIMPSE_MANAGED_IDENTITY_CLIENT_ID"
            )
            return AzureTableCardStore(table_uri, client_id)
        except Exception:
            pass
    return LocalCardStore(os.environ.get("GLIMPSE_CARDS_FILE"))


# --- OG image (Pillow) ----------------------------------------------------------------------

def _font(bold: bool, size: int):
    from PIL import ImageFont

    name = "JetBrainsMono-Bold.ttf" if bold else "JetBrainsMono-Regular.ttf"
    return ImageFont.truetype(str(_FONT_DIR / name), size)


def _k(n: int | None) -> str:
    if n is None:
        return "?"
    if n >= 1000:
        return f"{n / 1000:.0f}K"
    return str(n)


def _barcode(draw, x: int, y: int, seed: str) -> None:
    digest = hashlib.sha256(seed.encode()).digest()
    px = x
    for i in range(52):
        byte = digest[i % len(digest)]
        width = 1 + (byte % 4)
        if byte % 2:
            draw.rectangle([px, y, px + width, y + 52], fill=_INK)
        px += width + 2


def render_og_png(card: Card) -> bytes:
    """Render the 1200x630 'Agent Facts' card as PNG bytes — a nutrition-label parody whose footer
    carries the Context-Receipt total. No external requests, no headless browser."""
    from PIL import Image, ImageDraw

    width, height = 1200, 630
    img = Image.new("RGB", (width, height), _PAPER)
    draw = ImageDraw.Draw(img)
    margin = 70

    draw.rectangle([margin // 2, margin // 2, width - margin // 2, height - margin // 2],
                   outline=_HAIR, width=2)
    draw.text((margin, margin - 12), "MCP-GLIMPSE · AGENT FACTS", font=_font(True, 22), fill=_GREEN)

    top = margin + 34
    draw.line([margin, top, width - margin, top], fill=_INK, width=3)

    caps = " ".join(
        c for c, on in (("elicitation", card.elicitation), ("sampling", card.sampling), ("roots", card.roots)) if on
    ) or "none"
    dangerous = str(card.destructive)
    if card.destructive and card.annotation_coverage_pct < 50:
        dangerous += "  unlabeled!"
    rows = [
        ("Servers", str(card.servers)),
        ("Tools", str(card.tools)),
        ("Destructive", dangerous),
        ("Annotation coverage", f"{card.annotation_coverage_pct}%"),
        ("Capabilities", caps),
    ]
    row_y = top + 34
    label_font, value_font = _font(False, 34), _font(True, 34)
    for label, value in rows:
        draw.text((margin, row_y), label, font=label_font, fill=_MUTED)
        draw.text((width - margin, row_y), value, font=value_font, fill=_INK, anchor="ra")
        row_y += 66
        draw.line([margin, row_y - 16, width - margin, row_y - 16], fill=_HAIR, width=1)

    footer = height - margin - 78
    draw.line([margin, footer, width - margin, footer], fill=_INK, width=3)
    if card.cost_low and card.window:
        mid = (card.cost_low + (card.cost_high or card.cost_low)) / 2
        pct = int(round(100 * mid / card.window))
        total = f"TOTAL: ~{_k(card.cost_low)}-{_k(card.cost_high)} / {_k(card.window)} ({pct}%)"
    else:
        total = "TOTAL: tool-definition cost"
    draw.text((margin, footer + 18), total, font=_font(True, 30), fill=_GREEN)
    draw.text((margin, footer + 56), "spent before you said a word", font=_font(False, 24), fill=_MUTED)
    _barcode(draw, width - margin - 220, footer + 20, card.id)

    buffer = io.BytesIO()
    img.save(buffer, "PNG")
    return buffer.getvalue()


def aggregates_from_snapshot_json(snapshot_json: str | None) -> dict[str, Any]:
    """Convenience for the share tool: parse -> analyze -> aggregate, all server-side."""
    from .analyzer import analyze
    from .connection import observe
    from .parser import parse

    parsed = parse(snapshot_json)
    analysis = analyze(parsed.snapshot, observe(None))
    return aggregate(analysis, parsed.snapshot)


def json_dumps(value: Any) -> str:
    return json.dumps(value)
