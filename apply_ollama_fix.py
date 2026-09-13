#!/usr/bin/env python3
"""apply_ollama_fix.py -- Point the LAMB 'lamb' org config at the LOCAL Ollama
instance so 'http://localhost:9099/org-admin?...&view=settings' settings save
against the right API and persist.

Sets, inside LAMB_organizations.config -> setups.default.providers:
   openai.base_url    = http://host.docker.internal:11434/v1
   ollama.base_url    = http://host.docker.internal:11434
   (OpenAI-API-compatible endpoint that Ollama exposes)

Idempotent -- safe to run repeatedly. Runs INSIDE the lamb-lamb-1 container.
"""
import json
import sqlite3
import sys


def main():
    conn = sqlite3.connect("/data/lamb/lamb_v4.db")
    try:
        cur = conn.cursor()

        # 1. locate the 'lamb' org
        cur.execute("SELECT id FROM LAMB_organizations WHERE slug='lamb' LIMIT 1")
        org_row = cur.fetchone()
        if not org_row:
            cur.execute("SELECT id FROM LAMB_organizations LIMIT 1")
            org_row = cur.fetchone()
        if not org_row:
            print("[SKIP] No organization found.")
            return
        org_id = int(org_row[0])

        cur.execute("SELECT config FROM LAMB_organizations WHERE id=?", (org_id,))
        row = cur.fetchone()
        if not row or not row[0]:
            print("[SKIP] No config JSON yet; nothing to patch.")
            return

        conf = json.loads(row[0])
        ollama = "http://host.docker.internal:11434"

        # 2. ensure nested structure exists
        conf.setdefault("setups", {})
        default = conf["setups"].setdefault("default", {})
        providers = default.get("providers")
        if not isinstance(providers, dict):
            providers = {}

         # 3. point openai-compatible + ollama providers at local ollama
        openai = providers.setdefault("openai", {})
        openai["base_url"] = f"{ollama}/v1"
        if not openai.get("models"):
            openai["models"] = [
                "qwen3.6:35b-mlx",
                "qwen3.8:27b-mlx",
                "qwen3.6:27b-mlx",
                "gemma4:31b-mlx",
            ]
        if not openai.get("default_model"):
            openai["default_model"] = openai["models"][0]

        ollama_p = providers.setdefault("ollama", {})
        ollama_p["base_url"] = ollama
        if not ollama_p.get("models"):
            ollama_p["models"] = [
                "qwen3.6:35b-mlx",
                "qwen3.8:27b-mlx",
                "nomic-embed-text",
            ]

        default["providers"] = dict(providers)
        cur.execute("UPDATE LAMB_organizations SET config=? WHERE id=?",
                     (json.dumps(conf), org_id))
        conn.commit()

        print("[OK] Ollama providers patched in DB "
              f"(openai.base_url={openai['base_url']}, "
              f"ollama.base_url={ollama_p['base_url']})")
    except Exception as e:
        print(f"[ERROR] {e}")
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
