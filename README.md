# FEATSRV - Point-in-Time Correct Feature Serving for Insurance

A leakage-free feature store and REST API for actuarial data science.
Built with **Feast**, **Redis**, **PySpark**, and **FastAPI**.

**DOI:** [10.5281/zenodo.21798383](https://doi.org/10.5281/zenodo.21798383)  
**Report:** [`docs/PIT_Feature_Store.tex`](docs/PIT_Feature_Store.tex)

## Authors

| Role | Name | Affiliation / focus |
|------|------|---------------------|
| Main author | Raja Ram M | Kryptur OU / Krypur Quantum R&D |
| Contributor | Muskan S | Data T Research Org - Project Infrastructure |
| Contributor | Vipul Jain | AE Quantum Research Division (DCN) |
| Contributor | Kalinga Swain | AE Quantum Research Division (DCN) |

**Organisations:** Zius Quantum R&D Center (Quantum & AI) · Data T Research Org · AE Quantum Research Division (Digital & Cloud Networks) · Kryptur OU  
**Data Manager:** Borel Sigma Data Center

## Quick Start

### 1. Clone and set up environment
```bash
git clone https://github.com/BorelSigmaInc/FEATSRV
cd FEATSRV
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

### 2. Generate data, apply Feast, start stack
```bash
python scripts/generate_synthetic_data.py
feast apply
feast materialize 2024-01-01T00:00:00 $(date -u +"%Y-%m-%dT%H:%M:%S")
docker compose up -d   # requires Redis on 6379
```

### 3. CLI and dashboard
```bash
curl -s https://featsrv.q-dit.com/static/cli.sh -o /tmp/featsrv.sh
FEATSRV_API_KEY=... bash /tmp/featsrv.sh
# Dashboard: static/dashboard.html (or hosted URL)
```

Demo inputs for all seven services live under `Nimbus/`.
