#!/usr/bin/python3
"""Exercise the dock's D-Bus methods without starting its Wayland UI."""
import ast
from pathlib import Path
import unittest
from unittest.mock import Mock
from gi.repository import GLib


SOURCE = Path(__file__).resolve().parents[1] / "adaptation/shell/sfduo-dock"
tree = ast.parse(SOURCE.read_text())
methods = {"_on_dock_method", "_on_dock_property", "_follows_variant", "_follows_changed",
           "_relay_running", "_mode_for", "_shade_over", "_pane_targets"}
owner = next(node for node in tree.body if isinstance(node, ast.ClassDef)
             and any(isinstance(n, ast.FunctionDef) and n.name == "_on_dock_method"
                     for n in node.body))
selected = [node for node in owner.body
            if isinstance(node, ast.FunctionDef) and node.name in methods]
# The module's own constants come with them - the placing arithmetic is
# written in terms of EDGE_MARGIN and DOCK_HEIGHT, and a test that made its
# own numbers up would not be testing the dock.
constants = [node for node in tree.body
             if isinstance(node, ast.Assign)
             and all(isinstance(t, ast.Name) and t.id.isupper() for t in node.targets)
             and isinstance(node.value, ast.Constant)]
namespace = {"GLib": GLib, "debug": lambda *_: None}
exec(compile(ast.Module(body=constants, type_ignores=[]), str(SOURCE), "exec"), namespace)
exec(compile(ast.Module(body=selected, type_ignores=[]), str(SOURCE), "exec"), namespace)
Dock = type("Dock", (), {name: namespace[name] for name in methods})


class FollowsTest(unittest.TestCase):
    def setUp(self):
        self.dock = Dock()
        self.dock.DOCK_NAME = "org.sfduo.Dock"
        self.dock.DOCK_PATH = "/org/sfduo/Dock"
        self.dock.follow = {}
        self.dock.placed = {}
        self.dock.session_bus = Mock()
        self.dock._save_follows = Mock()
        self.reply = Mock()

    def follow(self, child, leader):
        self.dock._on_dock_method(None, None, None, None, "Follow",
                                 GLib.Variant("(ss)", (child, leader)), self.reply)

    def test_property_and_change_signal(self):
        self.follow("page", "settings")
        result = self.dock._on_dock_property(None, None, None, None, "Follows")
        self.assertEqual(result.get_type_string(), "a{ss}")
        self.assertEqual(result.unpack(), {"page": "settings"})
        signal = self.dock.session_bus.emit_signal.call_args.args
        self.assertEqual(signal[:4], (None, "/org/sfduo/Dock",
                         "org.freedesktop.DBus.Properties", "PropertiesChanged"))
        self.assertEqual(signal[4].unpack(), ("org.sfduo.Dock",
                         {"Follows": {"page": "settings"}}, []))
        self.reply.return_value.assert_called_once_with(None)

    def test_unchanged_relation_does_not_emit_again(self):
        self.follow("page", "settings")
        self.follow("page", "settings")
        self.dock.session_bus.emit_signal.assert_called_once()
        self.follow("page", "other")
        self.assertEqual(self.dock.session_bus.emit_signal.call_count, 2)

    def test_restored_mapping_is_available_without_new_follow_call(self):
        self.dock.follow = {"page": "settings"}
        self.assertEqual(self.dock._follows_variant().unpack(), self.dock.follow)
        self.dock.session_bus.emit_signal.assert_not_called()


class WhereTheDockStandsTest(unittest.TestCase):
    """_mode_for: which panel the dock is on, or whether it is out of sight."""

    def setUp(self):
        self.dock = Dock()
        self.dock.window_busy = set()
        self.dock.grid_side = "right"
        self.dock.osk_panel = None
        self.dock.launching = {}
        self.dock.shade = "none"

    def test_nothing_open_means_both_panels(self):
        self.assertEqual(self.dock._mode_for(False), "both")

    def test_a_window_sends_it_to_the_free_panel(self):
        self.dock.window_busy = {"left"}
        self.assertEqual(self.dock._mode_for(False), "right")

    def test_a_shade_takes_it_out_of_sight(self):
        self.dock.shade = "right"
        self.assertEqual(self.dock._mode_for(False), "hidden")
        self.dock.shade = "left"
        self.dock.window_busy = {"right"}
        self.assertEqual(self.dock._mode_for(False), "hidden")

    def test_it_comes_back_when_the_shade_folds(self):
        self.dock.shade = "none"
        self.dock.window_busy = {"right"}
        self.assertEqual(self.dock._mode_for(False), "left")


class Half:
    """A dock half, as _pane_targets reads one."""

    def __init__(self, width):
        self.width = width
        self.x = 0


class TheHalvesMeetTest(unittest.TestCase):
    """_pane_targets: on one panel the two halves are one bar, so the right
    one starts exactly where the left one ends - a gap there is a black slit
    down the middle of the dock."""

    def setUp(self):
        self.dock = Dock()
        self.dock.half = 675
        self.dock.gap = 42
        self.dock.panes = {"left": Half(194), "right": Half(194)}

    def test_joined_on_one_panel(self):
        for mode in ("left", "right"):
            targets = self.dock._pane_targets(mode)
            left_x, right_x = targets["left"][0], targets["right"][0]
            self.assertEqual(right_x - left_x, self.dock.panes["left"].width,
                             "the halves must touch in mode %s" % mode)

    def test_a_half_that_changed_width_is_still_joined(self):
        self.dock.panes["left"] = Half(140)          # a running app's button went
        targets = self.dock._pane_targets("right")
        self.assertEqual(targets["right"][0] - targets["left"][0], 140)

    def test_apart_on_two_panels(self):
        targets = self.dock._pane_targets("both")
        self.assertEqual(targets["left"][0], 10)     # EDGE_MARGIN from its own edge
        self.assertEqual(targets["right"][0], 675 * 2 + 42 - 194 - 10)


if __name__ == "__main__":
    unittest.main()
