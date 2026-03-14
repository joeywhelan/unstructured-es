# CLAUDE.md — Elasticsearch + Jina AI Manual Search

## Project Purpose

Single Jupyter notebook (`demo.ipynb`) demonstrating enterprise semantic search over iFixit repair manuals. Parsed with Jina Reader, embedded with Jina Embeddings v5, indexed into Elasticsearch 9.x. Four scenarios: brand isolation, fault diagnosis, version-aware, cross-lingual.

## Key Files

| Path | Purpose |
|---|---|
| `demo.ipynb` | Main notebook — all setup + 4 scenarios |
| `plan.md` | Full project spec and implementation notes |
| `requirements.txt` | Python deps |
| `.env.example` | Env var template |
| `.env` | Generated at runtime via Terraform outputs (gitignored) |
| `data/guide_urls.jsonl` | iFixit metadata cache (generated) |
| `data/chunks.jsonl` | Parsed + chunked manual text (generated) |
| `terraform/` | Elastic Serverless provisioning scripts |

## Elasticsearch 9.x Rules

- **Never** use `es.knn_search()` — removed in ES 9.x. Always use `es.search(index=..., knn={...})`
- **Always** pass `source_exclude_vectors=True` on any search not inspecting raw vectors
- Valid constructor params only: `cloud_id`, `hosts`, `api_key`, `basic_auth`, `ca_certs`, `request_timeout`, `verify_certs`
- Deprecated params (`timeout`, `maxsize`, `randomize_hosts`) raise errors at instantiation
- RRF uses `retriever={"rrf": {"retrievers": [...]}}` — ES 9.x built-in, no plugin needed

## Jina API Conventions

### Embeddings v5 (`jina-embeddings-v5-text-small`)
- `task="retrieval.query"` for search queries; `task="retrieval.passage"` for document chunks
- Physically prepend `"Query: "` to query text and `"Document: "` to passage text before API call
- `small` model → **1024 dims**; `nano` model → **768 dims** — must match `EMBED_DIMENSIONS` env var AND index mapping `dims` field exactly
- Wrong task or missing prefix silently degrades retrieval quality

### Reranker v3 (`jina-reranker-v3`)
- Listwise — pass all candidates at once in a single call, not one at a time
- Always set `return_documents: true` to get text back for display
- 131K combined token budget; 20 repair manual chunks is never a constraint

### Reader (`https://r.jina.ai/{url}`)
- Always pass `X-Retain-Images: none` — prevents base64 blobs from inflating chunk size
- Pass `Accept: application/json` for structured `{title, url, content}` response
- Use `asyncio.Semaphore(10)` for bulk fetching — respects 200 req/min with API key

## Environment Variables

```
ELASTIC_CLOUD_ID       # from Terraform output
ELASTIC_USERNAME       # from Terraform output
ELASTIC_PASSWORD       # from Terraform output
JINA_API_KEY

EMBED_MODEL=jina-embeddings-v5-text-small
RERANK_MODEL=jina-reranker-v3
EMBED_DIMENSIONS=1024   # change to 768 if switching to nano model
INDEX_NAME=manuals
CHUNK_SIZE=400
CHUNK_OVERLAP=50
INGEST_BATCH_SIZE=32
```

## Index Schema

`content` is typed as `semantic_text` with `inference_id="jina-embeddings-v5"` — ES handles chunking and embedding internally.
One document per guide (not per chunk). No `dense_vector`, no `section`, no `text` field.
`content_text` (type `text`) mirrors `content` and serves as the BM25 companion — all `match` queries target `content_text`, not `content` (which is `semantic_text` and silently rewrites `match` into a semantic query).
Metadata fields: `doc_id`, `guide_id`, `brand`, `category`, `product`, `language`, `generation` (int), `serial_range_start`, `serial_range_end`, `source_url`.

Passage text is returned in `hit._source.content.inference.chunks[0].text`. Exclude raw embeddings with `source_excludes=["content.inference.chunks.embeddings"]`.

## Scenario Quick Reference

| # | Query | Key ES feature |
|---|---|---|
| 1 | "filter replacement procedure" | `semantic` + `bool.filter` → `term: brand` |
| 2 | "machine makes grinding noise after startup" | `semantic` + Reranker v3 vs BM25; RRF bonus |
| 3 | "battery replacement steps" + serial | `semantic` + `bool.filter` → `range` on serial fields |
| 4 | "procédure de remplacement de la batterie" (FR) | Cross-lingual `semantic` + language `aggs` |

## Data Caching Pattern

Both `data/guide_urls.jsonl` and `data/chunks.jsonl` are checked before making API calls. Delete them to force a fresh fetch/parse on the next notebook run.
