"""Offline coverage for the SUSDB authority/recovery state table."""

from pathlib import Path
import unittest

from jinja2 import Environment
import yaml


TASK_FILE = Path(__file__).parents[1] / "tasks" / "present_windows.yml"
CLASSIFIER_TASK = "MAIN | Classify The SUSDB Recovery Action"


def walk_tasks(tasks):
    """Yield tasks recursively through Ansible block/rescue/always lists."""
    for task in tasks:
        yield task
        for section in ("block", "rescue", "always"):
            yield from walk_tasks(task.get(section, []))


def classifier_template():
    tasks = yaml.safe_load(TASK_FILE.read_text(encoding="utf-8"))
    task = next(item for item in walk_tasks(tasks) if item.get("name") == CLASSIFIER_TASK)
    return task["ansible.builtin.set_fact"]["__susdb_recovery_action__"]


def normalize(location, source_count, target_count):
    """Mirror the two safe pre-classification cleanup rules."""
    if location == "source" and source_count == 2 and target_count > 0:
        target_count = 0
    elif location == "absent" and source_count == 2 and target_count == 1:
        target_count = 0
    return source_count, target_count


class SusdbStateTableTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = Environment(autoescape=False).from_string(classifier_template())

    def classify(self, location, source_count, target_count):
        source_count, target_count = normalize(location, source_count, target_count)
        return self.template.render(
            __susdb_location__=location,
            __susdb_source_count__=source_count,
            __susdb_target_count__=target_count,
        ).strip()

    def test_allowed_authority_states(self):
        expected = {
            ("source", 2, 0): "rebuild_from_source",
            ("source", 2, 1): "rebuild_from_source",
            ("source", 2, 2): "rebuild_from_source",
            ("target", 0, 2): "converged",
            ("target", 2, 2): "converged",
            ("absent", 2, 0): "copy_from_source",
            ("absent", 2, 1): "copy_from_source",
            ("absent", 0, 2): "attach_target",
        }
        for state, action in expected.items():
            with self.subTest(state=state):
                self.assertEqual(self.classify(*state), action)

    def test_ambiguous_or_incomplete_states_fail_closed(self):
        allowed = {
            ("source", 2, 0),
            ("source", 2, 1),
            ("source", 2, 2),
            ("target", 0, 2),
            ("target", 2, 2),
            ("absent", 2, 0),
            ("absent", 2, 1),
            ("absent", 0, 2),
        }
        for location in ("source", "target", "absent", "other"):
            for source_count in range(3):
                for target_count in range(3):
                    state = (location, source_count, target_count)
                    if state in allowed:
                        continue
                    with self.subTest(state=state):
                        self.assertEqual(self.classify(*state), "invalid")

        # This is the destructive regression: without an attachment, neither complete pair
        # is authoritative, so the target must never be chosen merely because it exists.
        self.assertEqual(self.classify("absent", 2, 2), "invalid")


if __name__ == "__main__":
    unittest.main()
