"""Static and mutation controls for the shared approval invocation resolver."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261111170000_aios_shared_approval_invocation_resolver.sql"


def assert_shared_resolver_contract(source: str) -> None:
    resolver_start = source.index("create or replace function private.aios_resolve_approval_invocation")
    resolver_end = source.index("$f$;", resolver_start)
    resolver = source[resolver_start:resolver_end]
    required = (
        "where i.approval_id = p_approval_id",
        "order by i.created_at desc, i.id desc",
        "limit 1",
    )
    missing = [fragment for fragment in required if fragment not in resolver]
    if missing:
        raise AssertionError("shared resolver tie-break contract missing: " + ", ".join(missing))

    chain_start = source.index("create or replace function private.aios_lock_approval_chain")
    chain_end = source.index("$f$;", chain_start)
    chain = source[chain_start:chain_end]
    if "private.aios_resolve_approval_invocation(p_approval_id)" not in chain:
        raise AssertionError("phase-two chain lock does not use shared resolver")

    batch_start = source.index("create or replace function private.aios_prelock_approvals_batch")
    batch_end = source.index("$f$;", batch_start)
    batch = source[batch_start:batch_end]
    if "private.aios_resolve_approval_invocation(ap.id)" not in batch:
        raise AssertionError("phase-one batch pre-lock does not use shared resolver")


class SharedApprovalResolverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = MIGRATION.read_text(encoding="utf-8")

    def test_both_lock_phases_use_one_resolver(self):
        assert_shared_resolver_contract(self.source)

    def test_tied_timestamp_uses_invocation_id_descending(self):
        assert_shared_resolver_contract(self.source)
        self.assertIn("order by i.created_at desc, i.id desc", self.source)

    def test_mutation_removing_id_tie_break_is_detected(self):
        mutant = self.source.replace(
            "order by i.created_at desc, i.id desc",
            "order by i.created_at desc",
            1,
        )
        with self.assertRaisesRegex(AssertionError, "tie-break"):
            assert_shared_resolver_contract(mutant)

    def test_mutation_diverging_phase_two_resolver_is_detected(self):
        mutant = self.source.replace(
            "private.aios_resolve_approval_invocation(p_approval_id)",
            "p_approval_id",
            1,
        )
        with self.assertRaisesRegex(AssertionError, "phase-two"):
            assert_shared_resolver_contract(mutant)


BINDING_MIGRATION = ROOT / "supabase/migrations/20261111220000_aios_approval_binding_and_audit_lock_order.sql"


def assert_final_approval_audit_contract(source: str) -> None:
    expiry = "select private.aios_resolve_approval_invocation(a.id) into v_inv;"
    if expiry not in source:
        raise AssertionError("phase-two expiry does not use the shared resolver")

    chain_start = source.index("create or replace function private.aios_lock_approval_chain")
    chain_end = source.index("$f$;", chain_start)
    chain = source[chain_start:chain_end]
    for fragment in (
        "for no key update",
        "for update",
        "v_current_inv is distinct from v_inv",
        "v_current_task is distinct from v_task",
        "v_current_approval_inv is distinct from v_approval_inv_snapshot",
        "v_current_inv_approval is distinct from v_inv_approval_snapshot",
        "v_current_approval_inv is not null",
        "v_current_inv_approval is distinct from p_approval_id",
        "v_current_task_org is distinct from v_task_org",
        "v_current_mission_org is distinct from v_mission_org",
        "approval chain organization mismatch",
    ):
        if fragment not in chain:
            raise AssertionError("post-lock binding revalidation missing: " + fragment)

    audit_locks = source[source.index("create or replace function private.aios_prelock_audit_organizations"):]
    if "order by x.organization_id\n" not in audit_locks or "pg_advisory_xact_lock" not in audit_locks:
        raise AssertionError("cross-organization audit locks are not acquired in global order")
    if "aios_prelock_audit_organizations" not in source:
        raise AssertionError("batch processors do not pre-acquire organization audit locks")

    prelock_start = source.index("create or replace function private.aios_prelock_approvals_batch")
    prelock_end = source.index("$f$;", prelock_start)
    prelock = source[prelock_start:prelock_end]
    if "private.aios_resolve_approval_invocation(ap.id)" not in prelock:
        raise AssertionError("phase-one pre-lock does not use the shared resolver")
    if "private.aios_lock_approval_chain" in prelock:
        raise AssertionError("phase-one pre-lock invokes phase-two tenant validation on invalid legacy bindings")
    if "for no key update" not in prelock or "for update" not in prelock:
        raise AssertionError("phase-one pre-lock does not preserve task/invocation/approval row lock order")
    if "set timezone = 'UTC'" not in audit_locks:
        raise AssertionError("audit append trigger does not pin UTC")
    if "expected_function_fp = private.aios_function_fingerprint('private.aios_audit_append()'::regprocedure)" not in source:
        raise AssertionError("guard registry fingerprint was not advanced for the intentional trigger-function change")
    if "trigger_name = 'trg_aios_audit_hash'" not in source:
        raise AssertionError("guard registry update is not scoped to the audit hash trigger")


class FinalApprovalAuditClosureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = BINDING_MIGRATION.read_text(encoding="utf-8")

    def test_expiry_uses_shared_resolver_and_revalidates_bindings(self):
        assert_final_approval_audit_contract(self.source)

    def test_cross_organization_audit_locks_are_sorted(self):
        assert_final_approval_audit_contract(self.source)
        self.assertIn("order by x.organization_id\n", self.source)

    def test_audit_writer_is_timezone_independent(self):
        assert_final_approval_audit_contract(self.source)
        self.assertIn("set timezone = 'UTC'", self.source)

    def test_mutation_removing_post_lock_binding_check_is_detected(self):
        mutant = self.source.replace("v_current_inv is distinct from v_inv", "false", 1)
        with self.assertRaisesRegex(AssertionError, "post-lock binding"):
            assert_final_approval_audit_contract(mutant)

    def test_mutation_removing_global_audit_lock_order_is_detected(self):
        mutant = self.source.replace("order by x.organization_id", "order by x.organization_id desc", 1)
        with self.assertRaisesRegex(AssertionError, "global order"):
            assert_final_approval_audit_contract(mutant)

    def test_mutation_removing_utc_pin_is_detected(self):
        mutant = self.source.replace("set timezone = 'UTC'", "set timezone = 'Asia/Tokyo'", 1)
        with self.assertRaisesRegex(AssertionError, "pin UTC"):
            assert_final_approval_audit_contract(mutant)

    def test_mutation_omitting_guard_registry_advance_is_detected(self):
        mutant = self.source.replace(
            "expected_function_fp = private.aios_function_fingerprint('private.aios_audit_append()'::regprocedure)",
            "expected_function_fp = 'stale'",
            1,
        )
        with self.assertRaisesRegex(AssertionError, "guard registry fingerprint"):
            assert_final_approval_audit_contract(mutant)


if __name__ == "__main__":
    unittest.main()
