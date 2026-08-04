Service 5: Data Leakage Audit
------------------------------
Upload a CSV with columns:
  entity_id, event_timestamp, feature_timestamp, feature_value
The API checks for future feature_timestamps relative to event_timestamp.

Input:  sample_input.csv (contains a clean and a leaky row)
Output: sample_output.json (audit report)
