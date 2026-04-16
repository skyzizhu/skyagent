import Foundation

enum KnowledgeBaseSidecarBootstrap {
    nonisolated static let version = "0.7"
    nonisolated static let pythonScript = #"""
#!/usr/bin/env python3
import html
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
import urllib.request
import uuid
from datetime import datetime, timezone
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import lancedb
except Exception:
    lancedb = None

try:
    import pyarrow as pa
except Exception:
    pa = None

try:
    from docling.document_converter import DocumentConverter
except Exception:
    DocumentConverter = None


BASE_DIR = Path(__file__).resolve().parent.parent
LIBRARIES_ROOT = BASE_DIR / "libraries"
LIBRARIES_FILE = BASE_DIR / "libraries.json"
CONFIG_FILE = BASE_DIR / "sidecar" / "config.json"
LOGS_DIR = BASE_DIR / "sidecar" / "logs"
RUNTIME_DIR = BASE_DIR / "sidecar" / "runtime"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 9876
DOCLING_CONVERTER = None

TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".json", ".yaml", ".yml", ".csv", ".log", ".text",
    ".swift", ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".kt", ".kts", ".go",
    ".rs", ".rb", ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm", ".sh",
    ".zsh", ".bash", ".xml", ".html", ".htm"
}

CODE_EXTENSIONS = {
    ".swift", ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".kt", ".kts", ".go",
    ".rs", ".rb", ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm", ".sh",
    ".zsh", ".bash"
}

STRUCTURED_TEXT_EXTENSIONS = {
    ".json", ".yaml", ".yml", ".xml", ".csv"
}

WEB_LIKE_EXTENSIONS = {
    ".html", ".htm", ".md", ".markdown"
}


class HTMLTextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
        self._ignore_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript"}:
            self._ignore_depth += 1
        elif tag in {"p", "div", "section", "article", "li", "h1", "h2", "h3", "h4", "h5", "h6", "br"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript"} and self._ignore_depth > 0:
            self._ignore_depth -= 1
        elif tag in {"p", "div", "section", "article", "li"}:
            self.parts.append("\n")

    def handle_data(self, data):
        if self._ignore_depth == 0:
            text = data.strip()
            if text:
                self.parts.append(text)

    def text(self):
        merged = " ".join(self.parts)
        merged = html.unescape(merged)
        merged = re.sub(r"[ \t]+", " ", merged)
        merged = re.sub(r"\n{2,}", "\n\n", merged)
        return merged.strip()


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_dirs():
    for directory in (LIBRARIES_ROOT, LOGS_DIR, RUNTIME_DIR):
        directory.mkdir(parents=True, exist_ok=True)


def load_runtime_config():
    return read_json(CONFIG_FILE, {})


def configured_backend(config, key, default_value="auto"):
    section = config.get(key) or {}
    backend = str(section.get("backend") or default_value).strip().lower()
    if backend not in {"auto", "builtin", "docling", "lancedb"}:
        return default_value
    return backend


def docling_available():
    return DocumentConverter is not None


def lancedb_available():
    return lancedb is not None and pa is not None


def resolve_parser_backend(config):
    backend = configured_backend(config, "parser", "auto")
    if backend == "docling":
        return "docling" if docling_available() else "builtin"
    if backend == "builtin":
        return "builtin"
    return "docling" if docling_available() else "builtin"


def resolve_index_backend(config):
    backend = configured_backend(config, "index", "auto")
    if backend == "lancedb":
        return "lancedb" if lancedb_available() else "builtin"
    if backend == "builtin":
        return "builtin"
    return "lancedb" if lancedb_available() else "builtin"


def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


def normalize_text(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"\u0000", "", text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def tokenize(text):
    lowered = text.lower()
    ascii_tokens = re.findall(r"[a-z0-9]{2,}", lowered)
    cjk_segments = re.findall(r"[\u4e00-\u9fff]+", lowered)
    cjk_tokens = []
    for segment in cjk_segments:
        if len(segment) == 1:
            cjk_tokens.append(segment)
        else:
            for index in range(len(segment) - 1):
                cjk_tokens.append(segment[index:index + 2])
    return ascii_tokens + cjk_tokens


def split_sentences(text):
    return [segment.strip() for segment in re.split(r"(?<=[。！？!?；;.\n])", text) if segment.strip()]


def detect_chunk_profile(source_path, source_type):
    suffix = Path(source_path).suffix.lower()
    if source_type == "web" or suffix in WEB_LIKE_EXTENSIONS:
        return {"mode": "document", "max_chars": 1200, "overlap_chars": 180}
    if suffix in CODE_EXTENSIONS:
        return {"mode": "code", "max_chars": 560, "overlap_chars": 90}
    if suffix in STRUCTURED_TEXT_EXTENSIONS:
        return {"mode": "structured", "max_chars": 760, "overlap_chars": 110}
    if suffix in {".pdf", ".doc", ".docx", ".rtf"}:
        return {"mode": "document", "max_chars": 1200, "overlap_chars": 160}
    return {"mode": "document", "max_chars": 900, "overlap_chars": 120}


def chunk_code_text(text, max_chars, overlap_chars):
    lines = [line.rstrip() for line in text.split("\n")]
    lines = [line for line in lines if line.strip()]
    if not lines:
        return []

    chunks = []
    current_lines = []
    current_length = 0
    overlap_lines = max(1, overlap_chars // 40)

    for line in lines:
        projected = current_length + len(line) + 1
        if current_lines and projected > max_chars:
            chunks.append("\n".join(current_lines).strip())
            current_lines = current_lines[-overlap_lines:]
            current_length = sum(len(item) + 1 for item in current_lines)
        current_lines.append(line)
        current_length += len(line) + 1

    if current_lines:
        chunks.append("\n".join(current_lines).strip())
    return chunks


def chunk_text(text, source_path="", source_type="file"):
    normalized = normalize_text(text)
    if not normalized:
        return []

    profile = detect_chunk_profile(source_path, source_type)
    max_chars = profile["max_chars"]
    overlap_chars = profile["overlap_chars"]

    if profile["mode"] in {"code", "structured"}:
        chunks = chunk_code_text(normalized, max_chars=max_chars, overlap_chars=overlap_chars)
    else:
        paragraphs = [part.strip() for part in re.split(r"\n\s*\n", normalized) if part.strip()]
        chunks = []
        current = ""
        for paragraph in paragraphs:
            if len(paragraph) <= max_chars and len(current) + len(paragraph) + 2 <= max_chars:
                current = f"{current}\n\n{paragraph}".strip() if current else paragraph
                continue

            if current:
                chunks.append(current.strip())
                current = ""

            if len(paragraph) <= max_chars:
                current = paragraph
                continue

            sentences = split_sentences(paragraph)
            buffer = ""
            for sentence in sentences:
                if len(sentence) > max_chars:
                    start = 0
                    while start < len(sentence):
                        end = min(start + max_chars, len(sentence))
                        piece = sentence[start:end].strip()
                        if piece:
                            chunks.append(piece)
                        start = max(end - overlap_chars, start + 1)
                    continue

                candidate = f"{buffer} {sentence}".strip() if buffer else sentence
                if len(candidate) <= max_chars:
                    buffer = candidate
                else:
                    if buffer:
                        chunks.append(buffer)
                    buffer = sentence
            if buffer:
                current = buffer

        if current:
            chunks.append(current.strip())

    deduped = []
    seen = set()
    for chunk in chunks:
        clean = normalize_text(chunk)
        if clean and clean not in seen:
            deduped.append(clean)
            seen.add(clean)
    return deduped


def html_to_text(raw_html):
    parser = HTMLTextExtractor()
    parser.feed(raw_html)
    return parser.text()


def read_text_with_textutil(path):
    try:
        output = subprocess.check_output(
            ["textutil", "-convert", "txt", "-stdout", str(path)],
            stderr=subprocess.DEVNULL
        )
        return output.decode("utf-8", errors="ignore").strip()
    except Exception:
        return ""


def read_text_with_pdftotext(path):
    try:
        output = subprocess.check_output(
            ["pdftotext", str(path), "-"],
            stderr=subprocess.DEVNULL
        )
        return output.decode("utf-8", errors="ignore").strip()
    except Exception:
        return ""


def read_text_with_docling(path):
    global DOCLING_CONVERTER
    if DocumentConverter is None:
        return ""

    try:
        if DOCLING_CONVERTER is None:
            DOCLING_CONVERTER = DocumentConverter()
        result = DOCLING_CONVERTER.convert(str(path))
        document = getattr(result, "document", None)
        if document is None:
            return ""
        if hasattr(document, "export_to_markdown"):
            return normalize_text(document.export_to_markdown())
        if hasattr(document, "export_to_text"):
            return normalize_text(document.export_to_text())
    except Exception:
        return ""
    return ""


def fetch_web_text(url):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "SkyAgentKnowledgeSidecar/0.7"}
    )
    with urllib.request.urlopen(request, timeout=18) as response:
        content_type = response.headers.get("Content-Type", "")
        raw = response.read()
        charset = "utf-8"
        match = re.search(r"charset=([A-Za-z0-9_-]+)", content_type)
        if match:
            charset = match.group(1)
        decoded = raw.decode(charset, errors="ignore")
        if "html" in content_type.lower() or "<html" in decoded.lower():
            return html_to_text(decoded)
        return normalize_text(decoded)


def read_source_text(source_path, source_type):
    if source_type == "web":
        return fetch_web_text(source_path)

    path = Path(source_path)
    if not path.exists() or not path.is_file():
        return ""

    suffix = path.suffix.lower()
    parser_backend = resolve_parser_backend(load_runtime_config())

    if parser_backend == "docling" and suffix in {".pdf", ".doc", ".docx", ".rtf", ".html", ".htm"}:
        text = read_text_with_docling(path)
        if text:
            return text

    if suffix in {".html", ".htm"}:
        try:
            return html_to_text(path.read_text(encoding="utf-8", errors="ignore"))
        except Exception:
            return ""

    if suffix in {".doc", ".docx", ".rtf"}:
        return read_text_with_textutil(path)

    if suffix == ".pdf":
        text = read_text_with_pdftotext(path)
        if text:
            return text
        return ""

    if suffix in TEXT_EXTENSIONS:
        try:
            return path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return ""

    return ""


def enumerate_sources(source_type, source_path):
    if source_type == "web":
        return [(source_type, source_path, source_path)]

    path = Path(source_path)
    if source_type == "file":
        return [(source_type, str(path), path.name)]

    if not path.exists() or not path.is_dir():
        return []

    entries = []
    for candidate in path.rglob("*"):
        if not candidate.is_file():
            continue
        suffix = candidate.suffix.lower()
        if suffix in TEXT_EXTENSIONS or suffix in {".doc", ".docx", ".rtf", ".pdf"}:
            entries.append(("file", str(candidate), candidate.name))
    return entries


def build_query_variants(query):
    normalized = normalize_text(query)
    if not normalized:
        return []

    variants = [normalized]
    compact = re.sub(r"[，。！？、,:;；\-\(\)\[\]{}“”\"'`]+", " ", normalized)
    compact = normalize_text(compact)
    if compact and compact not in variants:
        variants.append(compact)

    stripped = re.sub(
        r"^(请|帮我|麻烦|看看|看一下|帮忙|用知识库|根据知识库|请用知识库|请根据知识库|再|重新|继续)\s*",
        "",
        compact
    ).strip()
    if stripped and stripped not in variants:
        variants.append(stripped)

    ascii_phrases = re.findall(r"[a-zA-Z][a-zA-Z0-9_./:-]{2,}", normalized)
    for phrase in ascii_phrases:
        lowered = phrase.lower()
        if lowered not in variants:
            variants.append(lowered)

    chinese_phrases = re.findall(r"[\u4e00-\u9fff]{2,}", normalized)
    for phrase in chinese_phrases:
        if phrase not in variants:
            variants.append(phrase)

    return variants[:8]


def normalize_match_text(text):
    lowered = normalize_text(text).lower()
    lowered = re.sub(r"\s+", " ", lowered)
    return lowered.strip()


def build_char_ngrams(text):
    compact = re.sub(r"\s+", "", normalize_match_text(text))
    if not compact:
        return set()
    gram_size = 2 if re.search(r"[\u4e00-\u9fff]", compact) else 3
    if len(compact) <= gram_size:
        return {compact}
    return {compact[index:index + gram_size] for index in range(len(compact) - gram_size + 1)}


def detect_query_profile(variants):
    joined = " ".join(variants)
    ascii_phrases = re.findall(r"[A-Za-z][A-Za-z0-9_./:-]{2,}", joined)
    if len(ascii_phrases) >= 2 or re.search(r"[{}();_=<>/]", joined):
        return "code"
    return "text"


def tokenize_for_rerank(text):
    lowered = normalize_match_text(text)
    return [token for token in re.split(r"\s+", lowered) if token]


def build_token_phrases(variants):
    phrases = []
    for variant in variants:
        tokens = tokenize(variant)
        if len(tokens) >= 2:
            phrases.append(tokens)
    return phrases[:6]


def ordered_token_score(tokens, token_set, phrases):
    if not tokens:
        return 0.0

    score = 0.0
    for phrase in phrases:
        positions = []
        cursor = 0
        matched = True
        for token in phrase:
            try:
                index = tokens.index(token, cursor)
            except ValueError:
                matched = False
                break
            positions.append(index)
            cursor = index + 1

        if not matched or len(positions) < 2:
            continue

        span = positions[-1] - positions[0] + 1
        compactness = len(phrase) / max(span, len(phrase))
        score = max(score, 0.45 + compactness * 0.35)

    if score == 0.0:
        matched_tokens = [index for index, token in enumerate(tokens) if token in token_set]
        if len(matched_tokens) >= 2:
            span = matched_tokens[min(len(matched_tokens) - 1, 2)] - matched_tokens[0] + 1
            score = min(0.45, 0.18 + 0.18 / max(span, 1))
    return min(score, 1.0)


def leading_match_score(title, snippet, source, variants, token_set):
    title_text = normalize_match_text(title)
    snippet_text = normalize_match_text(snippet)
    source_text = normalize_match_text(source)
    best = 0.0

    for variant in variants:
        normalized_variant = normalize_match_text(variant)
        if not normalized_variant:
            continue
        if title_text.startswith(normalized_variant):
            best = max(best, 1.0)
        elif snippet_text.startswith(normalized_variant):
            best = max(best, 0.85)
        elif source_text.startswith(normalized_variant):
            best = max(best, 0.72)

    if best == 0.0:
        title_tokens = tokenize(title_text)
        snippet_tokens = tokenize(snippet_text)
        leading_title = set(title_tokens[:4])
        leading_snippet = set(snippet_tokens[:10])
        if token_set & leading_title:
            best = max(best, 0.65)
        if token_set & leading_snippet:
            best = max(best, 0.4)
    return best


def variant_coverage_score(title, snippet, source, variants):
    combined = normalize_match_text(f"{title} {source} {snippet}")
    if not combined:
        return 0.0

    hit_count = 0
    weighted_hits = 0.0
    for index, variant in enumerate(variants):
        normalized_variant = normalize_match_text(variant)
        if not normalized_variant:
            continue
        if normalized_variant in combined:
            hit_count += 1
            weighted_hits += max(0.34, 1.0 - index * 0.1)

    if hit_count == 0:
        return 0.0

    coverage = hit_count / max(len(variants), 1)
    weight_factor = min(weighted_hits / max(min(len(variants), 4), 1), 1.0)
    return min(coverage * 0.55 + weight_factor * 0.45, 1.0)


def token_density_score(tokens, token_set):
    positions = [index for index, token in enumerate(tokens) if token in token_set]
    if not positions:
        return 0.0
    if len(positions) == 1:
        return 0.22

    best = 0.0
    window_size = min(4, len(positions))
    for start in range(len(positions)):
        end = min(start + window_size - 1, len(positions) - 1)
        span = positions[end] - positions[start] + 1
        coverage = end - start + 1
        density = coverage / max(span, coverage)
        best = max(best, density)
    return min(best, 1.0)


def match_position_score(title, snippet, source, variants, token_set):
    title_text = normalize_match_text(title)
    snippet_text = normalize_match_text(snippet)
    source_text = normalize_match_text(source)
    best = 0.0

    def score_for_position(index, base):
        if index < 0:
            return 0.0
        return max(base * (1.0 - min(index / 180.0, 0.72)), base * 0.28)

    for variant in variants:
        normalized_variant = normalize_match_text(variant)
        if not normalized_variant:
            continue
        best = max(best, score_for_position(title_text.find(normalized_variant), 1.0))
        best = max(best, score_for_position(source_text.find(normalized_variant), 0.72))
        best = max(best, score_for_position(snippet_text.find(normalized_variant), 0.82))

    if best > 0.0:
        return min(best, 1.0)

    title_tokens = tokenize(title_text)
    snippet_tokens = tokenize(snippet_text)
    title_positions = [index for index, token in enumerate(title_tokens) if token in token_set]
    snippet_positions = [index for index, token in enumerate(snippet_tokens) if token in token_set]
    if title_positions:
        best = max(best, 0.58)
    if snippet_positions:
        best = max(best, max(0.22, 0.5 - min(snippet_positions[0] / 28.0, 0.26)))
    return min(best, 1.0)


def source_name_match_score(source, title, variants, query_set):
    source_path = Path(source or "")
    stem = normalize_match_text(source_path.stem)
    name = normalize_match_text(source_path.name)
    title_text = normalize_match_text(title)
    if not stem and not name:
        return 0.0

    best = 0.0
    for variant in variants:
        normalized_variant = normalize_match_text(variant)
        if not normalized_variant:
            continue
        if normalized_variant and normalized_variant in stem:
            best = max(best, 1.0)
        elif normalized_variant and normalized_variant in name:
            best = max(best, 0.92)
        elif normalized_variant and normalized_variant in title_text:
            best = max(best, 0.68)

    stem_tokens = set(tokenize(stem))
    name_tokens = set(tokenize(name))
    if query_set & stem_tokens:
        best = max(best, 0.58)
    if query_set & name_tokens:
        best = max(best, 0.48)
    return min(best, 1.0)


def filter_reranked_hits(reranked, query_profile, limit):
    if not reranked:
        return []

    best_score = reranked[0].get("score") or 0.0
    if best_score < 0.2:
        return reranked[:min(limit, 2)]

    relative_floor = 0.56 if query_profile == "text" else 0.5
    absolute_floor = 0.19 if query_profile == "text" else 0.16
    threshold = max(absolute_floor, best_score * relative_floor)
    filtered = [item for item in reranked if (item.get("score") or 0.0) >= threshold]

    minimum_count = min(limit, 2)
    if len(filtered) < minimum_count:
        return reranked[:minimum_count]
    return filtered[:limit]


def rerank_hits(scored, variants, query_set, query_profile, limit):
    candidate_pool = scored[:max(limit * 5, 16)]
    phrases = build_token_phrases(variants)
    reranked = []
    seen_snippets = set()
    per_document_count = {}

    for item in candidate_pool:
        snippet_key = normalize_match_text(item["snippet"])
        if snippet_key in seen_snippets:
            continue

        title = item.get("title") or ""
        snippet = item.get("snippet") or ""
        source = item.get("source") or ""
        body_tokens = tokenize_for_rerank(f"{title}\n{source}\n{snippet}")
        order_score = ordered_token_score(body_tokens, query_set, phrases)
        leading_score = leading_match_score(title, snippet, source, variants, query_set)
        coverage_score = variant_coverage_score(title, snippet, source, variants)
        density_score = token_density_score(body_tokens, query_set)
        position_score = match_position_score(title, snippet, source, variants, query_set)
        source_score = source_name_match_score(source, title, variants, query_set)

        rerank_score = (
            item["score"] * 0.64 +
            order_score * 0.11 +
            leading_score * 0.07 +
            coverage_score * 0.06 +
            density_score * 0.03 +
            position_score * 0.03 +
            source_score * 0.06
        )

        source_suffix = Path(source).suffix.lower()
        if query_profile == "code" and source_suffix in CODE_EXTENSIONS and "\n" in snippet:
            rerank_score += 0.03
        elif query_profile == "text" and source_suffix in WEB_LIKE_EXTENSIONS:
            rerank_score += 0.02

        adjusted = dict(item)
        adjusted["score"] = round(rerank_score, 4)

        document_key = item.get("documentId") or item.get("source") or item.get("id")
        current_count = per_document_count.get(document_key, 0)
        if current_count >= 2:
            continue

        if current_count > 0:
            penalty = 0.08 if query_profile == "text" else 0.06
            adjusted["score"] = round(max(adjusted["score"] - current_count * penalty, 0.0), 4)

        reranked.append(adjusted)
        seen_snippets.add(snippet_key)
        per_document_count[document_key] = current_count + 1

    reranked.sort(key=lambda item: (item["score"], len(item["snippet"])), reverse=True)
    return filter_reranked_hits(reranked, query_profile, limit)


def load_library_index():
    raw = read_json(LIBRARIES_FILE, {"libraries": []})
    if isinstance(raw, dict):
        libraries = raw.get("libraries", [])
        if isinstance(libraries, list):
            raw["libraries"] = libraries
            return raw
        return {"libraries": []}
    if isinstance(raw, list):
        return {"libraries": raw}
    return {"libraries": []}


def persist_library_summary(library_id, doc_count, chunk_count, status):
    index = load_library_index()
    updated_at = now_iso()
    for library in index.get("libraries", []):
        if library.get("id") == library_id:
            library["documentCount"] = doc_count
            library["chunkCount"] = chunk_count
            library["status"] = status
            library["updatedAt"] = updated_at
            break
    write_json(LIBRARIES_FILE, index)
    meta_path = LIBRARIES_ROOT / library_id / "meta.json"
    meta = read_json(meta_path, {})
    if meta:
        meta["documentCount"] = doc_count
        meta["chunkCount"] = chunk_count
        meta["status"] = status
        meta["updatedAt"] = updated_at
        write_json(meta_path, meta)


def library_paths(library_id):
    root = LIBRARIES_ROOT / library_id
    return {
        "root": root,
        "documents": root / "index" / "documents.json",
        "chunks": root / "chunks" / "chunks.json",
        "lancedb": root / "index" / "lancedb"
    }


def write_lancedb_chunks(library_id, chunks_list):
    if not lancedb_available():
        return False

    paths = library_paths(library_id)
    db_dir = paths["lancedb"]
    db_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for chunk in chunks_list:
        rows.append({
            "id": chunk.get("id") or "",
            "documentId": chunk.get("documentId") or "",
            "source": chunk.get("source") or "",
            "title": chunk.get("title") or "",
            "snippet": chunk.get("snippet") or "",
            "score": float(chunk.get("score") or 0.0),
            "citation": chunk.get("citation") or "",
            "tokenCount": int(chunk.get("tokenCount") or 0),
            "importedAt": chunk.get("importedAt") or "",
            "tokensJson": json.dumps(chunk.get("tokens") or [], ensure_ascii=False)
        })

    try:
        db = lancedb.connect(str(db_dir))
        try:
            existing_names = set(db.table_names())
        except Exception:
            existing_names = set()

        if "chunks" in existing_names:
            db.drop_table("chunks")

        if rows:
            db.create_table("chunks", data=rows)
        return True
    except Exception:
        return False


def read_lancedb_chunks(library_id):
    if not lancedb_available():
        return None

    paths = library_paths(library_id)
    db_dir = paths["lancedb"]
    if not db_dir.exists():
        return None

    try:
        db = lancedb.connect(str(db_dir))
        try:
            existing_names = set(db.table_names())
        except Exception:
            existing_names = set()
        if "chunks" not in existing_names:
            return None
        table = db.open_table("chunks")
        rows = table.to_arrow().to_pylist()
        hydrated = []
        for row in rows:
            hydrated.append({
                "id": row.get("id") or "",
                "documentId": row.get("documentId") or "",
                "source": row.get("source") or "",
                "title": row.get("title") or "",
                "snippet": row.get("snippet") or "",
                "citation": row.get("citation") or "",
                "tokenCount": row.get("tokenCount") or 0,
                "importedAt": row.get("importedAt") or "",
                "tokens": json.loads(row.get("tokensJson") or "[]")
            })
        return hydrated
    except Exception:
        return None


def normalize_source_key(path):
    return os.path.normpath(str(path or ""))


def content_hash(text):
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def is_source_under_root(source, root_path):
    normalized_source = normalize_source_key(source)
    normalized_root = normalize_source_key(root_path)
    if not normalized_source or not normalized_root:
        return False
    return normalized_source == normalized_root or normalized_source.startswith(normalized_root + os.sep)


def remove_sources_from_indexes(documents_list, chunks_list, sources_to_remove):
    normalized_sources = {normalize_source_key(source) for source in sources_to_remove if source}
    if not normalized_sources:
        return documents_list, chunks_list

    filtered_documents = [
        doc for doc in documents_list
        if normalize_source_key(doc.get("source")) not in normalized_sources
    ]
    filtered_chunks = [
        chunk for chunk in chunks_list
        if normalize_source_key(chunk.get("source")) not in normalized_sources
    ]
    return filtered_documents, filtered_chunks


def load_query_chunks(library_id):
    config = load_runtime_config()
    index_backend = resolve_index_backend(config)
    if index_backend == "lancedb":
        rows = read_lancedb_chunks(library_id)
        if rows is not None:
            return rows, "lancedb"
    paths = library_paths(library_id)
    rows = read_json(paths["chunks"], {"chunks": []}).get("chunks", [])
    return rows, "builtin"


def import_into_library(library_id, sources):
    paths = library_paths(library_id)
    paths["root"].mkdir(parents=True, exist_ok=True)
    documents = read_json(paths["documents"], {"documents": []})
    chunks = read_json(paths["chunks"], {"chunks": []})

    documents_list = documents.get("documents", [])
    chunks_list = chunks.get("chunks", [])

    imported = 0
    skipped = 0
    failed = 0
    errors = []

    for source in sources:
        source_type = source.get("type") or "file"
        source_path = source.get("path") or ""
        title = source.get("title")
        entries = enumerate_sources(source_type, source_path)
        if not entries:
            failed += 1
            errors.append(f"未找到可导入内容：{source_path}")
            continue

        if source_type == "folder":
            current_entry_sources = {normalize_source_key(entry_path) for _, entry_path, _ in entries}
            stale_sources = [
                doc.get("source")
                for doc in documents_list
                if is_source_under_root(doc.get("source"), source_path) and normalize_source_key(doc.get("source")) not in current_entry_sources
            ]
            documents_list, chunks_list = remove_sources_from_indexes(documents_list, chunks_list, stale_sources)

        for entry_type, entry_path, entry_title in entries:
            try:
                text = read_source_text(entry_path, source_type if source_type == "web" else entry_type)
                text = normalize_text(text)
                if len(text) < 20:
                    failed += 1
                    errors.append(f"内容为空或过短：{entry_path}")
                    continue

                source_key = normalize_source_key(entry_path)
                text_digest = content_hash(text)
                effective_title = title or entry_title
                existing_document = next(
                    (doc for doc in documents_list if normalize_source_key(doc.get("source")) == source_key),
                    None
                )
                if existing_document and existing_document.get("contentHash") == text_digest:
                    skipped += 1
                    continue

                documents_list, chunks_list = remove_sources_from_indexes(documents_list, chunks_list, [entry_path])
                document_id = str(uuid.uuid4())

                doc_record = {
                    "id": document_id,
                    "source": entry_path,
                    "title": effective_title,
                    "sourceType": source_type if source_type == "web" else entry_type,
                    "importedAt": now_iso(),
                    "contentHash": text_digest
                }
                documents_list.append(doc_record)

                for chunk_index, chunk in enumerate(chunk_text(text, entry_path, source_type if source_type == "web" else entry_type), start=1):
                    tokens = tokenize(chunk)
                    if not tokens:
                        continue
                    chunks_list.append({
                        "id": str(uuid.uuid4()),
                        "documentId": document_id,
                        "source": entry_path,
                        "title": effective_title,
                        "snippet": chunk,
                        "citation": f"{entry_path}#chunk-{chunk_index}",
                        "tokens": tokens,
                        "tokenCount": len(tokens),
                        "importedAt": now_iso()
                    })
                imported += 1
            except Exception as error:
                failed += 1
                errors.append(f"{entry_path}: {error}")

    write_json(paths["documents"], {"documents": documents_list})
    write_json(paths["chunks"], {"chunks": chunks_list})
    write_lancedb_chunks(library_id, chunks_list)
    persist_library_summary(library_id, len(documents_list), len(chunks_list), "idle" if (imported > 0 or skipped > 0 or failed == 0) else "failed")
    return {
        "imported": imported,
        "skipped": skipped,
        "failed": failed,
        "errors": errors or None
    }


def query_library(library_id, query, top_k):
    chunks, _backend = load_query_chunks(library_id)
    variants = build_query_variants(query)
    query_tokens = []
    for variant in variants:
        query_tokens.extend(tokenize(variant))
    if not query_tokens:
        return {"hits": []}

    query_set = set(query_tokens)
    query_ngrams = set()
    for variant in variants:
        query_ngrams.update(build_char_ngrams(variant))

    total_chunks = max(len(chunks), 1)
    token_document_frequency = {}
    for chunk in chunks:
        token_set = set(chunk.get("tokens") or [])
        for token in query_set:
            if token in token_set:
                token_document_frequency[token] = token_document_frequency.get(token, 0) + 1

    token_idf = {
        token: 1.0 + math.log((1 + total_chunks) / (1 + token_document_frequency.get(token, 0)))
        for token in query_set
    }
    max_weight = max(sum(token_idf.values()), 1.0)
    query_profile = detect_query_profile(variants)

    scored = []
    for chunk in chunks:
        tokens = chunk.get("tokens") or []
        if not tokens:
            continue
        token_set = set(tokens)
        overlap = len(query_set & token_set)
        if overlap == 0:
            continue

        weighted_overlap = sum(token_idf[token] for token in query_set if token in token_set)
        lexical_score = weighted_overlap / max_weight
        coverage_score = overlap / max(len(query_set), 1)

        snippet = chunk.get("snippet", "")
        title = chunk.get("title") or ""
        source = chunk.get("source") or ""
        lowered_snippet = normalize_match_text(snippet)
        lowered_title = normalize_match_text(title)
        lowered_source = normalize_match_text(source)

        phrase_score = 0.0

        for variant in variants:
            lowered_variant = normalize_match_text(variant)
            if lowered_variant and lowered_variant in lowered_title:
                phrase_score = max(phrase_score, 1.0)
            elif lowered_variant and lowered_variant in lowered_source:
                phrase_score = max(phrase_score, 0.8)
            elif lowered_variant and lowered_variant in lowered_snippet:
                phrase_score = max(phrase_score, 0.65)

        chunk_ngrams = build_char_ngrams(f"{title}\n{snippet}")
        fuzzy_score = 0.0
        if query_ngrams and chunk_ngrams:
            fuzzy_score = len(query_ngrams & chunk_ngrams) / max(len(query_ngrams), 1)

        source_name_score = source_name_match_score(source, title, variants, query_set)

        score = (
            lexical_score * 0.46 +
            coverage_score * 0.18 +
            phrase_score * 0.17 +
            fuzzy_score * 0.09 +
            source_name_score * 0.1
        )

        source_suffix = Path(source).suffix.lower()
        if query_profile == "code" and source_suffix in CODE_EXTENSIONS:
            score += 0.08
        elif query_profile == "text" and (source_suffix in WEB_LIKE_EXTENSIONS or source_suffix in {".pdf", ".doc", ".docx", ".rtf"}):
            score += 0.04

        scored.append({
            "id": chunk.get("id"),
            "documentId": chunk.get("documentId"),
            "title": title,
            "snippet": snippet[:420],
            "score": round(score, 4),
            "citation": chunk.get("citation"),
            "source": source
        })

    scored.sort(key=lambda item: (item["score"], len(item["snippet"])), reverse=True)

    limit = max(1, min(int(top_k), 10))
    reranked = rerank_hits(scored, variants, query_set, query_profile, limit)
    return {"hits": reranked}


class Handler(BaseHTTPRequestHandler):
    server_version = "SkyAgentKnowledgeSidecar/0.6"

    def log_message(self, format, *args):
        with open(LOGS_DIR / "sidecar.log", "a", encoding="utf-8") as handle:
            handle.write(f"[{now_iso()}] " + (format % args) + "\n")

    def _json_response(self, status_code, payload):
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        if self.path == "/kb/status":
            config = load_runtime_config()
            parser_backend = resolve_parser_backend(config)
            index_backend = resolve_index_backend(config)
            self._json_response(200, {
                "status": "online",
                "message": "ok",
                "version": "0.6",
                "parserBackend": parser_backend,
                "indexBackend": index_backend,
                "capabilities": {
                    "doclingAvailable": docling_available(),
                    "lancedbAvailable": lancedb_available()
                }
            })
            return
        if self.path == "/kb/libraries":
            self._json_response(200, load_library_index())
            return
        self._json_response(404, {"error": "not_found"})

    def do_POST(self):
        try:
            if self.path == "/kb/import":
                payload = self._read_json_body()
                library_id = payload.get("libraryId", "")
                sources = payload.get("sources", [])
                if not library_id:
                    self._json_response(400, {"error": "missing_library_id"})
                    return
                persist_library_summary(library_id, 0, 0, "indexing")
                self._json_response(200, import_into_library(library_id, sources))
                return

            if self.path == "/kb/query":
                payload = self._read_json_body()
                library_id = payload.get("libraryId", "")
                query = payload.get("query", "")
                top_k = payload.get("topK", 5)
                if not library_id:
                    self._json_response(400, {"error": "missing_library_id"})
                    return
                self._json_response(200, query_library(library_id, query, top_k))
                return

            self._json_response(404, {"error": "not_found"})
        except Exception as error:
            traceback.print_exc()
            self._json_response(500, {"error": str(error)})


def main():
    ensure_dirs()
    server = ThreadingHTTPServer((DEFAULT_HOST, DEFAULT_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
"""#
}
