from feast import Entity, FeatureView, Field, FileSource
from feast.types import Float64, Int64, String, UnixTimestamp
from datetime import timedelta

# ------------------- Entities -------------------
policy = Entity(
    name="policy",
    join_keys=["policy_id"],
    description="Insurance policy entity"
)

claim = Entity(
    name="claim",
    join_keys=["claim_id"],
    description="Insurance claim entity"
)

# ------------------- Data Sources -------------------
policy_source = FileSource(
    path="data/raw/policies.parquet",
    timestamp_field="inception_date"
)

address_source = FileSource(
    path="data/raw/address_history.parquet",
    timestamp_field="valid_from"
)

claim_source = FileSource(
    path="data/raw/claims.parquet",
    timestamp_field="report_date"
)

# ------------------- Feature Views -------------------
policy_features = FeatureView(
    name="policy_features",
    entities=[policy],
    ttl=timedelta(days=365 * 5),
    schema=[
        Field(name="initial_premium", dtype=Float64),
        Field(name="region", dtype=String),
        Field(name="inception_date", dtype=UnixTimestamp),
    ],
    source=policy_source,
    online=True,
    description="Policy-level features: premium, region"
)

address_features = FeatureView(
    name="address_features",
    entities=[policy],
    ttl=timedelta(days=365 * 5),
    schema=[
        Field(name="address", dtype=String),
    ],
    source=address_source,
    online=True,
    description="Current address of the policyholder (SCD Type 2)"
)

claim_features = FeatureView(
    name="claim_features",
    entities=[claim],
    ttl=timedelta(days=365 * 5),
    schema=[
        Field(name="policy_id", dtype=String),
        Field(name="claim_amount", dtype=Float64),
        Field(name="fraud_flag", dtype=Int64),
    ],
    source=claim_source,
    online=True,
    description="Claim-level features: amount, fraud flag"
)
