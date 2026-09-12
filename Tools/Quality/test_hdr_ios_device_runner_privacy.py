#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(os.environ.get("IMAGECRAFT_PRIVACY_TEST_ROOT", pathlib.Path(__file__).resolve().parents[2])).resolve()
RUNNER = pathlib.Path(os.environ.get("IMAGECRAFT_PRIVACY_TEST_RUNNER", ROOT / "scripts" / "verify-hdr-ios-device.sh")).resolve()

IDENTIFIER = "PRIVACY-SENTINEL-IDENTIFIER-92e1"
DEVICE_NAME = "PRIVACY-SENTINEL-NAME-92e1"
UDID = "PRIVACY-SENTINEL-UDID-92e1"
SERIAL = "PRIVACY-SENTINEL-SERIAL-92e1"
ECID = "PRIVACY-SENTINEL-ECID-92e1"
PRIVATE_VALUES = (IDENTIFIER, DEVICE_NAME, UDID, SERIAL, ECID)


def physical(*, identifier: str | None = IDENTIFIER, connected: bool = True, suffix: str = "") -> dict:
    value = {
        "hardwareProperties": {
            "reality": "physical",
            "productType": "iPhone17,5",
            "udid": UDID + suffix,
            "serialNumber": SERIAL + suffix,
            "ecid": ECID + suffix,
        },
        "deviceProperties": {
            "name": DEVICE_NAME + suffix,
            "bootState": "booted" if connected else "shutdown",
            "ddiServicesAvailable": connected,
        },
        "connectionProperties": {
            "tunnelState": "connected" if connected else "disconnected",
        },
    }
    if identifier is not None:
        value["identifier"] = identifier + suffix
    return value


def simulator() -> dict:
    return {
        "identifier": "SIMULATOR-ONLY",
        "hardwareProperties": {"reality": "virtual", "productType": "iPhone17,1"},
        "deviceProperties": {
            "name": "Simulator",
            "bootState": "booted",
            "ddiServicesAvailable": True,
        },
        "connectionProperties": {"tunnelState": "connected"},
    }


class HDRDeviceRunnerPrivacyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="imagecraft-hdr-runner-privacy-test-")
        self.base = pathlib.Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.markers = self.base / "markers"
        self.markers.mkdir()
        self._write_mocks()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _write_mocks(self) -> None:
        xcrun = self.bin / "xcrun"
        xcrun.write_text(
            textwrap.dedent(
                f'''\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import stat
                import sys

                case = os.environ["MOCK_DEVICE_CASE"]
                markers = pathlib.Path(os.environ["MOCK_MARKER_DIR"])
                args = sys.argv[1:]
                if args[:3] != ["devicectl", "list", "devices"]:
                    raise SystemExit("unexpected xcrun invocation: " + repr(args))
                output = args[args.index("--json-output") + 1]
                if output not in ("-", "/dev/stdout", "/dev/fd/1"):
                    path = pathlib.Path(output)
                    mode = path.stat().st_mode if path.exists() else 0
                    if not stat.S_ISFIFO(mode):
                        (markers / "regular-json-output").write_text(output)
                        raise SystemExit(91)

                if case == "none":
                    devices = [{physical(connected=False)!r}, {simulator()!r}]
                elif case == "ambiguous":
                    devices = [{physical(suffix="-A")!r}, {physical(suffix="-B")!r}]
                elif case == "malformed":
                    devices = [{physical(identifier=None)!r}]
                elif case in ("selected", "signing"):
                    devices = [{physical()!r}]
                else:
                    raise SystemExit("unknown case: " + case)
                print(json.dumps({{"result": {{"devices": devices}}}}, separators=(",", ":")))
                '''
            )
        )
        xcrun.chmod(0o755)

        xcodebuild = self.bin / "xcodebuild"
        xcodebuild.write_text(
            textwrap.dedent(
                '''\
                #!/usr/bin/env python3
                import os
                import pathlib
                import sys
                import time

                markers = pathlib.Path(os.environ["MOCK_MARKER_DIR"])
                values = os.environ["MOCK_PRIVATE_VALUES"].split("|")
                print("diagnostic " + " ".join(values), flush=True)
                if os.environ["MOCK_DEVICE_CASE"] == "signing":
                    print("No Account for Team 'SENTINEL-TEAM'", flush=True)
                    print("No profiles for 'dev.imagecraft.qualification.hdrdevice' were found", flush=True)
                time.sleep(0.15)
                leaks = []
                for root in pathlib.Path("/private/tmp").glob("imagecraft-hdr-device.*"):
                    if not root.is_dir():
                        continue
                    for path in root.rglob("*"):
                        try:
                            if not path.is_file():
                                continue
                            data = path.read_bytes()
                        except (FileNotFoundError, PermissionError, OSError):
                            continue
                        if any(value.encode() in data for value in values):
                            leaks.append(str(path))
                if leaks:
                    (markers / "private-regular-file-leak").write_text("\\n".join(leaks))
                    raise SystemExit(92)
                (markers / "privacy-scan-passed").write_text("ok")
                raise SystemExit(73)
                '''
            )
        )
        xcodebuild.chmod(0o755)

    def _run(self, case: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(self.bin) + os.pathsep + env.get("PATH", ""),
                "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
                "MOCK_DEVICE_CASE": case,
                "MOCK_MARKER_DIR": str(self.markers),
                "MOCK_PRIVATE_VALUES": "|".join(PRIVATE_VALUES),
            }
        )
        return subprocess.run(
            [str(RUNNER)],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )

    def test_device_inventory_selection_and_build_log_are_memory_only_or_redacted(self) -> None:
        result = self._run("selected")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertTrue((self.markers / "privacy-scan-passed").is_file())
        self.assertFalse((self.markers / "regular-json-output").exists())
        self.assertFalse((self.markers / "private-regular-file-leak").exists())
        combined = result.stdout + result.stderr
        for value in PRIVATE_VALUES:
            self.assertNotIn(value, combined)
        self.assertIn("<redacted-device-value>", combined)

    def test_signing_credentials_failure_is_classified_without_device_private_values(self) -> None:
        result = self._run("signing")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertIn("SIGNING_CREDENTIALS_UNAVAILABLE", result.stderr)
        self.assertIn("No Account for Team", result.stderr)
        for value in PRIVATE_VALUES:
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_zero_connected_physical_device_remains_fail_closed(self) -> None:
        result = self._run("none")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("PHYSICAL_DEVICE_UNAVAILABLE", result.stderr)
        self.assertFalse((self.markers / "privacy-scan-passed").exists())

    def test_multiple_connected_physical_devices_remain_ambiguous(self) -> None:
        result = self._run("ambiguous")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("PHYSICAL_DEVICE_AMBIGUOUS", result.stderr)
        self.assertFalse((self.markers / "privacy-scan-passed").exists())

    def test_missing_identifier_remains_selection_failure(self) -> None:
        result = self._run("malformed")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertIn("PHYSICAL_DEVICE_SELECTION_FAILED", result.stderr)
        self.assertFalse((self.markers / "privacy-scan-passed").exists())

    def test_runner_has_no_regular_private_selection_files(self) -> None:
        text = RUNNER.read_text()
        self.assertNotIn("device-selection.json", text)
        self.assertNotIn("devices.json", text)
        self.assertIn("--json-output /dev/stdout", text)
        self.assertIn("DEVICE_SELECTION_JSON", text)
        self.assertIn("run_private_logged", text)

    def test_host_validator_tracks_probe_codec_implementation_version(self) -> None:
        runner_text = RUNNER.read_text()
        probe_text = (ROOT / "DeviceQualification/HDRDeviceProbe/HDRDeviceProbeApp.swift").read_text()
        runner_versions = re.findall(
            r'data\.get\("codecImplementationVersion"\) != ([0-9]+)', runner_text
        )
        probe_versions = re.findall(
            r'decoder\.codecDescriptor\.implementationVersion == ([0-9]+)', probe_text
        )
        self.assertEqual(len(runner_versions), 1, runner_versions)
        self.assertEqual(len(probe_versions), 1, probe_versions)
        self.assertEqual(runner_versions[0], probe_versions[0])


if __name__ == "__main__":
    unittest.main()
