"""
Bridge AI Analysis Endpoint

Flask server that provides AI-powered analysis for bridge CRE workflows.
Two endpoints:
  POST /api/cre/analyze-bridge       - Single vault state analysis (bridge-ai-advisor workflow)
  POST /api/cre/analyze-bridge-composite - Cross-workflow composite analysis

Uses Claude Haiku for cost-efficient structured analysis (~$0.001-0.003/call).
"""

import json
import os
import hashlib
from flask import Flask, request, jsonify

app = Flask(__name__)

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
CRE_SECRET = os.environ.get("CRE_SECRET", "")

if not CRE_SECRET:
    app.logger.warning("CRE_SECRET not set: all requests will be accepted without auth")


def verify_cre_secret(req):
    """Verify X-CRE-Secret header if CRE_SECRET is set."""
    if not CRE_SECRET:
        return True
    return req.headers.get("X-CRE-Secret") == CRE_SECRET


def analyze_vault_state(vault_state: dict) -> dict:
    """
    Analyze vault state and produce policy recommendations.
    Uses Claude Haiku for structured risk assessment.
    """
    if not ANTHROPIC_API_KEY:
        return heuristic_analysis(vault_state)

    try:
        import anthropic
        client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

        prompt = f"""Analyze this ERC-4626 bridge vault state and provide policy recommendations.

Vault State:
- Utilization: {vault_state.get('utilizationBps', 0)} bps (max allowed: {vault_state.get('maxUtilBps', 6000)} bps)
- Queue depth: {vault_state.get('queueDepth', 0)} pending redemptions
- Bad debt reserve ratio: {vault_state.get('reserveRatio', 0):.4f} ({vault_state.get('reserveRatio', 0) * 100:.2f}%)
- Share price: {vault_state.get('sharePrice', 1):.6f}
- Free liquidity: {vault_state.get('freeLiquidity', '0')}
- Reserved: {vault_state.get('reserved', '0')}
- In-flight: {vault_state.get('inFlight', '0')}
- Total assets: {vault_state.get('totalAssets', '0')}
- LINK/USD: ${vault_state.get('linkUsd', 0):.2f}
- Current policy: maxUtil={vault_state.get('maxUtilBps', 6000)}bps, reserveCut={vault_state.get('reserveCutBps', 1000)}bps, hotReserve={vault_state.get('hotReserveBps', 2000)}bps

Respond with ONLY valid JSON (no markdown, no explanation outside JSON):
{{
  "risk": "ok|warning|critical",
  "recommendation": "one-sentence summary",
  "suggestedActions": ["action1", "action2"],
  "policyAdjustments": {{
    "maxUtilizationBps": null_or_number,
    "badDebtReserveCutBps": null_or_number,
    "targetHotReserveBps": null_or_number
  }},
  "confidence": 0.0_to_1.0,
  "reasoning": "brief reasoning"
}}"""

        response = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=500,
            messages=[{"role": "user", "content": prompt}],
        )

        text = response.content[0].text.strip()
        # Strip markdown fences if present
        if text.startswith("```"):
            text = text.split("\n", 1)[1]
            if text.endswith("```"):
                text = text[:-3]
        return json.loads(text)

    except Exception as e:
        app.logger.warning(f"AI analysis failed, using heuristic: {e}")
        return heuristic_analysis(vault_state)


