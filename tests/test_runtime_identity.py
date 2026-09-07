import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "assets" / "package-template"


class RuntimeIdentityTests(unittest.TestCase):
    def test_defaults_and_runtime_identity_contract(self):
        defaults = json.loads((TEMPLATE / "configs" / "paper-reading-pool-defaults.json").read_text(encoding="utf-8"))
        self.assertEqual(defaults["workerCount"], 1)
        self.assertEqual(defaults["maxRunningPerCollection"], 1)
        self.assertEqual(defaults["logRetentionDays"], 14)
        common = (TEMPLATE / "scripts" / "pool-runtime-common.ps1").read_text(encoding="utf-8")
        start = (TEMPLATE / "scripts" / "start-paper-reading-pool.ps1").read_text(encoding="utf-8")
        install = (TEMPLATE / "scripts" / "install-pool-workers.ps1").read_text(encoding="utf-8")
        self.assertIn("stateRoot", common)
        self.assertIn("current-run.json", common)
        self.assertIn("processStartTimeUtc", common)
        self.assertIn("Get-PoolTaskName", install)
        self.assertIn("-RunId", start)


if __name__ == "__main__":
    unittest.main()
