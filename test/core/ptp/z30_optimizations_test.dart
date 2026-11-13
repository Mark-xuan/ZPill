import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:z_pill/core/ptp/ptp_session.dart';
import 'package:z_pill/core/ptp/ptp_transport.dart';
import 'package:z_pill/core/ptp/operation_codes.dart';
import 'package:z_pill/core/utils/priority_work_queue.dart';
import 'package:z_pill/core/media/jpeg_orientation.dart';
import 'ptp_session_harness.dart';

PtpResult ok([List<int>? data, List<int> params = const []]) => PtpResult(
    responseCode: PtpResponseCode.ok,
    data: data == null ? null : Uint8List.fromList(data),
    params: params);

void main() {
  test(
      'foreground passes queued background work without interrupting active work',
      () async {
    final q = PriorityWorkQueue();
    final gate = Completer<void>();
    final order = <int>[];
    final first = q.run(() async {
      await gate.future;
      order.add(1);
    });
    final background = PriorityWorkQueue.background(() => q.run(() async {
          order.add(3);
        }));
    final foreground = q.run(() async {
      order.add(2);
    });
    gate.complete();
    await Future.wait([first, background, foreground]);
    expect(order, [1, 2, 3]);
  });

  test(
      'head cache merges concurrent reads and fetches only missing suffix; close invalidates',
      () async {
    final gate = Completer<void>();
    final fake = FakePtpTransport()
      ..replyAfter(gate.future, ok([1, 2]))
      ..reply(ok([3, 4]));
    final session = PtpSession(transport: fake);
    final a = session.getObjectHead(1, 2);
    final b = session.getObjectHead(1, 4);
    gate.complete();
    expect(await a, [1, 2]);
    expect(await b, [1, 2, 3, 4]);
    expect(fake.requests[1].params, [1, 2, 0, 2, 0]);
    expect(await session.getObjectHead(1, 3), [1, 2, 3]);
    expect(fake.requests.length, 2);
    await session.close();
    fake.reply(ok([9, 8]));
    expect(await session.getObjectHead(1, 2), [9, 8]);
    expect(fake.requests.length, 3);
  });

  test(
      'high speed retains exclusive session ownership through terminate and restore',
      () async {
    final fake = FakePtpTransport()
      ..reply(ok([0]))
      ..reply(ok())
      ..reply(ok([1, 2], [2, 0, 0]))
      ..reply(ok([3, 4], [2, 2, 0]))
      ..reply(ok())
      ..reply(ok())
      ..reply(ok([255, 216, 255, 217]));
    final session = PtpSession(transport: fake);
    final bytes = <int>[];
    final transfer = session.getObjectHighSpeed(1, 4, 2,
        onData: bytes.addAll, shouldStop: () => false);
    final thumb = session.getThumb(1);
    await transfer;
    await thumb;
    expect(bytes, [1, 2, 3, 4]);
    expect(fake.requests.map((r) => r.opcode),
        [0x1015, 0x9435, 0x9400, 0x9400, 0x9400, 0x9435, 0x100a]);
    expect(fake.requests[4].params, [1, 0, 1]);
    expect(fake.requests[5].params, [0]);
  });

  test('high speed rejects cursor mismatch, terminates and restores mode',
      () async {
    final fake = FakePtpTransport()
      ..reply(ok([0]))
      ..reply(ok())
      ..reply(ok([1, 2], [2, 12, 0]))
      ..reply(ok())
      ..reply(ok());
    final session = PtpSession(transport: fake);
    final bytes = <int>[];
    await expectLater(
        session.getObjectHighSpeed(1, 2, 2,
            onData: bytes.addAll, shouldStop: () => false),
        throwsFormatException);
    expect(bytes, isEmpty);
    expect(fake.requests.last.params, [0]);
  });

  test('EXIF thumbnail beyond prefix is read by bounded TIFF offsets',
      () async {
    final file = Uint8List(6000);
    final b = ByteData.sublistView(file);
    file.setRange(
        0, 12, [255, 216, 255, 225, 0x17, 0x6c, 69, 120, 105, 102, 0, 0]);
    const base = 12;
    file[base] = 73;
    file[base + 1] = 73;
    b.setUint16(base + 2, 42, Endian.little);
    b.setUint32(base + 4, 8, Endian.little);
    b.setUint16(base + 8, 0, Endian.little);
    b.setUint32(base + 10, 14, Endian.little);
    b.setUint16(base + 14, 2, Endian.little);
    for (var i = 0; i < 2; i++) {
      final at = base + 16 + i * 12;
      b.setUint16(at, 0x201 + i, Endian.little);
      b.setUint16(at + 2, 4, Endian.little);
      b.setUint32(at + 4, 1, Endian.little);
      b.setUint32(at + 8, i == 0 ? 5000 : 4, Endian.little);
    }
    file.setRange(base + 5000, base + 5004, [255, 216, 255, 217]);
    final ranges = <(int, int)>[];
    final thumbnail = await readEmbeddedJpegThumbnail(
        Uint8List.sublistView(file, 0, 4096), file.length, (o, n) async {
      ranges.add((o, n));
      return Uint8List.sublistView(file, o, o + n);
    });
    expect(thumbnail, [255, 216, 255, 217]);
    expect(ranges, [(5012, 4)]);
    b.setUint32(base + 24, 999999, Endian.little);
    expect(
        await readEmbeddedJpegThumbnail(file, file.length,
            (o, n) async => throw StateError('out of range')),
        isNull);
  });
}
