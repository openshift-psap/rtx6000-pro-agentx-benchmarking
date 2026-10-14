import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from validate_aiperf import validate


class ValidateAiperfTests(unittest.TestCase):
    def test_accepts_complete_zero_error_agentx_export(self):
        export = {
            "is_complete": True,
            "was_cancelled": False,
            "metadata": {"submission_valid": True, "scenario": "inferencex-agentx-mvp"},
            "request_count": {"avg": 10},
            "completed_request_count": {"avg": 10},
            "error_request_count": {"avg": 0},
            "request_error_rate": {"avg": 0},
        }
        failures, counts = validate(export)
        self.assertEqual(failures, [])
        self.assertEqual(counts["requests"], 10)

    def test_rejects_invalid_submission_and_errors(self):
        export = {
            "is_complete": True,
            "was_cancelled": False,
            "metadata": {"submission_valid": False, "scenario": "inferencex-agentx-mvp"},
            "request_count": 10,
            "completed_request_count": 9,
            "error_request_count": 1,
            "request_error_rate": 0.1,
        }
        failures, _ = validate(export)
        self.assertIn("submission_valid", failures)
        self.assertIn("completed_matches_requests", failures)
        self.assertIn("zero_errors", failures)

    def test_rejects_non_object_export(self):
        failures, _ = validate([])
        self.assertEqual(failures, ["export_is_object"])


if __name__ == "__main__":
    unittest.main()
