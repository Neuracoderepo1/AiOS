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


if __name__ == "__main__":
    unittest.main()
