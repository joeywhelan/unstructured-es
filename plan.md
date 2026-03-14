# Project Plan: Elasticsearch + Jina AI — Unstructured Technical Manual Search

## Project Overview

A single Jupyter notebook demonstrating enterprise-grade semantic search over real product repair manuals sourced from iFixit, parsed with Jina Reader, embedded with Jina Embeddings v5, and indexed into Elasticsearch 9.x. The notebook walks through four sequential scenarios: brand isolation, fault diagnosis, version-aware search, and cross-lingual retrieval — all in one end-to-end flow.

---

## Tech Stack

| Component | Tool / Model |
|---|---|
| Search & Storage | Elasticsearch 9.x |
| Python Client | `elasticsearch>=9.0.0` (must match major version) |
| Manual Parsing | Jina Reader API (`https://r.jina.ai/`) |
| Embeddings | Jina Embeddings v5 (`jina-embeddings-v5-text-small`) |
| Reranking | Jina Reranker v3 (`jina-reranker-v3`) |
| Manual Source | iFixit Public API |
| Notebook Runtime | Python 3.10+, Jupyter |
| Utilities | `httpx`, `python-dotenv`, `tqdm`, `pandas` |

---

## Model Reference

### Jina Embeddings v5
- **Model:** `jina-embeddings-v5-text-small`
  - 677M parameters, 1024-dim output, 32K token context
  - Best multilingual retrieval under 1B parameters (67.0 MMTEB, 71.7 MTEB English)
  - `task="retrieval.query"` for queries; `task="retrieval.passage"` for document chunks
  - Prepend `"Query:"` to query text and `"Document:"` to passage text
- **Alternative (lighter):** `jina-embeddings-v5-text-nano`
  - 239M parameters, **768-dim** output — update `EMBED_DIMENSIONS=768` and index mapping if switching

### Jina Reranker v3
- **Model:** `jina-reranker-v3`
  - 597M parameters, 131K combined token context
  - Listwise: processes up to 64 documents simultaneously in one forward pass
  - API: `POST https://api.jina.ai/v1/rerank`

### Jina Reader
- **Endpoint:** `https://r.jina.ai/{url}`
- Pass `Accept: application/json` for structured `{title, url, content}` response
- Pass `Authorization: Bearer $JINA_API_KEY` for 200 req/min (vs 20 req/min unauthenticated)
- Pass `X-Retain-Images: none` to strip base64 image data from Markdown output
- Handles JavaScript-rendered pages and PDF URLs natively

---

## Data Source: iFixit (1000+ Real Manuals)

iFixit provides a free, public REST API with over 31,000 repair guides across 15 device categories. Non-commercial access requires no authentication.

### Collecting 1000+ Guide URLs

```python
import httpx

BASE = "https://www.ifixit.com/api/2.0"
guide_metadata = []

for offset in range(0, 1200, 200):
    resp = httpx.get(f"{BASE}/guides", params={"limit": 200, "offset": offset})
    guide_metadata.extend(resp.json())
    # Fields per guide: guideid, title, category, url, locale, modified_date, revisionid
```

### Suggested Category Targets

| Category | Scenario Coverage |
|---|---|
| `Mac Laptop` | Multi-generation Apple products — version-aware |
| `Android Phone` | Multi-brand (Samsung, Google, OnePlus) — brand isolation |
| `Power Tool` | Multi-manufacturer — brand isolation |
| `Car and Truck` | Multi-brand, fault diagnosis language — fault search |
| `Game Console` | PS4 vs PS5, Xbox One vs Series X — version-aware |
| `de`, `fr`, `it` locale guides | Same procedures in multiple languages — multilingual |

---

## Repository Structure

```
project/
|-- terraform # directory of scripts to build elastic serverless
├── plan.md                  # This file
├── README.md
├── .env.example
├── requirements.txt
├── data/
│   ├── guide_urls.jsonl     # iFixit metadata: guideid, title, category, url, locale
│   └── chunks.jsonl         # Reader-parsed, chunked, metadata-enriched documents
└── demo.ipynb           # Single notebook — all setup + 4 scenarios
```

---

## Environment Variables (`.env`)

```
ELASTIC_URL=https://your-cluster.es.io:9243
ELASTIC_API_KEY=your_elastic_api_key
JINA_API_KEY=your_jina_api_key

EMBED_MODEL=jina-embeddings-v5-text-small
RERANK_MODEL=jina-reranker-v3
EMBED_DIMENSIONS=1024
INDEX_NAME=manuals

CHUNK_SIZE=400
CHUNK_OVERLAP=50
INGEST_BATCH_SIZE=32
```

---

## Elasticsearch Index Mapping

```python
INDEX_MAPPING = {
    "mappings": {
        "properties": {
            "doc_id":              {"type": "keyword"},
            "guide_id":            {"type": "integer"},
            "brand":               {"type": "keyword"},
            "category":            {"type": "keyword"},
            "product":             {"type": "keyword"},
            "language":            {"type": "keyword"},
            "generation":          {"type": "integer"},
            "serial_range_start":  {"type": "keyword"},
            "serial_range_end":    {"type": "keyword"},
            "section":             {"type": "text"},
            "text":                {"type": "text"},
            "source_url":          {"type": "keyword"},
            "embedding": {
                "type":       "dense_vector",
                "dims":       1024,           # 768 if using nano model
                "index":      True,
                "similarity": "cosine"
            }
        }
    }
}
```

