from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
from select_simulator import TARGETS, select


class SimulatorSelectionTests(unittest.TestCase):
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

    def inventory(self, family, *names):
        name, _ = TARGETS[family]
        return {
            "runtimes": [{"identifier": self.runtime, "isAvailable": True}],
            "devicetypes": [{"name": name, "identifier": "target-type"}],
            "devices": {self.runtime: [{"name": model, "udid": model, "isAvailable": True}
                                       for model in names]},
        }

    def test_reuses_exact_device(self):
        preferred = TARGETS["iPhone"][0]
        create = Mock()
        result = select("iPhone", self.inventory("iPhone", preferred, "iPhone 17e"), create)
        self.assertEqual(result, ((26, 5, 0), preferred, preferred))
        create.assert_not_called()

    def test_creates_target_tablet_on_available_runtime(self):
        create = Mock(return_value="new-device")
        preferred = TARGETS["iPad"][0]
        result = select("iPad", self.inventory("iPad", "iPad mini"), create)
        self.assertEqual(result, ((26, 5, 0), preferred, "new-device"))
        create.assert_called_once_with(preferred, "target-type", self.runtime)

    def test_fallback_favors_similar_screen(self):
        for family, small, large in [("iPhone", "iPhone 17e", "iPhone 17 Pro Max"),
                                     ("iPad", "iPad mini", "iPad Pro 13-inch (M5)")]:
            with self.subTest(family=family):
                result = select(family, self.inventory(family, small, large), Mock(return_value=None))
                self.assertEqual(result[1], large)
