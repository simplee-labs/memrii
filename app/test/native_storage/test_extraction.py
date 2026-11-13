"""Check that harness extraction fails closed when production seams drift."""

import re
import unittest

from run import APP, HERE, SOURCE, notification_source, replace_seam, section


def after(text, start, end):
    """The text between the first [start] and the next [end]; fails if either is missing."""
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class ExtractionTest(unittest.TestCase):
    def test_notification_mode_is_independent_of_storage_and_pigeon(self):
        source = SOURCE.read_text(encoding="utf-8")
        source = source[:source.index("    inner class StorageDownloadSession(")]
        template = (HERE / "NotificationSubscriptionStubs.kt").read_text(encoding="utf-8")
        result = notification_source(source, template)
        self.assertIn("fun subscribeCharacteristic", result)
        self.assertIn("fun processNextCommand", result)
        self.assertIn("fun writeCharacteristic", result)
        self.assertIn("fun <T> answerInFlight", result)
        self.assertNotIn("// PRODUCTION_", result)

    def test_missing_duplicate_and_reversed_boundaries_fail(self):
        for source in ("start body", "start start end", "start end end", "end start"):
            with self.subTest(source=source), self.assertRaisesRegex(RuntimeError, "seam changed"):
                section(source, "start", "end", "test")

    def test_missing_or_duplicate_placeholders_fail(self):
        for template in ("none", "marker marker"):
            with self.subTest(template=template), self.assertRaisesRegex(RuntimeError, "seam changed"):
                replace_seam(template, "marker", "body")

    def test_duplicate_descriptor_callback_fails(self):
        source = SOURCE.read_text(encoding="utf-8")
        source += "\n        override fun onDescriptorWrite(fake: Int) {\n        }"
        template = (HERE / "NotificationSubscriptionStubs.kt").read_text(encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Descriptor callback seam changed"):
            notification_source(source, template)


class PigeonAgreementTest(unittest.TestCase):
    """The generated Dart and Kotlin sides of downloadStorageChunk must agree: the native
    harness and the Dart tests each exercise only their own side's codec."""

    kotlin = SOURCE.with_name("PigeonCommunicator.g.kt").read_text(encoding="utf-8")
    dart = (APP / "lib/gen/pigeon_communicator.g.dart").read_text(encoding="utf-8")

    def test_result_fields_are_in_the_same_order(self):
        expected = [("acceptedEnd", "0"), ("echoedAck", "1")]
        # Read on each side...
        kotlin = re.findall(r"val (\w+) = pigeonVar_list\[(\d+)\]",
                            after(self.kotlin, "fun fromList(pigeonVar_list: List<Any?>): StorageChunkResult", "}"))
        dart = re.findall(r"(\w+): result\[(\d+)\]", after(self.dart, "static StorageChunkResult decode", "}"))
        self.assertEqual(kotlin, expected)
        self.assertEqual(dart, expected)
        # ...and written on each side, in the order it is read.
        kotlin_class = after(self.kotlin, "data class StorageChunkResult", "override fun equals")
        kotlin_out = re.findall(r"(\w+),", after(kotlin_class, "return listOf(", ")"))
        dart_class = after(self.dart, "class StorageChunkResult", "static StorageChunkResult decode")
        dart_out = re.findall(r"(\w+),", after(dart_class, "return <Object?>[", "]"))
        self.assertEqual(kotlin_out, [name for name, _ in expected])
        self.assertEqual(dart_out, [name for name, _ in expected])

    def test_result_uses_the_same_codec_type(self):
        ids = {
            re.search(r"is StorageChunkResult -> \{\s*stream\.write\((\d+)\)", self.kotlin).group(1),
            re.search(r"(\d+)\.toByte\(\) -> \{\s*return \(readValue\(buffer\) as\? List<Any\?>\)\?\.let \{"
                      r"\s*StorageChunkResult\.fromList", self.kotlin).group(1),
            re.search(r"value is StorageChunkResult\) \{\s*buffer\.putUint8\((\d+)\)", self.dart).group(1),
            re.search(r"case (\d+):\s*return StorageChunkResult\.decode", self.dart).group(1),
        }
        self.assertEqual(len(ids), 1, ids)

    def test_arguments_are_in_the_same_order(self):
        kotlin = re.findall(r"val (\w+)Arg = args\[(\d+)\]",
                            after(self.kotlin, '"dev.flutter.pigeon.omi_pigeon.BleHostApi.downloadStorageChunk',
                                  "api.downloadStorageChunk("))
        dart = after(self.dart, "'dev.flutter.pigeon.omi_pigeon.BleHostApi.downloadStorageChunk", "]);")
        sent = re.search(r"send\(<Object\?>\[([^\]]*)$", dart).group(1).replace("\n", " ").split(",")
        self.assertEqual([name for name, _ in kotlin], [name.strip() for name in sent])
        self.assertEqual([index for _, index in kotlin], [str(i) for i in range(len(kotlin))])
        # The host handler passes them to the API in the same order.
        call = re.search(r"api\.downloadStorageChunk\(([^)]*)\)", self.kotlin).group(1)
        self.assertEqual([arg.strip() for arg in call.split(",")], [name + "Arg" for name, _ in kotlin])


if __name__ == "__main__":
    unittest.main()
