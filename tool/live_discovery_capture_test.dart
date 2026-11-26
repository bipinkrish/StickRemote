import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stickremote/main.dart';
import 'package:stickremote/src/receiver.dart';
import 'package:stickremote/src/discovery.dart';

// The widget-test HTTP client normally serves a synthetic HTTP 400.
class _LanHttp extends HttpOverrides {}

class _LiveFeed extends Discovery {
  final controller = StreamController<Stick>();
  @override
  Stream<Stick> scan() => controller.stream;
}

void main() {
  testWidgets('Capture a real LAN discovery pass', (tester) async {
    final sdk = Platform.environment['FLUTTER_ROOT']!;
    final fonts = '$sdk/bin/cache/artifacts/material_fonts';
    Future<ByteData> readFont(String name) async =>
        ByteData.sublistView(await File('$fonts/$name').readAsBytes());
    await tester.runAsync(() async {
      final text = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        text.addFont(readFont('Roboto-$weight.ttf'));
      }
      await text.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(readFont('MaterialIcons-Regular.otf'))).load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 820);
    addTearDown(tester.view.reset);
    final feed = _LiveFeed();
    final key = GlobalKey();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, (
      call,
    ) async {
      if (call.method == 'read') return null;
      throw StateError(
        'Unexpected platform call during discovery: ${call.method}',
      );
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: StickRemoteApp(home: DevicePage(discovery: feed)),
      ),
    );
    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 100));
      final layer =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await layer.toImage(pixelRatio: 2);
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File('screenshots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        image.dispose();
      });
    }

    await tester.pump();
    final found = <Stick>[];
    late Future<void> pass;
    await tester.runAsync(() async {
      pass = HttpOverrides.runWithHttpOverrides(() async {
        await for (final device in Discovery().scan()) {
          found.add(device);
          feed.controller.add(device);
          stdout.writeln('Fire TV found: ${device.name} (${device.host})');
        }
        unawaited(feed.controller.close());
      }, _LanHttp());
    });
    expect(find.text('Searching for devices…'), findsOneWidget);
    await capture('live-searching');
    await tester.runAsync(() => pass);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.text(found.isEmpty ? 'No Fire TVs found' : 'Available devices'),
      findsOneWidget,
    );
    await capture('live-result');
  });
}
