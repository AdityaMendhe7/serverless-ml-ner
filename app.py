import json
from transformers import pipeline

# INIT phase: runs once per cold start, not per request
nlp = pipeline(
    "token-classification",
    model="/var/task/ner-model",
    aggregation_strategy="simple",
)


def _response(status, payload):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def handler(event, context):
    try:
        body = event.get("body") or "{}"
        if isinstance(body, str):
            body = json.loads(body)
        text = body.get("text", "")
    except (json.JSONDecodeError, AttributeError):
        return _response(400, {"error": "Body must be valid JSON"})

    if not isinstance(text, str) or not text.strip():
        return _response(400, {"error": "Field 'text' is required"})
    if len(text) > 2000:
        return _response(400, {"error": "Text too long (max 2000 characters)"})

    entities = [
        {
            "entity": e["entity_group"],
            "text": e["word"],
            "score": round(float(e["score"]), 4),
            "start": int(e["start"]),
            "end": int(e["end"]),
        }
        for e in nlp(text)
    ]
    return _response(200, {"entities": entities})