---

## Notebook Structure (Single Notebook)

### Section 0 — Environment Setup

```python
from elasticsearch import Elasticsearch
import os

# ES 9.x client instantiation — use only supported constructor params
es = Elasticsearch(
    hosts=os.environ["ELASTIC_URL"],
    api_key=os.environ["ELASTIC_API_KEY"],
    request_timeout=60
)

assert es.ping(), "Elasticsearch connection failed"
print(es.info()["version"]["number"])  # Should show 9.x.x
```

- Create the `manuals` index using `es.indices.create(index=INDEX_NAME, body=INDEX_MAPPING)`
- If index already exists, skip or delete + recreate for a clean demo run

---

### Section 1 — Data Collection via iFixit API

- Paginate iFixit API to collect 1,000+ guide metadata records
- Parse `brand` from `category` field (e.g., "MacBook Unibody A1278" → brand: "Apple")
- Derive `generation` from title keywords ("Mid 2012", "Late 2015", "M1", "M2")
- Assign `serial_range_start` / `serial_range_end` per generation for Scenario 3
- Save to `data/guide_urls.jsonl`

---

### Section 2 — Manual Parsing via Jina Reader

- For each guide URL, call `https://r.jina.ai/{url}` to get clean Markdown
- Rate-limit with `asyncio.Semaphore(10)` — respect 200 req/min with API key
- Extract Markdown headings as `section` labels per chunk
- Chunk at `CHUNK_SIZE` tokens with `CHUNK_OVERLAP` overlap
- Save to `data/chunks.jsonl`

```python
async def fetch_with_reader(url: str, api_key: str) -> dict:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json",
        "X-Retain-Images": "none"
    }
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"https://r.jina.ai/{url}", headers=headers, timeout=30)
    return resp.json()  # {"title": ..., "url": ..., "content": "...(markdown)..."}
```

---

### Section 3 — Embedding + Indexing

```python
def embed_batch(texts: list[str], task: str, api_key: str) -> list[list[float]]:
    prefixed = [
        f"Query: {t}" if task == "retrieval.query" else f"Document: {t}"
        for t in texts
    ]
    resp = httpx.post(
        "https://api.jina.ai/v1/embeddings",
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": "jina-embeddings-v5-text-small",
            "task": task,
            "input": prefixed,
            "dimensions": 1024
        }
    )
    return [item["embedding"] for item in resp.json()["data"]]
```

Bulk index using `elasticsearch.helpers.bulk()` with `source_exclude_vectors` handled at search time, not index time.

---

### Scenario 1 — Brand Isolation

**Query:** `"filter replacement procedure"`

**ES 9.x pattern** — kNN is a parameter of `search`, not a standalone API:

```python
# CORRECT for ES 9.x
results = es.search(
    index=INDEX_NAME,
    knn={
        "field": "embedding",
        "query_vector": query_vector,
        "k": 5,
        "num_candidates": 50,
        "filter": {"term": {"brand": "Apple"}}
    },
    source_exclude_vectors=True   # ES 9.x: don't return embedding arrays in hits
)

# WRONG — removed in ES 9.x
# es.knn_search(...)
```

Demonstrate unfiltered vs. filtered side-by-side.

---

### Scenario 2 — Fault Diagnosis Semantic Search

**Query:** `"machine makes grinding noise after startup"`

```python
# Broad kNN retrieval
hits = es.search(
    index=INDEX_NAME,
    knn={
        "field": "embedding",
        "query_vector": query_vector,
        "k": 20,
        "num_candidates": 100
    },
    source_exclude_vectors=True
)["hits"]["hits"]

# Rerank with Jina Reranker v3
def rerank(query: str, docs: list[str], top_n: int, api_key: str) -> list[dict]:
    resp = httpx.post(
        "https://api.jina.ai/v1/rerank",
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": "jina-reranker-v3",
            "query": query,
            "documents": docs,
            "top_n": top_n,
            "return_documents": True
        }
    )
    return resp.json()["results"]
```

Contrast: BM25 (`match` query) vs. kNN vs. kNN + Reranker v3.

Optional bonus cell — RRF combining BM25 and kNN using ES 9.x's built-in `rrf` retriever:

```python
es.search(
    index=INDEX_NAME,
    retriever={
        "rrf": {
            "retrievers": [
                {"standard": {"query": {"match": {"text": query}}}},
                {"knn": {"field": "embedding", "query_vector": query_vector, "k": 20, "num_candidates": 100}}
            ]
        }
    },
    source_exclude_vectors=True
)
```

---

### Scenario 3 — Version-Aware / Serial-Scoped Search

**Query:** `"battery replacement steps"` + technician serial number

