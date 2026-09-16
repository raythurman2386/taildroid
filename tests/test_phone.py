#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("phone", ROOT / "phone.py")
phone = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(phone)


ADB_LIST = """\
List of devices attached
emulator-5554          device product:sdk_gphone model:sdk_gphone_x86 device:generic_x86 transport_id:1
100.78.239.18:5555     device product:caiman model:Pixel_10 device:caiman transport_id:2
ABCDEF12               unauthorized usb:1-3 transport_id:3
* daemon not running. starting it now *
"""


class ParseAdbTests(unittest.TestCase):
    def test_parses_usb_tcp_and_unauthorized(self):
        devices = phone.parse_adb_devices(ADB_LIST)
        self.assertEqual(len(devices), 3)
        self.assertEqual(devices[0]["transport"], "usb")
        self.assertEqual(devices[1]["serial"], "100.78.239.18:5555")
        self.assertEqual(devices[1]["transport"], "tcp")
        self.assertEqual(devices[1]["name"], "Pixel 10")
        self.assertFalse(devices[2]["authorized"])
        self.assertEqual(devices[2]["state"], "unauthorized")

    def test_ignores_noise_before_header(self):
        devices = phone.parse_adb_devices("* daemon started successfully\nList of devices attached\n")
        self.assertEqual(devices, [])


class PreferredPeerTests(unittest.TestCase):
    def test_matches_hostname_dns_and_slug(self):
        self.assertTrue(phone.is_preferred("Pixel 10", "pixel-10.tail.ts.net", "pixel-10"))
        self.assertTrue(phone.is_preferred("pixel-10", "pixel-10.tail.ts.net", "Pixel-10"))
        self.assertTrue(phone.is_preferred("Pixel 10", "pixel-10.tail.ts.net", "pixel-10.tail.ts.net"))
        self.assertFalse(phone.is_preferred("Pixel 10", "pixel-10.tail.ts.net", "10"))
        self.assertFalse(phone.is_preferred("Pixel 10", "pixel-10.tail.ts.net", "pixel"))


class HostPortTests(unittest.TestCase):
    def test_last_line(self):
        self.assertEqual(phone.last_line("a\n failed to connect\n"), "failed to connect")
        self.assertEqual(phone.last_line(""), "")


class MaskTests(unittest.TestCase):
    def test_masks_ipv4_and_keeps_port(self):
        self.assertEqual(phone.mask_text("100.78.239.18:5555"), "100.*.*.*:5555")
        self.assertEqual(
            phone.mask_text("failed to connect to 192.168.1.4:37123"),
            "failed to connect to 192.*.*.*:37123",
        )

    def test_masks_tailnet_dns(self):
        self.assertEqual(
            phone.mask_text("pixel-10.tailc2d479.ts.net"),
            "pixel-10.*****.ts.net",
        )

    def test_leaves_usb_serials(self):
        self.assertEqual(phone.mask_text("ABCDEF12"), "ABCDEF12")


if __name__ == "__main__":
    unittest.main()
