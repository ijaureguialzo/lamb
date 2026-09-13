#!/usr/bin/env python3
"""apply_admin_fix.py -- make admin@owi.com a SYSTEM + ORG admin so the
Admin / Org-Admin menu appears in the LAMB creator navbar.

Root cause (verified in the LAMB source):
  Nav.svelte renders the admin links only when BOTH are true:
     LAMB_Creator_users.role            == 'admin'   (system /admin link)
     LAMB_organization_roles.role      == 'admin'    (org   /org-admin link)
  On a fresh volume LAMB's own bootstrap materializes the bootstrap admin via
  initialize_system_organization(), but leaves role='user' and never assigns the
  organization role. This script ensures the user exists and forces both roles
  to 'admin'. It is idempotent and runs INSIDE the lamb-lamb-1 container.
"""
import sys

sys.path.insert(0, "/app/backend")
from lamb.database_manager import LambDatabaseManager


def main():
    db = LambDatabaseManager()

     # 1. materialize the system org + bootstrap admin user if missing
    #    (a fresh volume leaves LAMB_Creator_users empty until this runs)
    try:
        db.run_migrations()
    except Exception as e:  # pragma: no cover
        print(f"[WARN] run_migrations: {e}")
    try:
        db.initialize_system_organization()
    except Exception as e:  # pragma: no cover
        print(f"[WARN] initialize_system_organization: {e}")

    user = db.get_creator_user_by_email("admin@owi.com")
    if not user:
        sys.stderr.write(
            "[FAIL] admin@owi.com still not materialized after bootstrap. "
            "Log in once at OpenWebUI (http://localhost:8080) then re-run "
            "make admin-fix.\n"
        )
        sys.exit(1)

    org = db.get_organization_by_slug("lamb")
    if not org:
        sys.stderr.write("[FAIL] system organization 'lamb' not found\n")
        sys.exit(1)

    user_id = user["id"]
    org_id = org["id"]

     # 2. LAMB_Creator_users.role = 'admin'  -> drives the /admin system link
    current = db.get_user_organization_role(user_id, org_id)
    if current != "admin":
        db.assign_organization_role(org_id, user_id, "admin")
    try:
        db.update_creator_user_role("admin@owi.com", "admin")
    except Exception as e:  # pragma: no cover
        print(f"[WARN] update_creator_user_role: {e}")

     # 3. verify
    user = db.get_creator_user_by_email("admin@owi.com")
    org_role = db.get_user_organization_role(user_id, org_id)
    print(
        f"[OK] admin@owi.com -> Creator.role={user.get('role')}, "
        f"OrgRole={org_role} "
        f"({'admin menu will appear' if user.get('role') == 'admin' and org_role == 'admin' else 'INCOMPLETE'})"
    )


if __name__ == "__main__":
    main()
