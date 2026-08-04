from fastapi import FastAPI, HTTPException, Depends, File, UploadFile, Header
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import List, Optional
import pandas as pd
import io
import json
from feast import FeatureStore
from contextlib import asynccontextmanager

# ---------- Fixed API key (demo) ----------
VALID_API_KEY = "f709-474b-b47c-cf71310e09f4"

store: FeatureStore = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global store
    store = FeatureStore(repo_path=".")
    yield

app = FastAPI(title="FEATSRV - Point-in-Time Feature Serving API", lifespan=lifespan)

# Mount static files for CLI script
app.mount("/static", StaticFiles(directory="static"), name="static")

# ---------- API Key Dependency ----------
def verify_api_key(x_api_key: str = Header(None)):
    if x_api_key != VALID_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return x_api_key

# ---------- Pydantic Models ----------
class EntityRow(BaseModel):
    claim_id: Optional[str] = None
    policy_id: Optional[str] = None
    event_timestamp: str

class OfflineRequest(BaseModel):
    entities: List[EntityRow]
    features: List[str]

# ---------- Serve CLI script at /cli ----------
@app.get("/cli")
async def cli_script():
    """Return the bash script for terminal interaction."""
    try:
        with open("static/cli.sh", "r") as f:
            content = f.read()
        return content
    except FileNotFoundError:
        raise HTTPException(404, "CLI script not found")

# ---------- Health (protected) ----------
@app.get("/health")
async def health(api_key: str = Depends(verify_api_key)):
    return {"status": "ok", "store": "redis + parquet"}

# ---------- Online endpoints ----------
@app.get("/online/policy/{policy_id}")
async def online_policy(policy_id: str, api_key: str = Depends(verify_api_key)):
    try:
        result = store.get_online_features(
            features=["policy_features:initial_premium", "policy_features:region",
                       "address_features:address", "policy_features:inception_date"],
            entity_rows=[{"policy_id": policy_id}]
        ).to_dict()
        features = {
            "initial_premium": result.get("initial_premium", [None])[0],
            "region": result.get("region", [None])[0],
            "address": result.get("address", [None])[0],
            "inception_date": str(result.get("inception_date", [None])[0]) if result.get("inception_date") else None,
        }
        return {"entity_type": "policy", "entity_id": policy_id, "features": features}
    except Exception as e:
        raise HTTPException(500, str(e))

@app.get("/online/claim/{claim_id}")
async def online_claim(claim_id: str, api_key: str = Depends(verify_api_key)):
    try:
        result = store.get_online_features(
            features=["claim_features:claim_amount", "claim_features:fraud_flag", "claim_features:policy_id"],
            entity_rows=[{"claim_id": claim_id}]
        ).to_dict()
        features = {
            "claim_amount": result.get("claim_amount", [None])[0],
            "fraud_flag": result.get("fraud_flag", [None])[0],
            "policy_id": result.get("policy_id", [None])[0],
        }
        return {"entity_type": "claim", "entity_id": claim_id, "features": features}
    except Exception as e:
        raise HTTPException(500, str(e))

# ---------- Offline batch ----------
@app.post("/offline")
async def offline_features(req: OfflineRequest, api_key: str = Depends(verify_api_key)):
    try:
        df = pd.DataFrame([e.dict() for e in req.entities])
        df["event_timestamp"] = pd.to_datetime(df["event_timestamp"])
        training_data = store.get_historical_features(
            entity_df=df,
            features=req.features
        ).to_df()
        return json.loads(training_data.to_json(orient="records", date_format="iso"))
    except Exception as e:
        raise HTTPException(500, str(e))

# ---------- PIT Training Set (file upload) ----------
@app.post("/pit-training")
async def pit_training(file: UploadFile = File(...), api_key: str = Depends(verify_api_key)):
    try:
        contents = await file.read()
        # Try to parse CSV or JSON
        if file.filename.endswith(".csv"):
            df = pd.read_csv(io.BytesIO(contents))
        elif file.filename.endswith(".json"):
            df = pd.read_json(io.BytesIO(contents))
        elif file.filename.endswith((".xls", ".xlsx")):
            df = pd.read_excel(io.BytesIO(contents))
        else:
            raise HTTPException(400, "Unsupported file format. Use CSV, JSON, or Excel.")
        
        # Expect columns: claim_id/policy_id, event_timestamp, fraud_flag (optional)
        df["event_timestamp"] = pd.to_datetime(df["event_timestamp"])
        
        # Default features
        features = [
            "policy_features:initial_premium",
            "address_features:address",
            "claim_features:claim_amount",
        ]
        training_data = store.get_historical_features(entity_df=df, features=features).to_df()
        return {
            "columns": list(training_data.columns),
            "rows": json.loads(training_data.to_json(orient="records", date_format="iso"))
        }
    except Exception as e:
        raise HTTPException(500, str(e))

# ---------- Leakage Audit (file upload) ----------
@app.post("/leakage-audit")
async def leakage_audit(file: UploadFile = File(...), api_key: str = Depends(verify_api_key)):
    try:
        contents = await file.read()
        if file.filename.endswith(".csv"):
            df = pd.read_csv(io.BytesIO(contents))
        elif file.filename.endswith(".json"):
            df = pd.read_json(io.BytesIO(contents))
        else:
            raise HTTPException(400, "Unsupported format. Use CSV or JSON.")
        
        # Simple audit: check for future timestamps relative to event_timestamp
        total = len(df)
        leakage_rows = 0
        if "event_timestamp" in df.columns and "feature_timestamp" in df.columns:
            df["event_timestamp"] = pd.to_datetime(df["event_timestamp"])
            df["feature_timestamp"] = pd.to_datetime(df["feature_timestamp"])
            leakage_rows = int((df["feature_timestamp"] > df["event_timestamp"]).sum())
        
        return {
            "total_rows": total,
            "leakage_detected": leakage_rows,
            "leakage_percent": round(100 * leakage_rows / total, 2) if total else 0,
            "status": "PASS" if leakage_rows == 0 else "FAIL"
        }
    except Exception as e:
        raise HTTPException(500, str(e))

# ---------- Feature Importance (mock) ----------
@app.get("/feature-importance")
async def feature_importance(api_key: str = Depends(verify_api_key)):
    # Return a mock list for demonstration
    return [
        {"feature": "initial_premium", "importance": 0.35},
        {"feature": "region", "importance": 0.25},
        {"feature": "address_stability", "importance": 0.20},
        {"feature": "claim_amount", "importance": 0.15},
        {"feature": "policy_age", "importance": 0.05},
    ]
