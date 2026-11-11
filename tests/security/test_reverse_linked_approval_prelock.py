"""Static and mutation controls for reverse-linked approval pre-lock ordering."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261110100000_aios_batch_prelock_before_audit.sql"


def assert_reverse_link_contract(source: str) -> None:
    start = source.index("create or replace function private.aios_prelock_approvals_batch")
    end = source.index("$f$;", start)
    body = source[start:end]
    required = (
        "left join lateral",
        "where i0.id = ap.invocation_id",
        "where ap.invocation_id is null and i1.approval_id = ap.id",
        "order by t.mission_id nulls last, t.id nulls last, i.id nulls last, ap.id",
    )
    missing = [fragment for fragment in required if fragment not in body]
    if missing:
        raise AssertionError("approval pre-lock contract missing: " + ", ".join(missing))

    subtree_start = source.index("create or replace function private.aios_lock_mission_subtree")
    subtree_end = source.index("$f$;", subtree_start)
    subtree = source[subtree_start:subtree_end]
    if "a.id in (" not in subtree or "i.approval_id" not in subtree:
        raise AssertionError("mission subtree pre-lock omits reverse-linked approval rows")


class ReverseLinkedApprovalPrelockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = MIGRATION.read_text(encoding="utf-8")

    def test_effective_invocation_prefers_direct_link_then_reverse_link(self):
        assert_reverse_link_contract(self.source)

    def test_mission_subtree_locks_reverse_linked_approval_rows(self):
        subtree_start = self.source.index("create or replace function private.aios_lock_mission_subtree")
        subtree_end = self.source.index("$f$;", subtree_start)
        subtree = self.source[subtree_start:subtree_end]
        self.assertIn("a.id in (", subtree)
        self.assertIn("i.approval_id", subtree)

    def test_legacy_null_mission_sort_is_not_the_only_resolution_path(self):
        start = self.source.index("create or replace function private.aios_prelock_approvals_batch")
        end = self.source.index("$f$;", start)
        body = self.source[start:end]
        self.assertIn("left join lateral", body)
        self.assertIn("i1.approval_id = ap.id", body)

    def test_mutation_removing_reverse_link_fallback_is_detected(self):
        mutant = self.source.replace(
            "where ap.invocation_id is null and i1.approval_id = ap.id",
            "where false",
            1,
        )
        with self.assertRaisesRegex(AssertionError, "reverse link"):
            assert_reverse_link_contract(mutant)


if __name__ == "__main__":
    unittest.main()
