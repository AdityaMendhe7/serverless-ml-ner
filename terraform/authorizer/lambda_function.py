import hmac
import os


def lambda_handler(event, context):
    supplied = (event.get("headers") or {}).get("x-api-key", "")
    expected = os.environ.get("API_SECRET", "")
    ok = bool(expected) and hmac.compare_digest(
        supplied.encode(), expected.encode()
    )
    return {"isAuthorized": ok}