```python
es.search(
    index=INDEX_NAME,
    knn={
        "field": "embedding",
        "query_vector": query_vector,
        "k": 5,
        "num_candidates": 50,
        "filter": {
            "bool": {
                "must": [
                    {"range": {"serial_range_start": {"lte": technician_serial}}},
                    {"range": {"serial_range_end":   {"gte": technician_serial}}}
                ]
            }
        }
    },
    source_exclude_vectors=True
)
```

---

### Scenario 4 — Cross-Lingual Retrieval

**Query (French):** `"procédure de remplacement de la batterie"`

```python
# No translation needed — jina-embeddings-v5-text-small maps 119+ languages to shared space
french_vector = embed_batch([query], task="retrieval.query", api_key=JINA_API_KEY)[0]

results = es.search(
    index=INDEX_NAME,
    knn={
        "field": "embedding",
        "query_vector": french_vector,
        "k": 20,
        "num_candidates": 100
    },
    # Faceted language breakdown
    aggs={"by_language": {"terms": {"field": "language"}}},
    source_exclude_vectors=True
)
```

Then apply Jina Reranker v3 to final candidates. Contrast with BM25 `match` query on the same French text.

---

## Shared Utility Functions

```python
# All defined in an early notebook cell and reused across scenarios

def reader_fetch(url, api_key)              # Jina Reader: URL → {title, content} Markdown dict
def chunk_markdown(text, size, overlap)     # Token-aware chunking, preserves headings as section labels
def embed_batch(texts, task, api_key)       # Jina v5: texts → 1024-dim vectors
def es_knn(es, vector, k, filters=None)     # ES 9.x search() wrapper with knn param
def rerank(query, docs, top_n, api_key)     # Jina Reranker v3
def display_hits(hits, fields)              # Pandas DataFrame display of search hits
```

---

## Requirements

```
# requirements.txt
elasticsearch>=9.0.0,<10.0.0   # Must match ES server major version
httpx>=0.27.0
python-dotenv>=1.0.0
tqdm>=4.66.0
pandas>=2.0.0
tiktoken>=0.7.0                 # For token-aware chunking
jupyter>=1.0.0
ipywidgets>=8.0.0
```

---

## Implementation Order for Claude Code

1. `requirements.txt`
2. `.env.example`
3. **Section 0:** ES 9.x client setup (correct constructor params) + index creation
4. **Section 1:** iFixit API pagination → `guide_urls.jsonl`
5. Shared utilities cell (reader, chunker, embedder, reranker, display helpers)
6. **Section 2:** Async Jina Reader loop → `chunks.jsonl`
7. **Section 3:** Embed (Jina v5, `retrieval.passage`) + ES bulk index
8. **Scenario 1:** Brand isolation — unfiltered vs. filtered kNN (ES 9.x `search` API)
9. **Scenario 2:** Fault diagnosis — kNN + BM25 contrast + Reranker v3 + optional RRF
10. **Scenario 3:** Serial-scoped search — with/without range filter contrast
11. **Scenario 4:** Cross-lingual — kNN + BM25 contrast + language facet aggregation + Reranker v3

---

## Critical Notes for Claude Code

**Elasticsearch 9.x API:**
- Use `es.search(index=..., knn={...}, source_exclude_vectors=True)` — never `es.knn_search()`
- Always include `source_exclude_vectors=True` on any search that isn't explicitly inspecting vectors
- Client constructor accepts only: `hosts`, `api_key`, `basic_auth`, `ca_certs`, `request_timeout`, `verify_certs`
- Deprecated params like `timeout`, `maxsize`, `randomize_hosts` will raise errors at instantiation

**Jina Embeddings v5:**
- `task="retrieval.query"` for queries, `task="retrieval.passage"` for document chunks — wrong task silently degrades quality
- Physically prepend `"Query:"` / `"Document:"` strings to input texts before the API call
- `small` model → 1024 dims; `nano` model → 768 dims; must match ES index mapping `dims` field exactly

**Jina Reranker v3:**
- Listwise model — pass all candidates at once, not one at a time
- Set `return_documents: true` to receive text back for display
- 131K combined token budget; 20 repair manual chunks is never a constraint

**Jina Reader:**
- Always pass `X-Retain-Images: none` — skips base64 blobs that inflate chunk size dramatically
- Use `asyncio.Semaphore(10)` for bulk ingestion to stay within 200 req/min rate limit

**iFixit:**
- Non-commercial API access is free — note this in the notebook introduction
- `locale` field maps directly to `language`
- Parse `brand` from `category` with string heuristics; generation from title year/chip keywords

---

## Success Criteria

| Scenario | Pass Condition |
|---|---|
| Brand Isolation | Zero non-target brand results in filtered search; unfiltered shows bleed as contrast |
| Fault Diagnosis | Reranker v3 promotes semantically correct fault section into top-3; BM25 misses it |
| Version-Aware | Serial-scoped query returns only correct generation; without filter shows cross-gen bleed |
| Cross-Lingual | French query retrieves EN/DE/IT results with cosine similarity > 0.75; BM25 returns only FR |