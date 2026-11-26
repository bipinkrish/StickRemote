// Run with flutter test --no-pub tool/capture_screens_test.dart.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stickremote/main.dart';
import 'package:stickremote/src/receiver.dart';
import '../test/widget_test.dart' show AwakeReceiver, LocalDiscovery;

void main() {
  testWidgets('Capture device, pairing and remote screens', (tester) async {
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
    final key = GlobalKey();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, (
      call,
    ) async {
      if (call.method != 'request') return null;
      final path = call.arguments['path'] as String;
      return {
        'status': 200,
        'body': path.endsWith('/pin/verify') ? '{"description":"demo"}' : '{}',
      };
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: StickRemoteApp(
          home: DevicePage(
            discovery: LocalDiscovery(),
            receiverFor: AwakeReceiver.new,
          ),
        ),
      ),
    );
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
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

    await capture('devices');
    await tester.tap(find.text('Living room'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0123');
    await capture('pairing');
    await tester.tap(find.text('Pair remote'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Select'), findsOneWidget);
    await capture('volume-check');
    await tester.tap(find.text('Volume setup'));
    await capture('audio-setup');
    await tester.tap(find.text('Try Volume Up'));
    await capture('volume-confirmation');
    await tester.tap(find.text('No change'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Samsung').last);
    await capture('volume-brand-help');
    await tester.tap(find.text('Try Volume Up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try Mute'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes'));
    await capture('remote');
    await tester.tap(find.byTooltip('Use touchpad'));
    await capture('touchpad');
  });
}