def heuristic_analysis(vault_state: dict) -> dict:
    """Fallback heuristic when AI is unavailable."""
    util = vault_state.get("utilizationBps", 0)
    queue = vault_state.get("queueDepth", 0)
    reserve = vault_state.get("reserveRatio", 0)

    risk = "ok"
    actions = []
    adjustments = {}

    if util >= 9000:
        risk = "critical"
        actions.append("Consider reducing maxUtilizationBps to prevent liquidity crunch")
        adjustments["maxUtilizationBps"] = max(util - 1000, 5000)
    elif util >= 7000:
        risk = "warning"
        actions.append("Monitor utilization closely, approaching cap")

    if reserve < 0.02 and float(vault_state.get("totalAssets", "0")) > 0:
        risk = "critical" if risk != "critical" else risk
        actions.append("Increase badDebtReserveCutBps to rebuild reserve buffer")
        adjustments["badDebtReserveCutBps"] = 1500

    if queue >= 10:
        risk = "critical"
        actions.append("Process redemption queue urgently")
    elif queue >= 3:
        if risk == "ok":
            risk = "warning"
        actions.append("Queue building up, consider processing")

    return {
        "risk": risk,
        "recommendation": f"Vault at {util}bps utilization with {queue} queued redemptions",
        "suggestedActions": actions or ["No action needed"],
        "policyAdjustments": adjustments,
        "confidence": 0.6,
        "reasoning": "Heuristic analysis (AI unavailable)",
    }


def analyze_composite(data: dict) -> dict:
    """Composite cross-workflow analysis."""
    if not ANTHROPIC_API_KEY:
        return {
            "risk": data.get("compositeRisk", "ok"),
            "confidence": 0.5,
            "recommendation": "Heuristic composite (AI unavailable)",
            "escalations": [],
        }

    try:
        import anthropic
        client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

        prompt = f"""Analyze this cross-workflow bridge intelligence and identify ecosystem-level risks.

Composite Data:
- Vault utilization: {data.get('vaultUtilBps', 0)} bps
- Queue depth: {data.get('queueDepth', 0)}
- Coverage ratio: {data.get('coverageRatio', 1):.2%}
- Reserve ratio: {data.get('reserveRatio', 0):.4f}
- Share price: {data.get('sharePrice', 1):.6f}
- LINK/USD: ${data.get('linkUsd', 0):.2f}
- TVL USD: ${data.get('tvlUsd', 0):,.2f}
- AI advisor risk: {data.get('aiRisk', 'unknown')}
- AI confidence: {data.get('aiConfidence', 0):.2f}
- Signals: {json.dumps(data.get('signals', []))}

Respond with ONLY valid JSON:
{{
  "risk": "ok|warning|critical",
  "confidence": 0.0_to_1.0,
  "recommendation": "one-sentence ecosystem assessment",
  "escalations": ["escalation1_if_any"]
}}"""

        response = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=300,
            messages=[{"role": "user", "content": prompt}],
        )

        text = response.content[0].text.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1]
            if text.endswith("```"):
                text = text[:-3]
        return json.loads(text)

    except Exception as e:
        app.logger.warning(f"Composite AI failed: {e}")
        return {
            "risk": data.get("compositeRisk", "ok"),
            "confidence": 0.5,
            "recommendation": f"Heuristic: {e}",
            "escalations": [],
        }


# ─── Routes ───


@app.route("/api/cre/analyze-bridge", methods=["POST"])
def analyze_bridge():
    if not verify_cre_secret(request):
        return jsonify({"error": "unauthorized"}), 401

    try:
        body = request.get_json(force=True)
    except Exception:
        return jsonify({"error": "invalid JSON body"}), 400
    vault_state = body.get("vaultState", {})

    result = analyze_vault_state(vault_state)

    # Deterministic response for CRE consensus: hash the input to seed consistent output
    input_hash = hashlib.sha256(json.dumps(vault_state, sort_keys=True).encode()).hexdigest()[:8]
    result["_inputHash"] = input_hash

    return jsonify(result)


@app.route("/api/cre/analyze-bridge-composite", methods=["POST"])
def analyze_bridge_composite():
    if not verify_cre_secret(request):
        return jsonify({"error": "unauthorized"}), 401

    try:
        body = request.get_json(force=True)
    except Exception:
        return jsonify({"error": "invalid JSON body"}), 400
    data = body.get("data", {})
    result = analyze_composite(data)
    return jsonify(result)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "bridge-ai-analyzer"})


@app.errorhandler(Exception)
def handle_exception(e):
    app.logger.error(f"Unhandled exception: {e}")
    return jsonify({"error": "internal server error"}), 500


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5050"))
    app.run(host="0.0.0.0", port=port, debug=False)
