import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/browser/object_entry.dart';
import 'package:z_pill/core/ptpip/object_format.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/transfer/object_downloader.dart';
import '../ptp/ptp_session_harness.dart';

import 'package:z_pill/core/transfer/z30_transfer_profile.dart';

PtpResult ok([Uint8List? data, List<int> params = const []]) =>
    PtpResult(responseCode: 0x2001, data: data, params: params);
void main() {
  for (final profile in Z30TransferProfile.values) {
    test('${profile.name} transfers full bytes at requested block size',
        () async {
      final kib = profile.chunkKiB;
      final hs = profile.highSpeed;
      final dir = await Directory.systemTemp.createTemp('z30-profile-');
      addTearDown(() => dir.delete(recursive: true));
      final fake = FakePtpTransport();
      final bytes = Uint8List.fromList(
          List.generate(2 * 1024 * 1024 + 7, (i) => i % 251));
      if (hs) {
        fake.reply(ok(Uint8List.fromList([0])));
        fake.reply(ok());
      }
      var block = (kib == 0 ? (hs ? 1024 : 256) : kib) * 1024;
      for (var offset = 0; offset < bytes.length;) {
        final count = math.min(block, bytes.length - offset);
        fake.reply(ok(Uint8List.sublistView(bytes, offset, offset + count),
            hs ? [count, offset, 0] : []));
        offset += count;
        if (kib == 0 && !hs) block = 512 * 1024;
      }
      if (hs) {
        fake.reply(ok());
        fake.reply(ok());
      }
      final dl = ObjectDownloader(
          session: PtpSession(transport: fake),
          z30StartupProfile: Future.value(profile));
      final result = await dl.download(
          ObjectEntry(
              handle: 1,
              name: 'test.JPG',
              sizeInBytes: bytes.length,
              kind: ObjectKind.image,
              requiresExtendedRead: true),
          targetDir: dir.path);
      expect(await File(result.path).readAsBytes(), bytes);
      expect(fake.script, isEmpty);
      expect(
          fake.requests
              .where((r) => r.opcode == (hs ? 0x9400 : 0x9431))
              .first
              .params[hs ? 1 : 3],
          (kib == 0 ? (hs ? 1024 : 256) : kib) * 1024);
    });
  }
  test('high speed rejection restores mode and falls back', () async {
    final dir = await Directory.systemTemp.createTemp('z30-fallback-');
    addTearDown(() => dir.delete(recursive: true));
    final fake = FakePtpTransport()
      ..reply(ok(Uint8List.fromList([0])))
      ..reply(ok())
      ..reply(const PtpResult(responseCode: 0x2005))
      ..reply(ok())
      ..reply(ok())
      ..reply(ok(Uint8List.fromList([1, 2, 3])));
    final dl = ObjectDownloader(
        session: PtpSession(transport: fake),
        z30StartupProfile: Future.value(Z30TransferProfile.highspeed));
    final result = await dl.download(
        const ObjectEntry(
            handle: 1,
            name: 'test.JPG',
            sizeInBytes: 3,
            kind: ObjectKind.image,
            requiresExtendedRead: true),
        targetDir: dir.path);
    expect(await File(result.path).readAsBytes(), [1, 2, 3]);
    expect(fake.requests.map((r) => r.opcode),
        [0x1015, 0x9435, 0x9400, 0x9400, 0x9435, 0x9431]);
  });
}
