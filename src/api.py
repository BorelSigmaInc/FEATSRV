from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List, Optional
import pandas as pd
from feast import FeatureStore
from contextlib import asynccontextmanager

store: FeatureStore = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global store
    store = FeatureStore(repo_path=".")
    yield

app = FastAPI(title="FEATSRV — Point‑in‑Time Feature Serving API", lifespan=lifespan)

# ---------- Pydantic models ----------
class EntityRow(BaseModel):
    claim_id: Optional[str] = None
    policy_id: Optional[str] = None
    event_timestamp: str

class OfflineRequest(BaseModel):
    entities: List[EntityRow]
    features: List[str]

class OnlineResponse(BaseModel):
    entity_type: str
    entity_id: str
    features: dict

# ---------- Online endpoint (Redis) ----------
@app.get("/online/{entity_type}/{entity_id}", response_model=OnlineResponse)
async def get_online_features(entity_type: str, entity_id: str):
    valid_entities = {"policy": "policy_id", "claim": "claim_id"}
    if entity_type not in valid_entities:
        raise HTTPException(400, f"Invalid entity type. Choose: {list(valid_entities.keys())}")
    
    # Use short field names that Feast returns
    if entity_type == "policy":
        feature_refs = [
            "policy_features:initial_premium",
            "policy_features:region",
            "address_features:address",
            "policy_features:inception_date",
        ]
        short_names = ["initial_premium", "region", "address", "inception_date"]
    else:  # claim
        feature_refs = [
            "claim_features:claim_amount",
            "claim_features:fraud_flag",
            "claim_features:policy_id",
        ]
        short_names = ["claim_amount", "fraud_flag", "policy_id"]
    
    try:
        result = store.get_online_features(
            features=feature_refs,
            entity_rows=[{valid_entities[entity_type]: entity_id}]
        ).to_dict()
        clean = {}
        for name in short_names:
            if name in result:
                clean[name] = result[name][0]
        return OnlineResponse(entity_type=entity_type, entity_id=entity_id, features=clean)
    except Exception as e:
        raise HTTPException(500, str(e))

# ---------- Offline endpoint (batch PIT) ----------
@app.post("/offline")
async def get_offline_features(req: OfflineRequest):
    try:
        df = pd.DataFrame([e.dict() for e in req.entities])
        df["event_timestamp"] = pd.to_datetime(df["event_timestamp"])
        
        training_data = store.get_historical_features(
            entity_df=df,
            features=req.features
        ).to_df()
        
        return training_data.to_dict(orient="records")
    except Exception as e:
        raise HTTPException(500, str(e))

@app.get("/health")
async def health():
    return {"status": "ok", "store": "redis + parquet"}
